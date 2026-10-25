import Foundation

public enum NavState: String, Sendable {
    case home, whichWay, choose, navigate, shelter, arrived
}

/// One spoken + shown string. `template`/`vars` let the Speaker compose cached fragments.
public struct Utterance: Sendable, Equatable {
    public var text: String
    public var template: String?
    public var vars: [String: String]

    public init(_ text: String, template: String? = nil, vars: [String: String] = [:]) {
        self.text = text; self.template = template; self.vars = vars
    }

    public init(_ cue: Cue) {
        self.init(cue.text, template: cue.template, vars: cue.vars.mapValues(\.description))
    }
}

/// Home -> WhichWay -> Choose -> Navigate -> Arrived, with Shelter reachable from Choose/Navigate and always for bedbound.
/// Every action sets `utterances` (what to say and show) and bumps `serial` so the app speaks it once.
public final class NavigatorStateMachine {
    public static let noRoute = "No route. Stay where you are. Start the shelter steps."
    public static let sayAgain = "Say again?"
    public static let fireAhead = "Fire ahead. Turning away from it."
    public static let cardMismatch = "This card does not match the phone's plan. Ask staff for a new card."
    public static let noCompassReport = "No compass. Using the last fire report."
    public static let noCompassHistory = "No compass. Using where past fires came from."
    public static let noCompassAhead = "No compass. Treating the fire as straight ahead. Turning away from it."
    // v2 (engineer #2): spoken leads for "Skip"/"Not sure" and the shelter's last step; v1 (engineer #1): the picker prompts.
    public static let lastReport = "Using the last fire report."
    public static let noFireInfo = "No fire information. Showing the nearest safe places."
    public static let shelterLast = "That is the last step. Stay in the room and keep the phone on."
    public static let whichWaySmoke = "Which way is the smoke?"
    public static let whichWayNewFire = "Which way is the new fire?"
    // Confirm step (round 2, all five found the mis-tap risk): a tap on Blocked / New fire / Start over asks first.
    public static let rerouteQuestion = "Find a new route? Say yes to reroute."
    public static let fireAheadQuestion = "Fire ahead. Turning away from it. Say yes to reroute."
    public static let startOverQuestion = "Stop and go back to the start? Say yes to stop."
    public static let okay = "Okay."

    /// What a tapped button is waiting to do until the person answers Yes / No.
    public enum Pending: Equatable, Sendable { case blocked, fireAhead(heading: Double?), newFireNoCompass, startOver }
    public private(set) var pending: Pending?

    /// "Blocked" tapped: ask before throwing the route away (one mis-tap doubled Harold's trip).
    public func requestBlocked() {
        guard state == .navigate else { return }
        pending = .blocked
        say(NavigatorStateMachine.rerouteQuestion)
    }

    /// "New fire" tapped with a compass heading (nil: no compass, the report -> history -> ahead chain runs on Yes).
    public func requestFire(heading: Double?) {
        guard state == .navigate || state == .choose else { return }
        pending = heading == nil ? .newFireNoCompass : .fireAhead(heading: heading)
        say(NavigatorStateMachine.fireAheadQuestion)
    }

    /// "Start over" tapped on Navigate / Choose: back to Home only after a Yes.
    public func requestStartOver() {
        guard state != .home else { return }
        pending = .startOver
        say(NavigatorStateMachine.startOverQuestion)
    }

    public func confirmPending() {
        guard let p = pending else { return }
        pending = nil
        switch p {
        case .blocked: blockCurrent()
        case .fireAhead(let h): fireAhead(heading: h)
        case .newFireNoCompass: newFireWithoutCompass()
        case .startOver: goHome()
        }
    }

    public func cancelPending() {
        guard pending != nil else { return }
        pending = nil
        say([Utterance(NavigatorStateMachine.okay)] + currentRepeat())
    }

    public let bundle: EmberBundle
    public var config: SharedConfig { bundle.config }
    public var graph: Graph { bundle.graph }
    let cues: Cues
    let streets: StreetLookup

    public private(set) var state: NavState = .home
    public private(set) var utterances: [Utterance] = []
    public private(set) var serial = 0

    public private(set) var client: ClientProfile?
    public private(set) var caregiver = false
    public private(set) var profile: Profile?
    public var fireData: FireData
    public private(set) var fireBearing: Double?
    public private(set) var choices: [Choice] = []
    public private(set) var choiceIndex = 0
    public private(set) var progress: RouteProgress?
    /// Session list of edges blocked by the user (cleared on Start).
    public private(set) var blocked: Set<Int> = []
    /// Closures from the Apify feed, pre-marked as blocked before routing.
    public var feedBlocked: Set<Int> = []
    /// Compass heading (degrees) when the device has one; the app sets this. Nil falls back to the route edge bearing.
    public var headingProvider: () -> Double? = { nil }
    public private(set) var shelter = PlanShelter(room: "bedroom", steps: [])
    public private(set) var shelterIndex = 0
    public private(set) var arrivedRefuge: Refuge?
    public private(set) var stopped = false
    public private(set) var position: (lat: Double, lon: Double)?

    public init(bundle: EmberBundle, now: Date = Date()) {
        self.bundle = bundle
        cues = Cues(graph: bundle.graph, config: bundle.config)
        streets = StreetLookup(graph: bundle.graph, templates: bundle.config.templates)
        fireData = FireData(perimeter: bundle.perimeters?.current, wind: bundle.wind)
    }

    // MARK: derived

    public var currentChoice: Choice? { choices.indices.contains(choiceIndex) ? choices[choiceIndex] : nil }
    public var alternateChoice: Choice? {
        guard choices.count > 1 else { return nil }
        return choices[(choiceIndex + 1) % choices.count]
    }
    public var fireIsFresh: Bool { fireData.isFresh(now: clock()) }
    public var clock: () -> Date = { Date() }

    /// Bearing to the fire from the cached data at the client's position (WhichWay "OK").
    public var dataFireBearing: Double? {
        guard let p = originPoint else { return nil }
        return fireData.bearing(lat: p.lat, lon: p.lon)
    }

    var originPoint: (lat: Double, lon: Double)? {
        if let position { return position }
        if let c = client, let la = c.lat, let lo = c.lon { return (la, lo) }
        return nil
    }

    public var remainingRouteTimeS: Double? {
        if let p = progress { return p.remainingTimeS }
        return currentChoice?.route.timeS
    }

    public var fireETAMinutes: Double? {
        guard let p = originPoint else { return nil }
        return fireData.etaMinutes(lat: p.lat, lon: p.lon)
    }

    // MARK: output

    func say(_ u: [Utterance]) {
        utterances = u
        serial += 1
    }

    func say(_ texts: String...) { say(texts.map { Utterance($0) }) }

    func say(_ u: Utterance) { say([u]) }

    // MARK: Home

    /// Start on Home: bedbound always goes to Shelter; everyone else to WhichWay.
    public func start(client: ClientProfile, caregiver: Bool) throws {
        self.client = client
        self.caregiver = caregiver
        profile = try Profile(client.profileKey(caregiver: caregiver), batteryPct: client.batteryPct, config: config)
        blocked = []
        choices = []
        choiceIndex = 0
        progress = nil
        arrivedRefuge = nil
        stopped = false
        fireBearing = nil
        let planFile = bundle.plan(clientId: client.id)
        shelter = planFile?.shelter ?? PlanText.shelterSteps(client)
        planRefugeIds = (planFile?.choices ?? []).prefix(2).map { $0.refuge.id }
        cardMismatch = !NavigatorStateMachine.cardMatchesPlan(cardIds: client.refugeIds, planIds: planRefugeIds)
        if client.isBedbound || profile?.shelterOnly == true {
            enterShelter(lead: nil)
            return
        }
        state = .whichWay
        if fireIsFresh, let b = dataFireBearing {
            say(Utterance(config.phrase("fire_dir", ["direction": Geo.directionWord(b, config.templates.directions)]),
                          template: "fire_dir", vars: ["direction": Geo.directionWord(b, config.templates.directions)]))
        } else if let prior = historyPrior {
            let d = Geo.directionWord(prior, config.templates.directions)
            say([Utterance(config.phrase("history_dir", ["direction": d]), template: "history_dir", vars: ["direction": d]),
                 Utterance("Point the phone at the smoke and tap.")])
        } else {
            say("Point the phone at the smoke and tap.")
        }
    }

    /// Refuge ids A, B of the bundle's plan file for this client (plans/<id>.json, written by the staff tool when it
    /// plans and when it prints): the single source the printed card and the phone both follow.
    public private(set) var planRefugeIds: [String] = []
    /// True when the scanned card names other refuges than the plan file (an old card or a stale bundle).
    public private(set) var cardMismatch = false

    /// Card (QR refuge_ids) vs plan file: equal, or one side unknown, is a match.
    public static func cardMatchesPlan(cardIds: [String]?, planIds: [String]) -> Bool {
        guard let cardIds, !cardIds.isEmpty, !planIds.isEmpty else { return true }
        return Array(cardIds.prefix(2)) == Array(planIds.prefix(2))
    }

    /// Live routing may order refuges differently from the plan file (a slightly different bearing, a newer graph).
    /// When the plan's A is still an allowed choice it goes first, so the phone says what the card says; the router's
    /// own order (fire side, time) is kept for everything else.
    public static func ordered(_ choices: [Choice], planIds: [String]) -> [Choice] {
        guard let a = planIds.first, let i = choices.firstIndex(where: { $0.refuge.id == a }), i > 0 else { return choices }
        var out = choices
        out.insert(out.remove(at: i), at: 0)
        return out
    }

    /// Baked historical spread direction (history.json), used only when live data is stale and nothing better exists.
    public var historyPrior: Double? { bundle.history?.priorBearingDeg }

    public func setPosition(lat: Double, lon: Double) { position = (lat, lon) }

    // MARK: WhichWay

    /// "OK": accept the cached fire direction (only offered when the data is under 6 h old).
    public func confirmFire() {
        guard state == .whichWay, fireIsFresh, let b = dataFireBearing else { return }
        fireBearing = b
        planChoices()
    }

    /// "Not sure": fire data is old and there is no compass (or the user cannot see smoke). Plan without a fire
    /// bearing: the planned refuges are still ranked by safety score and distance, and "Fire"/"New fire" mid-route
    /// still close the wedge later. Better than the old dead end on Which Way.
    public func skipFireDirection() {
        guard state == .whichWay else { return }
        if let b = dataFireBearing {                       // a stale report still beats nothing: say so
            fireBearing = b
            planChoices(lead: Utterance(NavigatorStateMachine.lastReport))
        } else if let prior = historyPrior {
            fireBearing = prior
            let d = Geo.directionWord(prior, config.templates.directions)
            planChoices(lead: Utterance(config.phrase("history_dir", ["direction": d]), template: "history_dir", vars: ["direction": d]))
        } else {
            fireBearing = nil
            planChoices(lead: Utterance(NavigatorStateMachine.noFireInfo))
        }
    }

    /// "Point": the compass bearing of the phone, pointed at the smoke.
    public func point(bearing: Double) {
        guard state == .whichWay else { return }
        fireBearing = Py.mod(bearing, 360.0)
        planChoices()
    }

    func originNode() -> Int? {
        guard let p = originPoint, let profile else { return nil }
        return graph.snap(p.lat, p.lon, usable: Router.usableOrigin(graph, profile)).node
    }

    func route(from origin: Int?, prefer: Double? = nil) -> [Choice] {
        guard let origin, let profile else { return [] }
        return Router.choose(graph, refuges: bundle.refuges, profile: profile, origin: origin,
                             fireBearing: fireBearing, perimeter: fireData.polygon, blocked: blocked.union(feedBlocked),
                             prefer: prefer)
    }

    /// Direction of travel: the bearing of the current route edge (nil outside Navigate).
    public var travelHeading: Double? {
        guard let p = progress, !p.route.edges.isEmpty else { return nil }
        let i = min(p.edgeOffset, p.route.edges.count - 1)
        return graph.edgeBearing(p.route.edges[i], p.route.forward[i])
    }

    func planChoices(lead: Utterance? = nil) {
        choices = NavigatorStateMachine.ordered(route(from: originNode()), planIds: planRefugeIds)
        choiceIndex = 0
        if choices.isEmpty {
            enterShelter(lead: NavigatorStateMachine.noRoute)
            return
        }
        state = .choose
        var u: [Utterance] = lead.map { [$0] } ?? []
        if cardMismatch { u.append(Utterance(NavigatorStateMachine.cardMismatch)) }
        say(u + choiceUtterances())
    }

    func choiceUtterances() -> [Utterance] {
        guard let a = currentChoice else { return [] }
        // max(1, ...) like how_long: an origin at a refuge entry point yields a 0-minute route, and "0" has no clip
        var u = [Utterance(config.phrase("choose", ["refuge": a.refuge.name, "n": String(max(1, a.route.minutes))]),
                           template: "choose", vars: ["refuge": a.refuge.name, "n": String(max(1, a.route.minutes))])]
        if let b = alternateChoice {
            u.append(Utterance(config.phrase("or_b", ["refuge": b.refuge.name, "n": String(max(1, b.route.minutes))]),
                               template: "or_b", vars: ["refuge": b.refuge.name, "n": String(max(1, b.route.minutes))]))
        }
        return u
    }

    func sayChoice() { say(choiceUtterances()) }

    // MARK: Choose

    public func go() {
        guard state == .choose, let c = currentChoice, let profile else { return }
        startNavigation(c, profile: profile, lead: [])
    }

    /// "Other": the next-ranked refuge becomes the one offered.
    public func other() {
        guard state == .choose, choices.count > 1 else { return }
        choiceIndex = (choiceIndex + 1) % choices.count
        sayChoice()
    }

    public func cantMove() {
        guard state == .choose || state == .navigate || state == .whichWay else { return }
        enterShelter(lead: nil)
    }

    // MARK: Navigate

    func startNavigation(_ c: Choice, profile: Profile, lead: [Utterance]) {
        let cl = cues.buildCues(c.route, refugeName: c.refuge.name)
        var p = RouteProgress(route: c.route, cues: cl, graph: graph, profile: profile)
        if let pos = position { p.update(lat: pos.lat, lon: pos.lon, graph: graph) }
        progress = p
        state = .navigate
        stopped = false
        if let pos = position, Router.arrived(lat: pos.lat, lon: pos.lon, refuge: c.refuge) {
            arrive(c.refuge)
            return
        }
        say(lead + p.currentGroup.map(Utterance.init))
    }

    /// GPS fix. In Navigate: arrival within 25 m of an entry point, else advance the cue by progress.
    public func updatePosition(lat: Double, lon: Double) {
        position = (lat, lon)
        guard state == .navigate, var p = progress, let c = currentChoice else { return }
        if Router.arrived(lat: lat, lon: lon, refuge: c.refuge) {
            arrive(c.refuge)
            return
        }
        let advanced = p.update(lat: lat, lon: lon, graph: graph)
        progress = p
        if advanced {
            stopped = false
            say(p.currentGroup.map(Utterance.init))
        }
    }

    func arrive(_ r: Refuge) {
        arrivedRefuge = r
        state = .arrived
        let key = r.isBuilding ? "arrived_building" : "arrived"
        say(Utterance(config.template(key, ["refuge": r.name]), template: key, vars: ["refuge": r.name]))
    }

    /// "Blocked" (physical: tree down, road closed, car in the way): block the current edge (both directions) and
    /// re-plan from where the user is, preferring the detour that keeps the direction of travel.
    public func blockCurrent() {
        guard state == .navigate, let p = progress, let edge = p.currentEdge else { return }
        let heading = travelHeading
        blocked.insert(edge)
        // On the blocked edge the nearest node may lie past the blockage; start from the node behind the user.
        replan(origin: p.currentNode, prefer: heading)
    }

    /// Block edges named by the voice agent (after the user said yes) and re-plan, keeping the direction of travel.
    public func block(edges: [Int]) {
        let heading = travelHeading
        blocked.formUnion(edges)
        if state == .navigate || state == .choose { replan(origin: nil, prefer: heading) }
    }

    /// "Fire" / "smoke ahead": the fire is where the user is heading (compass heading when available, else the
    /// bearing of the current route edge). Same path as `pointAtNewFire`, with the fixed "Fire ahead" lead.
    public func fireAhead(heading: Double? = nil) {
        guard state == .navigate || state == .choose else {
            say(NavigatorStateMachine.sayAgain)
            return
        }
        guard let b = heading ?? headingProvider() ?? travelHeading ?? fireBearing else {
            say("Point the phone at the smoke and tap.")
            return
        }
        rerouteAwayFromFire(bearing: b, lead: [Utterance(NavigatorStateMachine.fireAhead)])
    }

    /// "New fire" tapped on a phone with no compass (the Simulator, some older phones). Never a silent no-op and
    /// never a silent drop to shelter: the best bearing we have, said aloud so the person can correct it with
    /// "Fire" / a new report: the fire report (fresh or stale) -> the historical prior -> straight ahead (the direction
    /// of travel). Returns the source used, for the UI and the tests.
    @discardableResult
    public func newFireWithoutCompass() -> String {
        guard state == .navigate || state == .choose else {
            say(NavigatorStateMachine.sayAgain)
            return "none"
        }
        func fireIs(_ b: Double) -> Utterance {
            let d = Geo.directionWord(b, config.templates.directions)
            return Utterance(config.phrase("fire_is", ["direction": d]), template: "fire_is", vars: ["direction": d])
        }
        if let b = dataFireBearing {
            rerouteAwayFromFire(bearing: b, lead: [Utterance(NavigatorStateMachine.noCompassReport), fireIs(b), Utterance("Rerouting.")])
            return "report"
        }
        if let b = historyPrior {
            rerouteAwayFromFire(bearing: b, lead: [Utterance(NavigatorStateMachine.noCompassHistory), fireIs(b), Utterance("Rerouting.")])
            return "history"
        }
        if let b = travelHeading ?? fireBearing {
            rerouteAwayFromFire(bearing: b, lead: [Utterance(NavigatorStateMachine.noCompassAhead)])
            return "ahead"
        }
        say("Point the phone at the smoke and tap.")
        return "none"
    }

    /// "Point" mid-route: the compass bearing of the phone, pointed at new smoke. Updates `fireBearing`, closes the
    /// wedge toward it and re-routes: "Fire is to the <direction>." + "Rerouting." + the first instruction.
    public func pointAtNewFire(bearing: Double) {
        guard state == .navigate || state == .choose else {
            point(bearing: bearing)
            return
        }
        let b = Py.mod(bearing, 360.0)
        let d = Geo.directionWord(b, config.templates.directions)
        rerouteAwayFromFire(bearing: b, lead: [Utterance(config.phrase("fire_is", ["direction": d]), template: "fire_is", vars: ["direction": d]),
                                               Utterance("Rerouting.")])
    }

    /// Fire re-plan: fireBearing = `bearing`; block the current edge and every edge in the +-60 deg / 400 m wedge
    /// toward it; Router.choose then drops refuges on the fire side (fireSideOK) and the far side wins.
    func rerouteAwayFromFire(bearing: Double, lead: [Utterance]) {
        fireBearing = bearing
        if let p = originPoint {
            blocked.formUnion(Router.wedgeBlockedEdges(graph, lat: p.lat, lon: p.lon, bearing: bearing))
        }
        if let e = progress?.currentEdge { blocked.insert(e) }
        replan(origin: progress?.currentNode, lead: lead)
    }

    /// Re-plan from the current GPS snap (or `origin`). Stays in Navigate; no route -> Shelter.
    /// `prefer`: previous heading; among similar-time routes the one that keeps it comes first (physical blockage).
    public func replan(origin: Int?, lead: String? = nil, prefer: Double? = nil) {
        replan(origin: origin, lead: lead.map { [Utterance($0)] }, prefer: prefer)
    }

    func replan(origin: Int?, lead: [Utterance]?, prefer: Double? = nil) {
        guard let profile else { return }
        let fresh = route(from: origin ?? originNodeAvoidingBlocked() ?? progress?.currentNode ?? originNode(), prefer: prefer)
        guard let best = fresh.first else {
            choices = []
            progress = nil
            enterShelter(lead: NavigatorStateMachine.noRoute)
            return
        }
        choices = fresh
        choiceIndex = 0
        if state == .choose {
            if let lead { say(lead + choiceUtterances()) } else { sayChoice() }
        } else {
            startNavigation(best, profile: profile, lead: lead ?? [Utterance("Rerouting.")])
        }
    }

    func originNodeAvoidingBlocked() -> Int? {
        guard let p = position, let profile else { return nil }
        if let pr = progress, let e = pr.currentEdge, blocked.contains(e) { return pr.currentNode }
        return graph.snap(p.lat, p.lon, usable: Router.usableOrigin(graph, profile)).node
    }

    /// Caregiver mode: manual-chair clients switch between solo and pushed; re-plans if a route is active.
    public func setVariant(pushed: Bool) {
        guard client?.mobility == "manual_chair" else {
            say("Okay.")
            return
        }
        let wasActive = state == .navigate || state == .choose
        setVariantQuiet(pushed: pushed)
        let lead = pushed ? "Switching to pushed chair." : "Switching to solo."
        if wasActive { replan(origin: nil, lead: lead) } else { say(lead) }
    }

    /// set_status from the voice agent.
    public func setStatus(_ status: String) {
        switch status {
        case "cannot_move": enterShelter(lead: nil)
        case "at_refuge":
            if let r = currentChoice?.refuge, state == .navigate { arrive(r) } else { say("Okay.") }
        default: say("Okay.")
        }
    }

    // MARK: Shelter

    func enterShelter(lead: String?) {
        state = .shelter
        shelterIndex = 0
        progress = nil
        var u: [Utterance] = []
        if let lead { u.append(Utterance(lead)) }
        if let s = shelter.steps.first { u.append(Utterance(s)) }
        say(u)
    }

    public func shelterNext() {
        guard state == .shelter, !shelter.steps.isEmpty else { return }
        if shelterIndex >= shelter.steps.count - 1 {        // past the end: say so instead of going silent (v2, B15)
            say([Utterance(NavigatorStateMachine.shelterLast), Utterance(shelter.steps[shelterIndex])])
            return
        }
        shelterIndex += 1
        say(shelter.steps[shelterIndex])
    }

    public var shelterIsLastStep: Bool { state == .shelter && !shelter.steps.isEmpty && shelterIndex >= shelter.steps.count - 1 }

    /// "Back": previous step; from the first step, back to Home.
    public func shelterBack() {
        guard state == .shelter else { return }
        if shelterIndex == 0 {
            goHome()
            return
        }
        shelterIndex -= 1
        say(shelter.steps[shelterIndex])
    }

    public var shelterStep: String? { shelter.steps.indices.contains(shelterIndex) ? shelter.steps[shelterIndex] : nil }

    // MARK: Arrived / Home

    public func done() { goHome() }

    public func goHome() {
        state = .home
        progress = nil
        choices = []
        utterances = []
        serial += 1
    }

    /// What "repeat" would say right now: the current instruction (Navigate), the current step (Shelter), else the last utterances.
    func currentRepeat() -> [Utterance] {
        switch state {
        case .navigate:
            if let g = progress?.currentGroup, !g.isEmpty { return g.map(Utterance.init) }
            return utterances
        case .shelter:
            if let s = shelterStep { return [Utterance(s)] }
            return utterances
        default:
            return utterances
        }
    }

    /// Repeat: the current instruction (Navigate), the current step (Shelter), else the last utterances.
    public func repeatCurrent() {
        stopped = false
        switch state {
        case .choose:
            sayChoice()
        default:
            say(currentRepeat())
        }
    }

    // MARK: Voice

    public func currentStreet() -> String? {
        if let e = progress?.currentEdge { return streets.streetName(edge: e) }
        if let p = position, let ne = graph.nearestEdge(p.lat, p.lon, maxM: 100) { return streets.streetName(edge: ne.edge) }
        return nil
    }

    public func resolveStreet(_ street: String, cross: String?) -> StreetLookup.Match? {
        guard let p = originPoint else { return nil }
        var ahead: [Int] = []
        if let pr = progress { ahead = Array(pr.route.edges[min(pr.edgeOffset, pr.route.edges.count)...]) }
        return streets.resolve(street: street, crossStreet: cross, nearLat: p.lat, nearLon: p.lon, routeAhead: ahead)
    }

    /// Apply an on-device intent (also the fallback for Claude).
    public func handle(_ intent: Intent) {
        switch intent {
        case .blocked:
            if state == .navigate { blockCurrent() } else { say(NavigatorStateMachine.sayAgain) }
        case .fire:
            fireAhead()
        case .repeat:
            repeatCurrent()
        case .slower:
            say([Utterance("Going slower.")] + currentRepeat())
        case .louder:
            say([Utterance("Louder.")] + currentRepeat())
        case .pushing:
            setVariant(pushed: true)
        case .cantMove:
            switch state {
            case .whichWay, .choose, .navigate: enterShelter(lead: nil)
            case .shelter: repeatCurrent()
            default: say("Okay.")
            }
        case .whereAmI:
            if let s = currentStreet() {
                say(Utterance(config.phrase("where", ["street": s]), template: "where", vars: ["street": s]))
            } else {
                say(NavigatorStateMachine.sayAgain)
            }
        case .howLong:
            if let t = remainingRouteTimeS, state == .navigate || state == .choose {
                let n = String(max(1, Int(ceil(t / 60.0))))
                say(Utterance(config.phrase("how_long", ["n": n]), template: "how_long", vars: ["n": n]))
            } else {
                say(NavigatorStateMachine.sayAgain)
            }
        case .whichWay:
            if state == .navigate, let p = progress, !p.route.edges.isEmpty {
                let i = min(p.edgeOffset, p.route.edges.count - 1)
                let d = Geo.directionWord(graph.edgeBearing(p.route.edges[i], p.route.forward[i]), config.templates.directions)
                say(Utterance(config.phrase("which_way", ["direction": d]), template: "which_way", vars: ["direction": d]))
            } else {
                say(NavigatorStateMachine.sayAgain)
            }
        case .stop:
            stopped = true
            say("Stopped. Speak or tap a button when you are ready.")
        case .yes:
            switch state {
            case .whichWay where fireIsFresh: confirmFire()
            case .choose: go()
            default: say("Okay.")
            }
        case .no:
            if state == .choose && choices.count > 1 { other() } else { say("Okay.") }
        }
    }

    func setVariantQuiet(pushed: Bool) {
        guard let client, client.mobility == "manual_chair" else { return }
        caregiver = pushed
        profile = try? Profile(client.profileKey(caregiver: pushed), batteryPct: client.batteryPct, config: config)
    }

    /// Apply a confirmed voice command.
    public func apply(_ cmd: VoiceCommand) {
        switch cmd {
        case .intent(let i): handle(i)
        case .blockEdges(let m): block(edges: m.edges)
        case .setProfile(let pushed): setVariant(pushed: pushed)
        case .setStatus(let s): setStatus(s)
        case .reroute:
            if state == .navigate || state == .choose { replan(origin: nil) } else { say(NavigatorStateMachine.sayAgain) }
        case .repeatInstruction: repeatCurrent()
        case .reportPosition: handle(.whereAmI)
        }
    }
}
