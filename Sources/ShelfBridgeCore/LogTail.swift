import Foundation

/// Plain-text tail of a pane log: tmux `pipe-pane` captures terminal control sequences, which
/// are stripped so `logs` and the status JSON never carry them.
public enum LogTail {
    public static func lines(_ text: String, _ count: Int) -> [String] {
        Array(allLines(text).suffix(count))
    }

    /// Every non-empty plain-text line, trimmed.
    public static func allLines(_ text: String) -> [String] {
        strip(text).split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Drops escape sequences and C0 controls, keeping the text a TUI drew:
    /// - CSI, OSC, DCS / SOS / PM / APC strings (ended by BEL or `ESC \`), and two-byte escapes
    ///   with intermediates such as `ESC ( B` (its `B` used to be left behind as "…textB").
    /// - Cursor moves: a column move (`G`, `C`, `` ` ``) is a space, because TUIs such as
    ///   Claude Code place words with it instead of spaces; a row move (`A`, `B`, `H`, …) ends the line.
    /// - `\r\n` ends the line. A lone `\r` returns to the line start: text written after it
    ///   replaces the line (progress bars), a row move after it keeps the line.
    /// - Backspace removes the character before it.
    public static func strip(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scan(s, styled: false).text)
        return String(out)
    }

    /// The engine behind `strip`. `styled` also keeps the SGR state of every kept scalar
    /// (`styles` parallel to `text`); SGR is otherwise dropped like any CSI. One engine, so
    /// the coloured log-answer lines are the plain ones by construction.
    static func scan(_ s: String, styled: Bool) -> (text: [Unicode.Scalar], styles: [AnsiText.Style]) {
        let scalars = Array(s.unicodeScalars)
        var out: [Unicode.Scalar] = []
        var styles: [AnsiText.Style] = []
        var style = AnsiText.Style.plain
        var lineStart = 0
        var returned = false  // a lone `\r` waiting to see what comes next

        func emit(_ c: Unicode.Scalar) {
            out.append(c)
            if styled { styles.append(style) }
        }
        func newline() {
            returned = false
            if out.count != lineStart { emit("\n"); lineStart = out.count }
        }
        func space() {
            if out.count != lineStart, out.last != " " { emit(" ") }
        }
        func put(_ c: Unicode.Scalar) {
            if returned {
                out.removeSubrange(lineStart...)
                if styled { styles.removeSubrange(lineStart...) }
                returned = false
            }
            emit(c)
        }
        /// Skips to the end of a string sequence: BEL or `ESC \`.
        func skipString(_ i: inout Int) {
            while i < scalars.count {
                if scalars[i] == "\u{07}" { i += 1; return }
                if scalars[i] == "\u{1B}" { i += 1; if i < scalars.count, scalars[i] == "\\" { i += 1 }; return }
                i += 1
            }
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            i += 1
            switch c {
            case "\u{1B}":
                guard i < scalars.count else { break }
                let n = scalars[i]
                i += 1
                switch n {
                case "[":
                    let params = i
                    while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                    guard i < scalars.count else { break }
                    let final = scalars[i]
                    i += 1
                    switch final {
                    case "G", "C", "`": space()
                    case "A", "B", "E", "F", "H", "f", "d": newline()
                    case "m" where styled: style.apply(sgr: scalars[params..<(i - 1)])
                    default: break
                    }
                case "]", "P", "X", "^", "_":
                    skipString(&i)
                case _ where (0x20...0x2F).contains(n.value):
                    // `ESC ( B` and friends: intermediates, then one final byte.
                    while i < scalars.count, (0x20...0x2F).contains(scalars[i].value) { i += 1 }
                    if i < scalars.count { i += 1 }
                default:
                    break  // `ESC 7`, `ESC 8`, `ESC =`, `ESC M` …
                }
            case "\r" where i < scalars.count && scalars[i] == "\n":
                continue
            case "\r":
                returned = true
            case "\n":
                if returned { returned = false }
                emit(c)
                lineStart = out.count
            case "\u{08}":
                if out.count != lineStart {
                    out.removeLast()
                    if styled { styles.removeLast() }
                }
            case "\t":
                put(" ")
            default:
                if c.value >= 0x20 && c.value != 0x7F && !(0x80...0x9F).contains(c.value) { put(c) }
            }
        }
        return (out, styles)
    }
}
