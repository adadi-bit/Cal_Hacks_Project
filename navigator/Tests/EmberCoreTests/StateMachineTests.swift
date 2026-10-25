import Foundation
import Testing
@testable import EmberCore

@Suite struct StateMachineTests {
    let fresh = Timestamps.parse("2026-10-23T13:00:00Z")!   // fixture fire data is 1 h old
    let stale = Timestamps.parse("2026-10-23T19:00:00Z")!   // 7 h old

    func machine(_ now: Date) -> NavigatorStateMachine {
        let m = NavigatorStateMachine(bundle: Fixtures.bundle)
        m.clock = { now }
        return m
    }

    @Test func bedboundAlwaysShelter() throws {
        let m = machine(fresh)
        try m.start(client: Fixtures.client("bedbound"), caregiver: true)
        #expect(m.state == .shelter)
        #expect(m.shelter.room == "back bedroom")
        #expect(m.utterances.map(\.text) == ["Go to the back bedroom."])
        m.confirmFire(); m.go()
        #expect(m.state == .shelter)
    }

    @Test func freshFireDataAsksToConfirmDirection() throws {
        let m = machine(fresh)
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        #expect(m.state == .whichWay)
        #expect(m.fireIsFresh)
        #expect(m.utterances.map(\.text) == ["Fire is to the northeast. OK?"])   // wind from 45 deg, no perimeter
        m.confirmFire()
        #expect(m.state == .choose)
        #expect(m.fireBearing == 45)
        let a = try #require(m.currentChoice), b = try #require(m.alternateChoice)
        #expect(m.utterances.map(\.text) == ["Go to \(a.refuge.name). \(a.route.minutes) minutes.", "Or \(b.refuge.name). \(b.route.minutes) minutes."])
    }

    @Test func staleFireDataAsksToPoint() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        #expect(m.state == .whichWay)
        #expect(!m.fireIsFresh)
        #expect(m.utterances.map(\.text) == ["Point the phone at the smoke and tap."])
        m.confirmFire()                       // OK is not available with stale data
        #expect(m.state == .whichWay)
        m.point(bearing: 270)
        #expect(m.state == .choose)
        #expect(m.fireBearing == 270)
    }

    @Test func chooseOtherGoNavigateArriveDone() throws {
        let m = machine(fresh)
        try m.start(client: Fixtures.client("manual_chair", node: 0), caregiver: false)
        m.point(bearing: 200)
        let first = try #require(m.currentChoice)
        m.other()
        #expect(m.currentChoice?.refuge.id != first.refuge.id)
        m.go()
        #expect(m.state == .navigate)
        let c = try #require(m.currentChoice)
        #expect(m.utterances.first?.template == "start")
        // Walk the route node by node: cues advance, then arrival within 25 m.
        var spoken: [String] = m.utterances.map(\.text)
        var last = m.serial
        for n in c.route.nodes {
            m.updatePosition(lat: Fixtures.bundle.graph.lat[n], lon: Fixtures.bundle.graph.lon[n])
            if m.serial != last { spoken += m.utterances.map(\.text); last = m.serial }
            if m.state == .arrived { break }
        }
        #expect(m.state == .arrived)
        let key = c.refuge.isBuilding ? "arrived_building" : "arrived"
        #expect(m.utterances.first?.template == key)
        #expect(m.utterances.first?.text == Fixtures.config.template(key, ["refuge": c.refuge.name]))
        let cueTexts = Cues(graph: Fixtures.bundle.graph, config: Fixtures.config).buildCues(c.route, refugeName: c.refuge.name)
            .filter { $0.template != "arrive" }.map(\.text)
        for t in cueTexts { #expect(spoken.contains(t), "\(t) spoken") }
        m.done()
        #expect(m.state == .home)
    }

    @Test func arrivedTextForLot() throws {
        let m = machine(fresh)
        try m.start(client: Fixtures.client("walker", node: 0), caregiver: false)
        m.point(bearing: 200)
        while m.currentChoice?.refuge.id != "r_safeway" { m.other() }
        m.go()
        let ep = m.currentChoice!.refuge.entryPoints[0]
        m.updatePosition(lat: ep.lat + 20 / 111320.0, lon: ep.lon)   // 20 m away
        #expect(m.state == .arrived)
        #expect(m.utterances.map(\.text) == ["You are at the Safeway lot. Stay in the middle, away from the cars. Keep the phone on."])
    }

    @Test func cantMoveFromChooseAndNavigate() throws {
        let m = machine(fresh)
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.confirmFire()
        #expect(m.state == .choose)
        m.cantMove()
        #expect(m.state == .shelter)
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.confirmFire(); m.go()
        #expect(m.state == .navigate)
        m.handle(.cantMove)
        #expect(m.state == .shelter)
    }

    @Test func shelterNextRepeatBack() throws {
        let m = machine(fresh)
        try m.start(client: Fixtures.client("bedbound"), caregiver: false)
        m.shelterNext()
        #expect(m.utterances.map(\.text) == ["Close every window and door. Close the vents."])
        let s = m.serial
        m.repeatCurrent()
        #expect(m.serial == s + 1 && m.utterances.map(\.text) == ["Close every window and door. Close the vents."])
        for _ in 0..<10 { m.shelterNext() }
        #expect(m.shelterStep == "Call 911. Say: I am in the back bedroom.")
        for _ in 0..<5 { m.shelterBack() }
        #expect(m.shelterIndex == 0 && m.state == .shelter)
        m.shelterBack()
        #expect(m.state == .home)
    }

    @Test func caregiverModeUsesPushedProfileForManualChairOnly() throws {
        let m = machine(fresh)
        try m.start(client: Fixtures.client("manual_chair"), caregiver: true)
        #expect(m.profile?.key == "manual_chair_pushed")
        try m.start(client: Fixtures.client("manual_chair"), caregiver: false)
        #expect(m.profile?.key == "manual_chair")
        try m.start(client: Fixtures.client("power_chair"), caregiver: true)
        #expect(m.profile?.key == "power_chair")
        try m.start(client: Fixtures.client("cane"), caregiver: true)
        #expect(m.profile?.key == "walker")
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.confirmFire(); m.go()
        m.handle(.pushing)
        #expect(m.profile?.key == "manual_chair_pushed")
        #expect(m.state == .navigate)
        #expect(m.utterances.first?.text == "Switching to pushed chair.")
    }

    @Test func blockedStaysInNavigateWithNewRoute() throws {
        let m = machine(fresh)
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.confirmFire(); m.go()
        let before = m.progress!.route.edges
        m.handle(.blocked)
        #expect(m.state == .navigate)
        #expect(m.blocked == [before[0]])
        #expect(m.progress!.route.edges != before)
        #expect(m.utterances.first?.text == "Rerouting.")
    }

    @Test func voiceIntentsSpeakFixedTemplates() throws {
        let m = machine(fresh)
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.confirmFire(); m.go()
        m.handle(.whereAmI)
        #expect(m.utterances.first?.template == "where")
        #expect(m.utterances.first?.text.hasPrefix("You are on ") == true)
        m.handle(.howLong)
        #expect(m.utterances.first?.text.hasSuffix(" minutes to go.") == true)
        m.handle(.whichWay)
        #expect(m.utterances.first?.text.hasPrefix("Go ") == true)
        m.handle(.stop)
        #expect(m.stopped)
        #expect(m.utterances.first?.text == "Stopped. Speak or tap a button when you are ready.")
        m.handle(.repeat)
        #expect(!m.stopped)
    }

    @Test func homeShowsFireDataAge() {
        let t = Fixtures.bundle.fireDataTimestamp!
        #expect(Timestamps.ageText(Timestamps.parse("2026-10-23T15:00:00Z")!.timeIntervalSince(t)) == "3 h ago")
    }

    func bearingTo(_ m: NavigatorStateMachine, _ r: Refuge, from node: Int) -> Double {
        let g = m.graph
        return Geo.bearingDeg(g.lat[node], g.lon[node], r.centroidLat, r.centroidLon)
    }

    @Test func fireAheadClosesTheWedgeAndTurnsAway() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.point(bearing: 200); m.go()
        let heading = try #require(m.travelHeading)
        let before = m.progress!.route.edges
        m.handle(.fire)                      // no compass: the route edge bearing is the fire bearing
        #expect(m.state == .navigate)
        #expect(m.fireBearing == heading)
        let wedge = Router.wedgeBlockedEdges(m.graph, lat: m.graph.lat[112], lon: m.graph.lon[112], bearing: heading)
        #expect(m.blocked == wedge.union([before[0]]))
        #expect(m.utterances.first?.text == "Fire ahead. Turning away from it.")
        #expect(m.utterances.count > 1)
        let c = try #require(m.currentChoice)
        #expect(Geo.angdiff(bearingTo(m, c.refuge, from: 112), heading) > Router.fireSideHalfAngle)
        #expect(wedge.isDisjoint(with: c.route.edges))
        #expect(m.alternateChoice != nil)    // B stays the fallback
    }

    @Test func fireAheadUsesTheCompassWhenAvailable() throws {
        let m = machine(stale)
        m.headingProvider = { 90 }
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        m.point(bearing: 200); m.go()
        m.handle(.fire)
        #expect(m.fireBearing == 90)
        #expect(m.state == .navigate)
        #expect(Geo.angdiff(bearingTo(m, m.currentChoice!.refuge, from: 112), 90) > Router.fireSideHalfAngle)
    }

    // "New fire" with no compass: report -> history prior -> straight ahead, each said aloud; never silent.
    @Test func newFireWithoutCompassUsesTheFireReportAndSaysSo() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        m.point(bearing: 200); m.go()
        #expect(m.state == .navigate)
        let b = try #require(m.dataFireBearing)            // the stale report still has a bearing (wind from 45)
        #expect(m.newFireWithoutCompass() == "report")
        #expect(m.fireBearing == b)
        #expect(m.utterances.first?.text == NavigatorStateMachine.noCompassReport)
        #expect(m.utterances.dropFirst().first?.text == "Fire is to the northeast.")
        #expect(m.utterances.count >= 3)                    // + "Rerouting." / the no-route shelter lead
        #expect(m.state == .navigate || m.state == .shelter)
    }

    @Test func newFireWithoutCompassFallsBackToStraightAheadWhenNothingIsKnown() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        m.point(bearing: 200); m.go()
        m.fireData = FireData(perimeter: nil, wind: nil)
        #expect(m.dataFireBearing == nil)
        #expect(m.historyPrior == nil)                      // the fake bundle has no history.json
        let heading = try #require(m.travelHeading)
        #expect(m.newFireWithoutCompass() == "ahead")
        #expect(m.fireBearing == heading)
        #expect(m.utterances.first?.text == NavigatorStateMachine.noCompassAhead)
        #expect(m.utterances.count >= 2)
    }

    @Test func newFireWithoutCompassOutsideNavigateAsksAgain() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        #expect(m.newFireWithoutCompass() == "none")
        #expect(m.utterances.map(\.text) == [NavigatorStateMachine.sayAgain])
        #expect(m.state == .whichWay)
    }

    @Test func noCompassLeadsArePreRecordedPhrases() {
        let fixed = Fixtures.config.phrases.fixed
        for t in [NavigatorStateMachine.noCompassReport, NavigatorStateMachine.noCompassHistory, NavigatorStateMachine.noCompassAhead] {
            #expect(fixed.contains(t), "\(t) must be in shared/phrases.json so Henry, not the Apple voice, says it")
        }
    }

    // The bundle's plan file is the single source: the card's refuge_ids must match it, and live routing keeps
    // the plan's A first whenever the router still allows it, so phone and printed card say the same place.
    @Test func cardMatchesPlanFileOrSaysSo() throws {
        #expect(NavigatorStateMachine.cardMatchesPlan(cardIds: ["r1", "r2"], planIds: ["r1", "r2"]))
        #expect(NavigatorStateMachine.cardMatchesPlan(cardIds: nil, planIds: ["r1", "r2"]))      // old card without ids
        #expect(NavigatorStateMachine.cardMatchesPlan(cardIds: ["r1"], planIds: []))             // bundle without a plan file
        #expect(!NavigatorStateMachine.cardMatchesPlan(cardIds: ["r9", "r2"], planIds: ["r1", "r2"]))
        #expect(!NavigatorStateMachine.cardMatchesPlan(cardIds: ["r2", "r1"], planIds: ["r1", "r2"]))  // A/B swapped by staff
        #expect(Fixtures.config.phrases.fixed.contains(NavigatorStateMachine.cardMismatch))
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        #expect(m.planRefugeIds.isEmpty && !m.cardMismatch)                                       // fake bundle: no plan file
    }

    @Test func liveChoicesKeepThePlanFilesRefugeFirst() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        m.point(bearing: 200)
        let live = m.choices
        try #require(live.count > 1)
        let b = live[1].refuge.id
        let re = NavigatorStateMachine.ordered(live, planIds: [b, live[0].refuge.id])
        #expect(re.first?.refuge.id == b)
        #expect(Set(re.map(\.refuge.id)) == Set(live.map(\.refuge.id)))
        #expect(NavigatorStateMachine.ordered(live, planIds: ["not-a-refuge"]).map(\.refuge.id) == live.map(\.refuge.id))
        #expect(NavigatorStateMachine.ordered(live, planIds: []).map(\.refuge.id) == live.map(\.refuge.id))
    }

    @Test func fireOutsideNavigateAsksAgain() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        m.handle(.fire)
        #expect(m.state == .whichWay)
        #expect(m.utterances.map(\.text) == ["Say again?"])
    }

    @Test func pointAtNewFireUpdatesBearingAndReroutes() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        m.point(bearing: 200); m.go()
        let before = m.progress!.route.edges
        let serial = m.serial
        m.pointAtNewFire(bearing: 45)
        #expect(m.state == .navigate)
        #expect(m.serial == serial + 1)
        #expect(m.fireBearing == 45)
        #expect(m.utterances.map(\.text).prefix(2) == ["Fire is to the northeast.", "Rerouting."])
        #expect(m.utterances.first?.template == "fire_is")
        #expect(m.progress!.route.edges != before)
        let c = try #require(m.currentChoice)
        #expect(Geo.angdiff(bearingTo(m, c.refuge, from: 112), 45) > Router.fireSideHalfAngle)
        let wedge = Router.wedgeBlockedEdges(m.graph, lat: m.graph.lat[112], lon: m.graph.lon[112], bearing: 45)
        #expect(m.blocked.isSuperset(of: wedge))
        #expect(wedge.isDisjoint(with: c.route.edges))
        // before Navigate it is the WhichWay "Point"
        let w = machine(stale)
        try w.start(client: Fixtures.client("manual_chair", node: 112), caregiver: false)
        w.pointAtNewFire(bearing: 270)
        #expect(w.state == .choose && w.fireBearing == 270)
    }

    @Test func physicalBlockKeepsDirection() throws {
        // Node 60: the fastest detour after blocking the first edge doubles back; the direction rule keeps going.
        let m = machine(stale)
        let g = Fixtures.bundle.graph
        try m.start(client: Fixtures.client("manual_chair", node: 60), caregiver: false)
        m.point(bearing: 270)
        // pick a refuge whose first edge heads east so the detour choice is meaningful
        let p = Fixtures.profile("manual_chair")
        let base = Router.choose(g, refuges: Fixtures.bundle.refuges, profile: p, origin: 60)
        let first = try #require(base.first)
        while m.currentChoice?.refuge.id != first.refuge.id { m.other() }
        m.go()
        let heading = try #require(m.travelHeading)
        m.handle(.blocked)
        #expect(m.state == .navigate)
        #expect(m.fireBearing == 270)                    // a physical block does not move the fire
        #expect(m.utterances.first?.text == "Rerouting.")
        let plain = Router.choose(g, refuges: Fixtures.bundle.refuges, profile: p, origin: 60, fireBearing: 270, blocked: m.blocked)
        let want = Router.preferHeading(g, plain, heading: heading)
        #expect(m.choices.map(\.refuge.id) == want.map(\.refuge.id))
        let limit = plain[0].route.timeS * Router.headingSimilarRatio
        func turn(_ c: Choice) -> Double { Geo.angdiff(Router.initialHeading(g, route: c.route)!, heading) }
        #expect(turn(m.currentChoice!) <= plain.filter { $0.route.timeS <= limit }.map(turn).min()!)
    }
}

@Suite struct HistoryPriorTests {
    let stale = Timestamps.parse("2026-10-23T19:00:00Z")!

    @Test func notSureOnWhichWayPlansWithoutDeadEnd() throws {
        let m = NavigatorStateMachine(bundle: Fixtures.bundle)
        m.clock = { stale }
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        #expect(m.state == .whichWay)
        #expect(!m.fireIsFresh)
        #expect(m.historyPrior == nil)                        // the fake bundle has no history.json
        m.skipFireDirection()
        #expect(m.state == .choose)
        #expect(m.fireBearing == m.dataFireBearing)           // the stale report still beats nothing, and it says so
        #expect(m.utterances.first?.text == NavigatorStateMachine.lastReport)
        #expect(m.currentChoice != nil)
        m.skipFireDirection()                                 // only valid on Which Way
        #expect(m.state == .choose)
    }

    @Test func historyFileDecodesEnginePriorAndPhraseExists() throws {
        let json = """
        {"since": 2017, "fires": [{"fire": "Camp (2018)", "date": "2018-11-08", "acres": 153335.6}],
         "prior_bearing_deg": 86.8, "source": "CAL FIRE FRAP"}
        """.data(using: .utf8)!
        let h = try JSONDecoder().decode(HistoryFile.self, from: json)
        #expect(h.priorBearingDeg == 86.8)
        #expect(h.fires?.first?.fire == "Camp (2018)")
        let d = Geo.directionWord(86.8, Fixtures.config.templates.directions)
        #expect(d == "east")
        #expect(Fixtures.config.phrase("history_dir", ["direction": d]) == "No fresh fire data. Past fires here came from the east.")
    }
}

@Suite struct FoldedLogicTests {
    func machine(_ now: Date) -> NavigatorStateMachine {
        let m = NavigatorStateMachine(bundle: Fixtures.bundle)
        m.clock = { now }
        return m
    }
    let stale = Timestamps.parse("2026-10-23T19:00:00Z")!   // 7 h old

    @Test func notSureWithAStaleReportSaysSoThenTheChoices() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        #expect(m.state == .whichWay)
        let b = try #require(m.dataFireBearing)
        m.skipFireDirection()
        #expect(m.state == .choose)
        #expect(m.fireBearing == b)
        #expect(m.utterances.first?.text == NavigatorStateMachine.lastReport)
        #expect(m.utterances.count >= 2)
    }

    @Test func notSureWithNothingKnownStillOffersTheNearestPlaces() throws {
        let m = machine(stale)
        m.fireData = FireData(perimeter: nil, wind: nil)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        m.skipFireDirection()
        #expect(m.state == .choose)
        #expect(m.fireBearing == nil)
        #expect(m.utterances.first?.text == NavigatorStateMachine.noFireInfo)
    }

    @Test func shelterPastTheLastStepSaysSoInsteadOfGoingSilent() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        m.cantMove()
        #expect(m.state == .shelter)
        for _ in 0..<20 { m.shelterNext() }
        #expect(m.shelterIsLastStep)
        #expect(m.utterances.first?.text == NavigatorStateMachine.shelterLast)
        #expect(m.utterances.count == 2)
    }

    @Test func pickerDirectionIsAPointOnWhichWayAndANewFireMidRoute() throws {
        let m = machine(stale)
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        m.point(bearing: 45)                                  // tapped "Northeast" on the picker
        #expect(m.state == .choose)
        #expect(m.fireBearing == 45)
        m.go()
        #expect(m.state == .navigate)
        m.pointAtNewFire(bearing: 270)                        // tapped "West" mid-route
        #expect(m.fireBearing == 270)
        #expect(m.utterances.first?.text == "Fire is to the west.")
    }

    @Test func foldedLeadsArePreRecordedPhrases() {
        let fixed = Fixtures.config.phrases.fixed
        for t in [NavigatorStateMachine.lastReport, NavigatorStateMachine.noFireInfo, NavigatorStateMachine.shelterLast,
                  NavigatorStateMachine.whichWaySmoke, NavigatorStateMachine.whichWayNewFire] {
            #expect(fixed.contains(t), "\(t) must be in shared/phrases.json so Henry, not the Apple voice, says it")
        }
    }
}

@Suite struct ConfirmStepTests {
    let stale = Timestamps.parse("2026-10-23T19:00:00Z")!
    func navigating() throws -> NavigatorStateMachine {
        let m = NavigatorStateMachine(bundle: Fixtures.bundle)
        m.clock = { stale }
        try m.start(client: Fixtures.client("walker", node: 112), caregiver: false)
        m.point(bearing: 200); m.go()
        #expect(m.state == .navigate)
        return m
    }

    @Test func blockedAsksFirstAndNoKeepsTheRoute() throws {
        let m = try navigating()
        let before = m.progress?.route.edges
        m.requestBlocked()
        #expect(m.pending == .blocked)
        #expect(m.utterances.first?.text == NavigatorStateMachine.rerouteQuestion)
        m.cancelPending()
        #expect(m.pending == nil)
        #expect(m.utterances.first?.text == NavigatorStateMachine.okay)
        #expect(m.progress?.route.edges == before, "No keeps the route")
        #expect(m.blocked.isEmpty)
    }

    @Test func blockedYesReroutes() throws {
        let m = try navigating()
        let edge = try #require(m.progress?.currentEdge)
        m.requestBlocked(); m.confirmPending()
        #expect(m.pending == nil)
        #expect(m.blocked.contains(edge))
        #expect(m.state == .navigate || m.state == .shelter)
    }

    @Test func newFireAsksFirstThenRunsTheNoCompassChain() throws {
        let m = try navigating()
        m.requestFire(heading: nil)
        #expect(m.pending == .newFireNoCompass)
        #expect(m.utterances.first?.text == NavigatorStateMachine.fireAheadQuestion)
        m.confirmPending()
        #expect(m.utterances.first?.text == NavigatorStateMachine.noCompassReport)   // stale report still has a bearing
    }

    @Test func startOverNeedsAYes() throws {
        let m = try navigating()
        m.requestStartOver()
        #expect(m.utterances.first?.text == NavigatorStateMachine.startOverQuestion)
        m.cancelPending()
        #expect(m.state == .navigate)
        m.requestStartOver(); m.confirmPending()
        #expect(m.state == .home)
    }

    @Test func confirmPhrasesArePreRecorded() {
        let fixed = Fixtures.config.phrases.fixed
        for t in [NavigatorStateMachine.rerouteQuestion, NavigatorStateMachine.fireAheadQuestion, NavigatorStateMachine.startOverQuestion, NavigatorStateMachine.okay] {
            #expect(fixed.contains(t), "\(t) must be in shared/phrases.json")
        }
    }
}
