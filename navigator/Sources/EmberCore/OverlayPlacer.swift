import Foundation
import CoreGraphics

/// Places map overlays (name pills, the Start label, street labels) so that none of them touches the route, another
/// overlay, the user marker or the map edge. The route is drawn first; every pill is drawn above it, and a pill that
/// has no free spot along its anchor is hidden rather than drawn over something. Pure geometry so it can be tested.
public struct OverlayPlacer: Sendable {
    public enum Side: CaseIterable, Sendable { case right, left, below, above }

    public let bounds: CGRect
    /// Half the route's drawn width plus a safety margin: a pill must stay this far from the route centre line.
    public var routeClearance: CGFloat
    /// Gap kept between two overlays.
    public var gap: CGFloat
    public private(set) var placed: [CGRect] = []
    public private(set) var obstacles: [CGRect] = []
    private var routes: [[CGPoint]] = []

    public init(bounds: CGRect, routeClearance: CGFloat = 10, gap: CGFloat = 4) {
        self.bounds = bounds; self.routeClearance = routeClearance; self.gap = gap
    }

    /// A polyline (screen points) that no overlay may cross.
    public mutating func addRoute(_ points: [CGPoint]) { if points.count >= 2 { routes.append(points) } }

    /// Something already drawn that overlays must avoid (user marker, pins, scale bar, compass).
    public mutating func addObstacle(_ rect: CGRect) { obstacles.append(rect) }

    /// True when a rect of this size can sit at `rect` without touching anything.
    public func fits(_ rect: CGRect) -> Bool {
        guard bounds.contains(rect) else { return false }
        let padded = rect.insetBy(dx: -gap, dy: -gap)
        if placed.contains(where: { $0.intersects(padded) }) { return false }
        if obstacles.contains(where: { $0.intersects(padded) }) { return false }
        let buffered = rect.insetBy(dx: -routeClearance, dy: -routeClearance)
        for line in routes where OverlayPlacer.polyline(line, intersects: buffered) { return false }
        return true
    }

    /// Finds a free rect of `size` next to `anchor`, trying each side (in the given order) at increasing distances
    /// and sliding along the map edge when needed. Returns nil when there is no free spot: the caller hides the label.
    public mutating func place(size: CGSize, anchor: CGPoint, offset: CGFloat, sides: [Side] = Side.allCases,
                               maxDistance: CGFloat? = nil) -> CGRect? {
        let limit = maxDistance ?? max(offset * 4, 48)
        var d = offset
        while d <= limit {
            for side in sides {
                var r = OverlayPlacer.rect(size: size, anchor: anchor, side: side, distance: d)
                r = clamp(r)
                if fits(r) { placed.append(r); return r }
            }
            d += max(8, offset)
        }
        return nil
    }

    /// Reserve a rect that was placed by other means (drawn pins, etc.) so later labels avoid it.
    public mutating func reserve(_ rect: CGRect) { placed.append(rect) }

    /// Slide a rect inside the bounds (no clipping at the map edge).
    public func clamp(_ r: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(r.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - r.width))
        r.origin.y = min(max(r.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - r.height))
        return r
    }

    public static func rect(size: CGSize, anchor: CGPoint, side: Side, distance: CGFloat) -> CGRect {
        switch side {
        case .right: return CGRect(x: anchor.x + distance, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        case .left:  return CGRect(x: anchor.x - distance - size.width, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        case .below: return CGRect(x: anchor.x - size.width / 2, y: anchor.y + distance, width: size.width, height: size.height)
        case .above: return CGRect(x: anchor.x - size.width / 2, y: anchor.y - distance - size.height, width: size.width, height: size.height)
        }
    }

    /// Preferred sides for a label beside a segment: the side the normal points to first, then the opposite, then
    /// the other axis (so a label never starts out on top of its own line).
    public static func sides(forSegmentFrom a: CGPoint, to b: CGPoint) -> [Side] {
        let dx = b.x - a.x, dy = b.y - a.y
        if abs(dx) >= abs(dy) { return [.below, .above, .right, .left] }   // mostly horizontal line: go above/below
        return [.right, .left, .below, .above]
    }

    // MARK: geometry

    public static func polyline(_ pts: [CGPoint], intersects r: CGRect) -> Bool {
        guard pts.count >= 2 else { return pts.first.map { r.contains($0) } ?? false }
        for i in 1..<pts.count where segment(pts[i - 1], pts[i], intersects: r) { return true }
        return false
    }

    /// Liang–Barsky: does the segment a–b touch the rect?
    public static func segment(_ a: CGPoint, _ b: CGPoint, intersects r: CGRect) -> Bool {
        if r.contains(a) || r.contains(b) { return true }
        var t0: CGFloat = 0, t1: CGFloat = 1
        let dx = b.x - a.x, dy = b.y - a.y
        func clip(_ p: CGFloat, _ q: CGFloat) -> Bool {
            if p == 0 { return q >= 0 }
            let t = q / p
            if p < 0 { if t > t1 { return false }; if t > t0 { t0 = t } }
            else { if t < t0 { return false }; if t < t1 { t1 = t } }
            return true
        }
        guard clip(-dx, a.x - r.minX), clip(dx, r.maxX - a.x), clip(-dy, a.y - r.minY), clip(dy, r.maxY - a.y) else { return false }
        return t0 <= t1
    }
}

// MARK: fixed chrome (scale bar, compass, Re-centre) and the refuge outline

extension OverlayPlacer {
    public enum Corner: CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight, bottomCentre, topCentre }

    public static func rect(size: CGSize, corner: Corner, bounds: CGRect, margin: CGFloat) -> CGRect {
        let x: CGFloat, y: CGFloat
        switch corner {
        case .topLeft, .bottomLeft: x = bounds.minX + margin
        case .topRight, .bottomRight: x = bounds.maxX - margin - size.width
        case .topCentre, .bottomCentre: x = bounds.midX - size.width / 2
        }
        switch corner {
        case .topLeft, .topRight, .topCentre: y = bounds.minY + margin
        case .bottomLeft, .bottomRight, .bottomCentre: y = bounds.maxY - margin - size.height
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Fixed chrome is not anchored to a map point: it takes the first corner (in preference order) where it touches
    /// nothing, and is hidden when every corner is taken or crossed by the route.
    public mutating func placeChrome(size: CGSize, corners: [Corner], margin: CGFloat) -> CGRect? {
        for c in corners {
            let r = OverlayPlacer.rect(size: size, corner: c, bounds: bounds, margin: margin)
            if fits(r) { placed.append(r); return r }
        }
        return nil
    }

    /// Ray casting: is `p` inside the closed ring?
    public static func polygon(_ ring: [CGPoint], contains p: CGPoint) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Parameter t in [0,1] along a–b of the first crossing with the ring, nil when it does not cross.
    public static func firstCrossing(_ a: CGPoint, _ b: CGPoint, ring: [CGPoint]) -> CGFloat? {
        guard ring.count >= 2 else { return nil }
        var best: CGFloat? = nil
        for i in 0..<ring.count {
            let c = ring[i], d = ring[(i + 1) % ring.count]
            let r = CGPoint(x: b.x - a.x, y: b.y - a.y), s = CGPoint(x: d.x - c.x, y: d.y - c.y)
            let den = r.x * s.y - r.y * s.x
            if abs(den) < 1e-9 { continue }
            let qp = CGPoint(x: c.x - a.x, y: c.y - a.y)
            let t = (qp.x * s.y - qp.y * s.x) / den, u = (qp.x * r.y - qp.y * r.x) / den
            if t >= 0, t <= 1, u >= 0, u <= 1 { best = min(best ?? t, t) }
        }
        return best
    }

    /// Distance from `p` to the closed ring's edge.
    public static func distance(_ p: CGPoint, toRing ring: [CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
            let t = l2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0
            best = min(best, hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t)))
        }
        return best
    }

    /// The route stops `clearance` points before it would touch the refuge outline (or any ring), so no route pixel
    /// lies on or inside it. The polyline is walked in 1-pt steps; it is cut at the last point that is still outside
    /// the ring and at least `clearance` away from its edge.
    public static func trim(_ pts: [CGPoint], outside ring: [CGPoint], clearance: CGFloat) -> [CGPoint] {
        guard pts.count >= 2, ring.count >= 3 else { return pts }
        func bad(_ p: CGPoint) -> Bool { polygon(ring, contains: p) || distance(p, toRing: ring) < clearance }
        guard !bad(pts[0]) else { return pts }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let len = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int(ceil(len)))
            var lastGood = a
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                if bad(p) {
                    var out = Array(pts[0..<i])
                    out.append(lastGood)
                    return out
                }
                lastGood = p
            }
        }
        return pts
    }
}

/// Everything one map drew, in screen points, so a test can rasterise the route against every overlay and fail on a
/// single shared pixel. Written by the app when EMBER_OVERLAY_AUDIT names a directory; read back by the test suite.
public struct OverlayAuditRecord: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var name: String
        public var x: Double, y: Double, w: Double, h: Double
        public init(name: String, rect: CGRect) {
            self.name = name; x = rect.minX; y = rect.minY; w = rect.width; h = rect.height
        }
        public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }
    public var id: String
    public var width: Double, height: Double
    /// Route centre line as drawn (already trimmed at the refuge outline), and its full stroke width incl. casing.
    public var route: [[Double]]
    public var routeWidth: Double
    public var overlays: [Item]
    /// The refuge outline ring (screen points) when one is drawn; the route may not touch it either.
    public var outline: [[Double]]?
    /// Rects cut out of the route when it was drawn (pins it starts/ends at): no route pixel exists inside them.
    public var holes: [Item]?
    /// How far the backdrop imagery is stretched past its native pixels at this zoom (1 = native, 2 = each image
    /// pixel covers 2 screen pixels); nil when the map is drawn from vectors only. Owner rule #3 wants ≤ 1.5.
    public var imageryScale: Double?

    public init(id: String, size: CGSize, route: [CGPoint], routeWidth: CGFloat, overlays: [Item], outline: [CGPoint]?,
                holes: [CGRect] = [], imageryScale: Double? = nil) {
        self.id = id; width = size.width; height = size.height; self.imageryScale = imageryScale
        self.route = route.map { [$0.x, $0.y] }; self.routeWidth = routeWidth; self.overlays = overlays
        self.outline = outline.map { $0.map { [$0.x, $0.y] } }
        self.holes = holes.isEmpty ? nil : holes.map { Item(name: "hole", rect: $0) }
    }

    public var routePoints: [CGPoint] { route.map { CGPoint(x: $0[0], y: $0[1]) } }
    public var outlinePoints: [CGPoint]? { outline?.map { CGPoint(x: $0[0], y: $0[1]) } }
}

public enum OverlayAudit {
    public struct Finding: Equatable, Sendable, CustomStringConvertible {
        public var kind: String, a: String, b: String
        public var description: String { "\(kind): \(a) × \(b)" }
    }

    /// Rasterises the route (every stroke pixel, casing included) on a 1-pt grid and reports every overlay rect that
    /// shares a pixel with it, every overlay pair that overlaps, every overlay outside the map, and the outline if the
    /// route touches it. Empty = the map obeys the owner's rules.
    public static func findings(_ r: OverlayAuditRecord) -> [Finding] {
        let w = Int(ceil(r.width)), h = Int(ceil(r.height))
        guard w > 0, h > 0 else { return [] }
        var grid = [Bool](repeating: false, count: w * h)
        func stamp(_ p: CGPoint, _ radius: CGFloat) {
            let x0 = max(0, Int(floor(p.x - radius))), x1 = min(w - 1, Int(ceil(p.x + radius)))
            let y0 = max(0, Int(floor(p.y - radius))), y1 = min(h - 1, Int(ceil(p.y + radius)))
            guard x0 <= x1, y0 <= y1 else { return }
            for y in y0...y1 { for x in x0...x1 where hypot(CGFloat(x) + 0.5 - p.x, CGFloat(y) + 0.5 - p.y) <= radius { grid[y * w + x] = true } }
        }
        let pts = r.routePoints, radius = CGFloat(r.routeWidth) / 2
        for i in 1..<max(1, pts.count) {
            let a = pts[i - 1], b = pts[i], len = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int(ceil(len / 0.5)))
            for s in 0...steps {
                let t = CGFloat(s) / CGFloat(steps)
                stamp(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), radius)
            }
        }
        if pts.count == 1 { stamp(pts[0], radius) }
        for hItem in r.holes ?? [] {
            let rect = hItem.rect
            let x0 = max(0, Int(floor(rect.minX))), x1 = min(w - 1, Int(ceil(rect.maxX)) - 1)
            let y0 = max(0, Int(floor(rect.minY))), y1 = min(h - 1, Int(ceil(rect.maxY)) - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 { grid[y * w + x] = false } }
        }
        func touched(_ rect: CGRect) -> Bool {
            let x0 = max(0, Int(floor(rect.minX))), x1 = min(w - 1, Int(ceil(rect.maxX)) - 1)
            let y0 = max(0, Int(floor(rect.minY))), y1 = min(h - 1, Int(ceil(rect.maxY)) - 1)
            guard x0 <= x1, y0 <= y1 else { return false }
            for y in y0...y1 { for x in x0...x1 where grid[y * w + x] { return true } }
            return false
        }
        var out: [Finding] = []
        let map = CGRect(x: 0, y: 0, width: r.width, height: r.height)
        for (i, o) in r.overlays.enumerated() {
            if touched(o.rect) { out.append(Finding(kind: "route-under-overlay", a: "route", b: o.name)) }
            if !map.contains(o.rect) { out.append(Finding(kind: "clipped-at-edge", a: o.name, b: "map edge")) }
            for p in r.overlays[(i + 1)...] where o.rect.intersects(p.rect) {
                out.append(Finding(kind: "overlay-overlap", a: o.name, b: p.name))
            }
        }
        if let ring = r.outlinePoints, ring.count >= 3 {
            var ringTouched = false
            for i in 0..<ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count], len = hypot(b.x - a.x, b.y - a.y)
                let steps = max(1, Int(ceil(len / 0.5)))
                for s in 0...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    let x = Int(floor(p.x)), y = Int(floor(p.y))
                    if x >= 0, y >= 0, x < w, y < h, grid[y * w + x] { ringTouched = true; break }
                }
                if ringTouched { break }
            }
            if ringTouched { out.append(Finding(kind: "route-touches-outline", a: "route", b: "refuge outline")) }
        }
        return out
    }
}
