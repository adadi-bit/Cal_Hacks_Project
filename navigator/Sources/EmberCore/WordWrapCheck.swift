import Foundation

/// Owner's rule: no word may ever break mid-word at any Dynamic Type size, on any screen, and nothing is cut with "…".
/// Given the lines a label actually rendered and the string it was given, this returns the offending lines: a line is
/// fine only when it is a run of whole words of the source (in order); "…" anywhere is an offence.
public enum WordWrapCheck {
    public static func fragments(renderedLines: [String], source: String) -> [String] {
        let words = source.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        var bad: [String] = []
        var cursor = 0
        for raw in renderedLines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.contains("…") || line.contains("...") { bad.append(line); continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // every part must equal the next source word (hyphenated words may legitimately break after the hyphen)
            var ok = true
            var c = cursor
            for p in parts {
                guard c < words.count else { ok = false; break }
                if p == words[c] { c += 1; continue }
                if p.hasSuffix("-"), words[c].hasPrefix(p) { words_hyphen: do { c += 0 }; ok = false; break }
                ok = false; break
            }
            if ok { cursor = c } else { bad.append(line) }
        }
        return bad
    }
}
