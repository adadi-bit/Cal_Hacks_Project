import SwiftUI
import EmberCore

/// Which way is the fire? Fresh data: confirm it. Otherwise point the phone (compass) or, with no compass, tap the
/// direction of the smoke on eight big buttons (engineer #1's picker). "Not sure" plans from the last report / the
/// historical prior and says which (engineer #2's lead). Never a dead end: Can't move and Back are always here.
struct WhichWayView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var speaker: Speaker
    @EnvironmentObject var compass: CompassService
    @State private var picking = false

    var body: some View {
        let fresh = !model.fireIsStale && model.fireBearingWord != nil
        let hasCompass = compass.heading != nil
        Screen {
            InstructionText(text: picking ? NavigatorStateMachine.whichWaySmoke : model.displayText)
            if picking {
                DirectionPicker { bearing in
                    picking = false
                    model.pickedSmokeDirection(bearing)
                }
                .onAppear { model.askDirection(newFire: false) }
            } else {
                CompassArrow(fireBearing: fresh ? model.machine?.dataFireBearing : nil, heading: compass.heading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                if !fresh { NoteText(text: model.fireStatusText, systemImage: "clock.badge.exclamationmark") }
                if !hasCompass { NoteText(text: "No compass on this phone.", systemImage: "location.slash") }
            }
        } buttons: {
            if picking {
                EmberButton(title: "Back", systemImage: "arrow.backward", hint: "Back without choosing a direction") { picking = false }
            } else {
                if fresh {
                    EmberButton(title: "OK", systemImage: "checkmark", hint: "The fire is to the \(model.fireBearingWord ?? "")") { model.confirmFire() }
                }
                ButtonRow {
                    EmberButton(title: hasCompass ? "Point" : "Direction",
                                systemImage: hasCompass ? "location.north.line.fill" : "hand.tap.fill",
                                hint: hasCompass ? "Hold the phone flat, point the top at the smoke, then tap" : "Choose the direction of the smoke from a list") {
                        if hasCompass { model.pointAtSmoke() } else { picking = true }
                    }
                    EmberButton(title: "Not sure", systemImage: "questionmark.circle",
                                hint: "Plan without pointing, from the last report or where fires have come from here") { model.skipFireDirection() }
                }
                ButtonRow {
                    EmberButton(title: "Can't move", systemImage: "house.fill", hint: "Stay here and start the shelter steps") { model.cantMove() }
                    EmberButton(title: "Back", systemImage: "arrow.backward", hint: "Back to the start screen") { model.goHome() }
                }
            }
        }
    }
}

/// Eight big direction buttons (from engineer #1). Used wherever the compass cannot answer "which way".
struct DirectionPicker: View {
    let onPick: (Double) -> Void
    static let directions: [(String, Double, String)] = [
        ("North", 0, "arrow.up"), ("Northeast", 45, "arrow.up.right"),
        ("East", 90, "arrow.right"), ("Southeast", 135, "arrow.down.right"),
        ("South", 180, "arrow.down"), ("Southwest", 225, "arrow.down.left"),
        ("West", 270, "arrow.left"), ("Northwest", 315, "arrow.up.left"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: DirectionPicker.directions.count, by: 2)), id: \.self) { i in
                ButtonRow {
                    ForEach(i..<min(i + 2, DirectionPicker.directions.count), id: \.self) { j in
                        let d = DirectionPicker.directions[j]
                        EmberButton(title: d.0, systemImage: d.2, hint: "The smoke is to the \(d.0.lowercased())") { onPick(d.1) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Direction of the smoke")
    }
}

/// Big arrow on a dial. With fresh data it points at the fire (relative to the phone); otherwise straight ahead, to aim at smoke.
struct CompassArrow: View {
    let fireBearing: Double?
    let heading: Double?
    @ScaledMetric(relativeTo: .largeTitle) var scaled: CGFloat = 170
    /// Capped so the dial always fits the screen width at accessibility sizes.
    var size: CGFloat { min(scaled, 200) }

    var angle: Double {
        guard let f = fireBearing else { return 0 }
        return f - (heading ?? 0)
    }

    var label: String {
        if let f = fireBearing { return "Arrow points toward the fire, \(Int(f.rounded())) degrees" }
        if let h = heading { return "Phone points \(Int(h.rounded())) degrees" }
        return "No compass"
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.card)
                Circle().stroke(Theme.cardRaised, lineWidth: 3)
                ForEach(0..<4, id: \.self) { i in
                    Rectangle().fill(Theme.dim).frame(width: 3, height: size * 0.08)
                        .offset(y: -size * 0.66)
                        .rotationEffect(.degrees(Double(i) * 90))
                }
                Image(systemName: "arrow.up")
                    .font(Theme.font(size * 0.75, .black))
                    .rotationEffect(.degrees(angle))
                    .animation(.easeOut(duration: 0.2), value: angle)
            }
            .frame(width: size * 1.45, height: size * 1.45)
            HStack(spacing: 8) {
                Image(systemName: fireBearing == nil ? "location.north.fill" : "flame.fill")
                Text(fireBearing == nil ? "Aim the top of the phone" : "Fire")
                if let h = heading { Text("· \(Int(h.rounded()))°") }
            }
            .font(Theme.font(size * 0.14, .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .foregroundColor(Theme.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

struct ChooseView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var voice: VoiceController
    @ScaledMetric(relativeTo: .title) var big: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) var small: CGFloat = 20
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
        let m = model.machine
        let a = m?.currentChoice
        let b = m?.alternateChoice
        let header = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        Screen {
            if let a, let m {
                VStack(alignment: .leading, spacing: 10) {
                    header {
                        Label("Go here", systemImage: "arrow.forward.circle.fill")
                            .font(Theme.font(small, .bold)).foregroundColor(Theme.accent)
                        if !typeSize.isAccessibilitySize { Spacer() }
                        Label("\(a.route.minutes) min", systemImage: "figure.roll")
                            .font(Theme.font(small, .bold)).foregroundColor(Theme.text)
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                    Text(typeSize.isAccessibilitySize ? a.refuge.shortName : a.refuge.name).font(Theme.font(min(big * 1.15, 40), .heavy)).foregroundColor(Theme.text)
                        .lineLimit(3).minimumScaleFactor(0.7)      // long OSM names: shrink, never break mid-word (engineer #1)
                        .fixedSize(horizontal: false, vertical: true)
                    RouteMapView(graph: m.graph, route: a.route, position: m.position, refuge: a.refuge,
                                 satellites: model.satellites,
                                 online: voice.online, thumbnail: true, height: typeSize.isAccessibilitySize ? 280 : 300)
                }
                .card(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.accent, lineWidth: 3))
                if let b {
                    // Text only (no postage-stamp map, owner complaint #4): short enough to sit whole above the buttons.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Or").font(Theme.font(small, .semibold)).foregroundColor(Theme.dim)
                        Text("\(typeSize.isAccessibilitySize ? b.refuge.shortName : b.refuge.name) · \(b.route.minutes) min").font(Theme.font(min(small * 1.2, 28), .bold)).foregroundColor(Theme.text)
                            .lineLimit(2).minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .card(padding: 12)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Or \(b.refuge.name), \(b.route.minutes) minutes. Tap Other to choose it.")
                }
            }
        } buttons: {
            EmberButton(title: "Go", systemImage: "arrow.forward", hint: "Start directions to \(a?.refuge.name ?? "")") { model.go() }
            ButtonRow {
                EmberButton(title: "Other", systemImage: "arrow.triangle.2.circlepath", hint: "Offer the next place") { model.other() }
                    .disabled(b == nil)
                EmberButton(title: "Can't move", systemImage: "house.fill", hint: "Start the shelter steps") { model.cantMove() }
            }
        }
    }
}

struct NavigateView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var speaker: Speaker
    @EnvironmentObject var voice: VoiceController
    @EnvironmentObject var compass: CompassService
    @Environment(\.dynamicTypeSize) var typeSize
    @State private var pickingFire = false

    var body: some View {
        let m = model.machine
        let p = m?.progress
        if pickingFire {
            // New fire, no compass: ask which way (engineer #1's picker); "Can't tell" uses report -> history -> ahead.
            Screen {
                InstructionText(text: NavigatorStateMachine.whichWayNewFire)
                DirectionPicker { bearing in
                    pickingFire = false
                    model.pickedSmokeDirection(bearing)
                }
                .onAppear { model.askDirection(newFire: true) }
            } buttons: {
                ButtonRow {
                    EmberButton(title: "Can't tell", systemImage: "questionmark.circle",
                                hint: "Use the last fire report or where fires have come from here; asks first") { pickingFire = false; model.newFireTapped() }
                    EmberButton(title: "Back", systemImage: "arrow.backward", hint: "Keep the current route") { pickingFire = false }
                }
            }
        } else {
            navigate(m, p)
        }
    }

    @ViewBuilder
    func navigateWords(_ p: RouteProgress?, mins: Int, eta: Double?, fireFirst: Bool) -> some View {
        InstructionText(text: model.displayText)
        // One compact line instead of three tiles: the map below gets the space (owner: "the map should take up a
        // large part of the screen").
        StatLine(items: [
            p?.distanceToNextTurnM.map { ("\(Int(($0 / 10).rounded()) * 10) m", "to next turn", "arrow.turn.up.right") },
            ("\(mins) min", "to go", "figure.roll"),
        ].compactMap { $0 })
        // Only a real number helps here: an unknown fire ETA used to take a third of the row as "?".
        if let eta {
            StatTile(value: "\(Int(eta.rounded()))", unit: "min", caption: fireFirst ? "Fire may arrive first" : "until fire reaches you",
                     systemImage: fireFirst ? "exclamationmark.triangle.fill" : "flame", warning: fireFirst)
        }
        if voice.listening { NoteText(text: voice.partial.isEmpty ? "Listening…" : voice.partial, systemImage: "waveform") }
    }

    @ViewBuilder
    func navigateMap(_ m: NavigatorStateMachine?, _ p: RouteProgress?) -> some View {
        if let m, let p {
            // Re-centre is drawn by the map itself (bottom-centre, inside the map, only while following is paused,
            // moved by the placer when the route runs there) so it is never clipped and never sits on the route.
            RouteMapView(graph: m.graph, route: p.route, position: m.position, refuge: m.currentChoice?.refuge,
                         heading: compass.heading ?? m.travelHeading, walkedM: p.progressM,
                         satellites: model.satellites, online: voice.online,
                         camera: model.mapViewport, paused: model.follow.isPaused,
                         onUserGesture: { model.mapInteracted() },
                         nextTurnNode: p.groupIndex + 1 < p.groups.count ? p.groups[p.groupIndex + 1].first?.node : nil,
                         onSize: { model.mapAspect = Double($0.width / max($0.height, 1)) },
                         showsRecentre: model.follow.showsRecentre, onRecentre: { model.recentreMap() })
        }
    }

    var navigateStartOver: some View {
        // Home exit (base finding, unfixed in all five): small, at the end of the content, never in the pinned row, confirmed.
        Button { model.startOver() } label: {
            StartOverLabel()
        }
        .accessibilityLabel("Start over")
        .accessibilityHint("Stop guidance and go back to the start screen; asks first")
    }

    @ViewBuilder
    func navigate(_ m: NavigatorStateMachine?, _ p: RouteProgress?) -> some View {
        let mins = Int(ceil((m?.remainingRouteTimeS ?? 0) / 60))
        let eta = m?.fireETAMinutes
        let fireFirst = eta.map { Double(mins) >= $0 } ?? false
        // Default sizes: nothing scrolls and the map takes every point left (never cut by the pinned panel); at
        // accessibility sizes the screen scrolls and the map is fixed-height.
        Screen(scrolls: false) {
            if typeSize.isAccessibilitySize {
                // Accessibility sizes: the words scroll in their own area and the map is pinned whole below them
                // (240 pt, never under the button panel; engineer #1's AX5 finding). Default sizes: nothing scrolls
                // and the map takes every point left.
                ScrollView(showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        navigateWords(p, mins: mins, eta: eta, fireFirst: fireFirst)
                        CaregiverInfo(client: m?.client)
                        navigateStartOver
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: .infinity)
                navigateMap(m, p).frame(height: 240)
            } else {
                navigateWords(p, mins: mins, eta: eta, fireFirst: fireFirst)
                navigateMap(m, p).frame(minHeight: 220, maxHeight: .infinity)
                navigateStartOver
            }
        } buttons: {
            if m?.pending != nil {
                // The tapped action waits for an answer: two big buttons, the question is the instruction text above.
                ButtonRow {
                    EmberButton(title: "Yes", systemImage: "checkmark", hint: "Yes, do it") { model.confirmPending() }
                    EmberButton(title: "No", systemImage: "xmark", hint: "No, keep going as before") { model.cancelPending() }
                }
            } else {
            // Owner reference structure: Blocked / Repeat, Can't move / Speak, then a full-width New fire. "Louder" stays
            // a voice command (and Repeat speaks at full volume when the user asked for louder before).
            ButtonRow {
                EmberButton(title: "Blocked", systemImage: "xmark.octagon.fill", hint: "Find a way around; asks first") { model.blocked() }
                EmberButton(title: "Repeat", systemImage: "speaker.wave.2.fill", hint: "Say the instruction again") { model.repeatInstruction() }
            }
            ButtonRow {
                EmberButton(title: "Can't move", systemImage: "house.fill", hint: "Start the shelter steps") { model.cantMove() }
                EmberButton(title: voice.listening ? "Done" : "Speak", systemImage: voice.listening ? "mic.fill" : "mic",
                            hint: "Say blocked, fire, repeat, louder, where am I, or how long") { model.micTapped() }
            }
            EmberButton(title: "New fire", systemImage: "flame.fill",
                        hint: compass.heading != nil ? "Point the phone at the fire, then tap; asks first" : "Choose the direction of the fire from a list") {
                if compass.heading != nil { model.newFireTapped() } else { pickingFire = true }
            }
            }
        }
    }
}

struct ShelterView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var speaker: Speaker
    @ScaledMetric(relativeTo: .largeTitle) var roomSize: CGFloat = 60

    var body: some View {
        let m = model.machine
        Screen {
            if let room = m?.shelter.room {
                // Bounded and shrink-to-fit: at AX5 a 60 pt scaled title wrapped mid-word ("bedro / om"; found by engineer #2).
                Text(room).font(Theme.font(min(roomSize, 48), .black)).foregroundColor(Theme.onAccent)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .card(Theme.accent)
                    .accessibilityLabel("Room: \(room)")
            }
            InstructionText(text: model.displayText)
            if let m { NoteText(text: "Step \(m.shelterIndex + 1) of \(m.shelter.steps.count)", systemImage: "list.number") }
            CaregiverInfo(client: m?.client)
        } buttons: {
            EmberButton(title: model.machine?.shelterIsLastStep == true ? "Stay here" : "Next",
                        systemImage: model.machine?.shelterIsLastStep == true ? "checkmark" : "arrow.forward",
                        hint: model.machine?.shelterIsLastStep == true ? "This is the last step: stay in the room" : "Next step") { model.shelterNext() }
            ButtonRow {
                EmberButton(title: "Repeat", systemImage: "speaker.wave.2.fill", hint: "Say this step again") { model.repeatInstruction() }
                EmberButton(title: "Back", systemImage: "arrow.backward", hint: "Previous step") { model.shelterBack() }
            }
        }
    }
}

struct ArrivedView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var speaker: Speaker
    @ScaledMetric(relativeTo: .largeTitle) var badge: CGFloat = 72

    var body: some View {
        Screen {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill").font(Theme.font(badge)).foregroundColor(Theme.accent)
                Text("You made it.").font(Theme.font(badge * 0.5, .heavy)).foregroundColor(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
            }
            .card()
            .accessibilityElement(children: .combine)
            InstructionText(text: model.displayText)
        } buttons: {
            EmberButton(title: "Done", systemImage: "checkmark", hint: "Back to the start screen") { model.done() }
        }
    }
}

/// Quiet (dim, unfilled) but still Dynamic Type: the way home must be readable at AX5 too.
private struct StartOverLabel: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 17
    var body: some View {
        Label("Start over", systemImage: "house").font(Theme.font(size, .semibold)).foregroundColor(Theme.dim)
            .frame(maxWidth: .infinity, minHeight: 56)
    }
}
