import Foundation
import AppKit

/// Launches the user's default terminal with the right command for a claude
/// session. Phase 4 has two entry points:
///
/// - **β handoff** (`openTopicViaCTA`): for daemon-mode topics. Tells the
///   poller to release the topic's daemon via `cta open <thread>`, which
///   then execs `claude --resume <uuid>` in the project dir. When the
///   user exits the TUI, `cta open`'s EXIT trap signals reacquire so the
///   daemon respawns lazily on the next inbound message.
/// - **`openLogTail`**: system rows. Used for the synthetic "Poller log"
///   sidebar row. P6c made the runtime launchd-direct (no tmux), so the
///   poller's output lives in $STATE_DIR/agent.log — we `tail -f` it
///   instead of attaching a tmux session.
///
/// Both write a temp `.command` file and `open` it. macOS associates
/// `.command` with the user's default terminal (Terminal / iTerm / wezterm),
/// so this needs NO Apple Events automation permission. The previous
/// AppleScript (`tell application "Terminal" … do script`) path required
/// (Claude Pager → Terminal.app) TCC automation consent, which macOS revokes
/// on every rebuild of the unsigned binary — so osascript failed with -1743
/// ("Not authorized to send Apple events") after each reinstall. This mirrors
/// `MenuView.openTerminal`, which already solved the same problem.
enum TerminalLauncher {

    enum LaunchResult: Equatable {
        case launched
        case scriptFailed(stderr: String)
    }

    /// Phase 4: open a TUI for a daemon-mode topic via `cta open <thread>`.
    /// The CLI does the full β round-trip — request release flag, wait for
    /// ack, exec `claude --resume <uuid>` in the project dir, reacquire
    /// on exit via EXIT/INT/TERM trap.
    static func openTopicViaCTA(threadId: String) -> LaunchResult {
        let ctaPath = resolveCTA() ?? NSHomeDirectory() + "/.local/bin/cta"
        return runCommand(openTopicCommand(threadId: threadId, ctaPath: ctaPath))
    }

    /// Open a terminal that `tail -f`s a log file. Used for the synthetic
    /// "Poller log" system row — P6c's launchd-direct poller writes its
    /// stdout/stderr to $STATE_DIR/agent.log, so following that file is the
    /// live view of the poller. Returns immediately; the terminal launches
    /// asynchronously via `open`.
    static func openLogTail(path: String) -> LaunchResult {
        return runCommand(logTailCommand(path: path))
    }

    /// Build the `cta open <thread>` command. Pure (no I/O) so the command
    /// construction is testable. `threadId` comes from mounts.json — "dm" or
    /// a numeric string; strip quotes/backslashes defensively so a crafted
    /// entry can't inject into the shell script we write to disk.
    static func openTopicCommand(threadId: String, ctaPath: String) -> String {
        let safeThread = threadId.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        return "\(ctaPath) open \(safeThread)"
    }

    /// Build the `tail -f` command for `path`. Pure (no I/O) so the command
    /// construction is testable. Single-quotes the path for the shell,
    /// escaping any embedded single-quote as '\'' so a path with shell
    /// metacharacters can't break out of the quoted string.
    static func logTailCommand(path: String) -> String {
        let shellQuoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "tail -n 200 -f \(shellQuoted)"
    }

    /// Wrap a shell command as a `.command` file body. Pure. Mirrors
    /// `MenuView.openTerminal`: a plain `#!/bin/bash` script (no `exec`
    /// prefix, so compound commands work), the command on its own line, and a
    /// trailing newline so the launched tab closes cleanly when it exits.
    static func commandFileBody(_ command: String) -> String {
        return "#!/bin/bash\n\(command)\n"
    }

    /// Probe known cta install paths. Same ordering as CTAClient.
    private static func resolveCTA() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/cta",
            "/opt/homebrew/bin/cta",
            "/usr/local/bin/cta",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Write `command` to a temp executable `.command` file and `open` it so
    /// macOS hands it to the user's default terminal. No Apple Events / TCC
    /// automation consent required (unlike the old osascript path).
    private static func runCommand(_ command: String) -> LaunchResult {
        let path = NSTemporaryDirectory()
            + "claude-pager-\(UUID().uuidString.prefix(8)).command"
        let body = commandFileBody(command)
        guard let data = body.data(using: .utf8),
              FileManager.default.createFile(
                atPath: path, contents: data,
                attributes: [.posixPermissions: 0o755]) else {
            return .scriptFailed(stderr: "failed to write command file at \(path)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        do {
            try proc.run()
        } catch {
            return .scriptFailed(stderr: error.localizedDescription)
        }
        // Drain BOTH pipes before waitUntilExit — reading after wait risks a
        // full-pipe deadlock if the child ever writes >64KB (mirrors CTAClient.run).
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "unknown open error"
            return .scriptFailed(stderr: msg)
        }
        return .launched
    }
}
