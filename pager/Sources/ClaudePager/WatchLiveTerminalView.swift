import SwiftUI
import AppKit
import SwiftTerm

/// Embeds a real terminal emulator in Watch live's main pane. We spawn
/// `tmux attach -t topic-<thread_id>` as the child process; SwiftTerm's
/// LocalProcessTerminalView handles PTY, ANSI, scrollback, and keyboard
/// input natively. This replaces the earlier polling-based plain-text
/// rendering, which had:
///
///   - Cursor-positioning escapes leaking into the SwiftUI Text view
///   - 500ms polling latency between content updates
///   - A 3-hop input path (TextEditor → cta send → load-buffer → paste-buffer)
///     that was prone to race conditions
///
/// Architectural notes:
///
///   - Topic switching: the parent uses `.id(threadId)` to recreate this
///     view when focus changes. SwiftUI calls `dismantleNSView`, which
///     calls `terminate()` on the previous process, then `makeNSView`
///     spawns a fresh tmux client for the new topic. No manual switch
///     logic needed.
///
///   - PATH: Pager's LaunchAgent context has a minimal PATH that does
///     NOT include `/opt/homebrew/bin`. We pass an explicit environment
///     to the spawned tmux so it can find its own helpers, and we use
///     the absolute path from TmuxResolver as the executable.
///
///   - tmux session presence: if the session doesn't exist, tmux prints
///     "can't find session" and exits; the terminal shows the error. The
///     parent should normally gate this view behind `paneStatus == .live
///     || .starting`, so we don't reach that error path in practice.
struct WatchLiveTerminalView: NSViewRepresentable {

    let threadId: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator

        // Try to start tmux. If tmux is not installed, leave the view empty —
        // the parent SwiftUI layer handles the "tmux missing" diagnostic via
        // existing status pills.
        guard let tmux = TmuxResolver.path else {
            return term
        }

        // Why grouped session (not plain `attach -t topic-<id>`):
        //
        // A bare `tmux attach -t topic-X` adds us as a SECOND client on the
        // same session that topic-wrapper.sh already attached to. tmux then
        // resizes the pane to MIN(all clients' sizes), so every time SwiftTerm
        // resizes (window open, drag, etc.) the pane shrinks/grows, sending
        // SIGWINCH to claude. claude's interactive TUI components (/effort,
        // /model, file picker) don't always handle live resize gracefully and
        // appear to freeze.
        //
        // `new-session -A -s viewer-<id> -t topic-<id>` creates a SEPARATE
        // session that's "grouped" with topic-X — it shares the same windows
        // but maintains independent geometry. SwiftTerm's resizing only
        // affects viewer-<id>'s view; topic-X's pane size stays whatever
        // topic-wrapper.sh set it to. `-A` means attach-if-exists, so
        // reopening Pager reuses the same viewer session.
        let target = "topic-\(threadId)"
        let viewer = "viewer-\(threadId)"
        term.startProcess(
            executable: tmux,
            args: ["new-session", "-A", "-s", viewer, "-t", target],
            environment: terminalEnvironment(),
            execName: nil
        )

        // Auto-focus the terminal once it enters the window hierarchy. Without
        // this, SwiftTerm renders in its "no focus" state — caret becomes an
        // outline and the whole view appears dimmed/unselected. The async
        // dispatch waits one runloop tick so `term.window` is non-nil (SwiftUI
        // attaches the NSView to its hosting window after makeNSView returns).
        DispatchQueue.main.async {
            term.window?.makeFirstResponder(term)
        }
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // No-op. Parent recreates the view on threadId change via .id().
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        // Detach the tmux client (the tmux server keeps running because
        // topic-wrapper.sh is still attached via the original session).
        nsView.terminate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Environment for the spawned tmux. Must explicitly include PATH +
    /// HOME + TERM because LaunchAgent's environment is minimal.
    private func terminalEnvironment() -> [String] {
        var env: [String: String] = [:]
        // Inherit Pager's own env as the base — gives us LANG/USER/etc.
        for (k, v) in ProcessInfo.processInfo.environment {
            env[k] = v
        }
        // Prepend Homebrew paths so tmux's own helpers resolve.
        let currentPath = env["PATH"] ?? ""
        let extraPath = TmuxResolver.pathEnv
        env["PATH"] = currentPath.isEmpty ? extraPath : "\(extraPath):\(currentPath)"
        // SwiftTerm advertises itself as xterm-256color-compatible.
        env["TERM"] = "xterm-256color"
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Coordinator surfaces SwiftTerm's process-level callbacks. We currently
    /// don't act on title/size/exit events — the SwiftUI parent watches its
    /// own paneStatus for that. Stub conforms to the delegate protocol.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}
