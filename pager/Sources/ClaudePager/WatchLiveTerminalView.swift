import SwiftUI
import AppKit
import SwiftTerm

/// LocalProcessTerminalView subclass that auto-focuses itself the moment it
/// enters a window hierarchy. SwiftTerm's "no focus" rendering dims the caret
/// to an outline and the view feels unselected; without this hook, the view
/// only acquires focus when the user explicitly clicks into it.
///
/// Why a subclass instead of `DispatchQueue.main.async { window?.makeFirstResponder }`
/// from makeNSView: at makeNSView time the view is not yet attached to any
/// window, and the async dispatch can fire either before or after window
/// attachment depending on SwiftUI's hosting timing. viewDidMoveToWindow is
/// the canonical AppKit lifecycle hook for "I now have a window."
private final class FocusingTerminalView: LocalProcessTerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }
}

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
        let term = FocusingTerminalView(frame: .zero)
        term.processDelegate = context.coordinator

        // Force a high-contrast dark terminal theme regardless of system
        // appearance. SwiftTerm defaults to NSColor.textColor /
        // NSColor.textBackgroundColor, which in dark mode are "soft white"
        // (around #DDDDDD) on "dark gray" (around #1E1E1E) — that low
        // contrast was what the user perceived as "dim / unselected" feel.
        // Real terminals (Terminal.app, iTerm2) ship near-pure white on
        // near-pure black; matching that visual register makes the embedded
        // terminal feel like a real terminal instead of a SwiftUI panel.
        term.nativeForegroundColor = NSColor(white: 0.95, alpha: 1.0)
        term.nativeBackgroundColor = NSColor(white: 0.05, alpha: 1.0)

        // Try to start tmux. If tmux is not installed, leave the view empty —
        // the parent SwiftUI layer handles the "tmux missing" diagnostic via
        // existing status pills.
        guard let tmux = TmuxResolver.path else {
            return term
        }

        // Plain `tmux attach -t topic-<id>`. We add ourselves as a second
        // client on the same session that topic-wrapper.sh already attached
        // to. tmux sizes the pane to MIN(clients), so SwiftTerm and the
        // wrapper-side client share whatever the smaller of the two is.
        //
        // History: tried `new-session -A -s viewer-<id> -t topic-<id>` to
        // isolate geometry, but `-t` creates a session GROUP, not a shared
        // window — viewer-<id> spawned its own empty bash window and our
        // keystrokes never reached claude in topic-<id>. The correct
        // window-sharing dance would need `link-window` + `kill-window`,
        // which is multi-command and brittle. Plain attach works.
        let session = "topic-\(threadId)"
        term.startProcess(
            executable: tmux,
            args: ["attach", "-t", session],
            environment: terminalEnvironment(),
            execName: nil
        )

        // Force a sensible PTY winsize AFTER the child process is spawned.
        // SwiftTerm's resize() goes through sizeChanged() which only pushes
        // setWinSize to the PTY when `process.running` is true — calling it
        // BEFORE startProcess is a no-op for the actual TIOCSWINSZ. Without
        // this post-spawn nudge, tmux reads the default forkpty winsize (0×0
        // or tiny), shrinks the pane, and claude rewraps its current TUI
        // (the picker, the prompt) to 1-column-wide vertical garbage. That
        // mangled rendering then sits in the scrollback forever because
        // SwiftUI's later layout pass (which DOES resize correctly) only
        // affects future output. 80×24 is a generic "real terminal" default
        // — once SwiftUI lays the view out, setFrameSize → processSizeChange
        // rescales to the actual cols/rows, which is just a normal SIGWINCH
        // claude handles cleanly.
        term.resize(cols: 80, rows: 24)
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
