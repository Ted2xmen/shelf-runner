import Foundation

/// Log-answer colours (`styles`, see `fixtures/protocol/v2/README.md`): the plain lines of `LogTail.allLines` plus, per line,
/// the SGR runs that coloured them. Offsets are Unicode scalars on the cleaned, trimmed line.
public enum AnsiText {
    /// Colour state. `fg`/`bg`: -1 default, 0…255 palette, ≥256 truecolor `256 + (r<<16 | g<<8 | b)`.
    /// `flags`: 1 bold, 2 dim, 4 italic, 8 underline, 16 inverse.
    public struct Style: Equatable, Hashable, Sendable {
        public var fg = -1
        public var bg = -1
        public var flags = 0

        public static let plain = Style()
        public static let bold = 1, dim = 2, italic = 4, underline = 8, inverse = 16

        /// Applies one SGR parameter string (`ESC [` … `m`, without either end). Only the codes
        /// of the spec are read; others are skipped with their arguments, so `58;5;n` cannot
        /// turn into "blink" and a colour. Private (`ESC [ > 4 m`) and intermediate forms are
        /// not SGR and change nothing.
        mutating func apply<C: Collection>(sgr params: C) where C.Element == Unicode.Scalar {
            guard params.allSatisfy({ ("0"..."9").contains($0) || $0 == ";" || $0 == ":" }) else { return }
            let text = String(String.UnicodeScalarView(params))
            let groups = text.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) } }
            var i = 0
            while i < groups.count {
                let g = groups[i]
                i += 1
                let code = g[0] ?? 0
                switch code {
                case 0: self = .plain
                case 1: flags |= Style.bold
                case 2: flags |= Style.dim
                case 3: flags |= Style.italic
                case 4: if (g.count > 1 ? g[1] ?? 0 : 1) == 0 { flags &= ~Style.underline } else { flags |= Style.underline }
                case 7: flags |= Style.inverse
                case 22: flags &= ~(Style.bold | Style.dim)
                case 23: flags &= ~Style.italic
                case 24: flags &= ~Style.underline
                case 27: flags &= ~Style.inverse
                case 30...37: fg = code - 30
                case 39: fg = -1
                case 40...47: bg = code - 40
                case 49: bg = -1
                case 90...97: fg = code - 90 + 8
                case 100...107: bg = code - 100 + 8
                case 38, 48, 58:
                    let color: Int?
                    if g.count > 1 {
                        color = Style.color(Array(g.dropFirst()), colon: true)  // 38:5:n, 38:2:r:g:b, 38:2::r:g:b
                    } else {
                        let mode = i < groups.count ? groups[i][0] : nil
                        let take = mode == 5 ? 2 : mode == 2 ? 4 : 1
                        let args = groups[i..<min(i + take, groups.count)].map { $0[0] }
                        color = Style.color(args, colon: false)
                        i += take
                    }
                    if let color { if code == 38 { fg = color } else if code == 48 { bg = color } }
                default: break
                }
            }
        }

        /// `[5, n]` or `[2, r, g, b]` (colon form may carry a colour space id: `[2, cs, r, g, b]`).
        static func color(_ a: [Int?], colon: Bool) -> Int? {
            func byte(_ v: Int??) -> Int? { (v ?? nil).flatMap { (0...255).contains($0) ? $0 : nil } }
            switch a.first ?? nil {
            case 5?: return a.count >= 2 ? byte(a[1]) : nil
            case 2?:
                let rgb = colon && a.count >= 5 ? Array(a[2...4]) : a.count >= 4 ? Array(a[1...3]) : []
                guard rgb.count == 3, let r = byte(rgb[0]), let g = byte(rgb[1]), let b = byte(rgb[2]) else { return nil }
                return 256 + (r << 16 | g << 8 | b)
            default: return nil
            }
        }

        /// A space with no background, underline or inverse looks the same in any such style.
        var invisibleOnSpace: Bool { bg == -1 && flags & (Style.underline | Style.inverse) == 0 }
    }

    /// One `[start, len, fg, bg, flags]` of the `styles` field.
    public struct Run: Equatable, Sendable {
        public var start: Int
        public var len: Int
        public var style: Style

        public init(start: Int, len: Int, style: Style) {
            self.start = start; self.len = len; self.style = style
        }

        public var array: [Int] { [start, len, style.fg, style.bg, style.flags] }
    }

    /// At most this many runs per line; later runs are dropped and their text stays plain.
    public static let maxRuns = 24

    /// `raw` is a `capture-pane -e` text (or any text with SGR). `lines` is exactly
    /// `LogTail.allLines(raw)`: the same engine, split, trim and empty-line rule. SGR state carries
    /// across lines and across dropped empty lines (tmux does not reset at a line end).
    public static func parse(raw: String) -> (lines: [String], styles: [[Run]]) {
        let (text, styles) = LogTail.scan(raw, styled: true)
        var lines: [String] = [], out: [[Run]] = []
        var start = 0
        for end in text.indices.filter({ text[$0] == "\n" }) + [text.count] {
            defer { start = end + 1 }
            guard start < end else { continue }
            // The same expression as `allLines`, so `lines` cannot drift from the plain path.
            let line = String(String.UnicodeScalarView(text[start..<end])).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var a = start, b = end
            while a < b, CharacterSet.whitespaces.contains(text[a]) { a += 1 }
            while b > a, CharacterSet.whitespaces.contains(text[b - 1]) { b -= 1 }
            lines.append(line)
            // Offsets only if the scalar trim matches Foundation's; otherwise the line stays plain.
            out.append(line.unicodeScalars.count == b - a ? runs(text[a..<b], styles[a..<b]) : [])
        }
        return (lines, out)
    }

    /// Runs of one line: all-default runs left out, equal neighbours merged, at most `maxRuns`
    /// (the first ones; the rest of the line stays plain). Spaces that look plain whatever their
    /// colour join the run around them when both sides match ("Worked for 34s" is one run), else
    /// count as plain, so a run never starts or ends on such a space.
    static func runs(_ scalars: ArraySlice<Unicode.Scalar>, _ styles: ArraySlice<Style>) -> [Run] {
        let c = Array(scalars), own = Array(styles)
        var eff = own
        var k = 0
        while k < c.count {
            guard c[k] == " " else { k += 1; continue }
            var e = k
            while e < c.count, c[e] == " " { e += 1 }
            let before = k > 0 ? own[k - 1] : nil, after = e < c.count ? own[e] : nil
            let bridge = before != nil && before == after && before!.invisibleOnSpace ? before! : Style.plain
            for j in k..<e where own[j].invisibleOnSpace { eff[j] = bridge }
            k = e
        }
        var out: [Run] = []
        for (k, style) in eff.enumerated() where style != .plain {
            if let last = out.last, last.style == style, last.start + last.len == k {
                out[out.count - 1].len += 1
            } else {
                out.append(Run(start: k, len: 1, style: style))
            }
        }
        return Array(out.prefix(maxRuns))
    }

    /// Runs cut to a line of `count` scalars (the 400-character line cut of the log answer).
    public static func clip(_ runs: [Run], to count: Int) -> [Run] {
        runs.compactMap { r in
            guard r.start < count else { return nil }
            var r = r
            r.len = min(r.len, count - r.start)
            return r
        }
    }
}
