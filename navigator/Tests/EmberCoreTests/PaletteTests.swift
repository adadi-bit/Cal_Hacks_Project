import Foundation
import Testing
@testable import EmberCore

/// Both selectable palettes must meet the owner's contrast floors: ≥7:1 body text, ≥4.5:1 large text / controls.
struct PaletteTests {
    @Test func everyPaletteKeepsBodyTextAboveSevenToOne() {
        for p in Palette.all {
            #expect(Palette.contrast(p.text, p.background) >= 7, "\(p.id) text on background")
            #expect(Palette.contrast(p.text, p.card) >= 7, "\(p.id) text on card")
            #expect(Palette.contrast(p.text, p.cardRaised) >= 7, "\(p.id) text on raised card")
            #expect(Palette.contrast(p.dim, p.background) >= 7, "\(p.id) dim text on background")
        }
    }

    @Test func everyPaletteKeepsControlsAndRouteAboveFourPointFive() {
        for p in Palette.all {
            #expect(Palette.contrast(p.onAccent, p.accent) >= 4.5, "\(p.id) label on primary control")
            #expect(Palette.contrast(p.route, .black) >= 4.5, "\(p.id) route on its casing")
            #expect(Palette.contrast(.white, p.veil) >= 7, "\(p.id) white pill text over the veil")
        }
    }

    @Test func offWhiteIsTheOnlyPalette() {
        #expect(Palette.named(nil) == Palette.offWhite)
        #expect(Palette.named("purple") == Palette.offWhite)
        #expect(Palette.named("navy") == Palette.offWhite)       // an old stored choice resolves to the one palette
        #expect(Palette.all.map(\.id) == ["offwhite"])
    }

    @Test func wcagMathMatchesKnownValues() {
        #expect(abs(Palette.contrast(.white, .black) - 21) < 0.01)
        #expect(abs(Palette.contrast(Palette.RGB(hex: 0x2B3440), Palette.RGB(hex: 0xF6F3EE)) - 11.4) < 0.15)
    }
}
