import XCTest
@testable import ClaudePager

/// P6c/P6d: the "Poller log" row opens a `tail -f agent.log` Terminal window
/// (the poller is launchd-direct now, not a tmux session). logTailScript is
/// the pure command builder; we assert it produces a tail of the path and
/// shell-quotes it so a path with shell metacharacters can't break out.
final class TerminalLauncherTests: XCTestCase {

    func test_logTailScript_tailsThePath() {
        let script = TerminalLauncher.logTailScript(path: "/Users/x/.pager/agent.log")
        XCTAssertTrue(script.contains("tail -n 200 -f '/Users/x/.pager/agent.log'"),
                      "expected a single-quoted tail -f of the path; got: \(script)")
        XCTAssertTrue(script.contains("do script"),
                      "expected an AppleScript do-script wrapper")
    }

    func test_logTailScript_shellQuotesEmbeddedSingleQuote() {
        // A path containing a single quote must be escaped as '\'' so the
        // shell sees the literal quote rather than ending the quoted string.
        let script = TerminalLauncher.logTailScript(path: "/tmp/we'rd/agent.log")
        XCTAssertTrue(script.contains("'/tmp/we'\\''rd/agent.log'"),
                      "single quote in path must be escaped as '\\''; got: \(script)")
    }
}
