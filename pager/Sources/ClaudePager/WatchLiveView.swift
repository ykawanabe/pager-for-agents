import SwiftUI

/// Unified Watch-Live window: sidebar lists every active mount with a 1-line
/// preview + activity dot; main pane renders the focused topic's tmux pane.
/// See docs/plans/pager-watch-live.md (Phase A).
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
        .onDisappear { vm.stop() }
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
            Circle().fill(.green).frame(width: 8, height: 8)
        case .idle:
            Circle().stroke(.secondary, lineWidth: 1).frame(width: 8, height: 8)
        case .dead:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 10))
        }
    }

    // MARK: - Main pane

    @ViewBuilder
    private var mainPane: some View {
        VStack(spacing: 0) {
            mainPaneHeader
            Divider()
            ScrollView {
                Text(paneRenderedText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
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

    private var paneRenderedText: String {
        switch vm.paneStatus {
        case .live(let content):
            return WatchLiveView.stripAnsi(content)
        case .sessionDead(let stderr):
            return "Topic's tmux session is not running.\n\nStart it with:\n  cta start\n\nDetails: \(stderr)"
        case .noMount(let stderr):
            return "No mount for this thread.\n\nDetails: \(stderr)"
        case .error(let msg):
            return "Error fetching pane:\n\n\(msg)"
        case .unknown:
            return "Loading…"
        }
    }

    /// Minimal ANSI-CSI strip: removes `ESC [ ... letter` sequences. Phase D
    /// adds proper color rendering; for now plain text matches the existing
    /// Pager menu-bar log views and is easier to read in a sidebar context.
    static func stripAnsi(_ s: String) -> String {
        s.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )
    }
}
