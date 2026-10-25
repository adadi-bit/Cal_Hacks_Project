import SwiftUI
import EmberCore

/// One screen at a time, chosen by the state machine. "Leave now" sits on top of every screen.
public struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Theme.fontKey) private var fontChoice = "inter"

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if let text = model.leaveNow { LeaveNowBanner(text: text, powerBack: { model.powerBack() }).padding([.horizontal, .top], 12) }
            Group {                 // the font is read statically: rebuild the screens (not the root, whose onAppear
                switch model.state {   // launches the app) when it changes; the Settings sheet lives in the model
                case .home: HomeView()
                case .whichWay: WhichWayView()
                case .choose: ChooseView()
                case .navigate: NavigateView()
                case .shelter: ShelterView()
                case .arrived: ArrivedView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(fontChoice)
        }
        .background(Theme.background.ignoresSafeArea())
        .environmentObject(model.speaker)
        .environmentObject(model.compass)
        .environmentObject(model.voice)
        .preferredColorScheme(.light)
        .onAppear { model.launch() }
    }
}

struct LeaveNowBanner: View {
    let text: String
    let powerBack: () -> Void
    @ScaledMetric(relativeTo: .title) var size: CGFloat = 28

    /// The device sentence already starts with "Leave now."; the heading says it once.
    var detail: String {
        let t = text.hasPrefix("Leave now. ") ? String(text.dropFirst("Leave now. ".count)) : text
        return t.hasSuffix(" Leave now.") ? String(t.dropLast(" Leave now.".count)) : t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Leave now.", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.font(min(size, 40), .heavy))
            Text(detail).font(Theme.font(min(size * 0.7, 30), .semibold)).fixedSize(horizontal: false, vertical: true)
            Button(action: powerBack) {
                Label("Power is back", systemImage: "bolt.fill")
                    .font(Theme.font(min(size * 0.7, 28), .bold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundColor(Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.background))
            }
            .accessibilityLabel("Power is back")
            .accessibilityHint("Stops the battery timer and clears this warning")
        }
        .foregroundColor(Theme.onAccent)
        .card(Theme.accent, padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Leave now. \(detail)")
    }
}

/// Transfer method and equipment, for whoever is moving the client, without asking.
struct CaregiverInfo: View {
    let client: ClientProfile?
    @ScaledMetric(relativeTo: .body) var size: CGFloat = 18

    var body: some View {
        if let c = client {
            VStack(alignment: .leading, spacing: 6) {
                Label(c.transferLabel, systemImage: "figure.roll")
                Label(c.equipmentLabel, systemImage: "bolt.heart")
                if let chair = c.home?.chairLocation, !chair.isEmpty { Label("Chair: \(chair)", systemImage: "house") }
            }
            .font(Theme.font(size, .medium))
            .foregroundColor(Theme.text)
            .card(padding: 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("For the helper: \(c.transferLabel). Equipment: \(c.equipmentLabel).")
        }
    }
}

/// Content above, buttons pinned below. `scrolls: false` lets a flexible child (the map) take the spare height.
struct Screen<Content: View, Buttons: View>: View {
    var scrolls = true
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(spacing: 16) {
            if scrolls {
                // Room at the end so the last line never sits cut against the pinned buttons (round-1 "clipped" findings).
                ScrollView(showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) { content }.padding(.top, 4).padding(.bottom, 28)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) { content }.padding(.top, 4)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            VStack(spacing: 12) { buttons }
        }
        .padding(16)
    }
}
