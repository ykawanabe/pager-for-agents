import XCTest
@testable import ClaudePager

final class DiagnosticsTests: XCTestCase {
    func test_formatReport_alignsLabelsToWidestLabel() {
        let steps = [
            Diagnostics.Step(label: "short",                    ok: true,  detail: "ok-1"),
            Diagnostics.Step(label: "much longer label here",   ok: false, detail: "ok-2"),
        ]
        let lines = Diagnostics.formatReport(steps).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        // Both detail strings should start at the same column — find them and
        // assert their positions match. Robust against future padding-format
        // tweaks as long as labels stay column-aligned.
        let pos1 = lines[0].range(of: "ok-1")!.lowerBound.utf16Offset(in: lines[0])
        let pos2 = lines[1].range(of: "ok-2")!.lowerBound.utf16Offset(in: lines[1])
        XCTAssertEqual(pos1, pos2)
    }

    func test_formatReport_marksPassAndFailDistinctly() {
        let steps = [
            Diagnostics.Step(label: "x", ok: true,  detail: "yep"),
            Diagnostics.Step(label: "y", ok: false, detail: "nope"),
        ]
        let report = Diagnostics.formatReport(steps)
        XCTAssertTrue(report.contains("✓"))
        XCTAssertTrue(report.contains("✗"))
    }

    /// Tokens look like `123456789:ABCdef...`. The masker must preserve the
    /// numeric ID (not secret on its own — it's part of the bot's identity)
    /// and the last 4 chars of the secret (for human verification).
    func test_maskToken_preservesIdAndTail() {
        let masked = Diagnostics.maskToken("123456789:ABCdefGHIjklMNOpqrSTUvwxYZ0123456")
        XCTAssertEqual(masked, "123456789:****3456")
    }

    /// Tokens are usually in `id:secret` shape, but a malformed token (no
    /// colon) should not crash the masker — it should just say invalid.
    func test_maskToken_handlesMalformedInput() {
        let masked = Diagnostics.maskToken("not-a-real-token-no-colon")
        XCTAssertEqual(masked, "(invalid format)")
    }
}
