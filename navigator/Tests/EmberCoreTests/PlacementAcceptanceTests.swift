import Foundation
import CoreGraphics
import Testing
@testable import EmberCore

/// The owner's acceptance cases (coordinates read off the v3 screenshots; cases written by engineer #1 for his
/// LabelPlacer, ported to OverlayPlacer). Each one was a visible defect; each must now be impossible.
@Suite struct PlacementAcceptanceTests {
    func clear(_ route: [CGPoint], _ r: CGRect, _ d: CGFloat) -> Bool { !OverlayPlacer.polyline(route, intersects: r.insetBy(dx: -d, dy: -d)) }

    /// Overview: the route came down from the refuge badge straight through the name pill, and "Clark Road" sat on the route.
    @Test func overviewRouteNeverRunsThroughAPill() throws {
        var p = OverlayPlacer(bounds: CGRect(x: 6, y: 6, width: 806, height: 610), routeClearance: 10, gap: 8)
        let route = [(575, 60), (590, 110), (600, 230), (575, 300), (320, 345), (325, 400), (300, 500), (260, 600)].map { CGPoint(x: $0.0, y: $0.1) }
        p.addRoute(route)
        p.addObstacle(CGRect(x: 575 - 34, y: 60 - 34, width: 68, height: 68))              // badge
        let refugeOpt = p.place(size: CGSize(width: 300, height: 60), anchor: CGPoint(x: 575, y: 60), offset: 40,
                                sides: [.below, .above, .right, .left], maxDistance: 96)
        let refuge = try #require(refugeOpt)
        #expect(clear(route, refuge, 10), "route through refuge pill")
        #expect(refuge.minX >= 6 && refuge.maxX <= 812)
        #expect(refuge.maxX < 575 - 10, "moved to the left of the badge, clear of the route")
        // "Clark Road" at (650, 270) on the vertical leg: it relocates clear of the route or hides, never lies on it.
        if let clark = p.place(size: CGSize(width: 200, height: 56), anchor: CGPoint(x: 597, y: 270), offset: 10, sides: [.right, .left], maxDistance: 52) {
            #expect(clear(route, clark, 10), "Clark Road on the route")
            #expect(!clark.insetBy(dx: -8, dy: -8).intersects(refuge))
        }
        var wide = OverlayPlacer(bounds: CGRect(x: 6, y: 6, width: 1088, height: 610), routeClearance: 10, gap: 8)
        wide.addRoute(route)
        let clarkWideOpt = wide.place(size: CGSize(width: 200, height: 56), anchor: CGPoint(x: 597, y: 270), offset: 10, sides: [.right, .left], maxDistance: 52)
        let clarkWide = try #require(clarkWideOpt)
        #expect(clarkWide.minX >= 597 + 10, "relocated to the right of the leg")
        #expect(clear(route, clarkWide, 10))
    }

    /// 20 m follow: the pointer pill and the scale bar were cut at the left edge; the pill lay across the route; the
    /// Start pill covered the you-arrow.
    @Test func followViewPillsStayInsideAndOffTheArrow() throws {
        var p = OverlayPlacer(bounds: CGRect(x: 12, y: 12, width: 726, height: 606), routeClearance: 12, gap: 8)
        let route = [CGPoint(x: 345, y: 630), CGPoint(x: 345, y: 0)]            // straight up the middle, under the arrow
        p.addRoute(route)
        let halo = CGRect(x: 345 - 48, y: 530 - 48, width: 96, height: 96)
        p.addObstacle(halo)                                                      // you-arrow halo
        p.addObstacle(CGRect(x: 0, y: 0, width: 240, height: 76))                // scale bar
        p.addObstacle(CGRect(x: 750 - 96, y: 0, width: 96, height: 96))          // compass
        // A 540-wide pointer pill cannot clear a centre route on a 750 pt map: hidden, never drawn across the line.
        let edge = CGPoint(x: 12, y: 44)
        #expect(p.place(size: CGSize(width: 540, height: 60), anchor: edge, offset: 0, maxDistance: 40) == nil,
                "a pill that cannot clear the route is hidden, not drawn over it")
        // A short one (the short refuge name) finds a spot inside the map, off the route.
        let shortOpt = p.place(size: CGSize(width: 260, height: 60), anchor: edge, offset: 0, maxDistance: 40)
        let short = try #require(shortOpt)
        #expect(p.bounds.contains(short) && clear(route, short, 12))
        // The Start dot is under the arrow: its pill must not touch the halo, and must still appear (further out).
        p.addObstacle(CGRect(x: 345 - 16, y: 530 - 16, width: 32, height: 32))
        let startOpt = p.place(size: CGSize(width: 110, height: 50), anchor: CGPoint(x: 345, y: 530), offset: 26,
                               sides: [.right, .left, .below, .above], maxDistance: 82)
        let start = try #require(startOpt)
        #expect(!start.insetBy(dx: -8, dy: -8).intersects(halo), "Start pill over the arrow")
        #expect(clear(route, start, 12))
        #expect(start.maxX <= 738 && start.maxY <= 618)
    }

    @Test func shortRefugeNamesAreNeverCut() {
        func short(_ n: String) -> String { Refuge(id: "r", name: n, centroid: [0, 0], entryPoints: [], score: 1).shortName }
        #expect(short("the parking lot on Nunneley Road") == "Nunneley Road lot")
        #expect(short("the Paradise Performing Arts Center lot") == "Paradise Performing Arts Center lot")
        #expect(short("Terry Ashe Park") == "Terry Ashe Park")
        #expect(short("the lot at Feather River Hospital") == "Feather River Hospital lot")
    }
}
