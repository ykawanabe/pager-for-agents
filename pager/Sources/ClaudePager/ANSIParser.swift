import Foundation
import SwiftUI

/// Minimal ANSI CSI/SGR parser for rendering claude's TUI output in the
/// WatchLive window. Targets the subset claude actually emits: 8/16 named
/// colors + bold/italic/underline + reset. 256-color and 24-bit color
/// sequences are recognized (consumed) but not styled — they fall back to
/// the default foreground so the text is at least visible.
///
/// Scope deliberately small (Phase D of pager-watch-live.md):
///   - Other CSI sequences (cursor positioning, erase, alternate screen
///     buffer) are SILENTLY DROPPED. We're rendering a snapshot, not
///     emulating a terminal. Dropping is correct — the displayed text
///     stays readable even when claude's TUI tries to move the cursor.
///   - DEC private mode sequences (ESC [ ? ...) are dropped.
///   - OSC, ESC ], ESC P (DCS) are not handled (not commonly emitted).
enum ANSIParser {

    enum Color8: Equatable {
        case black, red, green, yellow, blue, magenta, cyan, white
        case brightBlack, brightRed, brightGreen, brightYellow
        case brightBlue, brightMagenta, brightCyan, brightWhite
    }

    struct Style: Equatable {
        var fg: Color8?
        var bg: Color8?
        var bold: Bool = false
        var italic: Bool = false
        var underline: Bool = false
    }

    /// Split `input` into runs, each a (text, style) tuple. Empty-text runs
    /// are not emitted. Caller materializes runs into AttributedString.
    static func parse(_ input: String) -> [(String, Style)] {
        var runs: [(String, Style)] = []
        var current = Style()
        var buf = ""
        var i = input.startIndex

        func flush() {
            if !buf.isEmpty {
                runs.append((buf, current))
                buf = ""
            }
        }

        while i < input.endIndex {
            let c = input[i]
            // CSI sequence: ESC [ params final
            if c == "\u{001B}" {
                let next = input.index(after: i)
                if next < input.endIndex && input[next] == "[" {
                    flush()
                    var j = input.index(after: next)
                    var params = ""
                    var final: Character = " "
                    while j < input.endIndex {
                        let pc = input[j]
                        if pc.isLetter {
                            final = pc
                            j = input.index(after: j)
                            break
                        }
                        params.append(pc)
                        j = input.index(after: j)
                    }
                    if final == "m" {
                        current = applySGR(params: params, to: current)
                    }
                    // Any other CSI final byte (H, J, K, etc.) is dropped.
                    i = j
                    continue
                }
                // Non-CSI ESC sequences: skip the ESC + next byte to be
                // forgiving rather than dumping the raw ESC into the output.
                i = next < input.endIndex ? input.index(after: next) : next
                continue
            }
            buf.append(c)
            i = input.index(after: i)
        }
        flush()
        return runs
    }

    /// Strip ANSI sequences and return plain text. Used by sidebar previews
    /// and any path that doesn't want styling — same parser logic so we
    /// can't drift between the "rendered" and "stripped" representations.
    static func strip(_ input: String) -> String {
        parse(input).map(\.0).joined()
    }

    /// Render parsed runs into an AttributedString suitable for SwiftUI Text.
    /// Bold uses .bold; italic uses .italic; underline uses .underlineStyle.
    /// Colors map to SwiftUI Color values picked to read well on both light
    /// and dark backgrounds.
    static func attributed(_ input: String) -> AttributedString {
        var result = AttributedString()
        for (text, style) in parse(input) {
            var run = AttributedString(text)
            // monospaced font set by caller via .font on the outer Text;
            // here we only emit deltas (bold/italic/underline + color).
            if style.bold && style.italic {
                run.font = .system(size: 12, design: .monospaced).bold().italic()
            } else if style.bold {
                run.font = .system(size: 12, design: .monospaced).bold()
            } else if style.italic {
                run.font = .system(size: 12, design: .monospaced).italic()
            } else {
                run.font = .system(size: 12, design: .monospaced)
            }
            if style.underline {
                run.underlineStyle = .single
            }
            if let fg = style.fg {
                run.foregroundColor = swiftUIColor(fg)
            }
            if let bg = style.bg {
                run.backgroundColor = swiftUIColor(bg).opacity(0.25)
            }
            result.append(run)
        }
        return result
    }

    // MARK: - SGR application

    private static func applySGR(params: String, to style: Style) -> Style {
        var out = style
        // Empty params is the reset-to-default form per spec.
        let codes = params.isEmpty ? ["0"] : params.split(separator: ";").map(String.init)
        var idx = 0
        while idx < codes.count {
            let code = codes[idx]
            switch code {
            case "0", "":
                out = Style()
            case "1": out.bold = true
            case "2": out.bold = false   // dim — treat as not-bold
            case "22": out.bold = false  // "normal intensity" — bold/dim off
            case "3": out.italic = true
            case "23": out.italic = false
            case "4": out.underline = true
            case "24": out.underline = false

            case "30": out.fg = .black
            case "31": out.fg = .red
            case "32": out.fg = .green
            case "33": out.fg = .yellow
            case "34": out.fg = .blue
            case "35": out.fg = .magenta
            case "36": out.fg = .cyan
            case "37": out.fg = .white
            case "38":
                // 256-color: 38;5;N — consume N
                // 24-bit:   38;2;R;G;B — consume 3
                idx += skipCount(after: idx, in: codes)
            case "39": out.fg = nil

            case "40": out.bg = .black
            case "41": out.bg = .red
            case "42": out.bg = .green
            case "43": out.bg = .yellow
            case "44": out.bg = .blue
            case "45": out.bg = .magenta
            case "46": out.bg = .cyan
            case "47": out.bg = .white
            case "48":
                idx += skipCount(after: idx, in: codes)
            case "49": out.bg = nil

            case "90": out.fg = .brightBlack
            case "91": out.fg = .brightRed
            case "92": out.fg = .brightGreen
            case "93": out.fg = .brightYellow
            case "94": out.fg = .brightBlue
            case "95": out.fg = .brightMagenta
            case "96": out.fg = .brightCyan
            case "97": out.fg = .brightWhite

            case "100": out.bg = .brightBlack
            case "101": out.bg = .brightRed
            case "102": out.bg = .brightGreen
            case "103": out.bg = .brightYellow
            case "104": out.bg = .brightBlue
            case "105": out.bg = .brightMagenta
            case "106": out.bg = .brightCyan
            case "107": out.bg = .brightWhite

            default:
                break  // unknown code — ignore, keep current style
            }
            idx += 1
        }
        return out
    }

    /// Number of params to skip after a 38/48 selector code. Returns 2 for
    /// 256-color (5;N) or 4 for truecolor (2;R;G;B). Conservative — if the
    /// stream is truncated, we exit the loop in applySGR naturally.
    private static func skipCount(after idx: Int, in codes: [String]) -> Int {
        guard idx + 1 < codes.count else { return 0 }
        switch codes[idx + 1] {
        case "5": return 2
        case "2": return 4
        default:  return 0
        }
    }

    // MARK: - Color mapping

    /// Pick concrete SwiftUI Colors. Bright variants slightly differ from
    /// base to be discernible in actual TUI output (claude uses both).
    /// Tuned to read on both light and dark Pager themes.
    private static func swiftUIColor(_ c: Color8) -> Color {
        switch c {
        case .black:         return Color(red: 0.2, green: 0.2, blue: 0.2)
        case .red:           return Color(red: 0.80, green: 0.20, blue: 0.20)
        case .green:         return Color(red: 0.10, green: 0.65, blue: 0.20)
        case .yellow:        return Color(red: 0.75, green: 0.55, blue: 0.10)
        case .blue:          return Color(red: 0.20, green: 0.40, blue: 0.85)
        case .magenta:       return Color(red: 0.70, green: 0.25, blue: 0.70)
        case .cyan:          return Color(red: 0.15, green: 0.55, blue: 0.65)
        case .white:         return Color(red: 0.85, green: 0.85, blue: 0.85)
        case .brightBlack:   return Color(red: 0.50, green: 0.50, blue: 0.50)
        case .brightRed:     return Color(red: 0.95, green: 0.30, blue: 0.30)
        case .brightGreen:   return Color(red: 0.20, green: 0.80, blue: 0.30)
        case .brightYellow:  return Color(red: 0.95, green: 0.80, blue: 0.20)
        case .brightBlue:    return Color(red: 0.40, green: 0.60, blue: 1.00)
        case .brightMagenta: return Color(red: 0.90, green: 0.40, blue: 0.90)
        case .brightCyan:    return Color(red: 0.30, green: 0.80, blue: 0.85)
        case .brightWhite:   return Color.white
        }
    }
}
