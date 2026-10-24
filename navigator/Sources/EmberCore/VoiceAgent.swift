import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Injected so the agent and the feed are testable without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Runs `op` with a hard deadline; returns nil on timeout or error. Never waits for a transport that ignores cancellation.
public func withDeadline<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async -> T? {
    await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        let gate = ResumeGate()
        let work = Task {
            let r = try? await op()
            if gate.claim() { cont.resume(returning: r) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if gate.claim() {
                work.cancel()
                cont.resume(returning: nil)
            }
        }
    }
}

/// What a voice turn resolves to before the confirmation rule.
public enum VoiceCommand: Sendable, Equatable {
    case intent(Intent)
    case blockEdges(StreetLookup.Match)
    case setProfile(pushed: Bool)
    case setStatus(String)
    case reroute
    case repeatInstruction
    case reportPosition
}

/// Claude Job 3: free speech -> one tool call. Only used with signal; any failure returns nil (caller falls back).
public struct VoiceAgent: Sendable {
    public static let model = "claude-sonnet-4-6"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let timeoutS = 2.0
    public static let systemPrompt = "You help a person evacuating a wildfire in a wheelchair, or the person pushing them. Map what they say to one tool call. Never give directions yourself; the router does that. If unsure, ask one short question."
    public static let toolNames = ["block_edge", "set_profile", "set_status", "reroute", "repeat_instruction", "report_position"]

    public enum Outcome: Sendable, Equatable {
        case tool(name: String, input: [String: JSONValue])
        case text(String)
    }

    public struct Context: Sendable {
        public var street: String?
        public var instruction: String?
        public init(street: String? = nil, instruction: String? = nil) { self.street = street; self.instruction = instruction }
    }

    public let apiKey: String
    public let transport: HTTPTransport
    public let timeoutS: Double

    public init(apiKey: String, transport: HTTPTransport = URLSessionTransport(), timeoutS: Double = VoiceAgent.timeoutS) {
        self.apiKey = apiKey; self.transport = transport; self.timeoutS = timeoutS
    }

    public static var tools: [[String: Any]] {
        func obj(_ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }
        return [
            ["name": "block_edge",
             "description": "Mark a street as blocked (tree down, fire, closed). cross_street names the intersection if they said one.",
             "input_schema": obj(["street": ["type": "string", "description": "Street name as spoken"],
                                  "cross_street": ["type": "string", "description": "Nearest cross street, if said"]], ["street"])],
            ["name": "set_profile",
             "description": "pushed: someone is pushing the chair. solo: the person is moving on their own.",
             "input_schema": obj(["variant": ["type": "string", "enum": ["pushed", "solo"]]], ["variant"])],
            ["name": "set_status",
             "description": "ok, cannot_move (they cannot go on; start shelter steps), or at_refuge (they have arrived).",
             "input_schema": obj(["status": ["type": "string", "enum": ["ok", "cannot_move", "at_refuge"]]], ["status"])],
            ["name": "reroute", "description": "Find a new route from here.", "input_schema": obj([:], [])],
            ["name": "repeat_instruction", "description": "Say the current instruction again.", "input_schema": obj([:], [])],
            ["name": "report_position", "description": "Tell them which street they are on.", "input_schema": obj([:], [])],
        ]
    }

    public func buildRequest(transcript: String, context: Context) throws -> URLRequest {
        var lines: [String] = []
        if let s = context.street { lines.append("Current street: \(s).") }
        if let i = context.instruction { lines.append("Current instruction: \(i)") }
        lines.append("They said: \"\(transcript)\"")
        let body: [String: Any] = [
            "model": VoiceAgent.model,
            "max_tokens": 200,
            "system": VoiceAgent.systemPrompt,
            "tools": VoiceAgent.tools,
            "tool_choice": ["type": "auto"],
            "messages": [["role": "user", "content": lines.joined(separator: "\n")]],
        ]
        var r = URLRequest(url: VoiceAgent.endpoint, timeoutInterval: timeoutS)
        r.httpMethod = "POST"
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    public static func parse(_ data: Data) throws -> Outcome {
        struct Block: Decodable { let type: String; let text: String?; let name: String?; let input: [String: JSONValue]? }
        struct Msg: Decodable { let content: [Block] }
        let m = try JSONDecoder().decode(Msg.self, from: data)
        if let t = m.content.first(where: { $0.type == "tool_use" }) {
            guard let name = t.name, toolNames.contains(name) else { throw EmberError.missing("known tool") }
            return .tool(name: name, input: t.input ?? [:])
        }
        let text = m.content.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EmberError.missing("reply") }
        return .text(text)
    }

    /// nil after 2 s, on any HTTP error, or on an unparseable reply.
    public func interpret(_ transcript: String, context: Context = Context()) async -> Outcome? {
        guard !apiKey.isEmpty, let req = try? buildRequest(transcript: transcript, context: context) else { return nil }
        let transport = self.transport
        return await withDeadline(timeoutS) {
            let (data, resp) = try await transport.send(req)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw EmberError.missing("HTTP 200") }
            return try VoiceAgent.parse(data)
        }
    }
}

/// The confirmation rule and the on-device fallback, in code.
/// block_edge / set_profile / reroute are read back and run only after a "yes" from the on-device matcher;
/// repeat_instruction / report_position (and set_status) run at once. No reply in 2 s or any error -> intent matcher.
public final class VoiceCommandProcessor: @unchecked Sendable {
    public struct Result: Sendable, Equatable {
        public var say: String?
        public var execute: VoiceCommand?
        public var usedClaude = false
        public init(say: String? = nil, execute: VoiceCommand? = nil, usedClaude: Bool = false) {
            self.say = say; self.execute = execute; self.usedClaude = usedClaude
        }
    }

    public struct Pending: Sendable, Equatable { public var prompt: String; public var command: VoiceCommand }

    let matcher: IntentMatcher
    let config: SharedConfig
    public private(set) var pending: Pending?

    public init(matcher: IntentMatcher, config: SharedConfig) { self.matcher = matcher; self.config = config }

    /// `agent` is nil when offline or no key. `resolve` maps block_edge(street, cross) to edges.
    public func process(_ transcript: String, agent: VoiceAgent?, context: VoiceAgent.Context = .init(),
                        resolve: (String, String?) -> StreetLookup.Match?) async -> Result {
        if let p = pending {
            pending = nil
            switch matcher.match(transcript)?.intent {
            case .yes?: return Result(execute: p.command)
            case .no?: return Result(say: "Okay.")
            default: break
            }
        }
        if let agent, let outcome = await agent.interpret(transcript, context: context) {
            switch outcome {
            case .text(let q):
                return Result(say: q, usedClaude: true)
            case .tool(let name, let input):
                if let r = toolResult(name, input, resolve: resolve) { return r }
            }
        }
        guard let m = matcher.match(transcript) else { return Result(say: NavigatorStateMachine.sayAgain) }
        return Result(execute: .intent(m.intent))
    }

    func toolResult(_ name: String, _ input: [String: JSONValue], resolve: (String, String?) -> StreetLookup.Match?) -> Result? {
        func confirm(_ prompt: String, _ cmd: VoiceCommand) -> Result {
            pending = Pending(prompt: prompt, command: cmd)
            return Result(say: prompt, usedClaude: true)
        }
        switch name {
        case "block_edge":
            guard let street = input["street"]?.string, !street.isEmpty else { return nil }
            let cross = input["cross_street"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            guard let m = resolve(street, cross), !m.edges.isEmpty else {
                return Result(say: NavigatorStateMachine.sayAgain, usedClaude: true)
            }
            let prompt = m.crossStreet.map { config.phrase("blocking_cross", ["street": m.street, "cross_street": $0]) }
                ?? config.phrase("blocking", ["street": m.street])
            return confirm(prompt, .blockEdges(m))
        case "set_profile":
            guard let v = input["variant"]?.string, v == "pushed" || v == "solo" else { return nil }
            let lead = v == "pushed" ? "Switching to pushed chair." : "Switching to solo."
            return confirm("\(lead) Say yes to reroute.", .setProfile(pushed: v == "pushed"))
        case "reroute":
            return confirm("Find a new route? Say yes to reroute.", .reroute)
        case "set_status":
            guard let s = input["status"]?.string, ["ok", "cannot_move", "at_refuge"].contains(s) else { return nil }
            return Result(execute: .setStatus(s), usedClaude: true)
        case "repeat_instruction":
            return Result(execute: .repeatInstruction, usedClaude: true)
        case "report_position":
            return Result(execute: .reportPosition, usedClaude: true)
        default:
            return nil
        }
    }
}
