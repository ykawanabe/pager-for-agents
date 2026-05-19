import Foundation
import AppKit

/// Opens the user's preferred terminal app with `tmux attach -t topic-<id>`.
/// We delegate full interaction to a real terminal emulator (Terminal.app
/// by default) rather than embedding SwiftTerm — the embedded route hit
/// geometry/lifecycle issues (resize SIGWINCH on every reopen, alt-screen
/// races during interactive pickers) that a real terminal handles natively.
///
/// macOS's Terminal.app exposes AppleScript via the `do script` verb, which
/// opens a fresh window and runs the command in it. We use AppleScript via
/// `osascript` for the path-of-least-resistance integration. If the user
/// has iTerm2, future iterations can detect and prefer it.
enum TerminalLauncher {

    enum LaunchResult: Equatable {
        case launched
        case scriptFailed(stderr: String)
    }

    /// Open Terminal.app and attach to the given topic's tmux session.
    /// Returns immediately; Terminal.app launches asynchronously.
    static func openTmux(session: String) -> LaunchResult {
        // Use the absolute tmux path so the spawned shell finds it even
        // though Terminal.app inherits its own PATH (Homebrew may or may
        // not be on it depending on the user's shell rc).
        let tmuxPath = resolveTmux() ?? "/opt/homebrew/bin/tmux"
        // The double-quote-escape is needed because the AppleScript string
        // is itself inside the osascript -e single-quoted argument.
        let command = "\(tmuxPath) attach -t \(session)"
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        return runOsascript(script)
    }

    /// Probe known tmux install paths. Mirrors the pattern in CTAClient for
    /// resolving `cta`. Nil if not found — caller falls back to the default.
    private static func resolveTmux() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux",
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
