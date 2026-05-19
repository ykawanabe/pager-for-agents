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
    /// Debounced tmux resize task — replaced (cancelling the old one) on
    /// every geometry change. The actual resize-window fires 400ms after
    /// the last change so a drag doesn't fire 60 SIGWINCH per second.
    @State private var resizeTask: Task<Void, Never>? = nil

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
    ///
    /// Wrapped in a GeometryReader so we can keep tmux's pane width in
    /// sync with Pager's window width — otherwise claude wraps its TUI at
    /// whatever cols topic-wrapper.sh's session was created with (usually
    /// 80), and a wider Pager window just shows that 80-col content with
    /// trailing whitespace. The resize fires debounced from the .onChange
    /// below.
    @ViewBuilder
    private var paneBody: some View {
        if let _ = vm.focusedThreadId {
            // Phase 3 (JSONL view): if claude has written messages to the
            // session's JSONL transcript, render them as conversation
            // bubbles instead of the raw tmux pane. The bubbles are
            // Claude.app-style — paragraph-aligned, user vs. assistant
            // distinguished by tint + alignment, tool calls noted inline
            // as small italic tags. Falls back to the pane snapshot for
            // synthetic rows (poller log) and topics whose transcript
            // hasn't materialized yet (no claude turns completed).
            if !vm.messages.isEmpty {
                messagesPane
            } else {
                tmuxPane
            }
        } else {
            placeholderText("Select a topic from the sidebar.", muted: true)
        }
    }

    /// Existing tmux capture-pane renderer. Kept as the fallback path for
    /// the "Poller log" synthetic row and for topics that haven't generated
    /// a JSONL transcript yet (pre-stream-json installs, fresh mounts).
    @ViewBuilder
    private var tmuxPane: some View {
        GeometryReader { geo in
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
                    scheduleResize(width: geo.size.width, height: geo.size.height)
                }
            }
            .onChange(of: geo.size) { _, new in
                scheduleResize(width: new.width, height: new.height)
            }
            .onChange(of: vm.focusedThreadId) { _, _ in
                scheduleResize(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// Phase 3 JSONL-bubble renderer. Walks vm.messages, draws each as a
    /// roleColored chat bubble. Scrolls to the last message on append.
    @ViewBuilder
    private var messagesPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: vm.messages.last?.id) { _, newId in
                guard let newId else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newId, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = vm.messages.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
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

    /// Cached cell dimensions for the monospace font we render in. Measured
    /// from NSFont rather than guessed — magic numbers (7.2, 16) were off
    /// enough that tmux's pane width didn't match Pager's display width
    /// and lines wrapped a few cols early or late.
    ///
    /// Computed once per process: font metrics don't change at runtime.
    private static let cellSize: (width: CGFloat, height: CGFloat) = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Mono width: every glyph has the same advance, so "M" is
        // representative. Using NSAttributedString.size() picks up the
        // layout-system width that SwiftUI Text actually uses.
        let attrs = [NSAttributedString.Key.font: font]
        let width = ("M" as NSString).size(withAttributes: attrs).width
        // SwiftUI Text spacing is ascender + |descender| + leading.
        let height = font.ascender + abs(font.descender) + font.leading
        return (width, height)
    }()

    /// Translate pane pixel size into tmux cols/rows and fire a debounced
    /// CTAClient.resizeTopic.
    private func scheduleResize(width: CGFloat, height: CGFloat) {
        guard let thread = vm.focusedThreadId else { return }
        // System rows (poller log etc.) don't get resized — they're shared
        // infrastructure sessions, not user-owned topics, and forcing them
        // to track Pager's window width would interfere with anyone else
        // observing them via `tmux attach -t poller` or similar.
        if thread == WatchLiveViewModel.pollerThreadId { return }
        // Padding from the 10pt padding inside the ScrollView + scroll bar
        // gutter. The constants here account for the actual SwiftUI chrome
        // around the text view: 10pt of padding on both horizontal edges
        // plus ~16pt for the scroll bar.
        let usableW = max(width - 36, 100)
        let usableH = max(height - 20, 100)
        let cell = Self.cellSize
        let cols = Int(usableW / cell.width)
        let rows = Int(usableH / cell.height)

        resizeTask?.cancel()
        resizeTask = Task.detached {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            CTAClient.resizeTopic(thread: thread, cols: cols, rows: rows)
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
        // System rows attach to their bare session name (poller, watchdog),
        // topic rows use the topic-<id> prefix that topic-wrapper.sh creates.
        let session = id == WatchLiveViewModel.pollerThreadId ? "poller" : "topic-\(id)"
        let result = TerminalLauncher.openTmux(session: session)
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
