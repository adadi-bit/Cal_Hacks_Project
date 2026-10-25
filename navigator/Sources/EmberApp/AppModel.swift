import Foundation
import SwiftUI
import Combine
import CoreLocation
import EmberCore

/// Owns the bundle, the state machine and the device services; the views read only from here.
@MainActor
public final class AppModel: ObservableObject {
    public static let autoRepeatS: TimeInterval = 45
    static let feedRefreshS: TimeInterval = 300

    // Bundle and profiles
    @Published public private(set) var bundle: EmberBundle?
    @Published public private(set) var loadError: String?
    @Published public private(set) var profiles: [ClientProfile] = []
    @Published public var selectedId: String? { didSet { UserDefaults.standard.set(selectedId, forKey: "selectedId") } }
    @Published public var caregiverMode: Bool { didSet { UserDefaults.standard.set(caregiverMode, forKey: "caregiverMode") } }
    @Published public private(set) var notice: String?

    // Device-runtime deadline
    @Published public private(set) var powerOutSince: Date?
    @Published public private(set) var leaveNow: String?

    // Navigation mirror (the machine is a plain class)
    @Published public private(set) var state: NavState = .home
    /// Navigate map: whole route for a second, then a close heading-up view that follows the GPS fix.
    @Published public private(set) var follow = FollowCamera()
    @Published public private(set) var mapViewport: FollowCamera.Viewport?
    @Published private(set) var satellites: [SatelliteSnapshot] = []
    private var followTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var cameraAnimation: Timer?
    @Published public private(set) var tick = 0
    @Published public private(set) var feedNote: String?

    public let speaker = Speaker()
    public let voice = VoiceController()
    public let location = LocationService()
    public let compass = CompassService()

    public private(set) var machine: NavigatorStateMachine?
    private var processor: VoiceCommandProcessor?
    private var spokenSerial = -1
    private var repeatTimer: Timer?
    private var minuteTimer: Timer?
    private var leaveNowSpoken = false
    private var feed: ApifyFeed?
    private var lastFeedFetch: Date?
    private var fireFeed: FireFeed?
    private var lastFireFetch: Date?
    /// The newest successful keyless fire check (NIFC WFIGS + NWS); nil = the bundle snapshot is all we have.
    @Published public private(set) var liveFire: FireFeed.Check?
    @Published public private(set) var fireCheckFailed = false
    let store = BundleStore()
    private lazy var profileStore = ProfileStore(support: store.support)

    public init() {
        caregiverMode = UserDefaults.standard.bool(forKey: "caregiverMode")
        selectedId = UserDefaults.standard.string(forKey: "selectedId")
        let t = UserDefaults.standard.double(forKey: "powerOutSince")
        powerOutSince = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static let powerScopeKey = "powerOutScope"

    // MARK: launch

    /// onAppear can fire again whenever the root view is rebuilt (e.g. the `.id(fontChoice)` key on font change);
    /// setup must run once or it leaks a second minuteTimer and resets the state machine mid-session.
    private var launched = false

    public func launch() {
        guard !launched else { return }
        launched = true
        Platform.activatePlaybackSession()
        profiles = profileStore.load()
        if selectedId == nil || !profiles.contains(where: { $0.id == selectedId }) { selectedId = profiles.first?.id }
        loadBundle()
        location.onFix = { [weak self] l in self?.gotFix(l) }
        location.start()
        compass.start()
        compass.$heading.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateFollowCamera() }.store(in: &cancellables)
        voice.requestAuthorization()
        voice.onlineChanged = { [weak self] up in self?.networkChanged(up) }
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodic() }
        }
        periodic()
    }

    public func loadBundle() {
        do {
            let b = try store.load(county: selected?.county)
            bundle = b
            machine = NavigatorStateMachine(bundle: b)
            machine?.headingProvider = { [weak self] in self?.compass.heading }
            processor = VoiceCommandProcessor(matcher: IntentMatcher(b.config.intents), config: b.config)
            loadError = nil
            configureFeed()
            configureFireFeed()
        } catch {
            loadError = "\(error)"
        }
        speaker.configure(bundle: bundle, clientId: selectedId)
        configureCartesia()
        reloadSatellites()
        sync()
    }

    /// Re-read keys after Settings is saved.
    public func settingsChanged() {
        configureCartesia()
        configureFeed()
    }

    func configureCartesia() {
        speaker.online = voice.online
        if let key = KeychainStore.get(.cartesiaAPIKey) {
            if speaker.cartesia == nil { speaker.cartesia = CartesiaStream(apiKey: key) }
            speaker.voiceId = selected?.voice?.voiceId ?? KeychainStore.get(.cartesiaVoiceId)
            if voice.online { speaker.cartesia?.open() }
        } else {
            speaker.cartesia?.close()
            speaker.cartesia = nil
        }
    }

    func configureFeed() {
        guard let b = bundle, let ds = KeychainStore.get(.apifyDatasetId) else { feed = nil; return }
        feed = ApifyFeed(datasetId: ds, token: KeychainStore.get(.apifyToken), county: b.county,
                         cacheURL: store.support.appendingPathComponent("feed-\(b.county).json"))
        applyFeed(feed!.cached())
    }

    func networkChanged(_ up: Bool) {
        speaker.online = up
        if up { speaker.cartesia?.open(); refreshFeed(force: true); refreshFire(force: true) } else { speaker.cartesia?.close() }
    }

    // MARK: live fire data (keyless; the bundle stays the offline truth)

    var fireCacheURL: URL? { bundle.map { store.support.appendingPathComponent("fire-\($0.county).json") } }

    func configureFireFeed() {
        liveFire = nil; lastFireFetch = nil; fireCheckFailed = false
        guard let b = bundle, let bbox = b.manifest?.bbox, bbox.count == 4 else { fireFeed = nil; return }
        fireFeed = FireFeed(bbox: bbox, windSource: b.wind?.source)
        if let u = fireCacheURL, let d = try? Data(contentsOf: u), let c = try? JSONDecoder().decode(FireFeed.Check.self, from: d) {
            applyFireCheck(c, cache: false)
        }
    }

    func refreshFire(force: Bool) {
        guard let fireFeed, voice.online else { return }
        if !force, let t = lastFireFetch, Date().timeIntervalSince(t) < 60 { return }
        lastFireFetch = Date()
        Task { @MainActor in
            if let c = await fireFeed.fetch() { self.applyFireCheck(c, cache: true) } else { self.fireCheckFailed = true }
        }
    }

    /// Newer than what the phone has -> the state machine's fire inputs change; older (a stale cache) is ignored.
    func applyFireCheck(_ c: FireFeed.Check, cache: Bool) {
        fireCheckFailed = false
        let have = liveFire?.checkedAt ?? bundle?.fireDataTimestamp ?? .distantPast
        guard c.checkedAt >= have else { return }
        liveFire = c
        machine?.fireData = FireData(perimeter: c.perimeter, wind: c.wind ?? bundle?.wind)
        if cache, let u = fireCacheURL, let d = try? JSONEncoder().encode(c) { try? d.write(to: u, options: .atomic) }
        sync()
    }

    /// Newest fire inputs the phone has (live check or bundle snapshot).
    public var fireDataTimestamp: Date? { machine?.fireData.timestamp ?? bundle?.fireDataTimestamp }

    public var fireStatusText: String {
        FireFeed.statusText(dataAge: fireDataTimestamp.map { Date().timeIntervalSince($0) }, stale: fireIsStale, online: voice.online,
                            lastCheck: liveFire?.checkedAt, checkFailed: fireCheckFailed, now: Date())
    }

    /// "Map and voice from Oct 24": when staff last synced this bundle.
    public var bundleBuiltText: String? {
        Timestamps.dayText(bundle?.manifest?.builtAt).map { "Map and voice from \($0)" }
    }

    // MARK: profiles

    public var selected: ClientProfile? { profiles.first { $0.id == selectedId } }

    public func addProfile(fromCode code: String) {
        do {
            let p = try QRPayload.parse(code)
            profiles.removeAll { $0.id == p.id }
            profiles.append(p)
            profileStore.save(profiles)
            selectedId = p.id
            checkPowerScope()
            notice = "Added \(p.name)."
            if let b = bundle, let c = p.county, c != b.county { notice = "Added \(p.name). The map on this phone is for \(b.county), not \(c)." }
            speaker.configure(bundle: bundle, clientId: selectedId)
        } catch {
            notice = "That code is not an Ember card. Try again."
        }
        speaker.speak([Utterance(notice ?? "Okay.")])
    }

    public func handleURL(_ url: URL) {
        if url.scheme == "ember" { addProfile(fromCode: url.absoluteString) }
    }

    public func removeProfile(_ id: String) {
        profiles.removeAll { $0.id == id }
        profileStore.save(profiles)
        if selectedId == id { selectedId = profiles.first?.id }
    }

    public func select(_ id: String) {
        selectedId = id
        checkPowerScope()
        speaker.configure(bundle: bundle, clientId: id)
        speaker.voiceId = selected?.voice?.voiceId ?? KeychainStore.get(.cartesiaVoiceId)
    }

    // MARK: power out

    public var powerIsOut: Bool { powerOutSince != nil }

    public func setPowerOut(_ on: Bool, at date: Date = Date()) {
        powerOutSince = on ? (powerOutSince ?? date) : nil
        UserDefaults.standard.set(powerOutSince?.timeIntervalSince1970 ?? 0, forKey: "powerOutSince")
        UserDefaults.standard.set(on ? powerScope : nil, forKey: AppModel.powerScopeKey)
        // Once the user says the power is back, no feed report re-arms the timer for this card and bundle; only the
        // user (or a new card / bundle) can. Stored by scope so a new card starts fresh.
        UserDefaults.standard.set(on ? nil : powerScope, forKey: AppModel.powerUserClearedKey)
        leaveNowSpoken = false
        periodic()
    }

    static let powerUserClearedKey = "powerUserCleared"

    /// May a county-feed outage report start the timer? Not while the timer runs, and never after the user cleared
    /// it for this card and bundle.
    var feedMayArmPower: Bool {
        DeviceTimer.feedMayArm(timerRunning: powerIsOut,
                               userClearedScope: UserDefaults.standard.string(forKey: AppModel.powerUserClearedKey),
                               scope: powerScope)
    }

    /// "Power is back": clears the timer and the Leave-now banner, and says so.
    public func powerBack() {
        setPowerOut(false)
        speaker.speak([Utterance("Power is back.")])
    }

    var powerScope: String { DeviceTimer.scope(clientId: selectedId, county: bundle?.county, builtAt: bundle?.manifest?.builtAt) }

    /// A timer started for another card or another bundle build does not carry over (field report: "Oxygen has 1
    /// minute left" pinned for hours after testing with a different bundle).
    func checkPowerScope() {
        guard powerIsOut, UserDefaults.standard.string(forKey: AppModel.powerScopeKey) != powerScope else { return }
        powerOutSince = nil
        UserDefaults.standard.set(0, forKey: "powerOutSince")
        UserDefaults.standard.removeObject(forKey: AppModel.powerScopeKey)
        UserDefaults.standard.removeObject(forKey: AppModel.powerUserClearedKey)
        leaveNow = nil
        leaveNowSpoken = false
    }

    // MARK: derived for views

    public var fireAgeText: String {
        guard let t = fireDataTimestamp else { return "Fire data: none on this phone" }
        return "Fire data from \(Timestamps.ageText(Date().timeIntervalSince(t)))"
    }

    public var fireIsStale: Bool { !(machine?.fireIsFresh ?? false) }

    public var displayText: String {
        if !speaker.currentText.isEmpty { return speaker.currentText }
        return machine?.utterances.first?.text ?? ""
    }

    public var fireBearingWord: String? {
        guard let m = machine, let b = m.dataFireBearing, m.fireIsFresh else { return nil }
        return Geo.directionWord(b, m.config.templates.directions)
    }

    // MARK: actions (buttons)

    public func start() {
        guard let c = selected else { return }
        if let county = c.county, bundle?.county != county { loadBundle() }
        guard let m = machine else { return }
        speaker.configure(bundle: bundle, clientId: c.id)
        if let l = location.location, usable(l) { m.setPosition(lat: l.coordinate.latitude, lon: l.coordinate.longitude) }
        refreshFeed(force: false)
        // A fresh session starts at normal pace and volume ("slower"/"louder" used to stick for ever; v2, B11).
        speaker.slower = false
        speaker.volume = Speaker.normalVolume
        course.reset()
        do { try m.start(client: c, caregiver: caregiverMode) } catch { notice = "\(error)" }
        sync()
    }

    /// "Louder" button (v2, B8): full volume, then the instruction again. Voice "louder" takes the same path.
    public func louder() {
        speaker.volume = 1.0
        machine?.handle(.louder)
        sync()
    }

    /// Asks the direction aloud when the compass cannot answer (v1's direction picker is shown meanwhile).
    public func askDirection(newFire: Bool) {
        speaker.speak([Utterance(newFire ? NavigatorStateMachine.whichWayNewFire : NavigatorStateMachine.whichWaySmoke)])
    }

    /// A direction tapped on the picker: the smoke on Which way, or a new fire mid-route.
    public func pickedSmokeDirection(_ bearing: Double) {
        guard let m = machine else { return }
        if m.state == .whichWay { m.point(bearing: bearing) } else { m.pointAtNewFire(bearing: bearing) }
        sync()
    }

    /// New fire, no compass and the person cannot tell where: report -> history -> straight ahead, said aloud.
    public func newFireUnknownDirection() { machine?.newFireWithoutCompass(); sync() }

    public func confirmFire() { machine?.confirmFire(); sync() }
    public func skipFireDirection() { machine?.skipFireDirection(); sync() }

    public func pointAtSmoke() {
        guard let h = compass.heading else { return }          // no compass: the view shows the direction picker
        machine?.point(bearing: h)
        sync()
    }

    /// Navigate/Choose "Point": the phone is pointed at new smoke; the fire bearing is updated and the route turns away.
    public func pointAtNewFire() { newFireTapped() }

    /// "Fire ahead" without a bearing: the fire is where the user is heading (compass, else the route edge).
    public func fireAhead() { machine?.fireAhead(heading: compass.heading); sync() }

    public func go() { machine?.go(); sync() }
    public func other() { machine?.other(); sync() }
    public func cantMove() { machine?.cantMove(); sync() }
    public func blocked() { machine?.requestBlocked(); sync() }
    public func confirmPending() { machine?.confirmPending(); sync() }
    public func cancelPending() { machine?.cancelPending(); sync() }
    public func startOver() { machine?.requestStartOver(); sync() }
    /// "New fire" tapped: with a compass the phone's heading is the fire's direction; asks before rerouting.
    public func newFireTapped() { machine?.requestFire(heading: compass.heading); sync() }
    public func repeatInstruction() { machine?.repeatCurrent(); sync() }
    public func shelterNext() { machine?.shelterNext(); sync() }
    public func shelterBack() { machine?.shelterBack(); sync() }
    /// Settings sheet flag lives here so a font/colour change (which rebuilds the screens) never closes Settings.
    @Published public var settingsShown = false

    public func done() { machine?.done(); speaker.stop(); sync() }
    /// Back to Home from any screen (Which way "Back", Navigate "Start over"): stops speech and guidance.
    public func goHome() { leaveNavigateCamera(); machine?.goHome(); speaker.stop(); sync() }
    /// Re-check after a confirmed Start over: the camera and timers go with the route.
    func syncAfterPending() { if state == .home { leaveNavigateCamera() } }

    public func micTapped() {
        voice.toggle { [weak self] text in
            Task { @MainActor in await self?.heard(text) }
        }
    }

    func heard(_ transcript: String) async {
        guard let m = machine, let p = processor else { return }
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            speaker.speak([Utterance(NavigatorStateMachine.sayAgain)])
            return
        }
        var agent: VoiceAgent? = nil
        if voice.online, let key = KeychainStore.get(.anthropicAPIKey) { agent = VoiceAgent(apiKey: key) }
        let ctx = VoiceAgent.Context(street: m.currentStreet(), instruction: m.utterances.first?.text)
        let r = await p.process(t, agent: agent, context: ctx) { m.resolveStreet($0, cross: $1) }
        if let say = r.say { speaker.speak([Utterance(say)]) }
        if let cmd = r.execute {
            switch cmd {
            case .intent(.slower): speaker.slower = true
            case .intent(.louder): speaker.volume = 1.0
            default: break
            }
            m.apply(cmd)
            sync()
        }
    }

    // MARK: GPS, timers

    /// A fix outside the county bundle (e.g. a demo far from the county) is ignored; the card's home point is used.
    func usable(_ l: CLLocation) -> Bool {
        bundle?.contains(lat: l.coordinate.latitude, lon: l.coordinate.longitude) ?? false
    }

    func gotFix(_ l: CLLocation) {
        guard let m = machine, usable(l) else { return }
        m.updatePosition(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        course.add(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        sync()
    }

    func periodic() {
        let now = Date()
        checkPowerScope()
        if let c = selected {
            // Before Start there is no live route: use the stamped plan's route A time if the bundle has it.
            let routeS = machine?.remainingRouteTimeS ?? bundle?.plan(clientId: c.id)?.choices.first?.route.timeS ?? 0
            let dt = DeviceTimer(devices: c.devices, powerOutSince: powerOutSince)
            if let r = dt.leaveNow(routeTimeS: routeS, now: now), let cfg = bundle?.config {
                leaveNow = DeviceTimer.leaveNowSentence(r, config: cfg)
                if !leaveNowSpoken {
                    leaveNowSpoken = true
                    Platform.haptic()
                    // the leave_now_dev sentence already starts with "Leave now."; speaking a standalone
                    // "Leave now." clip first would say it twice
                    speaker.speak([Utterance(leaveNow!, template: "leave_now_dev")])
                }
            } else {
                leaveNow = nil
            }
        }
        if voice.online, lastFeedFetch.map({ now.timeIntervalSince($0) > AppModel.feedRefreshS }) ?? true {
            refreshFeed(force: false)
        }
        if voice.online, lastFireFetch.map({ now.timeIntervalSince($0) > AppModel.feedRefreshS }) ?? true {
            refreshFire(force: false)
        }
        tick += 1
    }

    func refreshFeed(force: Bool) {
        guard let feed, voice.online else { return }
        if !force, let t = lastFeedFetch, Date().timeIntervalSince(t) < 60 { return }
        lastFeedFetch = Date()
        Task { @MainActor in
            let r = await feed.fetch()
            self.applyFeed(r)
        }
    }

    func applyFeed(_ r: ApifyFeed.Result) {
        guard let m = machine, let s = r.situation else { return }
        feedNote = nil
        let here = location.location.flatMap { usable($0) ? $0 : nil }.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
            ?? selected.flatMap { c in c.lat.flatMap { la in c.lon.map { (la, $0) } } }
        if let (la, lo) = here { m.feedBlocked = ApifyFeed.blockedEdges(s, graph: m.graph, lat: la, lon: lo) }
        // a feed closure that lands on the active route re-plans immediately; the user should not have to hit Blocked
        if m.state == .navigate, let p = m.progress, !m.feedBlocked.isDisjoint(with: p.route.edges) {
            m.replan(origin: nil)
        }
        if let o = ApifyFeed.outage(s, zip: selected?.zip), feedMayArmPower {
            setPowerOut(true, at: r.fetchedAt ?? Date())
            feedNote = "Power outage reported for \(o.area)."
        }
        if let t = r.fetchedAt {
            let closures = m.feedBlocked.count
            feedNote = (feedNote.map { $0 + " " } ?? "") + "County feed from \(Timestamps.ageText(Date().timeIntervalSince(t))): \(closures) closure\(closures == 1 ? "" : "s") nearby."
        }
    }

    // MARK: Navigate map camera

    static let followAnimateS = 0.8
    /// Width / height of the Navigate map as laid out, so the 1 s overview fits the whole route in a wide, short map.
    @Published public var mapAspect: Double = 1.0 {
        didSet {   // the size arrives after the overview was framed: re-frame it while still in the 1 s overview
            if state == .navigate, follow.mode == .overview, cameraAnimation == nil, abs(mapAspect - oldValue) > 0.01 {
                mapViewport = overviewViewport()
            }
        }
    }

    /// Up on the follow map: the compass, else the direction of travel from GPS fixes (v1's CourseEstimator), else
    /// the bearing of the current route edge.
    var followHeading: Double? { compass.heading ?? course.heading ?? machine?.travelHeading }
    var course = CourseEstimator()

    func followTarget() -> FollowCamera.Viewport? {
        guard let m = machine else { return nil }
        let pos = m.position ?? m.progress.map { (lat: m.graph.lat[$0.route.nodes[0]], lon: m.graph.lon[$0.route.nodes[0]]) }
        return FollowCamera.viewport(lat: pos?.lat, lon: pos?.lon, heading: followHeading)
    }

    func overviewViewport() -> FollowCamera.Viewport? {
        guard let m = machine, let p = m.progress else { return nil }
        var pts = p.route.nodes.map { (lat: m.graph.lat[$0], lon: m.graph.lon[$0]) }
        if let pos = m.position { pts.append(pos) }
        if let r = m.currentChoice?.refuge { pts.append((lat: r.centroidLat, lon: r.centroidLon)) }
        var s = pts[0].lat, n = pts[0].lat, w = pts[0].lon, e = pts[0].lon
        for q in pts { s = min(s, q.lat); n = max(n, q.lat); w = min(w, q.lon); e = max(e, q.lon) }
        return FollowCamera.Viewport(lat: (s + n) / 2, lon: (w + e) / 2,
                                     spanM: FollowCamera.overviewSpanM(points: pts, aspect: mapAspect), rotationDeg: 0)
    }

    func enterNavigateCamera() {
        follow.reset()
        cameraAnimation?.invalidate(); cameraAnimation = nil
        mapViewport = overviewViewport()
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: FollowCamera.overviewS, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .navigate, self.follow.tick(), let t = self.followTarget() else { return }
                self.animateCamera(to: t)
            }
        }
    }

    func leaveNavigateCamera() {
        followTimer?.invalidate(); followTimer = nil
        cameraAnimation?.invalidate(); cameraAnimation = nil
        mapViewport = nil
    }

    /// A new fix or heading while following: move the camera (unless the zoom-in animation is still running).
    func updateFollowCamera() {
        guard state == .navigate, follow.isFollowing, cameraAnimation == nil, let t = followTarget() else { return }
        mapViewport = t
    }

    public func mapInteracted() {
        guard state == .navigate else { return }
        cameraAnimation?.invalidate(); cameraAnimation = nil
        follow.userInteracted()
    }

    public func recentreMap() {
        follow.recentre()
        if let t = followTarget() { animateCamera(to: t, seconds: 0.5) }
    }

    func animateCamera(to target: FollowCamera.Viewport, seconds: Double = followAnimateS) {
        cameraAnimation?.invalidate()
        guard let from = mapViewport else { mapViewport = target; return }
        let frames = max(1, Int(seconds * 30))
        var i = 0
        var dRot = target.rotationDeg - from.rotationDeg
        if dRot > 180 { dRot -= 360 } else if dRot < -180 { dRot += 360 }
        cameraAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                i += 1
                let u = min(1.0, Double(i) / Double(frames))
                let t = u * u * (3 - 2 * u)                       // ease in-out
                let live = self.followTarget() ?? target           // keep tracking a fix that arrives mid-animation
                let to = self.follow.isFollowing ? live : target
                self.mapViewport = FollowCamera.Viewport(
                    lat: from.lat + (to.lat - from.lat) * t, lon: from.lon + (to.lon - from.lon) * t,
                    spanM: exp(log(from.spanM) + (log(to.spanM) - log(from.spanM)) * t),
                    rotationDeg: Py.mod(from.rotationDeg + dRot * t, 360))
                if u >= 1 { timer.invalidate(); self.cameraAnimation = nil; self.mapViewport = to }
            }
        }
    }

    func reloadSatellites() {
        guard let b = bundle, let id = selectedId else { satellites = []; return }
        satellites = SatelliteSnapshot.all(bundle: b, clientId: id)
    }

    /// Mirror the machine and speak anything new (with a haptic on every new instruction).
    func sync() {
        guard let m = machine else { state = .home; leaveNavigateCamera(); return }
        let was = state
        state = m.state
        if m.state == .navigate, was != .navigate { enterNavigateCamera() }
        if m.state != .navigate, was == .navigate { leaveNavigateCamera() }
        if m.state == .navigate { updateFollowCamera() }
        Platform.keepScreenOn(m.state == .navigate)
        if m.serial != spokenSerial {
            spokenSerial = m.serial
            if m.utterances.isEmpty {
                speaker.stop()
            } else {
                speaker.speak(m.utterances)
                Platform.haptic()
            }
            restartAutoRepeat()
        }
        tick += 1
    }

    /// Navigate repeats the current instruction every 45 s (not while "stop" is in effect).
    func restartAutoRepeat() {
        repeatTimer?.invalidate()
        guard machine?.state == .navigate else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: AppModel.autoRepeatS, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let m = self.machine, m.state == .navigate, !m.stopped,
                      let group = m.progress?.currentGroup, !group.isEmpty else { return }
                self.speaker.speak(group.map(Utterance.init))
                Platform.haptic()
            }
        }
    }
}
