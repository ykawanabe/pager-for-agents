import SwiftUI
import AppKit

/// Unified Watch-Live window: sidebar lists every active mount with a 1-line
/// preview + activity dot; main pane renders the focused topic's tmux pane.
/// See docs/plans/pager-watch-live.md (Phase A).
struct WatchLiveView: View {
    @StateObject private var vm = WatchLiveViewModel()
    @State private var inputText: String = ""
    @State private var sendInFlight: Bool = false
    @State private var sendError: String?
    @FocusState private var inputFocused: Bool

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
            ScrollView {
                paneContent
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color(NSColor.textBackgroundColor))
            Divider()
            inputArea
        }
    }

    /// Render the focused topic's pane. For .live we delegate to
    /// ANSIParser.attributed so colors/bold/underline survive; for the
    /// error states we render plain text — those messages don't have ANSI.
    @ViewBuilder
    private var paneContent: some View {
        switch vm.paneStatus {
        case .live(let content):
            Text(ANSIParser.attributed(content))
        case .starting:
            Text("Topic just started — waiting for claude to print.\n\n(this is normal for ~5–15s after a restart or fresh mount)")
                .foregroundColor(.secondary)
        case .sessionDead(let stderr):
            Text("Topic's tmux session is not running.\n\nStart it with:\n  cta start\n\nDetails: \(stderr)")
        case .noMount(let stderr):
            Text("No mount for this thread.\n\nDetails: \(stderr)")
        case .error(let msg):
            Text("Error fetching pane:\n\n\(msg)")
        case .unknown:
            Text("Loading…")
        }
    }

    @ViewBuilder
    private var inputArea: some View {
        VStack(spacing: 4) {
            TextEditor(text: $inputText)
                .font(.system(size: 13))
                .frame(minHeight: 44, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .focused($inputFocused)

            HStack(spacing: 8) {
                if let err = sendError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("⌘↩ to send")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button("Send") { submitInput() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(canSend == false)
            }
        }
        .padding(8)
        .background(.bar)
    }

    private var canSend: Bool {
        !sendInFlight
            && vm.focusedThreadId != nil
            && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = vm.focusedThreadId else { return }
        sendInFlight = true
        sendError = nil
        Task.detached {
            let result = CTAClient.send(thread: id, text: text)
            await MainActor.run {
                sendInFlight = false
                switch result {
                case .ok:
                    inputText = ""
                    inputFocused = true
                case .noMount(let s):
                    sendError = "No mount: \(s.trimmingCharacters(in: .whitespacesAndNewlines))"
                case .sessionDead(let s):
                    sendError = "Topic not running: \(s.trimmingCharacters(in: .whitespacesAndNewlines))"
                case .error(let m):
                    sendError = m.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
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
