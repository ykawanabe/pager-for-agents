import XCTest
@testable import ClaudePager

/// Tests for the JSON-decode side of CTAClient — the contract with the
/// agent's `cta status --json` output. The process-spawning side is harder to
/// unit-test cleanly (Process+FileManager mocks would obscure more than they
/// reveal), so end-to-end behavior is verified by running Pager against a
/// live `cta` install. These tests pin the schema we accept.
final class CTAClientTests: XCTestCase {
    /// Schema version this Pager build accepts. Bumping requires a Pager
    /// update — this test is the canary that prevents silent drift.
    func test_supportedSchemaVersion_is_1() {
        XCTAssertEqual(CTAClient.supportedSchemaVersion, 1)
    }

    /// Happy path: parse the everything-up JSON `cta status --json` emits.
    /// Mirrors the exact shape from the agent's scripts/cta header.
    func test_decode_allFieldsPresent() throws {
        let json = """
        {
          "schema_version": 1,
          "launch_agent": {"label": "com.claude-agent", "loaded": true},
          "claude": {"pid": 12345, "rss_mb": 312},
          "telegram_mcp": {"alive": true},
          "tmux": {
            "claude": {"name": "claude", "alive": true},
            "watchdog": {"name": "watchdog", "alive": true}
          },
          "last_activity": "2026-05-12T10:00:00Z"
        }
        """.data(using: .utf8)!

        let s = try JSONDecoder().decode(CTAClient.AgentStatusJSON.self, from: json)
        XCTAssertEqual(s.schemaVersion, 1)
        XCTAssertEqual(s.launchAgent.label, "com.claude-agent")
        XCTAssertTrue(s.launchAgent.loaded)
        XCTAssertEqual(s.claude.pid, 12345)
        XCTAssertEqual(s.claude.rssMb, 312)
        XCTAssertTrue(s.telegramMcp.alive)
        XCTAssertEqual(s.tmux.claude.name, "claude")
        XCTAssertTrue(s.tmux.claude.alive)
        XCTAssertEqual(s.tmux.watchdog.name, "watchdog")
        XCTAssertTrue(s.tmux.watchdog.alive)
        XCTAssertEqual(s.lastActivity, "2026-05-12T10:00:00Z")
    }

    /// Everything-down JSON. `pid`, `rss_mb`, and `last_activity` are null
    /// because the agent reports those as null when there's nothing to report
    /// (rather than omitting fields). Confirms Codable handles `null`-vs-int.
    func test_decode_nullableFields() throws {
        let json = """
        {
          "schema_version": 1,
          "launch_agent": {"label": "com.claude-agent", "loaded": false},
          "claude": {"pid": null, "rss_mb": null},
          "telegram_mcp": {"alive": false},
          "tmux": {
            "claude": {"name": "claude", "alive": false},
            "watchdog": {"name": "watchdog", "alive": false}
          },
          "last_activity": null
        }
        """.data(using: .utf8)!

        let s = try JSONDecoder().decode(CTAClient.AgentStatusJSON.self, from: json)
        XCTAssertNil(s.claude.pid)
        XCTAssertNil(s.claude.rssMb)
        XCTAssertNil(s.lastActivity)
        XCTAssertFalse(s.launchAgent.loaded)
        XCTAssertFalse(s.telegramMcp.alive)
    }

    /// Custom tmux session names from .env should round-trip through the
    /// JSON. This is the dual-repo bug we fixed for v0.1.0 — agent supports
    /// it, Pager respects it.
    func test_decode_customSessionNames() throws {
        let json = """
        {
          "schema_version": 1,
          "launch_agent": {"label": "com.claude-agent", "loaded": true},
          "claude": {"pid": 1, "rss_mb": 100},
          "telegram_mcp": {"alive": true},
          "tmux": {
            "claude": {"name": "my-bot", "alive": true},
            "watchdog": {"name": "my-watchdog", "alive": true}
          },
          "last_activity": null
        }
        """.data(using: .utf8)!

        let s = try JSONDecoder().decode(CTAClient.AgentStatusJSON.self, from: json)
        XCTAssertEqual(s.tmux.claude.name, "my-bot")
        XCTAssertEqual(s.tmux.watchdog.name, "my-watchdog")
    }
}
