import SwiftUI

/// One palette (owner decision): off-white (#F6F3EE) / slate (#2B3440, #3A4654) / orange (#E8731A). Slate text on
/// off-white 11.4:1, on the card (#ECE7DF) 10.2:1, secondary slate (#3F4B59) on the card 7.3:1, off-white on the slate
/// control 8.7:1; the orange is the route (inside its black casing) and the single accent, never body text. Green is
/// used only on the map for the refuge area, never as the sole carrier of meaning. eval/build_dashboard.py measures the
/// `static let` lines below.
public enum Theme {
    public static let background = Color(red: 0.965, green: 0.953, blue: 0.933)   // #F6F3EE
    public static let text = Color(red: 0.169, green: 0.204, blue: 0.251)         // #2B3440 slate
    public static let dim = Color(red: 0.247, green: 0.294, blue: 0.349)          // #3F4B59
    public static let accent = Color(red: 0.227, green: 0.275, blue: 0.329)       // #3A4654 slate controls
    public static let onAccent = Color(red: 0.965, green: 0.953, blue: 0.933)
    public static let card = Color(red: 0.925, green: 0.906, blue: 0.875)         // #ECE7DF
    public static let cardRaised = Color(red: 0.867, green: 0.843, blue: 0.804)   // #DDD7CD
    public static let land = Color(red: 0.16, green: 0.17, blue: 0.18)
    public static let safe = Color(red: 0.30, green: 0.80, blue: 0.45)
    /// Orange (#E8731A) inside the black casing: reads on the veiled photo and on the pale Blueprint.
    public static let route = Color(red: 0.91, green: 0.451, blue: 0.102)
    /// The route's casing and the dark pills: what the route orange and refuge green are measured against.
    public static let casing = Color(red: 0.0, green: 0.0, blue: 0.0)
    /// Dark veil over the satellite photo (look A "Signal"): photo still readable, overlays win.
    public static let mapVeil = Color(red: 0.01, green: 0.03, blue: 0.08).opacity(0.42)
    /// Look C "Blueprint": pale land, slate roads, drawn from graph.json (offline / no photo / Settings → Map).
    public static let mapLand = Color(red: 0.89, green: 0.87, blue: 0.84)
    public static let mapRoadMinor = Color(red: 0.55, green: 0.60, blue: 0.66)
    public static let mapRoadMajor = Color(red: 0.23, green: 0.28, blue: 0.33)
    public static let minButtonHeight: CGFloat = 64
    /// "satellite" (default, look A) | "drawn" (look C). Settings → Map.
    public static let mapStyleKey = "ember.mapStyle"

    /// "inter" (default, bundled) | "system" | "rounded" | "hyperlegible" (Atkinson Hyperlegible, bundled). Both custom fonts are OFL. Settings → Font.
    public static let fontKey = "ember.font"
    public static var fontChoice: String { UserDefaults.standard.string(forKey: fontKey) ?? "inter" }
    public static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let bold: Set<Font.Weight> = [.semibold, .bold, .heavy, .black]
        switch fontChoice {
        // fixedSize: callers already scale `size` with @ScaledMetric; `.custom(_, size:)` would scale it a second
        // time with Dynamic Type, which is what blew Inter up to "Bloc…" buttons at AX5 while Apple stayed sane.
        case "hyperlegible": return .custom(bold.contains(weight) ? "AtkinsonHyperlegible-Bold" : "AtkinsonHyperlegible-Regular", fixedSize: size)
        case "system": return .system(size: size, weight: weight)
        case "rounded": return .system(size: size, weight: weight, design: .rounded)
        default: return .custom(bold.contains(weight) ? "Inter-Bold" : "Inter-Regular", fixedSize: size)
        }
    }
    public static let corner: CGFloat = 18
}

/// Sizes scale with Dynamic Type up to the largest accessibility size.
struct ScaledFonts {
    @ScaledMetric(relativeTo: .title) var instruction: CGFloat = 28
    @ScaledMetric(relativeTo: .largeTitle) var room: CGFloat = 60
    @ScaledMetric(relativeTo: .title3) var secondary: CGFloat = 22
    @ScaledMetric(relativeTo: .body) var body: CGFloat = 20
}

/// Icon + title on one line; the title shrinks (to 60 %) rather than wrapping.
struct SingleLineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
            configuration.title
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
        }
    }
}

/// The one button style. Text never wraps: one line, scaled down if the title is long.
struct EmberButtonStyle: ButtonStyle {
    @ScaledMetric(relativeTo: .title2) var size: CGFloat = 24
    @Environment(\.isEnabled) var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(min(size, 40), .bold))
            .labelStyle(SingleLineLabelStyle())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundColor(enabled ? Theme.onAccent : Theme.dim)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: Theme.minButtonHeight)
            .background(enabled ? Theme.accent : Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .stroke(Theme.dim.opacity(enabled ? 0 : 0.7), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct EmberButton: View {
    let title: String
    let systemImage: String
    var hint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(EmberButtonStyle())
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
    }
}

/// Two buttons side by side; at accessibility text sizes they stack so no title has to shrink past readability.
struct ButtonRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) var typeSize
    @ViewBuilder let content: Content

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 12) { content }
        } else {
            HStack(spacing: 12) { content }
        }
    }
}

struct CardModifier: ViewModifier {
    var fill: Color
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

extension View {
    /// Dark-grey rounded card behind a block of text or controls.
    func card(_ fill: Color = Theme.card, padding: CGFloat = 16) -> some View {
        modifier(CardModifier(fill: fill, padding: padding))
    }
}

/// The instruction sentence: 28 pt, white on a dark card, never truncated.
struct InstructionText: View {
    let text: String
    @ScaledMetric(relativeTo: .title) var size: CGFloat = 28

    var body: some View {
        Text(text)
            .font(Theme.font(min(size, 56), .bold))     // bounded: a 6-word instruction must stay on one screen at AX5
            .foregroundColor(Theme.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .card()
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Explanatory line under a heading: dim, but Dynamic Type like everything else.
struct HelpText: View {
    let text: String
    @ScaledMetric(relativeTo: .body) var size: CGFloat = 17

    var body: some View {
        Text(text).font(Theme.font(size)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
    }
}

struct SecondaryText: View {
    let text: String
    @ScaledMetric(relativeTo: .title3) var size: CGFloat = 22

    var body: some View {
        Text(text)
            .font(Theme.font(size, .semibold))
            .foregroundColor(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A note or status line on its own card (feed notes, errors, "listening…").
struct NoteText: View {
    let text: String
    var systemImage: String? = nil
    @ScaledMetric(relativeTo: .title3) var size: CGFloat = 20

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage { Image(systemName: systemImage).font(Theme.font(size, .semibold)) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.font(size, .semibold))
        .foregroundColor(Theme.text)
        .card(padding: 14)
    }
}

/// A big number with a unit and a caption, for distance and time on Navigate.
struct StatTile: View {
    let value: String
    let unit: String
    let caption: String
    let systemImage: String
    var warning = false
    @ScaledMetric(relativeTo: .largeTitle) var big: CGFloat = 44
    @ScaledMetric(relativeTo: .body) var small: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.font(big, .heavy))
                Text(unit).font(Theme.font(small * 1.2, .bold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Label(caption, systemImage: systemImage)
                .font(Theme.font(small, .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(warning ? Theme.onAccent : Theme.text)
        .card(warning ? Theme.accent : Theme.card, padding: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(unit) \(caption)")
    }
}

/// Distance and time on one line: "130 m to next turn · 33 min to go". Wraps to two lines at accessibility sizes.
struct StatLine: View {
    let items: [(String, String, String)]
    @ScaledMetric(relativeTo: .title2) var big: CGFloat = 26
    @ScaledMetric(relativeTo: .body) var small: CGFloat = 17
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 18))
        layout {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: it.2).font(Theme.font(small, .semibold)).foregroundColor(Theme.dim)
                    Text(it.0).font(Theme.font(big, .heavy))
                    Text(it.1).font(Theme.font(small, .semibold)).foregroundColor(Theme.dim)
                }
                .lineLimit(1).minimumScaleFactor(0.6)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
        .foregroundColor(Theme.text)
        .card(padding: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    }
}
