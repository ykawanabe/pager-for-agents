import SwiftUI
import AppKit

/// Unified Watch-Live window: sidebar lists every active mount with a 1-line
/// preview + activity dot; main pane shows the focused topic's recent output
/// as read-only text, plus an "Open in Terminal" button + Send field for
/// interaction.
///
/// This is the post-SwiftTerm redesign: embedding a real terminal emulator
/// (SwiftTerm + `tmux attach`) created cascading geometry / lifecycle issues
/// — initial PTY winsize race rendered TUI vertically, every window open
/// triggered a tmux re-attach that flashed the scrollback, and interactive
/// pickers were caught in SIGWINCH races. Pager now stays in its lane as the
/// operator UI: show what's happening, push messages via `cta send`, and
/// delegate true terminal interaction to Terminal.app when the user wants
/// to actually drive claude's TUI.
struct WatchLiveView: View {
    @StateObject private var vm = WatchLiveViewModel()
    @State private var inputText: String = ""
    @State private var sendInFlight: Bool = false
    @State private var sendError: String?
    @State private var launchError: String?
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
            // Sectioned sidebar: "Topics" for user-facing chats, "System"
            // for infrastructure rows (poller log, future watchdog log).
            // Splitting them prevents the synthetic Poller row from
            // visually mixing with conversation topics — earlier feedback
            // was that without the divider it looked like a chat.
            let topicRows = vm.rows.filter { $0.threadId != WatchLiveViewModel.pollerThreadId }
            let systemRows = vm.rows.filter { $0.threadId == WatchLiveViewModel.pollerThreadId }
            List(selection: Binding(
                get: { vm.focusedThreadId },
                set: { if let s = $0 { vm.focus(thread: s) } }
            )) {
                if !topicRows.isEmpty {
                    Section("Topics") {
                        ForEach(topicRows) { row in
                            sidebarRow(row).tag(row.threadId)
                        }
                    }
                }
                if !systemRows.isEmpty {
                    Section("System") {
                        ForEach(systemRows) { row in
                            sidebarRow(row).tag(row.threadId)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ row: WatchLiveViewModel.Row) -> some View {
        let isSystem = row.threadId == WatchLiveViewModel.pollerThreadId
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                activityDot(row.activity)
                // "#" for topic rows (Telegram-flavored), gear glyph for the
                // synthetic system rows (poller log etc.) so they read as
                // infrastructure instead of conversations.
                Text(isSystem ? "⚙ \(row.label)" : "# \(row.label)")
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
            Divider()
            actionBar
            Divider()
            inputArea
        }
    }

    /// Read-only render of the focused topic's last ~N lines of output.
    /// VM's polling fills paneStatus.live(content) every 2s; we strip ANSI
    /// and trim to a reasonable trailing slice so the user sees recent
    /// activity without the full scrollback. For real interaction the user
    /// clicks "Open in Terminal" below.
    @ViewBuilder
    private var paneBody: some View {
        if let id = vm.focusedThreadId {
            // System rows (Poller log) use tmuxPane — they're real tmux
            // sessions and the capture-pane snapshot is the right view.
            // Topic rows always use messagesPane (JSONL bubble view):
            // Phase 4 has no per-topic tmux session so the old tmuxPane
            // fallback would show a misleading "Topic's tmux session is
            // not running" status. Empty-state when no claude turns yet
            // is handled inside messagesPane.
            if id == WatchLiveViewModel.pollerThreadId {
                tmuxPane
            } else {
                messagesPane
            }
        } else {
            placeholderText("Select a topic from the sidebar.", muted: true)
        }
    }

    /// tmux capture-pane renderer — used for the "Poller log" synthetic row
    /// (a real tmux session) and as the fallback for topics whose JSONL
    /// transcript hasn't materialized yet. Phase 4 has no per-topic tmux
    /// session, so for regular topics this path only renders the VM's
    /// "no session" status until the JSONL bubble path takes over on the
    /// first claude turn.
    @ViewBuilder
    private var tmuxPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                paneText
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                    .id("watch-live-bottom")
            }
            .onChange(of: paneSignal) { _, _ in
                proxy.scrollTo("watch-live-bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("watch-live-bottom", anchor: .bottom)
            }
        }
    }

    /// Phase 3 JSONL-bubble renderer. Walks vm.messages, draws each as a
    /// roleColored chat bubble. Scrolls to the last message on append.
    /// Shows an empty-state hint when the topic hasn't generated any turns
    /// yet (no JSONL transcript yet — daemon hasn't been engaged).
    /// Bottom "Claude is working…" row — a typing-indicator analog so the user
    /// sees progress while the daemon generates (the JSONL only gains the
    /// assistant turn once it completes).
    @ViewBuilder
    private var workingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Claude is working…")
                .font(.system(size: 12))
                .italic()
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var messagesPane: some View {
        if vm.messages.isEmpty {
            if vm.isGenerating {
                // First turn cold-starting — show progress instead of the
                // "No messages yet" empty state.
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("Claude is working…")
                        .font(.headline)
                    Text("Cold-starting the daemon and generating the first reply (5–15s).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No messages yet")
                        .font(.headline)
                    Text("Send a message in Telegram (or use the input below) to start a claude session for this topic. The first reply takes 5–15s while the daemon cold-starts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { msg in
                            messageBubble(msg)
                                .id(msg.id)
                        }
                        if vm.isGenerating {
                            workingIndicator
                                .id("watch-live-working")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // Auto-scroll only when a NEW bubble is appended (count grows),
                // not on every re-publish of the array. refreshMessages re-emits
                // the whole list each poll; keying the scroll on count avoids
                // yanking the view to the bottom while the user is reading
                // history (a re-publish with the same count = no scroll).
                .onChange(of: vm.messages.count) { oldCount, newCount in
                    guard newCount > oldCount, let last = vm.messages.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
                .onChange(of: vm.isGenerating) { _, gen in
                    if gen { proxy.scrollTo("watch-live-working", anchor: .bottom) }
                }
                .onAppear {
                    if let last = vm.messages.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// A single bubble. User turns indent right with a blue tint; assistant
    /// turns indent left with the system text background — matches the
    /// Claude.app convention so the visual language is familiar. Tool calls
    /// (Bash, Read, etc.) are rendered as small italic tag rows under the
    /// assistant's text so the user can see "claude did stuff" even when
    /// the turn was tool-heavy.
    @ViewBuilder
    private func messageBubble(_ msg: JsonlReader.Message) -> some View {
        let isUser = msg.role == .user
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                if !msg.text.isEmpty {
                    Text(msg.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .foregroundColor(isUser ? .white : .primary)
                }
                if !msg.toolNames.isEmpty {
                    Text(msg.toolNames.map { "[\($0)]" }.joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .italic()
                        .foregroundColor(isUser ? .white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isUser ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            )
            if !isUser { Spacer(minLength: 60) }
        }
    }

    /// Cheap change-detection key for the scroll auto-bottom — comparing the
    /// full content string would be expensive for long captures.
    private var paneSignal: String {
        switch vm.paneStatus {
        case .unknown: return "u"
        case .starting: return "s"
        case .live(let c): return "l\(c.count)"
        case .sessionDead: return "d"
        case .noMount: return "n"
        case .error: return "e"
        }
    }

    @ViewBuilder
    private var paneText: some View {
        switch vm.paneStatus {
        case .live(let content):
            // Show the full capture (typically up to ~200 lines from the
            // VM's captureProvider). Stripping ANSI keeps the readout
            // legible — color isn't load-bearing for "what's claude doing
            // right now." ScrollView handles overflow; auto-scroll keeps
            // the latest at the bottom.
            let cleaned = trimTrailingBlankLines(ANSIParser.strip(content))
            Text(cleaned.isEmpty ? "(no recent output)" : cleaned)
                .foregroundColor(cleaned.isEmpty ? .secondary : .primary)
        case .starting:
            Text("Topic just started — waiting for claude to print.")
                .foregroundColor(.secondary)
        case .sessionDead(let stderr):
            Text("Topic's tmux session is not running.\n\nStart it with:\n  cta start\n\nDetails: \(stderr)")
        case .noMount(let stderr):
            Text("No mount for this thread.\n\nDetails: \(stderr)")
        case .error(let msg):
            Text("Error fetching pane:\n\n\(msg)")
        case .unknown:
            Text("Loading…")
                .foregroundColor(.secondary)
        }
    }

    /// Strip the trailing blank lines that `tmux capture-pane` emits to pad
    /// the pane to its full height. Without this the read-only display has
    /// a wide swath of empty space at the bottom before the auto-scroll
    /// anchors there.
    private func trimTrailingBlankLines(_ s: String) -> String {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
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
    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                openInTerminal()
            } label: {
                Label("Open in Terminal", systemImage: "terminal")
            }
            .disabled(vm.focusedThreadId == nil)
            if let err = launchError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("For interactive pickers (/effort, /model)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
            && vm.focusedThreadId != WatchLiveViewModel.pollerThreadId
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

    private func openInTerminal() {
        guard let id = vm.focusedThreadId else { return }
        launchError = nil
        let result: TerminalLauncher.LaunchResult
        if id == WatchLiveViewModel.pollerThreadId {
            // Synthetic poller-log row is a real tmux session, attach directly.
            result = TerminalLauncher.openTmux(session: "poller")
        } else {
            // Phase 4: regular topic rows don't have a per-topic tmux session
            // anymore — claude lives inside the poller's ClaudeDaemonRegistry.
            // `cta open <thread>` does the β handoff: signals the poller to
            // release the daemon, execs `claude --resume <uuid>` in the
            // project dir, and reacquires on exit. Single source of truth
            // for the protocol — same code path as a terminal user typing it.
            result = TerminalLauncher.openTopicViaCTA(threadId: id)
        }
        if case .scriptFailed(let msg) = result {
            launchError = "Terminal launch failed: \(msg)"
        }
    }

    @ViewBuilder
    private var mainPaneHeader: some View {
        HStack(spacing: 8) {
            if let id = vm.focusedThreadId,
               let label = vm.rows.first(where: { $0.threadId == id })?.label {
                // System rows (poller log etc.) get the gear glyph so they
                // visually separate from chat-style topic rows.
                let isSystem = id == WatchLiveViewModel.pollerThreadId
                Text(isSystem ? "⚙ \(label)" : "# \(label)")
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
