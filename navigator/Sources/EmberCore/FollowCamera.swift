import Foundation

/// The Navigate map camera: show the whole route for a moment, then follow the user closely; a hand on the map
/// pauses following until "Re-centre". Pure logic (no MapKit) so it is unit-tested like the state machine.
public struct FollowCamera: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case overview, follow, paused }

    /// How long the whole route stays on screen when Navigate opens.
    public static let overviewS: TimeInterval = 1.0
    /// Ground width of the follow view.
    public static let followSpanM = 150.0
    /// The user sits this fraction of the span behind the centre, so the map shows what is ahead.
    public static let aheadFraction = 0.22
    /// Pinch limits in the paused view.
    public static let minSpanM = 60.0, maxSpanM = 3000.0

    public private(set) var mode: Mode = .overview
    public private(set) var enteredAt: Date

    public init(now: Date = Date()) { enteredAt = now }

    /// Navigate was (re-)entered: the whole route again, then follow.
    public mutating func reset(now: Date = Date()) { mode = .overview; enteredAt = now }

    /// Advance the clock. Returns true when the camera changed (overview -> follow).
    @discardableResult
    public mutating func tick(now: Date = Date()) -> Bool {
        guard mode == .overview, now.timeIntervalSince(enteredAt) >= FollowCamera.overviewS else { return false }
        mode = .follow
        return true
    }

    /// A pinch or drag: following pauses so the map stays where the hand put it.
    public mutating func userInteracted() { mode = .paused }

    /// The Re-centre button.
    public mutating func recentre() { mode = .follow }

    public var isFollowing: Bool { mode == .follow }
    public var isPaused: Bool { mode == .paused }
    public var showsRecentre: Bool { mode == .paused }

    /// What the map shows: a centre, a ground width and a rotation (degrees clockwise, 0 = north-up).
    public struct Viewport: Equatable, Sendable {
        public var lat: Double, lon: Double, spanM: Double, rotationDeg: Double
        public init(lat: Double, lon: Double, spanM: Double, rotationDeg: Double) {
            self.lat = lat; self.lon = lon; self.spanM = spanM; self.rotationDeg = rotationDeg
        }
    }

    /// The follow viewport for a position: heading-up and centred slightly ahead when a heading is known,
    /// north-up and centred on the user otherwise. `nil` position -> nil (the overview stays).
    public static func viewport(lat: Double?, lon: Double?, heading: Double?, spanM: Double = followSpanM) -> Viewport? {
        guard let lat, let lon else { return nil }
        guard let h = heading, h.isFinite else { return Viewport(lat: lat, lon: lon, spanM: spanM, rotationDeg: 0) }
        let rot = Py.mod(h, 360)
        let (clat, clon) = destination(lat: lat, lon: lon, bearingDeg: rot, distanceM: spanM * aheadFraction)
        return Viewport(lat: clat, lon: clon, spanM: spanM, rotationDeg: rot)
    }

    /// The point `distanceM` along `bearingDeg` from (lat, lon) (flat-earth, fine for a few hundred metres).
    public static func destination(lat: Double, lon: Double, bearingDeg: Double, distanceM: Double) -> (lat: Double, lon: Double) {
        let b = Py.radians(bearingDeg)
        let dlat = distanceM * cos(b) / 111_320.0
        let dlon = distanceM * sin(b) / (111_320.0 * max(cos(Py.radians(lat)), 1e-6))
        return (lat + dlat, lon + dlon)
    }

    /// Smallest ground width that shows every point (route, you, refuge) with a margin: the overview span.
    public static func overviewSpanM(points: [(lat: Double, lon: Double)], aspect: Double, marginFraction: Double = 0.18) -> Double {
        guard let f = points.first else { return followSpanM }
        var s = f.lat, n = f.lat, w = f.lon, e = f.lon
        for p in points { s = min(s, p.lat); n = max(n, p.lat); w = min(w, p.lon); e = max(e, p.lon) }
        let k = cos(Py.radians((s + n) / 2))
        let widthM = (e - w) * k * 111_320.0, heightM = (n - s) * 111_320.0
        let need = max(widthM, heightM * max(aspect, 0.1), 40) * (1 + 2 * marginFraction)
        return need
    }
}

/// Direction of travel from successive GPS fixes (from engineer #1's v1): fixes closer than `minMoveM` are jitter and
/// ignored; the bearing between real moves is low-pass filtered so the heading-up map does not twitch.
public struct CourseEstimator: Sendable {
    public var minMoveM = 6.0
    public var smoothing = 0.5
    public private(set) var heading: Double?
    var last: (lat: Double, lon: Double)?

    public init() {}

    public mutating func add(lat: Double, lon: Double) {
        guard let l = last else { last = (lat, lon); return }
        let d = Geo.haversineM(l.lat, l.lon, lat, lon)
        guard d >= minMoveM else { return }
        let b = Geo.bearingDeg(l.lat, l.lon, lat, lon)
        if let h = heading { heading = Py.mod(h + Geo.signedTurn(h, b) * smoothing, 360.0) } else { heading = b }
        last = (lat, lon)
    }

    public mutating func reset() { heading = nil; last = nil }
}
