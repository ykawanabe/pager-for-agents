import SwiftUI
import AppKit

/// Unified Watch-Live window: sidebar lists every active mount with a 1-line
/// preview + activity dot; main pane embeds a real terminal that's attached
/// to the focused topic's tmux session. See docs/plans/pager-watch-live.md.
///
/// Main pane uses SwiftTerm's LocalProcessTerminalView (WatchLiveTerminalView)
/// rather than a polling+Text rendering. This eliminates the 500ms refresh
/// jitter, ANSI parsing complexity, and the multi-hop input path. The VM is
/// still used for sidebar mounts/activity dots and for gating: we only spawn
/// the terminal when paneStatus says the tmux session is alive.
struct WatchLiveView: View {
    @StateObject private var vm = WatchLiveViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            mainPane
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 400)
        .onAppear { vm.start() }
        .onDisappear {
            vm.stop()
            // Restore accessory mode so Pager doesn't keep a Dock icon
            // after the user closes the watch window. MenuView's open
            // handler bumped us to .regular so the window could take focus.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if vm.rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("No topics yet")
                    .font(.headline)
                Text("Pair the bot from Telegram to begin.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(vm.rows, selection: Binding(
                get: { vm.focusedThreadId },
                set: { if let s = $0 { vm.focus(thread: s) } }
            )) { row in
                sidebarRow(row).tag(row.threadId)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ row: WatchLiveViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                activityDot(row.activity)
                Text("# \(row.label)")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !row.preview.isEmpty {
                Text(row.preview)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func activityDot(_ a: WatchLiveViewModel.Activity) -> some View {
        switch a {
        case .live:
            // Filled green circle = content moved since last refresh.
            Image(systemName: "circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 10))
        case .idle:
            // Green check = alive and healthy, just not currently producing
            // output. Distinct from .live (still moving) and from .dead.
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green.opacity(0.7))
                .font(.system(size: 11))
        case .dead:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 11))
        }
    }

    // MARK: - Main pane

    @ViewBuilder
    private var mainPane: some View {
        VStack(spacing: 0) {
            mainPaneHeader
            Divider()
            paneBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
        }
    }

    /// Switches between the embedded terminal and a placeholder based on the
    /// VM's paneStatus. We only spawn `tmux attach` when the session is
    /// believed alive — otherwise tmux just prints "can't find session" and
    /// exits, which is worse UX than a clean placeholder.
    @ViewBuilder
    private var paneBody: some View {
        if let threadId = vm.focusedThreadId {
            switch vm.paneStatus {
            case .live, .starting, .unknown:
                // Optimistic render: show the terminal as soon as we have a
                // focused thread, without waiting for the 2s polling loop to
                // confirm .live. The previous "case .unknown: placeholderText
                // (Loading…)" path was the source of the user-perceived
                // "load 走ってる" flash on every window open — paneStatus
                // resets to .unknown when the VM is recreated, and the user
                // had to wait for the next refreshPane before the terminal
                // appeared. If the session turns out to be dead, the next
                // poll will flip paneStatus and we'll switch to the
                // placeholder. tmux attach's own error message ("can't find
                // session") is also reasonable to show transiently.
                //
                // .id(threadId) recreates the NSViewRepresentable when focus
                // moves to a different topic. SwiftTerm's terminate() runs
                // via dismantleNSView, so the old tmux client is released
                // before the new one attaches.
                WatchLiveTerminalView(threadId: threadId)
                    .id(threadId)
            case .sessionDead(let stderr):
                placeholderText("Topic's tmux session is not running.\n\nStart it with:\n  cta start\n\nDetails: \(stderr)")
            case .noMount(let stderr):
                placeholderText("No mount for this thread.\n\nDetails: \(stderr)")
            case .error(let msg):
                placeholderText("Error checking topic status:\n\n\(msg)")
            }
        } else {
            placeholderText("Select a topic from the sidebar.", muted: true)
        }
    }

    @ViewBuilder
    private func placeholderText(_ msg: String, muted: Bool = false) -> some View {
        Text(msg)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .foregroundColor(muted ? .secondary : .primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
    }

    @ViewBuilder
    private var mainPaneHeader: some View {
        HStack(spacing: 8) {
            if let id = vm.focusedThreadId,
               let label = vm.rows.first(where: { $0.threadId == id })?.label {
                Text("# \(label)")
                    .font(.headline)
            } else {
                Text("No topic selected")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            paneStatusPill(vm.paneStatus)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func paneStatusPill(_ s: WatchLiveViewModel.PaneStatus) -> some View {
        switch s {
        case .unknown:
            Label("…", systemImage: "circle.dotted")
                .font(.caption)
                .foregroundColor(.secondary)
        case .starting:
            Label("Starting…", systemImage: "circle.fill")
                .font(.caption)
                .foregroundColor(.yellow)
        case .live:
            Label("Live", systemImage: "circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .sessionDead:
            Label("Dead", systemImage: "circle.fill")
                .font(.caption)
                .foregroundColor(.red)
        case .noMount:
            Label("Unmounted", systemImage: "circle.fill")
                .font(.caption)
                .foregroundColor(.orange)
        case .error:
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
        }
    }

}
