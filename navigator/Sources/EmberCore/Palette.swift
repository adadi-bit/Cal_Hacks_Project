import Foundation

/// The two colour schemes behind Settings → Colours, as plain RGB so EmberCore tests can check contrast without
/// SwiftUI; `Theme` turns them into `Color`s. Off-white / slate / orange is the only palette (owner decision).
public struct Palette: Equatable, Sendable {
    public struct RGB: Equatable, Sendable {
        public let r: Double, g: Double, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        public init(hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
        }
        /// WCAG 2.x relative luminance.
        public var luminance: Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        public static let black = RGB(0, 0, 0)
        public static let white = RGB(1, 1, 1)
    }

    public let id: String
    public let name: String
    /// Preferred colour scheme for system chrome (status bar, keyboard).
    public let dark: Bool
    public let background: RGB, text: RGB, dim: RGB
    public let accent: RGB, onAccent: RGB
    public let card: RGB, cardRaised: RGB, land: RGB
    public let safe: RGB, route: RGB
    public let veil: RGB, veilOpacity: Double
    public let mapLand: RGB, mapRoadMinor: RGB, mapRoadMajor: RGB

    /// WCAG contrast ratio, 1…21.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    public static let key = "ember.palette"

    public static let offWhite = Palette(
        id: "offwhite", name: "Off-white", dark: false,
        background: RGB(hex: 0xF6F3EE), text: RGB(hex: 0x2B3440), dim: RGB(hex: 0x3F4854),
        accent: RGB(hex: 0x3A4654), onAccent: RGB(hex: 0xF6F3EE),   // slate controls (engineer #2); orange is the route only
        card: RGB(hex: 0xECE7DF), cardRaised: RGB(hex: 0xE3DCD1), land: RGB(hex: 0xD8D1C5),
        safe: RGB(0.30, 0.80, 0.45), route: RGB(hex: 0xE8731A),
        veil: RGB(0.01, 0.03, 0.08), veilOpacity: 0.42,
        mapLand: RGB(0.04, 0.08, 0.16), mapRoadMinor: RGB(0.36, 0.46, 0.58), mapRoadMajor: RGB(0.62, 0.72, 0.84))

    public static let all = [offWhite]

    /// The one palette (owner decision): any stored choice resolves to it.
    public static func named(_ id: String?) -> Palette { offWhite }
}
