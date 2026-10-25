import SwiftUI
import EmberCore

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var scanning = false
    @ScaledMetric(relativeTo: .title2) var nameSize: CGFloat = 26
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
        Screen {
            InstructionText(text: model.profiles.isEmpty ? "Add a profile from the plan card." : "Who are you moving?")
            ForEach(model.profiles) { p in
                let selected = p.id == model.selectedId
                Button { model.select(p.id) } label: {
                    HStack(spacing: 14) {
                        if !typeSize.isAccessibilitySize {
                            Image(systemName: icon(p))
                                .font(Theme.font(nameSize, .semibold))
                                .frame(width: nameSize * 1.8, height: nameSize * 1.8)
                                .background(Circle().fill(selected ? Theme.accent : Theme.cardRaised))
                                .foregroundColor(selected ? Theme.onAccent : Theme.text)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(Theme.font(nameSize, .bold))
                            Text(p.mobilityLabel).font(Theme.font(nameSize * 0.72, .medium)).foregroundColor(Theme.dim)
                        }
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(Theme.font(nameSize * 1.1, .bold))
                            .foregroundColor(selected ? Theme.accent : Theme.dim)
                    }
                    .foregroundColor(Theme.text)
                    .frame(minHeight: Theme.minButtonHeight)
                    .card(padding: 12)
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .stroke(selected ? Theme.accent : Color.clear, lineWidth: 3))
                }
                .accessibilityLabel("\(p.name), \(p.mobilityLabel)\(selected ? ", selected" : "")")
                .accessibilityHint("Select who you are moving")
            }
            VStack(spacing: 0) {
                ToggleRow(title: "I am pushing the chair", isOn: $model.caregiverMode)
                Divider().overlay(Theme.cardRaised)
                ToggleRow(title: "Power is out", isOn: Binding(get: { model.powerIsOut }, set: { model.setPowerOut($0) }))
                    .accessibilityHint("Starts the battery timer for oxygen and other devices")
            }
            .card(padding: 14)
            NoteText(text: model.fireStatusText, systemImage: model.fireIsStale ? "clock.badge.exclamationmark" : "clock")
            if let built = model.bundleBuiltText { NoteText(text: built, systemImage: "map") }
            if let note = model.feedNote { NoteText(text: note, systemImage: "antenna.radiowaves.left.and.right") }
            if let err = model.loadError { NoteText(text: err, systemImage: "exclamationmark.triangle") }
            if let n = model.notice { NoteText(text: n, systemImage: "info.circle") }
        } buttons: {
            EmberButton(title: "Start", systemImage: "play.fill", hint: "Find a safe place to go") { model.start() }
                .disabled(model.selected == nil || model.bundle == nil)
            ButtonRow {
                EmberButton(title: "Add profile", systemImage: "qrcode.viewfinder", hint: "Scan the QR code on the plan card") { scanning = true }
                EmberButton(title: "Settings", systemImage: "gearshape", hint: "Map style, font and keys") { model.settingsShown = true }
            }
        }
        .sheet(isPresented: $scanning) {
            VStack(spacing: 12) {
                InstructionText(text: "Point the camera at the code on the card.")
                QRScanner { code in
                    scanning = false
                    model.addProfile(fromCode: code)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                EmberButton(title: "Cancel", systemImage: "xmark") { scanning = false }
            }
            .padding(16)
            .background(Theme.background.ignoresSafeArea())
        }
        .sheet(isPresented: $model.settingsShown) {
            SettingsView { model.settingsShown = false; model.settingsChanged() }
                .environmentObject(model)
        }
    }

    func icon(_ p: ClientProfile) -> String {
        switch p.mobility {
        case "manual_chair", "power_chair": return "figure.roll"
        case "walker", "cane": return "figure.walk"
        case "bedbound": return "bed.double.fill"
        default: return "person.fill"
        }
    }
}

/// Label that wraps, switch on the right, at every text size.
/// A big switch whose OFF state is still visible on the off-white card (the system switch's pale grey track is not).
struct EmberSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.accent : Theme.dim).frame(width: 68, height: 40)
                Circle().fill(Color.white).frame(width: 32, height: 32).padding(4)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            SecondaryText(text: title)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(EmberSwitchStyle())
        }
        .frame(minHeight: Theme.minButtonHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isButton)
        .onTapGesture { isOn.toggle() }
    }
}

struct SettingsView: View {
    let close: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var values: [KeychainStore.Key: String] = [:]
    @State private var snapshotNote: String?
    @State private var saving = false

    static let labels: [KeychainStore.Key: String] = [
        .anthropicAPIKey: "Anthropic API key", .cartesiaAPIKey: "Cartesia API key", .cartesiaVoiceId: "Cartesia voice id",
        .apifyToken: "Apify token", .apifyDatasetId: "Apify county feed dataset id",
    ]

    static let fonts = [("inter", "Inter"), ("system", "Apple"), ("hyperlegible", "Hyperlegible")]
    static let mapStyles = [("satellite", "Satellite", "photo.fill"), ("drawn", "Drawn", "map.fill")]
    @AppStorage(Theme.fontKey) private var fontChoice = "inter"
    @AppStorage(Theme.mapStyleKey) private var mapStyle = "satellite"

    /// The font is read statically: rebuild the sheet's content (not the sheet, whose state holds the half-typed
    /// keys) when it changes.
    var body: some View { content.id(fontChoice) }

    private var content: some View {
        Screen {
            InstructionText(text: "Settings")
            VStack(spacing: 0) {
                ToggleRow(title: "Power is out", isOn: Binding(get: { model.powerIsOut }, set: { model.setPowerOut($0) }))
                    .accessibilityHint("Off means power is back: stops the battery timer")
                if let built = model.bundleBuiltText { NoteText(text: built, systemImage: "map") }
                NoteText(text: model.fireStatusText, systemImage: "clock")
            }
            .card(padding: 14)
            VStack(alignment: .leading, spacing: 10) {
                SecondaryText(text: "Map")
                HelpText(text: "Satellite photo when the phone has signal or a saved picture; Drawn streets always work offline.")
                ButtonRow {
                    ForEach(SettingsView.mapStyles, id: \.0) { m in
                        EmberButton(title: m.1, systemImage: mapStyle == m.0 ? "checkmark.circle.fill" : m.2,
                                    hint: "Show the \(m.1.lowercased()) map") { mapStyle = m.0 }
                    }
                }
            }
            .card()
            VStack(alignment: .leading, spacing: 10) {
                SecondaryText(text: "Font")
                // two per row at most: three across truncated "Hyperlegible" to "Hyp…" on a 390 pt phone
                ButtonRow {
                    ForEach(SettingsView.fonts.prefix(2), id: \.0) { f in
                        EmberButton(title: f.1, systemImage: fontChoice == f.0 ? "checkmark.circle.fill" : "circle",
                                    hint: "Use the \(f.1) font everywhere") { fontChoice = f.0 }
                    }
                }
                ForEach(SettingsView.fonts.dropFirst(2), id: \.0) { f in
                    EmberButton(title: f.1, systemImage: fontChoice == f.0 ? "checkmark.circle.fill" : "circle",
                                hint: "Use the \(f.1) font everywhere") { fontChoice = f.0 }
                }
            }
            .card()
            VStack(alignment: .leading, spacing: 14) {
                SecondaryText(text: "Keys (stay on this phone)")
                ForEach(KeychainStore.Key.allCases, id: \.self) { k in
                    VStack(alignment: .leading, spacing: 6) {
                        SecondaryText(text: SettingsView.labels[k] ?? k.rawValue)
                        SecureField(SettingsView.labels[k] ?? k.rawValue, text: Binding(get: { values[k] ?? "" }, set: { values[k] = $0 }))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 48)
                            .background(Theme.cardRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityLabel(SettingsView.labels[k] ?? k.rawValue)
                    }
                }
            }
            .card()
            #if os(iOS)
            VStack(alignment: .leading, spacing: 10) {
                SecondaryText(text: "Offline map (developer)")
                HelpText(text: "Saves satellite pictures of \(model.selected?.name ?? "the selected person")'s routes into the county bundle, for use with no signal.")
                EmberButton(title: saving ? "Saving…" : "Save satellite snapshot", systemImage: "square.and.arrow.down",
                            hint: "Needs signal; writes satellite/<client>_<n>.jpg into the bundle") { saveSnapshots() }
                    .disabled(saving || model.selected == nil || model.bundle == nil)
                if let snapshotNote { NoteText(text: snapshotNote, systemImage: "photo") }
            }
            .card()
            #endif
        } buttons: {
            EmberButton(title: "Save", systemImage: "checkmark") {
                for k in KeychainStore.Key.allCases { KeychainStore.set(k, values[k]) }
                close()
            }
            EmberButton(title: "Cancel", systemImage: "xmark") { close() }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            for k in KeychainStore.Key.allCases { values[k] = KeychainStore.get(k) ?? "" }
        }
    }

    func saveSnapshots() {
        #if os(iOS)
        guard let bundle = model.bundle, let client = model.selected else { return }
        saving = true
        Task { @MainActor in
            do {
                let n = try await SatelliteCache.save(bundle: bundle, client: client)
                snapshotNote = n == 0 ? "No routes to save for \(client.name)." : "Saved \(n) snapshot\(n == 1 ? "" : "s") to \(bundle.county)/satellite."
                model.reloadSatellites()
            } catch {
                snapshotNote = "Could not save: \(error.localizedDescription)"
            }
            saving = false
        }
        #endif
    }
}
