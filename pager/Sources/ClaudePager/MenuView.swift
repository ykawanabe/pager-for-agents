import SwiftUI

struct MenuView: View {
    @ObservedObject var monitor: StatusMonitor
    @ObservedObject var caffeinate: CaffeinateController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("caffeinateEnabled") private var caffeinateEnabled = false
    @AppStorage("caffeinateOnlyOnAC") private var caffeinateOnlyOnAC = true

    var body: some View {
        let s = monitor.status

        // Healthy: one bold word + last-seen. Anything else: show only what's
        // actually broken — the menu bar icon already signals overall health.
        // Color follows macOS warning semantics: brand accent when green,
        // system orange/red when degraded/offline.
        Text(overallText(s))
            .fontWeight(.semibold)
            .foregroundStyle(verdictColor(s))

        if s.color == .green {
            if let last = s.lastActivity {
                // bot.pid mtime reflects when the plugin started polling, not
                // when it last processed a message — the official plugin
                // doesn't write a real heartbeat. Until we ship our own MCP
                // with a heartbeat file, this label has to be honest about
                // what it actually means.
                Text("Polling since \(relative(last))")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(brokenComponents(s), id: \.self) { line in
                Text(line).foregroundStyle(.secondary)
            }
        }

        Divider()

        // MULTI_TOPIC has one claude session per topic. The unified Watch-Live
        // window shows every active topic in one place — sidebar lists them
        // with activity dots + 1-line previews; main pane renders the focused
        // topic's tmux pane. See docs/plans/pager-watch-live.md.
        // Power users can still drop to Terminal: `tmux attach -t topic-<id>`.
        Button("Watch live…") {
            openWindow(id: "watch-live")
        }
        Button("Watch poller log") {
            // Separate item for the dispatch / routing log (poller stdout).
            // Helpful for diagnosing drops, pair state changes, etc.
            openTerminal(running: "tmux attach -t poller 2>/dev/null || tail -F \"\(CTAClient.stateDir)/agent.log\"")
        }
        Button("Show recent activity") {
            openTerminal(running: "tail -f \"\(CTAClient.stateDir)/agent.log\"")
        }
        Button("Restart bot") {
            _ = run("/bin/bash", ["-lc", "~/.local/bin/start_agents.sh"])
        }
        Button("Run diagnostics…") {
            Task {
                let steps = await Diagnostics.run()
                await MainActor.run { showDiagnostics(steps) }
            }
        }

        Divider()

        // One-click sleep prevention. The label reflects three states so the
        // user can see why caffeinate isn't actually running even when the
        // toggle is "on" — i.e. AC-only mode while unplugged.
        Button(caffeinateMenuLabel) {
            caffeinateEnabled.toggle()
            caffeinate.configure(enabled: caffeinateEnabled, onlyOnAC: caffeinateOnlyOnAC)
        }

        Divider()

        // The standard "showSettingsWindow:" selector does not fire in
        // accessory (LSUIElement) apps. SwiftUI's openSettings environment
        // action does the right thing.
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Quit Claude Pager") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Three-state label. "Paused (on battery)" when the user wants caffeinate
    /// on but AC-only mode is suppressing it — surfaces the gap between intent
    /// and effect so the user doesn't wonder why the Mac slept anyway. The
    /// "actually running" bit comes from `cta status` (the agent is the source
    /// of truth for the subprocess); `caffeinate.onACPower` is local to Pager
    /// because it drives the policy.
    private var caffeinateMenuLabel: String {
        if !caffeinateEnabled { return "Keep Mac awake" }
        if monitor.status.caffeinateAlive { return "Keep Mac awake ✓" }
        if caffeinateOnlyOnAC && !caffeinate.onACPower { return "Keep Mac awake (paused — on battery)" }
        return "Keep Mac awake ✓"
    }

    private func overallText(_ s: AgentStatus) -> String {
        switch s.color {
        case .green:  return "Online"
        case .yellow: return "Degraded"
        case .red:    return "Offline"
        }
    }

    private func verdictColor(_ s: AgentStatus) -> Color {
        switch s.color {
        case .green:  return .accentColor   // honors the system accent in System Settings → Appearance
        case .yellow: return .orange
        case .red:    return .red
        }
    }

    private func brokenComponents(_ s: AgentStatus) -> [String] {
        var lines: [String] = []
        if s.claudePid == nil { lines.append("Bot not running") }
        if !s.telegramMcpAlive { lines.append("Plugin not polling") }
        if !s.launchAgentLoaded { lines.append("LaunchAgent not loaded") }
        if !s.tmuxClaudeAlive { lines.append("Bot session missing") }
        if !s.tmuxWatchdogAlive { lines.append("Watchdog session missing") }
        return lines
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func showDiagnostics(_ steps: [Diagnostics.Step]) {
        let failed = steps.contains { !$0.ok }
        let alert = NSAlert()
        alert.messageText = failed
            ? "Diagnostic — \(steps.filter { !$0.ok }.count) issue(s) found"
            : "Diagnostic — all checks passed"
        alert.informativeText = Diagnostics.formatReport(steps)
        alert.alertStyle = failed ? .warning : .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func openTerminal(running cmd: String) {
        // Write a temp .command file and open it with the user's default
        // Terminal app via `open`. macOS associates .command with Terminal /
        // iTerm / wezterm without us needing Apple Events automation
        // permission — avoids the recurring "Allow Claude Pager to control
        // Terminal.app?" prompt that AppleScript triggers on every rebuild
        // of an unsigned binary.
        let path = NSTemporaryDirectory() + "claude-pager-\(UUID().uuidString.prefix(8)).command"
        // Drop the `exec` prefix so multi-line shell scripts work. `exec` only
        // accepts a single program+args, not assignments or compound commands —
        // so `exec LATEST=$(tmux ls...)` fails with "LATEST=topic-dm: not found".
        // Just run as a normal bash script; the trailing `exit` from .command
        // closes the Terminal tab when done.
        let body = "#!/bin/bash\n\(cmd)\n"
        guard let data = body.data(using: .utf8),
              FileManager.default.createFile(atPath: path, contents: data,
                  attributes: [.posixPermissions: 0o755]) else { return }
        _ = run("/usr/bin/open", [path])
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
