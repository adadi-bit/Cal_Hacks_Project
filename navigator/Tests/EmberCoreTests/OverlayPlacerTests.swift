import Foundation
import CoreGraphics
import Testing
@testable import EmberCore

@Suite struct OverlayPlacerTests {
    let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)

    @Test func segmentRectIntersection() throws {
        let r = CGRect(x: 100, y: 100, width: 50, height: 20)
        #expect(OverlayPlacer.segment(CGPoint(x: 0, y: 110), CGPoint(x: 300, y: 110), intersects: r))     // straight through
        #expect(OverlayPlacer.segment(CGPoint(x: 90, y: 90), CGPoint(x: 160, y: 130), intersects: r))     // diagonal through
        #expect(!OverlayPlacer.segment(CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 50), intersects: r))       // misses above
        #expect(!OverlayPlacer.segment(CGPoint(x: 0, y: 130), CGPoint(x: 90, y: 300), intersects: r))     // misses below-left
        #expect(OverlayPlacer.segment(CGPoint(x: 120, y: 105), CGPoint(x: 400, y: 400), intersects: r))   // starts inside
    }

    @Test func pillNeverCrossesTheRoute() throws {
        var p = OverlayPlacer(bounds: bounds, routeClearance: 8)
        p.addRoute([CGPoint(x: 0, y: 150), CGPoint(x: 300, y: 150)])          // horizontal route across the middle
        let r = p.place(size: CGSize(width: 120, height: 30), anchor: CGPoint(x: 150, y: 150), offset: 10,
                        sides: OverlayPlacer.sides(forSegmentFrom: CGPoint(x: 0, y: 150), to: CGPoint(x: 300, y: 150)))
        let rect = try #require(r)
        #expect(rect.minY >= 158 || rect.maxY <= 142, "pill is clear of the 8 pt clearance band")
        #expect(!OverlayPlacer.polyline([CGPoint(x: 0, y: 150), CGPoint(x: 300, y: 150)], intersects: rect.insetBy(dx: -8, dy: -8)))
    }

    @Test func pillsNeverOverlapEachOther() throws {
        var p = OverlayPlacer(bounds: bounds)
        let a = CGPoint(x: 150, y: 150)
        let r1Opt = p.place(size: CGSize(width: 80, height: 24), anchor: a, offset: 6)
        let r1 = try #require(r1Opt)
        let r2Opt = p.place(size: CGSize(width: 80, height: 24), anchor: a, offset: 6)
        let r2 = try #require(r2Opt)
        let r3Opt = p.place(size: CGSize(width: 80, height: 24), anchor: a, offset: 6)
        let r3 = try #require(r3Opt)
        #expect(!r1.insetBy(dx: -4, dy: -4).intersects(r2))
        #expect(!r1.insetBy(dx: -4, dy: -4).intersects(r3))
        #expect(!r2.insetBy(dx: -4, dy: -4).intersects(r3))
    }

    @Test func pillAvoidsTheUserMarker() throws {
        var p = OverlayPlacer(bounds: bounds)
        let you = CGRect(x: 130, y: 130, width: 40, height: 40)
        p.addObstacle(you)
        let rOpt = p.place(size: CGSize(width: 60, height: 24), anchor: CGPoint(x: 150, y: 150), offset: 4)
        let r = try #require(rOpt)
        #expect(!r.insetBy(dx: -4, dy: -4).intersects(you))
    }

    @Test func pillIsClampedInsideTheMapNeverClipped() throws {
        var p = OverlayPlacer(bounds: bounds)
        let rOpt = p.place(size: CGSize(width: 200, height: 30), anchor: CGPoint(x: 5, y: 5), offset: 4)
        let r = try #require(rOpt)
        #expect(bounds.contains(r))
        #expect(r.minX >= 0 && r.minY >= 0)
        let r2Opt = p.place(size: CGSize(width: 200, height: 30), anchor: CGPoint(x: 295, y: 295), offset: 4)
        let r2 = try #require(r2Opt)
        #expect(bounds.contains(r2))
    }

    @Test func hiddenWhenNoFreeSpot() throws {
        var p = OverlayPlacer(bounds: CGRect(x: 0, y: 0, width: 100, height: 60), routeClearance: 6)
        p.addRoute([CGPoint(x: 0, y: 30), CGPoint(x: 100, y: 30)])
        p.addObstacle(CGRect(x: 0, y: 0, width: 100, height: 24))              // scale bar strip takes the top
        p.addObstacle(CGRect(x: 0, y: 36, width: 100, height: 24))             // something fills the bottom
        #expect(p.place(size: CGSize(width: 80, height: 20), anchor: CGPoint(x: 50, y: 30), offset: 4) == nil)
    }

    @Test func priorityIsCallerOrder_firstPlacedKeepsItsSpot() throws {
        var p = OverlayPlacer(bounds: bounds)
        let refugeOpt = p.place(size: CGSize(width: 160, height: 30), anchor: CGPoint(x: 150, y: 60), offset: 8, sides: [.below])
        let refuge = try #require(refugeOpt)
        let street = p.place(size: CGSize(width: 90, height: 24), anchor: CGPoint(x: 150, y: 60), offset: 8, sides: [.below, .above])
        #expect(refuge.minY == 68)
        let s = try #require(street)
        #expect(!s.insetBy(dx: -4, dy: -4).intersects(refuge))
        #expect(s.maxY <= 60 - 8, "the lower-priority street label moved to the other side")
    }

    @Test func sidesFollowTheSegmentDirection() throws {
        #expect(OverlayPlacer.sides(forSegmentFrom: .zero, to: CGPoint(x: 100, y: 10)).first == .below)
        #expect(OverlayPlacer.sides(forSegmentFrom: .zero, to: CGPoint(x: 10, y: 100)).first == .right)
    }

    @Test func refugeShortNameNeverTruncates() throws {
        var r = Refuge(id: "r", name: "the parking lot on Nunneley Road", centroid: [-121.6, 39.75], entryPoints: [], score: 50)
        #expect(r.shortName == "Nunneley Road lot")
        r.name = "the Paradise Performing Art Center lot"
        #expect(r.shortName == "Paradise Performing Art Center lot")
        r.name = "Terry Ashe Park"
        #expect(r.shortName == "Terry Ashe Park")
    }
}
