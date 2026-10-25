import Testing
import Foundation
import CoreGraphics
@testable import EmberCore

/// Owner hard rule: no route pixel under any label, pill, pin, scale bar, compass, Re-centre or the refuge outline,
/// anywhere. `OverlayAudit` rasterises a map's route against every overlay rect; these tests pin the rule with the
/// owner's two phone screenshots as cases and check the placer's relocation/trim/hide behaviour fixes each.
@Suite struct OverlayAuditTests {
    /// Owner screenshot 1 (Choose, "Or" thumbnail): the refuge name box sat across the route, and the route ran into
    /// the refuge outline. Audit must flag both.
    @Test func ownerThumbnailCaseIsFlagged() {
        let route = [CGPoint(x: 30, y: 110), CGPoint(x: 60, y: 80), CGPoint(x: 60, y: 60), CGPoint(x: 95, y: 40), CGPoint(x: 100, y: 20)]
        let rec = OverlayAuditRecord(id: "owner-thumb", size: CGSize(width: 130, height: 120), route: route, routeWidth: 10,
                                     overlays: [.init(name: "refuge pill", rect: CGRect(x: 15, y: 48, width: 110, height: 30))],
                                     outline: [CGPoint(x: 85, y: 30), CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 15), CGPoint(x: 85, y: 15)])
        let f = OverlayAudit.findings(rec)
        #expect(f.contains { $0.kind == "route-under-overlay" && $0.b == "refuge pill" })
        #expect(f.contains { $0.kind == "route-touches-outline" })
    }

    /// Owner screenshot 2 (follow view): the route ran under the scale bar at top-left and the Re-centre button was
    /// clipped at the bottom edge.
    @Test func ownerFollowCaseIsFlagged() {
        let route = [CGPoint(x: 20, y: 0), CGPoint(x: 230, y: 160), CGPoint(x: 320, y: 230)]
        let rec = OverlayAuditRecord(id: "owner-follow", size: CGSize(width: 350, height: 300), route: route, routeWidth: 14,
                                     overlays: [.init(name: "scale bar", rect: CGRect(x: 8, y: 8, width: 60, height: 24)),
                                                .init(name: "Re-centre", rect: CGRect(x: 160, y: 270, width: 150, height: 56))],
                                     outline: nil)
        let f = OverlayAudit.findings(rec)
        #expect(f.contains { $0.kind == "route-under-overlay" && $0.b == "scale bar" })
        #expect(f.contains { $0.kind == "clipped-at-edge" && $0.a == "Re-centre" })
    }

    /// The same follow view through the placer: the scale bar moves to a free corner (bottom-left) and Re-centre to
    /// a free corner inside the map; the audit is then clean.
    @Test func chromeRelocatesOffTheRoute() {
        let size = CGSize(width: 350, height: 300)
        var placer = OverlayPlacer(bounds: CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5), routeClearance: 10, gap: 4)
        let route = [CGPoint(x: 20, y: 0), CGPoint(x: 230, y: 160), CGPoint(x: 320, y: 230)]
        placer.addRoute(route)
        let rc = placer.placeChrome(size: CGSize(width: 150, height: 44), corners: [.bottomCentre, .bottomRight, .bottomLeft, .topCentre], margin: 10)
        let sb = placer.placeChrome(size: CGSize(width: 60, height: 24), corners: [.topLeft, .bottomLeft, .topRight, .bottomRight], margin: 8)
        let cp = placer.placeChrome(size: CGSize(width: 30, height: 30), corners: [.topRight, .topLeft, .bottomRight, .bottomLeft], margin: 8)
        #expect(rc != nil && sb != nil && cp != nil)
        #expect(sb?.origin == CGPoint(x: 13, y: 263))            // top-left was on the route: moved to bottom-left
        #expect(rc.map { CGRect(origin: .zero, size: size).contains($0) } == true)
        var items: [OverlayAuditRecord.Item] = []
        if let rc { items.append(.init(name: "Re-centre", rect: rc)) }
        if let sb { items.append(.init(name: "scale bar", rect: sb)) }
        if let cp { items.append(.init(name: "compass", rect: cp)) }
        #expect(OverlayAudit.findings(OverlayAuditRecord(id: "fixed", size: size, route: route, routeWidth: 14, overlays: items, outline: nil)).isEmpty)
    }

    /// Chrome with no free corner is hidden, never drawn over the route.
    @Test func chromeHidesWhenEveryCornerIsOnTheRoute() {
        let size = CGSize(width: 100, height: 100)
        var placer = OverlayPlacer(bounds: CGRect(origin: .zero, size: size), routeClearance: 10, gap: 4)
        placer.addRoute([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)])
        placer.addRoute([CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)])
        placer.addRoute([CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100)])
        #expect(placer.placeChrome(size: CGSize(width: 40, height: 20), corners: OverlayPlacer.Corner.allCases, margin: 4) == nil)
    }

    /// The route stops short of the refuge outline: after the trim no route pixel touches the ring.
    @Test func routeIsTrimmedAtTheRefugeOutline() {
        let ring = [CGPoint(x: 80, y: 20), CGPoint(x: 120, y: 20), CGPoint(x: 120, y: 60), CGPoint(x: 80, y: 60)]
        let route = [CGPoint(x: 10, y: 100), CGPoint(x: 60, y: 40), CGPoint(x: 100, y: 40)]   // ends inside the lot
        let trimmed = OverlayPlacer.trim(route, outside: ring, clearance: 8)
        #expect(trimmed.count == 3)
        #expect(trimmed.last!.x < 80 - 7.9)
        let rec = OverlayAuditRecord(id: "trim", size: CGSize(width: 150, height: 120), route: trimmed, routeWidth: 14, overlays: [], outline: ring)
        #expect(OverlayAudit.findings(rec).isEmpty)
        let untrimmed = OverlayAuditRecord(id: "raw", size: CGSize(width: 150, height: 120), route: route, routeWidth: 14, overlays: [], outline: ring)
        #expect(OverlayAudit.findings(untrimmed).contains { $0.kind == "route-touches-outline" })
    }

    @Test func trimLeavesRoutesThatNeverReachTheRing() {
        let ring = [CGPoint(x: 80, y: 20), CGPoint(x: 120, y: 20), CGPoint(x: 120, y: 60), CGPoint(x: 80, y: 60)]
        let route = [CGPoint(x: 10, y: 100), CGPoint(x: 60, y: 90)]
        #expect(OverlayPlacer.trim(route, outside: ring, clearance: 8) == route)
        #expect(OverlayPlacer.polygon(ring, contains: CGPoint(x: 100, y: 40)))
        #expect(!OverlayPlacer.polygon(ring, contains: CGPoint(x: 10, y: 40)))
    }

    /// Every map the simulator drew (Choose overview, 'Or' thumbnail, follow at each zoom, paused with Re-centre,
    /// both palettes, default and AX5) is replayed through the audit: one shared pixel fails the build.
    @Test func shippedMapsHaveNoRouteUnderAnyOverlay() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/overlay_audit")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        #expect(files.count >= 8, "expected the simulator audit dumps in \(dir.path)")
        var worstImagery = 0.0
        for f in files {
            let rec = try JSONDecoder().decode(OverlayAuditRecord.self, from: Data(contentsOf: f))
            let findings = OverlayAudit.findings(rec)
            #expect(findings.isEmpty, "\(f.lastPathComponent): \(findings)")
            worstImagery = max(worstImagery, rec.imageryScale ?? 0)
        }
        // Owner rule #3: imagery scale is recorded for every shipped map (the report states the worst value); the
        // satellite look is the owner's choice, so this does not gate on 1.5 yet.
        print("overlay audit: worst imagery upscale \(worstImagery)")
    }
}
