import Foundation
import XCTest
@testable import ClaudePager

/// Tests for JsonlReader — the Phase 3 transcript parser that feeds the
/// JSONL view in Pager Watch live.
final class JsonlReaderTests: XCTestCase {

    // MARK: - path encoding

    func test_encodeProjectDir_replacesNonAlnumWithDash() {
        XCTAssertEqual(
            JsonlReader.encodeProjectDir("/home/code/repo/proj-name"),
            "-home-code-repo-proj-name"
        )
    }

    func test_encodeProjectDir_handlesUnicodeAndPunctuation() {
        XCTAssertEqual(JsonlReader.encodeProjectDir("/a.b_c"), "-a-b-c")
        // CJK characters are 3 UTF-8 bytes each; sed under C locale (the
        // bash impl) produces one dash per byte, so 日本 = 6 dashes.
        XCTAssertEqual(JsonlReader.encodeProjectDir("/日本/path"), "--------path")
    }

    func test_transcriptPath_isUnderClaudeProjects() {
        let url = JsonlReader.transcriptPath(
            projectPath: "/tmp/proj",
            sessionUuid: "abc-1234",
            claudeHome: URL(fileURLWithPath: "/Users/x/.claude")
        )
        XCTAssertTrue(url.path.hasSuffix(".claude/projects/-tmp-proj/abc-1234.jsonl"))
    }

    // MARK: - parsing user/assistant messages

    func test_parseTranscript_extractsUserAndAssistantText() {
        let lines = [
            // assistant text-only turn
            #"{"type":"assistant","uuid":"u1","timestamp":"2026-05-18T10:00:00.000Z","message":{"model":"claude-opus-4-7","content":[{"type":"text","text":"Hello there"}]}}"#,
            // user text turn
            #"{"type":"user","uuid":"u2","timestamp":"2026-05-18T10:00:05.000Z","message":{"content":[{"type":"text","text":"Hi back"}]}}"#,
            // assistant tool_use + text
            #"{"type":"assistant","uuid":"u3","timestamp":"2026-05-18T10:00:10.000Z","message":{"content":[{"type":"text","text":"Reading file"},{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}"#,
        ].joined(separator: "\n")

        let messages = JsonlReader.parseTranscript(lines)
        XCTAssertEqual(messages.count, 3)

        XCTAssertEqual(messages[0].role, .assistant)
        XCTAssertEqual(messages[0].text, "Hello there")
        XCTAssertTrue(messages[0].toolNames.isEmpty)

        XCTAssertEqual(messages[1].role, .user)
        XCTAssertEqual(messages[1].text, "Hi back")

        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertEqual(messages[2].text, "Reading file")
        XCTAssertEqual(messages[2].toolNames, ["Read"])
    }

    func test_parseTranscript_skipsSystemAndAttachmentEvents() {
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"x"}"#,
            #"{"type":"attachment","uuid":"a1"}"#,
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            #"{"type":"last-prompt","leafUuid":"x"}"#,
            #"{"type":"permission-mode","permissionMode":"auto"}"#,
            #"{"type":"assistant","uuid":"u1","message":{"content":[{"type":"text","text":"only message"}]}}"#,
        ].joined(separator: "\n")

        let messages = JsonlReader.parseTranscript(lines)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "only message")
    }

    func test_parseTranscript_supportsPlainStringContent() {
        // Older transcript format: content is a plain String, not a block array.
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"content":"What's up?"}}"#,
        ].joined(separator: "\n")
        let messages = JsonlReader.parseTranscript(lines)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "What's up?")
    }

    func test_parseTranscript_concatenatesMultipleTextBlocks() {
        let lines = [
            #"{"type":"assistant","uuid":"u1","message":{"content":[{"type":"text","text":"Step 1."},{"type":"tool_use","id":"t1","name":"Bash","input":{}},{"type":"text","text":"Step 2."}]}}"#,
        ].joined(separator: "\n")
        let messages = JsonlReader.parseTranscript(lines)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].text.contains("Step 1."))
        XCTAssertTrue(messages[0].text.contains("Step 2."))
        XCTAssertEqual(messages[0].toolNames, ["Bash"])
    }

    func test_parseTranscript_skipsToolOnlyTurnsWithNoTextAndNoTool() {
        // A row with content: [] and no extractable signal — skip entirely.
        let lines = [
            #"{"type":"assistant","uuid":"u1","message":{"content":[]}}"#,
            #"{"type":"assistant","uuid":"u2","message":{"content":[{"type":"text","text":"real"}]}}"#,
        ].joined(separator: "\n")
        let messages = JsonlReader.parseTranscript(lines)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].id, "u2")
    }

    func test_parseTranscript_tolerantOfMalformedTrailingLine() {
        let lines = [
            #"{"type":"assistant","uuid":"u1","message":{"content":[{"type":"text","text":"ok"}]}}"#,
            #"{partial json"#,
            #""#,
        ].joined(separator: "\n")
        let messages = JsonlReader.parseTranscript(lines)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "ok")
    }

    func test_parseTranscript_emptyStringReturnsEmpty() {
        XCTAssertTrue(JsonlReader.parseTranscript("").isEmpty)
    }

    func test_parseTranscript_keepsToolOnlyTurnIfToolNamesPresent() {
        // Assistant did tool work but emitted no text — still surface the
        // tool name so the user knows something happened.
        let lines = [
            #"{"type":"assistant","uuid":"u1","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}"#,
        ].joined(separator: "\n")
        let messages = JsonlReader.parseTranscript(lines)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "")
        XCTAssertEqual(messages[0].toolNames, ["Read"])
    }

    // MARK: - file I/O

    func test_parseTranscript_atURL_returnsEmptyWhenFileMissing() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).jsonl")
        XCTAssertEqual(JsonlReader.parseTranscript(at: url).count, 0)
    }

    func test_parseTranscript_atURL_readsValidFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        let content = #"{"type":"user","uuid":"u1","message":{"content":"hello"}}"#
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let messages = JsonlReader.parseTranscript(at: tmp)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "hello")
    }
}
