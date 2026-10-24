import Foundation
import Testing
@testable import EmberCore

struct MockTransport: HTTPTransport {
    var delayS: Double = 0
    var status = 200
    var body: String
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if delayS > 0 { try await Task.sleep(nanoseconds: UInt64(delayS * 1e9)) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Never finishes and ignores cancellation, like a socket stuck in smoke.
struct HangingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }   // never resumes
        throw URLError(.timedOut)
    }
}

func toolReply(_ name: String, _ input: String) -> String {
    #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4-6","stop_reason":"tool_use","content":[{"type":"text","text":"Okay."},{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":\#(input)}]}"#
}

@Suite struct VoiceAgentTests {
    let config = Fixtures.config

    func processor() -> VoiceCommandProcessor {
        VoiceCommandProcessor(matcher: IntentMatcher(config.intents), config: config)
    }

    func resolver(_ m: NavigatorStateMachine) -> (String, String?) -> StreetLookup.Match? {
        { m.resolveStreet($0, cross: $1) }
    }

    @Test func requestHasExactPromptModelAndSixTools() throws {
        let a = VoiceAgent(apiKey: "sk-test", transport: MockTransport(body: "{}"))
        let r = try a.buildRequest(transcript: "tree down on Clark", context: .init(street: "Wagstaff Rd"))
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(r.timeoutInterval == 2)
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-sonnet-4-6")
        #expect(body["stream"] == nil)
        #expect(body["system"] as? String == "You help a person evacuating a wildfire in a wheelchair, or the person pushing them. Map what they say to one tool call. Never give directions yourself; the router does that. If unsure, ask one short question.")
        let tools = body["tools"] as! [[String: Any]]
        #expect(tools.map { $0["name"] as! String } == ["block_edge", "set_profile", "set_status", "reroute", "repeat_instruction", "report_position"])
        let be = tools[0]["input_schema"] as! [String: Any]
        #expect((be["properties"] as! [String: Any]).keys.sorted() == ["cross_street", "street"])
        #expect(be["required"] as! [String] == ["street"])
        let sp = (tools[1]["input_schema"] as! [String: Any])["properties"] as! [String: [String: Any]]
        #expect(sp["variant"]?["enum"] as? [String] == ["pushed", "solo"])
        let ss = (tools[2]["input_schema"] as! [String: Any])["properties"] as! [String: [String: Any]]
        #expect(ss["status"]?["enum"] as? [String] == ["ok", "cannot_move", "at_refuge"])
        for t in tools[3...] { #expect(((t["input_schema"] as! [String: Any])["properties"] as! [String: Any]).isEmpty) }
    }

    @Test func parsesToolUse() throws {
        let o = try VoiceAgent.parse(Data(toolReply("block_edge", #"{"street":"Clark","cross_street":"Pearson"}"#).utf8))
        #expect(o == .tool(name: "block_edge", input: ["street": .string("Clark"), "cross_street": .string("Pearson")]))
        #expect(throws: (any Error).self) { try VoiceAgent.parse(Data(toolReply("drive_car", "{}").utf8)) }
    }

    func navigating() throws -> NavigatorStateMachine {
        let m = NavigatorStateMachine(bundle: Fixtures.bundle)
        m.clock = { Timestamps.parse("2026-10-23T13:00:00Z")! }
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.confirmFire(); m.go()
        return m
    }

    @Test func blockEdgeIsReadBackAndRunsOnlyAfterYes() async throws {
        let m = try navigating()
        let p = processor()
        let agent = VoiceAgent(apiKey: "k", transport: MockTransport(body: toolReply("block_edge", #"{"street":"Clark","cross_street":"Pearson"}"#)))
        let r1 = await p.process("There's a tree down on Clark at Pearson", agent: agent, resolve: resolver(m))
        #expect(r1.say == "Blocking Clark Rd at Pearson Rd. Say yes to reroute.")
        #expect(r1.execute == nil)
        #expect(p.pending != nil)
        #expect(m.blocked.isEmpty)
        // "yes" is matched on-device even though the agent is available (and would answer something else).
        let r2 = await p.process("yes", agent: agent, resolve: resolver(m))
        guard case .blockEdges(let match)? = r2.execute else { Issue.record("expected blockEdges"); return }
        #expect(!match.edges.isEmpty)
        let before = m.progress?.route.edges
        m.apply(r2.execute!)
        #expect(m.blocked == Set(match.edges))
        #expect(m.state == .navigate || m.state == .shelter)
        if m.state == .navigate { #expect(m.utterances.first?.text == "Rerouting."); _ = before }
    }

    @Test func noCancelsPendingAndOtherSpeechDropsIt() async throws {
        let m = try navigating()
        let p = processor()
        let agent = VoiceAgent(apiKey: "k", transport: MockTransport(body: toolReply("set_profile", #"{"variant":"pushed"}"#)))
        let r1 = await p.process("I'm pushing her now", agent: agent, resolve: resolver(m))
        #expect(r1.say == "Switching to pushed chair. Say yes to reroute.")
        let r2 = await p.process("no", agent: agent, resolve: resolver(m))
        #expect(r2 == .init(say: "Okay."))
        #expect(p.pending == nil)
        let reroute = VoiceAgent(apiKey: "k", transport: MockTransport(body: toolReply("reroute", "{}")))
        _ = await p.process("find another way", agent: reroute, resolve: resolver(m))
        #expect(p.pending?.command == .reroute)
        let offline = await p.process("how long", agent: nil, resolve: resolver(m))
        #expect(p.pending == nil)
        #expect(offline.execute == .intent(.howLong))
    }

    @Test func repeatAndReportPositionRunImmediately() async throws {
        let m = try navigating()
        let p = processor()
        let r = await p.process("what was that", agent: VoiceAgent(apiKey: "k", transport: MockTransport(body: toolReply("repeat_instruction", "{}"))), resolve: resolver(m))
        #expect(r.execute == .repeatInstruction && r.say == nil && p.pending == nil)
        let q = await p.process("where", agent: VoiceAgent(apiKey: "k", transport: MockTransport(body: toolReply("report_position", "{}"))), resolve: resolver(m))
        #expect(q.execute == .reportPosition)
        m.apply(q.execute!)
        #expect(m.utterances.first?.template == "where")
    }

    @Test func twoSecondTimeoutFallsBackSilentlyToIntents() async throws {
        let m = try navigating()
        let p = processor()
        let slow = VoiceAgent(apiKey: "k", transport: MockTransport(delayS: 5, body: toolReply("reroute", "{}")))
        let t0 = Date()
        let r = await p.process("there's a tree down on Clark", agent: slow, resolve: resolver(m))
        let dt = Date().timeIntervalSince(t0)
        #expect(dt >= 1.9 && dt < 2.6)
        #expect(r.execute == .intent(.blocked))
        #expect(r.say == nil && !r.usedClaude && p.pending == nil)
    }

    @Test func hangingTransportStillReturnsAfterTwoSeconds() async throws {
        let m = try navigating()
        let t0 = Date()
        let r = await processor().process("stuck", agent: VoiceAgent(apiKey: "k", transport: HangingTransport()), resolve: resolver(m))
        #expect(Date().timeIntervalSince(t0) < 2.6)
        #expect(r.execute == .intent(.cantMove))
    }

    @Test func revokedKeyOrBadReplyFallsBack() async throws {
        let m = try navigating()
        let p = processor()
        let revoked = VoiceAgent(apiKey: "revoked", transport: MockTransport(status: 401, body: #"{"type":"error","error":{"type":"authentication_error"}}"#))
        #expect(await p.process("tree down on Clark", agent: revoked, resolve: resolver(m)).execute == .intent(.blocked))
        let garbage = VoiceAgent(apiKey: "k", transport: MockTransport(body: "not json"))
        #expect(await p.process("louder please", agent: garbage, resolve: resolver(m)).execute == .intent(.louder))
        #expect(await p.process("mumble mumble", agent: nil, resolve: resolver(m)).say == "Say again?")
    }

    @Test func claudeQuestionIsSpoken() async throws {
        let m = try navigating()
        let body = #"{"content":[{"type":"text","text":"Which street is blocked?"}],"stop_reason":"end_turn"}"#
        let r = await processor().process("it's blocked up there", agent: VoiceAgent(apiKey: "k", transport: MockTransport(body: body)), resolve: resolver(m))
        #expect(r.say == "Which street is blocked?" && r.execute == nil)
    }

    @Test func streetLookupWithoutCrossUsesRouteAhead() throws {
        let m = try navigating()
        let street = try #require(m.currentStreet())
        let match = try #require(m.resolveStreet(street, cross: nil))
        #expect(match.edges.first == m.progress?.route.edges.first)
        #expect(m.resolveStreet("Nonexistent Blvd", cross: nil) == nil)
    }
}

@Suite struct ApifyFeedTests {
    let g = Fixtures.bundle.graph

    func situationJSON() -> String {
        let n = 40   // a grid node
        return #"[{"county":"Other","fetched_at":"2026-10-23T12:30:00Z","closures":[],"outages":[]},"# +
            #"{"county":"Fake County","fetched_at":"2026-10-23T12:00:00Z","closures":[{"lat":\#(g.lat[n] + 0.00005),"lon":\#(g.lon[n]),"road":"Bille Rd","kind":"full"},{"lat":40.5,"lon":-120.0,"road":"far","kind":"full"}],"outages":[{"area":"95969, 95967","kind":"psps","est_restore":null}],"zones":[]}]"#
    }

    @Test func closuresWithin2kmBecomeBlockedEdgesAndCacheIsUsedOffline() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("feed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let live = ApifyFeed(datasetId: "ds1", token: "t", county: "fake", cacheURL: cache, transport: MockTransport(body: situationJSON()))
        #expect(live.request.url?.absoluteString.hasPrefix("https://api.apify.com/v2/datasets/ds1/items") == true)
        #expect(live.request.timeoutInterval == 2)
        let r = await live.fetch()
        #expect(r.source == .live)
        #expect(r.situation?.county == "Fake County")
        let edges = ApifyFeed.blockedEdges(r.situation, graph: g, lat: g.lat[0], lon: g.lon[0])
        #expect(edges.count == 1)
        let e = g.edges[edges.first!]
        #expect(e.a == 40 || e.b == 40)
        #expect(ApifyFeed.outage(r.situation, zip: "95969")?.kind == "psps")
        #expect(ApifyFeed.outage(r.situation, zip: "90210") == nil)

        let down = ApifyFeed(datasetId: "ds1", token: nil, county: "fake", cacheURL: cache, transport: MockTransport(delayS: 5, body: "[]"))
        let t0 = Date()
        let c = await down.fetch()
        #expect(Date().timeIntervalSince(t0) < 2.6)
        #expect(c.source == .cached)
        #expect(c.situation?.closures.count == 2)
    }

    @Test func feedClosuresArePreBlockedBeforeRouting() throws {
        let m = NavigatorStateMachine(bundle: Fixtures.bundle)
        m.clock = { Timestamps.parse("2026-10-23T13:00:00Z")! }
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.confirmFire()
        let first = m.currentChoice!.route.edges[0]
        m.feedBlocked = [first]
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.confirmFire()
        #expect(m.choices.allSatisfy { !$0.route.edges.contains(first) })
    }
}
