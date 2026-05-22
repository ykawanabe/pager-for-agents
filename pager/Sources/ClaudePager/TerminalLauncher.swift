import Foundation
import AppKit

/// Launches a real terminal emulator (Terminal.app by default) with the
/// right command for the user to interact with a claude session. Phase 4
/// has two entry points:
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
/// macOS's Terminal.app exposes AppleScript via the `do script` verb,
/// which opens a fresh window and runs the command in it.
enum TerminalLauncher {

    enum LaunchResult: Equatable {
        case launched
        case scriptFailed(stderr: String)
    }

    /// Phase 4: open a TUI for a daemon-mode topic via `cta open <thread>`.
    /// The CLI does the full β round-trip — request release flag, wait for
    /// ack, exec `claude --resume <uuid>` in the project dir, reacquire
    /// on exit via EXIT/INT/TERM trap.
    ///
    /// Pure path-shell-out via osascript. The Pager itself doesn't manage
    /// any of the IPC plumbing — `cta open` is the single source of truth
    /// for the handoff protocol, used identically from any caller.
    static func openTopicViaCTA(threadId: String) -> LaunchResult {
        let ctaPath = resolveCTA() ?? NSHomeDirectory() + "/.local/bin/cta"
        // threadId comes from mounts.json — it's "dm" or a numeric string.
        // Sanitize defensively even though no legitimate value can break
        // out of the AppleScript do-script string.
        let safeThread = threadId.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        let command = "\(ctaPath) open \(safeThread)"
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        return runOsascript(script)
    }

    /// Open Terminal.app and `tail -f` a log file. Used for the synthetic
    /// "Poller log" system row — P6c's launchd-direct poller writes its
    /// stdout/stderr to $STATE_DIR/agent.log (StandardOutPath + the exec
    /// redirect), so following that file is the live view of the poller.
    /// Returns immediately; Terminal.app launches asynchronously.
    static func openLogTail(path: String) -> LaunchResult {
        return runOsascript(logTailScript(path: path))
    }

    /// Build the AppleScript that opens Terminal.app and tails `path`.
    /// Factored out (pure) so the command construction is testable without
    /// actually spawning Terminal.app. Single-quotes the path for the shell
    /// and escapes embedded single-quotes + double-quotes for the nested
    /// AppleScript string.
    static func logTailScript(path: String) -> String {
        // Shell-quote: wrap in single quotes, escaping any embedded ' as '\''.
        let shellQuoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "tail -n 200 -f \(shellQuoted)"
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
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

    private static func runOsascript(_ script: String) -> LaunchResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return .scriptFailed(stderr: error.localizedDescription)
        }
        if proc.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "unknown osascript error"
            return .scriptFailed(stderr: msg)
        }
        return .launched
    }
}
