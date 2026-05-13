import XCTest
@testable import ClaudePager

final class AgentStatusTests: XCTestCase {
    /// Everything up → green. The "all healthy" baseline.
    func test_green_whenEverythingHealthy() {
        var s = AgentStatus()
        s.launchAgentLoaded = true
        s.claudePid = 1234
        s.telegramMcpAlive = true
        s.tmuxClaudeAlive = true
        s.tmuxWatchdogAlive = true
        XCTAssertEqual(s.color, .green)
    }

    /// claude process gone → red. This is the failure mode users care about
    /// most — the bot isn't reachable, period.
    func test_red_whenClaudePidMissing() {
        var s = AgentStatus()
        s.launchAgentLoaded = true
        s.claudePid = nil
        s.telegramMcpAlive = true
        s.tmuxClaudeAlive = true
        s.tmuxWatchdogAlive = true
        XCTAssertEqual(s.color, .red)
    }

    /// MCP plugin gone → red. Matches the silent-plugin-death state the
    /// watchdog also detects on the bash side; the UI signals it identically.
    func test_red_whenMcpDead() {
        var s = AgentStatus()
        s.launchAgentLoaded = true
        s.claudePid = 1234
        s.telegramMcpAlive = false
        s.tmuxClaudeAlive = true
        s.tmuxWatchdogAlive = true
        XCTAssertEqual(s.color, .red)
    }

    /// Both ends gone → red. Don't bury this state in yellow just because
    /// multiple components are down.
    func test_red_whenBothDown() {
        let s = AgentStatus()
        XCTAssertEqual(s.color, .red)
    }

    /// LaunchAgent unloaded but bot running → yellow. Bot works right now,
    /// but won't survive a reboot.
    func test_yellow_whenLaunchAgentUnloaded() {
        var s = AgentStatus()
        s.launchAgentLoaded = false
        s.claudePid = 1234
        s.telegramMcpAlive = true
        s.tmuxClaudeAlive = true
        s.tmuxWatchdogAlive = true
        XCTAssertEqual(s.color, .yellow)
    }

    /// Watchdog tmux session missing → yellow. Bot is alive but auto-recovery
    /// is degraded — exactly the case where the menu should warn without
    /// alarming the user.
    func test_yellow_whenWatchdogMissing() {
        var s = AgentStatus()
        s.launchAgentLoaded = true
        s.claudePid = 1234
        s.telegramMcpAlive = true
        s.tmuxClaudeAlive = true
        s.tmuxWatchdogAlive = false
        XCTAssertEqual(s.color, .yellow)
    }

    /// cta CLI not installed → red, regardless of other fields. The agent
    /// isn't on this Mac, or it's a pre-v0.1.0 build — either way Pager
    /// can't trust any sampled state, so don't pretend things are green.
    func test_red_whenCtaNotInstalled() {
        var s = AgentStatus()
        // Even if every "alive" field is true, ctaInstalled=false forces red.
        s.launchAgentLoaded = true
        s.claudePid = 1234
        s.telegramMcpAlive = true
        s.tmuxClaudeAlive = true
        s.tmuxWatchdogAlive = true
        s.ctaInstalled = false
        XCTAssertEqual(s.color, .red)
    }

    /// Schema mismatch → red. cta is newer (or older) than this Pager
    /// expects; we can't trust the parsed values. User needs to upgrade
    /// the laggard component.
    func test_red_whenSchemaMismatch() {
        var s = AgentStatus()
        s.launchAgentLoaded = true
        s.claudePid = 1234
        s.telegramMcpAlive = true
        s.tmuxClaudeAlive = true
        s.tmuxWatchdogAlive = true
        s.schemaMismatch = (got: 2, expected: 1)
        XCTAssertEqual(s.color, .red)
    }
}
