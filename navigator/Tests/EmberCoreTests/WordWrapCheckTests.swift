import Testing
@testable import EmberCore

/// Owner's screenshot (Choose "Or" row at AX5) as the negative case, and whole-word wraps as the positive ones.
@Suite struct WordWrapCheckTests {
    let name = "Or the Paradise Preforming Art Center lot 34 min"

    @Test func ownerScreenshotIsRejected() {
        let rendered = ["Or", "the", "Para", "dise", "Pref", "ormi", "ng", "Art", "Cent", "er lot", "34", "min"]
        let bad = WordWrapCheck.fragments(renderedLines: rendered, source: name)
        #expect(bad.contains("Para") && bad.contains("Pref") && bad.contains("er lot"), "\(bad)")
    }

    @Test func wholeWordWrapIsAccepted() {
        let rendered = ["Or the Paradise", "Preforming Art", "Center lot", "34 min"]
        #expect(WordWrapCheck.fragments(renderedLines: rendered, source: name).isEmpty)
        #expect(WordWrapCheck.fragments(renderedLines: ["Or", "the", "Paradise", "Preforming", "Art", "Center", "lot", "34", "min"], source: name).isEmpty)
    }

    @Test func ellipsisIsRejected() {
        #expect(WordWrapCheck.fragments(renderedLines: ["Hyp…"], source: "Hyperlegible") == ["Hyp…"])
        #expect(WordWrapCheck.fragments(renderedLines: ["Can't m…"], source: "Can't move") == ["Can't m…"])
    }
}
