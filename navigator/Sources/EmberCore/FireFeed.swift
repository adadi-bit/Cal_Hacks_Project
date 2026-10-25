import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keyless live fire inputs for a phone with signal: the current interagency fire perimeters (NIFC WFIGS, a public
/// ArcGIS FeatureServer) and the NWS gridpoint the bundle's wind.json came from. The bundle snapshot stays the
/// offline truth; a check only replaces it when it is newer. Nothing waits on it (deadline, then the cached data).
public struct FireFeed: Sendable {
    public static let timeoutS = 4.0
    public static let perimeterLayer = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/"
        + "WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query"
    public static let sources = "NIFC WFIGS Interagency Fire Perimeters (Current), api.weather.gov gridpoint forecast"

    /// One successful check: a perimeter (polygon nil = no active fire touching the county bbox) and, when the
    /// gridpoint answered, the prevailing wind computed exactly like the engine's wind.json.
    public struct Check: Codable, Sendable, Equatable {
        public var perimeter: Perimeter
        public var wind: Wind?
        public var checkedAt: Date
        public init(perimeter: Perimeter, wind: Wind?, checkedAt: Date) {
            self.perimeter = perimeter; self.wind = wind; self.checkedAt = checkedAt
        }
    }

    public let bbox: [Double]
    public let windSource: String?
    let transport: HTTPTransport

    public init(bbox: [Double], windSource: String?, transport: HTTPTransport = URLSessionTransport()) {
        self.bbox = bbox; self.windSource = windSource; self.transport = transport
    }

    public var perimeterRequest: URLRequest {
        var c = URLComponents(string: FireFeed.perimeterLayer)!
        c.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "geometry", value: bbox.map { String($0) }.joined(separator: ",")),
            URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"), URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "poly_IncidentName,attr_IncidentName,poly_DateCurrent,poly_PolygonDateTime"),
            URLQueryItem(name: "returnGeometry", value: "true"), URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "geometryPrecision", value: "6"), URLQueryItem(name: "f", value: "geojson"),
        ]
        return URLRequest(url: c.url!, timeoutInterval: FireFeed.timeoutS)
    }

    /// "api.weather.gov gridpoints/STO/47,122" (wind.json `source`) -> "gridpoints/STO/47,122".
    public static func gridpointPath(_ source: String?) -> String? {
        guard let s = source, let r = s.range(of: "gridpoints/") else { return nil }
        return s[r.lowerBound...].split(separator: " ").first.map(String.init)
    }

    public var windRequest: URLRequest? {
        guard let path = FireFeed.gridpointPath(windSource), let u = URL(string: "https://api.weather.gov/" + path) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: FireFeed.timeoutS)
        r.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        r.setValue("ember-navigator (offline wildfire evacuation app)", forHTTPHeaderField: "User-Agent")
        return r
    }

    public func fetch(now: Date = Date()) async -> Check? {
        let transport = self.transport
        let pReq = perimeterRequest
        let pData: Data? = await withDeadline(FireFeed.timeoutS) {
            let (d, resp) = try await transport.send(pReq)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw EmberError.missing("perimeters") }
            return d
        }
        guard let pData, let perimeter = FireFeed.parsePerimeter(pData, now: now) else { return nil }
        var wind: Wind? = nil
        if let wReq = windRequest {
            let wData: Data? = await withDeadline(FireFeed.timeoutS) {
                let (d, resp) = try await transport.send(wReq)
                guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw EmberError.missing("gridpoint") }
                return d
            }
            if let wData { wind = FireFeed.parseWind(wData, source: windSource, now: now) }
        }
        return Check(perimeter: perimeter, wind: wind, checkedAt: now)
    }

    // MARK: parsing (pure, tested)

    /// WFIGS geojson -> the most recently mapped perimeter touching the bbox (outer ring, [lon, lat] like the
    /// bundle), or `polygon: nil` stamped `now` when the answer is "no active fire here". nil = not an answer.
    public static func parsePerimeter(_ data: Data, now: Date) -> Perimeter? {
        guard let fc = try? JSONDecoder().decode(JSONValue.self, from: data), let feats = fc["features"]?.array else { return nil }
        func ring(_ v: JSONValue?) -> [[Double]]? {
            let pts = (v?.array ?? []).compactMap { p -> [Double]? in
                guard let a = p.array, a.count >= 2, let x = a[0].number, let y = a[1].number else { return nil }
                return [x, y]
            }
            return pts.count >= 3 ? pts : nil
        }
        var best: (Date, [[Double]], String?)? = nil
        for f in feats {
            guard let g = f["geometry"], let type = g["type"]?.string else { continue }
            var rings: [[[Double]]] = []
            if type == "Polygon" { if let r = ring(g["coordinates"]?.array?.first) { rings.append(r) } }
            if type == "MultiPolygon" { for poly in g["coordinates"]?.array ?? [] { if let r = ring(poly.array?.first) { rings.append(r) } } }
            guard let outer = rings.max(by: { $0.count < $1.count }) else { continue }
            let props = f["properties"]
            let ms = props?["poly_DateCurrent"]?.number ?? props?["poly_PolygonDateTime"]?.number
            let t = ms.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
            let name = props?["poly_IncidentName"]?.string ?? props?["attr_IncidentName"]?.string
            if best.map({ t > $0.0 }) ?? true { best = (t, outer, name) }
        }
        guard let b = best else { return Perimeter(timestamp: Timestamps.iso(now), polygon: nil, fire: nil) }
        return Perimeter(timestamp: Timestamps.iso(b.0), polygon: b.1, fire: b.2)
    }

    /// NWS gridpoint -> wind.json: speed-weighted vector mean of the hourly windDirection (engine `wind.prevailing`),
    /// speed in m/s, stamped with the fetch time like the engine does.
    public static func parseWind(_ data: Data, source: String?, now: Date) -> Wind? {
        guard let o = try? JSONDecoder().decode(JSONValue.self, from: data), let p = o["properties"] else { return nil }
        let dirs = series(p["windDirection"])
        let uom = p["windSpeed"]?["uom"]?.string ?? "km_h"
        let speeds = series(p["windSpeed"]).mapValues { toMps($0, uom) }
        guard !dirs.isEmpty else { return nil }
        var sx = 0.0, sy = 0.0, spd: [Double] = []
        for (t, d) in dirs {
            let w = speeds[t] ?? 1.0
            sx += w * sin(d * .pi / 180); sy += w * cos(d * .pi / 180)
            if let s = speeds[t] { spd.append(s) }
        }
        let dir = Py.mod(atan2(sx, sy) * 180 / .pi, 360.0)
        let speed = spd.isEmpty ? nil : spd.reduce(0, +) / Double(spd.count)
        return Wind(timestamp: Timestamps.iso(now), directionFromDeg: (dir * 10).rounded() / 10,
                    speedMps: speed.map { ($0 * 10).rounded() / 10 }, source: source ?? "api.weather.gov")
    }

    static func toMps(_ v: Double, _ uom: String) -> Double {
        if uom.contains("m_s") { return v }
        if uom.contains("kt") { return v * 0.514444 }
        if uom.contains("mi_h") { return v * 0.44704 }
        return v / 3.6
    }

    /// {hour: value} from an NWS series: each validTime "start/PnDTnHnM" is expanded to hourly instants.
    static func series(_ prop: JSONValue?) -> [Date: Double] {
        var out: [Date: Double] = [:]
        for v in prop?["values"]?.array ?? [] {
            guard let val = v["value"]?.number, let vt = v["validTime"]?.string else { continue }
            let parts = vt.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let t0 = Timestamps.parse(parts[0]) else { continue }
            for k in 0..<durationHours(parts[1]) { out[t0.addingTimeInterval(Double(k) * 3600)] = val }
        }
        return out
    }

    /// ISO-8601 duration "P1DT2H30M" -> whole hours (a partial hour counts), at least 1.
    public static func durationHours(_ s: String) -> Int {
        var days = 0, hours = 0, minutes = 0, num = "", inTime = false
        for ch in s {
            switch ch {
            case "P": continue
            case "T": inTime = true
            case "D": days = Int(num) ?? 0; num = ""
            case "H": hours = Int(num) ?? 0; num = ""
            case "M": if inTime { minutes = Int(num) ?? 0 }; num = ""
            default: if ch.isNumber { num.append(ch) }
            }
        }
        return max(1, days * 24 + hours + (minutes > 0 ? 1 : 0))
    }

    // MARK: status line

    /// The Home / Which-way line about fire data. Age is always shown; with no signal it says WHY the data is old,
    /// with signal it says when the phone last checked (or that the check failed).
    public static func statusText(dataAge: TimeInterval?, stale: Bool, online: Bool, lastCheck: Date?, checkFailed: Bool,
                                  now: Date) -> String {
        let age = dataAge.map { "Fire data from \(Timestamps.ageText($0))" + (stale ? " (old)" : "") } ?? "Fire data: none on this phone"
        if !online { return age + ". No connection: using the data saved on this phone." }
        if let c = lastCheck { return age + ". Checked for updates \(Timestamps.ageText(now.timeIntervalSince(c)))." }
        if checkFailed { return age + ". Update check failed; trying again." }
        return age + ". Checking for updates."
    }
}

extension Timestamps {
    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// "Oct 24" for Home/Settings ("Map and voice from Oct 24"): staff see when the bundle was last synced.
    public static func dayText(_ iso: String?) -> String? {
        guard let d = parse(iso) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}
