import XCTest
@testable import ClaudePager

final class ANSIParserTests: XCTestCase {

    func test_plain_text_single_run() {
        let runs = ANSIParser.parse("hello world")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].0, "hello world")
        XCTAssertEqual(runs[0].1, ANSIParser.Style())
    }

    func test_empty_input() {
        XCTAssertEqual(ANSIParser.parse("").count, 0)
    }

    func test_red_then_reset() {
        let s = "\u{001B}[31mRED\u{001B}[0m default"
        let runs = ANSIParser.parse(s)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].0, "RED")
        XCTAssertEqual(runs[0].1.fg, .red)
        XCTAssertEqual(runs[1].0, " default")
        XCTAssertEqual(runs[1].1, ANSIParser.Style())
    }

    func test_compound_bold_red() {
        let s = "\u{001B}[1;31mBOLDRED"
        let runs = ANSIParser.parse(s)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].0, "BOLDRED")
        XCTAssertEqual(runs[0].1.fg, .red)
        XCTAssertTrue(runs[0].1.bold)
    }

    func test_bright_foreground() {
        let s = "\u{001B}[92mGREEN"
        let runs = ANSIParser.parse(s)
        XCTAssertEqual(runs[0].1.fg, .brightGreen)
    }

    func test_background_color() {
        let s = "\u{001B}[44mBLUEBG"
        let runs = ANSIParser.parse(s)
        XCTAssertEqual(runs[0].1.bg, .blue)
    }

    func test_underline_then_disable() {
        let s = "\u{001B}[4mU\u{001B}[24mN"
        let runs = ANSIParser.parse(s)
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs[0].1.underline)
        XCTAssertFalse(runs[1].1.underline)
    }

    func test_256_color_consumes_2_params_without_styling() {
        // 38;5;196 = bright red in 256-color. We don't render 256-color
        // but we must consume the params so the rest of the stream
        // doesn't see "196" as a stray SGR code.
        let s = "\u{001B}[38;5;196mUNCOLORED\u{001B}[0m after"
        let runs = ANSIParser.parse(s)
        // "UNCOLORED" should have unknown fg (no styling applied), then
        // reset brings " after" back to default. The key assertion is
        // that we DON'T crash and DON'T leak "196m" into the buffer.
        XCTAssertEqual(runs.map(\.0).joined(), "UNCOLORED after")
        XCTAssertNil(runs.last?.1.fg)
    }

    func test_truecolor_consumes_4_params() {
        let s = "\u{001B}[38;2;255;128;64mTRUE"
        let runs = ANSIParser.parse(s)
        XCTAssertEqual(runs[0].0, "TRUE")
        // No truecolor support; fg stays nil but the params don't leak.
    }

    func test_empty_sgr_is_reset() {
        // ESC[m  ==  ESC[0m  (reset to default)
        let s = "\u{001B}[31mRED\u{001B}[mDEFAULT"
        let runs = ANSIParser.parse(s)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].1.fg, .red)
        XCTAssertNil(runs[1].1.fg)
    }

    func test_non_sgr_csi_dropped_silently() {
        // ESC[H is cursor-home, ESC[2J is clear-screen. We don't emulate
        // these; the visible text should still survive without the
        // control sequences leaking through.
        let s = "\u{001B}[Hbefore\u{001B}[2Jafter"
        let runs = ANSIParser.parse(s)
        XCTAssertEqual(runs.map(\.0).joined(), "beforeafter")
    }

    func test_orphan_esc_skipped() {
        // ESC followed by something that's not '[' is dropped along with
        // the next byte. Defensive — claude can emit ESC] (OSC) etc.
        let s = "\u{001B}]0;titlevisible"
        let runs = ANSIParser.parse(s)
        // ESC ] is consumed, then "0;titlevisible" remains.
        XCTAssertTrue(runs.last?.0.contains("visible") ?? false)
    }

    func test_multiline_with_colors() {
        // Real-world-ish: each line has its own color reset.
        let s = "\u{001B}[31mline1\u{001B}[0m\n\u{001B}[32mline2\u{001B}[0m"
        let runs = ANSIParser.parse(s)
        let joined = runs.map(\.0).joined()
        XCTAssertEqual(joined, "line1\nline2")
        XCTAssertEqual(runs[0].1.fg, .red)
        XCTAssertTrue(runs.contains(where: { $0.1.fg == .green }))
    }

    func test_attributed_render_produces_attributed_string() {
        let s = "\u{001B}[1;31mBOLDRED\u{001B}[0m"
        let attr = ANSIParser.attributed(s)
        // AttributedString basic shape — not byte-perfect, just that we
        // emit some runs and the text round-trips.
        XCTAssertEqual(String(attr.characters), "BOLDRED")
    }
}
