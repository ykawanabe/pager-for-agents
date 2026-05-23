import XCTest
@testable import ClaudePager

/// P6c/P6d + TCC fix: the "Open in Terminal" rows now write a temp `.command`
/// file and `open` it (so macOS routes it to the user's default terminal),
/// instead of driving Terminal.app over AppleScript. Apple Events automation
/// permission (Claude Pager → Terminal.app) is lost on every rebuild of the
/// unsigned binary, so the osascript path failed with -1743 after each
/// reinstall. The pure builders below produce the shell command and the
/// `.command` body; we assert the command tails/opens correctly and that the
/// path / thread id are quoted/sanitized so they can't break out of the shell.
final class TerminalLauncherTests: XCTestCase {

    func test_logTailCommand_tailsThePath() {
        let cmd = TerminalLauncher.logTailCommand(path: "/Users/x/.pager/agent.log")
        XCTAssertEqual(cmd, "tail -n 200 -f '/Users/x/.pager/agent.log'")
    }

    func test_logTailCommand_shellQuotesEmbeddedSingleQuote() {
        // A path containing a single quote must be escaped as '\'' so the
        // shell sees the literal quote rather than ending the quoted string.
        let cmd = TerminalLauncher.logTailCommand(path: "/tmp/we'rd/agent.log")
        XCTAssertEqual(cmd, "tail -n 200 -f '/tmp/we'\\''rd/agent.log'")
    }

    func test_commandFileBody_isBashScriptWithTrailingNewline() {
        // Mirrors MenuView.openTerminal: a #!/bin/bash script (no `exec`
        // prefix), the command on its own line, trailing newline so the
        // .command tab closes cleanly when the command exits.
        let body = TerminalLauncher.commandFileBody("tail -f '/x'")
        XCTAssertEqual(body, "#!/bin/bash\ntail -f '/x'\n")
    }

    func test_openTopicCommand_buildsCtaOpen() {
        let cmd = TerminalLauncher.openTopicCommand(threadId: "dm",
                                                    ctaPath: "/Users/x/.local/bin/cta")
        XCTAssertEqual(cmd, "/Users/x/.local/bin/cta open dm")
    }

    func test_openTopicCommand_sanitizesThreadId() {
        // No legitimate thread id contains quotes/backslashes, but strip them
        // defensively so a crafted mounts.json entry can't inject shell.
        let cmd = TerminalLauncher.openTopicCommand(threadId: "d\"m\\",
                                                    ctaPath: "/bin/cta")
        XCTAssertEqual(cmd, "/bin/cta open dm")
    }
}
