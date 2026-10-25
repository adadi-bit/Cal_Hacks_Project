import Foundation

// Bundle file shapes from CONTRACTS.md ("Bundle").

public struct Node: Sendable, Equatable {
    public var id: Int
    public var lat: Double
    public var lon: Double
    public var elev: Double?
}

public enum CurbCut: Sendable, Equatable {
    case yes, no, unknown, missing
}

public struct Edge: Sendable, Equatable {
    public var a: Int
    public var b: Int
    public var lengthM: Double
    public var gradePct: Double
    public var surface: String?
    public var steps: Bool
    public var stepCount: Double?
    public var curbCut: CurbCut
    public var roadClass: String?
    public var sidewalk: Bool
    public var name: String?
    public var driveway: Bool

    public init(a: Int, b: Int, lengthM: Double, gradePct: Double, surface: String? = "paved", steps: Bool = false,
                stepCount: Double? = nil, curbCut: CurbCut = .yes, roadClass: String? = "residential",
                sidewalk: Bool = true, name: String? = nil, driveway: Bool = false) {
        self.a = a; self.b = b; self.lengthM = lengthM; self.gradePct = gradePct; self.surface = surface
        self.steps = steps; self.stepCount = stepCount; self.curbCut = curbCut; self.roadClass = roadClass
        self.sidewalk = sidewalk; self.name = name; self.driveway = driveway
    }
}

public struct GraphFile: Sendable {
    public var nodes: [Node]
    public var edges: [Edge]

    public init(nodes: [Node], edges: [Edge]) { self.nodes = nodes; self.edges = edges }

    /// JSONSerialization is several times faster than JSONDecoder on 80k edges.
    public static func parse(_ data: Data) throws -> GraphFile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ns = root["nodes"] as? [[String: Any]], let es = root["edges"] as? [[String: Any]] else {
            throw EmberError.badBundle("graph.json")
        }
        func num(_ v: Any?) -> Double? {
            if v is String { return nil }
            return (v as? NSNumber)?.doubleValue
        }
        func truthy(_ v: Any?) -> Bool {
            if let n = v as? NSNumber { return n.boolValue }
            if let s = v as? String { return !s.isEmpty }
            return false
        }
        func str(_ v: Any?) -> String? { v as? String }
        var nodes: [Node] = []
        nodes.reserveCapacity(ns.count)
        for (i, n) in ns.enumerated() {
            guard let lat = num(n["lat"]), let lon = num(n["lon"]) else { throw EmberError.badBundle("graph.json node \(i)") }
            nodes.append(Node(id: (n["id"] as? NSNumber)?.intValue ?? i, lat: lat, lon: lon, elev: num(n["elev"])))
        }
        var edges: [Edge] = []
        edges.reserveCapacity(es.count)
        for (i, e) in es.enumerated() {
            guard let a = (e["a"] as? NSNumber)?.intValue, let b = (e["b"] as? NSNumber)?.intValue,
                  let len = num(e["length_m"]), let grade = num(e["grade_pct"]) else {
                throw EmberError.badBundle("graph.json edge \(i)")
            }
            let cc: CurbCut
            switch e["curb_cut"] {
            case let s as String: cc = s == "unknown" ? .unknown : .missing
            case let n as NSNumber: cc = n.boolValue ? .yes : .no
            default: cc = .missing
            }
            edges.append(Edge(a: a, b: b, lengthM: len, gradePct: grade, surface: str(e["surface"]), steps: truthy(e["steps"]),
                              stepCount: num(e["step_count"]), curbCut: cc, roadClass: str(e["road_class"]),
                              sidewalk: truthy(e["sidewalk"]), name: str(e["name"]), driveway: truthy(e["driveway"])))
        }
        return GraphFile(nodes: nodes, edges: edges)
    }
}

public struct EntryPoint: Codable, Sendable, Equatable {
    public var node: Int?
    public var lat: Double
    public var lon: Double
    public init(node: Int?, lat: Double, lon: Double) { self.node = node; self.lat = lat; self.lon = lon }
}

public struct Refuge: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String?
    public var polygon: [[Double]]?
    public var centroid: [Double]          // [lon, lat]
    public var entryPoints: [EntryPoint]
    public var score: Double
    public var terms: JSONValue?
    public var claude: JSONValue?
    public var flag: String?
    public var thumb: String?

    /// Map-pill form of the name ("the parking lot on Nunneley Road" -> "Nunneley Road lot"); never truncated.
    public var shortName: String {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.lowercased().hasPrefix("the ") { n = String(n.dropFirst(4)) }
        for prefix in ["parking lot on ", "parking lot at ", "parking lot of ", "lot at ", "lot on "] where n.lowercased().hasPrefix(prefix) {
            n = String(n.dropFirst(prefix.count)) + " lot"
            break
        }
        if let f = n.first { n = f.uppercased() + n.dropFirst() }
        return n
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, polygon, centroid, score, terms, claude, flag, thumb
        case entryPoints = "entry_points"
    }

    public init(id: String, name: String, kind: String? = nil, polygon: [[Double]]? = nil, centroid: [Double],
                entryPoints: [EntryPoint], score: Double, terms: JSONValue? = nil, claude: JSONValue? = nil,
                flag: String? = nil, thumb: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.polygon = polygon; self.centroid = centroid
        self.entryPoints = entryPoints; self.score = score; self.terms = terms; self.claude = claude
        self.flag = flag; self.thumb = thumb
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        polygon = try? c.decodeIfPresent([[Double]].self, forKey: .polygon)
        centroid = try c.decode([Double].self, forKey: .centroid)
        entryPoints = try c.decodeIfPresent([EntryPoint].self, forKey: .entryPoints) ?? []
        score = try c.decode(Double.self, forKey: .score)
        terms = try c.decodeIfPresent(JSONValue.self, forKey: .terms)
        claude = try c.decodeIfPresent(JSONValue.self, forKey: .claude)
        flag = try c.decodeIfPresent(String.self, forKey: .flag)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
    }

    public var centroidLat: Double { centroid[1] }
    public var centroidLon: Double { centroid[0] }
    /// "arrived_building" applies to refuges you shelter inside.
    public var isBuilding: Bool { kind == "building" }
}

public struct RefugesFile: Codable, Sendable {
    public var generatedAt: String?
    public var refuges: [Refuge]
    enum CodingKeys: String, CodingKey { case refuges; case generatedAt = "generated_at" }
}

public struct Perimeter: Codable, Sendable, Equatable {
    public var timestamp: String?
    public var polygon: [[Double]]?
    public var fire: String?
    public init(timestamp: String?, polygon: [[Double]]?, fire: String? = nil) {
        self.timestamp = timestamp; self.polygon = polygon; self.fire = fire
    }
}

public struct PerimetersFile: Codable, Sendable {
    public var current: Perimeter?
    public var historical: [Perimeter]?
    public init(current: Perimeter?, historical: [Perimeter]? = nil) { self.current = current; self.historical = historical }
}

/// `history.json`: the bundle's baked historical-fire summary (engine `history.summary`). `priorBearingDeg` is where
/// recorded fires since `since` came from; the phone uses it when it has no fresh fire data and no compass.
public struct HistoryFile: Codable, Sendable, Equatable {
    public struct Fire: Codable, Sendable, Equatable {
        public var fire: String
        public var date: String?
        public var acres: Double?
    }
    public var since: Int?
    public var fires: [Fire]?
    public var priorBearingDeg: Double?
    public var source: String?
    enum CodingKeys: String, CodingKey {
        case since, fires, source
        case priorBearingDeg = "prior_bearing_deg"
    }
    public init(since: Int? = nil, fires: [Fire]? = nil, priorBearingDeg: Double?, source: String? = nil) {
        self.since = since; self.fires = fires; self.priorBearingDeg = priorBearingDeg; self.source = source
    }
}

public struct Wind: Codable, Sendable, Equatable {
    public var timestamp: String?
    public var directionFromDeg: Double?
    public var speedMps: Double?
    public var source: String?
    enum CodingKeys: String, CodingKey {
        case timestamp, source
        case directionFromDeg = "direction_from_deg"
        case speedMps = "speed_mps"
    }
    public init(timestamp: String?, directionFromDeg: Double?, speedMps: Double?, source: String? = nil) {
        self.timestamp = timestamp; self.directionFromDeg = directionFromDeg; self.speedMps = speedMps; self.source = source
    }
}

public struct Manifest: Codable, Sendable {
    public var county: String
    public var bbox: [Double]?
    public var builtAt: String?
    public var version: Int?
    enum CodingKeys: String, CodingKey { case county, bbox, version; case builtAt = "built_at" }
}

// MARK: - Plan JSON (CONTRACTS.md "Plan JSON")

public struct PlanRoute: Codable, Sendable, Equatable {
    public var nodes: [Int]
    public var edges: [Int]
    public var forward: [Bool]?
    public var lengthM: Double
    public var timeS: Double
    public var minutes: Int
    enum CodingKeys: String, CodingKey {
        case nodes, edges, forward, minutes
        case lengthM = "length_m"
        case timeS = "time_s"
    }
}

public struct PlanChoice: Codable, Sendable {
    public var refuge: Refuge
    public var route: PlanRoute
    public var cardSteps: [String]?
    enum CodingKeys: String, CodingKey { case refuge, route; case cardSteps = "card_steps" }
}

public struct PlanShelter: Codable, Sendable, Equatable {
    public var room: String
    public var steps: [String]
}

public struct PlanDevice: Codable, Sendable, Equatable {
    public var kind: String
    public var hours: Double?
    public var batteryPct: Double?
    public var sentence: String
    enum CodingKeys: String, CodingKey { case kind, hours, sentence; case batteryPct = "battery_pct" }
}

public struct PlanFile: Codable, Sendable {
    public var version: Int?
    public var county: String?
    public var clientId: String?
    public var profileKey: String?
    public var fireBearingDeg: Double?
    public var choices: [PlanChoice]
    public var shelter: PlanShelter?
    public var devices: [PlanDevice]?
    public var noRoute: Bool?
    enum CodingKeys: String, CodingKey {
        case version, county, choices, shelter, devices
        case clientId = "client_id"
        case profileKey = "profile_key"
        case fireBearingDeg = "fire_bearing_deg"
        case noRoute = "no_route"
    }
}

public enum EmberError: Error, Equatable, CustomStringConvertible {
    case badBundle(String)
    case badQR(String)
    case missing(String)

    public var description: String {
        switch self {
        case .badBundle(let s): return "Bad bundle file: \(s)"
        case .badQR(let s): return "Bad QR code: \(s)"
        case .missing(let s): return "Missing: \(s)"
        }
    }
}

/// ISO8601 "…Z" timestamps from the bundle; fractional seconds tolerated.
public enum Timestamps {
    public static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// "3 h ago" style age text; staleness is always shown.
    public static func ageText(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 90 { return "just now" }
        let m = s / 60
        if m < 90 { return "\(Int(m.rounded())) min ago" }
        let h = m / 60
        if h < 48 { return "\(Int(h.rounded())) h ago" }
        return "\(Int((h / 24).rounded())) days ago"
    }
}
