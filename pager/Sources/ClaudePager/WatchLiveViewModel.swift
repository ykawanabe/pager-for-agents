import Foundation
import SwiftUI

/// View model for the unified Watch-Live window (docs/plans/pager-watch-live.md
/// Phase A.2). Periodically refreshes the sidebar (mounts list + 1-line preview
/// per topic) and the focused-topic pane content. Data providers are injected
/// so tests can drive the model without spawning real `cta` processes.
@MainActor
final class WatchLiveViewModel: ObservableObject {

    struct Row: Identifiable, Equatable {
        let threadId: String       // canonical CLI arg form ("42", "dm", "*")
        let label: String          // display label (topic_name or fallback)
        let preview: String        // last non-empty line of pane; "" if none
        let activity: Activity
        var id: String { threadId }
    }

    /// Activity classification for sidebar dot.
    enum Activity: Equatable {
        case live       // tmux alive, content changed since last refresh
        case idle       // tmux alive, content unchanged
        case dead       // tmux session not running
    }

    /// What the main pane should render.
    enum PaneStatus: Equatable {
        case unknown
        /// tmux is alive but capture is empty — claude is cold-starting,
        /// or the pane just respawned and hasn't produced output yet.
        case starting
        case live(content: String)
        case sessionDead(stderr: String)
        case noMount(stderr: String)
        case error(String)
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var paneStatus: PaneStatus = .unknown
    @Published var focusedThreadId: String?

    /// Phase 3: structured message bubbles parsed from the focused topic's
    /// claude-code JSONL transcript. Replaces the pane snapshot as the
    /// primary content view in stream-json mode (the bot dispatches via
    /// `claude -p` subprocess; the tmux pane is just an idle bash). When
    /// the JSONL isn't available yet (mount has no path, no session UUID,
    /// pre-stream-json install) this stays empty and the view falls back
    /// to the legacy pane content.
    @Published private(set) var messages: [JsonlReader.Message] = []

    /// Per-thread cached content from the last successful capture. Survives
    /// topic switches: when focus moves to thread X, we immediately restore
    /// its cached content into paneStatus so the user doesn't see the
    /// "Loading…" flash before refreshPane runs. Refreshed every time
    /// refreshPane sees .ok for any thread. In-memory only — clears on VM
    /// recreation (Pager restart), which is the expected staleness.
    private var contentCache: [String: String] = [:]

    typealias MountsProvider = () async throws -> [CTAClient.MountJSON]
    typealias CaptureProvider = (String) async -> CTAClient.WatchResult
    typealias FocusPersist = (String?) -> Void
    typealias FocusRestore = () -> String?
    /// Pluggable JSONL provider: given a thread id, return the parsed
    /// message list (or empty when no transcript exists). Default reads
    /// from disk via JsonlReader; tests inject a fixture.
    typealias MessagesProvider = (String) async -> [JsonlReader.Message]

    /// Phase B.3: long-running subprocess that streams pane content for one
    /// topic. Returns a cancel closure, or nil if spawn failed (cta path not
    /// resolvable, etc.). `onContent` / `onExit` are called from arbitrary
    /// threads; the ViewModel bounces back to MainActor via Task.
    typealias StreamSpawner = (
        _ thread: String,
        _ onContent: @escaping @Sendable (String) -> Void,
        _ onExit: @escaping @Sendable (Int32) -> Void
    ) -> (() -> Void)?

    private let mountsProvider: MountsProvider
    private let captureProvider: CaptureProvider
    private let streamSpawner: StreamSpawner?
    private let persistFocus: FocusPersist
    private let messagesProvider: MessagesProvider
    private var messagesTask: Task<Void, Never>?
    private var lastPreviewByThread: [String: String] = [:]
    /// Phase 4 sidebar activity: tracks JSONL mtime per topic so we can flag
    /// .live when the daemon writes new turns. Cheaper + more accurate than
    /// polling `cta watch` (which always returns sessionDead in Phase 4).
    private var lastJsonlMtimeByThread: [String: Date] = [:]
    private var sidebarTask: Task<Void, Never>?
    private var paneTask: Task<Void, Never>?
    private var streamCancel: (() -> Void)?
    /// Thread the current stream subprocess targets. Set on attach,
    /// cleared on teardown / exit. Not enough to gate polling — see
    /// `streamHasContent` for the "stream is actually producing" signal.
    private var streamThread: String?
    /// True once the stream subprocess has delivered at least one chunk.
    /// Polling defers (skips its work) only when this is true; otherwise
    /// polling fills paneStatus while the stream warms up (defense-in-
    /// depth against the empty-log + tail -F blocks forever failure mode).
    private var streamHasContent: Bool = false
    private var streamBuffer: String = ""
    /// Threads that returned exit 2 (no per-topic log) — don't retry
    /// streaming for them; polling takes over. Reset only when the ViewModel
    /// itself is rebuilt (i.e. window reopen) — pessimistic but cheap.
    private var failedStreamThreads: Set<String> = []
    /// Max in-memory stream buffer before we drop the oldest bytes. 256KB ≈
    /// 3000 lines of typical TUI output, plenty for context.
    private static let streamMaxBytes = 256 * 1024

    /// UserDefaults key for the last-selected thread_id (Phase E.3).
    /// Restored on init; persisted whenever focus changes. Survives Pager
    /// restarts so the user doesn't lose their place. Nonisolated so the
    /// default init closures can read it without crossing actor boundaries.
    nonisolated static let lastFocusedKey = "watchLive.lastFocusedThreadId"

    /// Synthetic thread id for the "Poller log" sidebar row. Underscore
    /// prefix keeps it from colliding with any real numeric / dm thread.
    /// captureProvider branches on this to route to the poller tmux session
    /// directly instead of the topic-X mount path. `nonisolated` because the
    /// default messagesProvider (a nonisolated closure) needs to compare
    /// against this constant without crossing actor boundaries.
    nonisolated static let pollerThreadId = "_poller"

    init(
        mountsProvider: @escaping MountsProvider = { try CTAClient.listMounts() },
        // ansi:false → cta watch strips escape codes via tmux capture-pane
        // (default behavior). lines:20 is the SwiftTerm-era minimum: the
        // terminal owns content rendering now, so refreshPane only needs to
        // know if the session is alive, and refreshSidebar only needs the
        // last non-empty line for the preview. Was 500 (full scrollback)
        // back when refreshPane fed the main pane Text view — that's a
        // 25× cost reduction per poll. Combined with the 2s paneTask
        // interval (was 500ms), the overall watch-live polling cost drops
        // by ~100×.
        // Route the synthetic "_poller" thread id (a non-topic system row in
        // the sidebar) to a direct tmux capture against the "poller" session.
        // The regular cta-watch path only resolves mounted topics, so without
        // this branch the Poller row would forever show as session-dead.
        captureProvider: @escaping CaptureProvider = { thread in
            if thread == WatchLiveViewModel.pollerThreadId {
                return CTAClient.watchSystemSession(session: "poller", lines: 200)
            }
            return CTAClient.watch(thread: thread, lines: 200, ansi: false)
        },
        streamSpawner: StreamSpawner? = WatchLiveViewModel.defaultStreamSpawner,
        messagesProvider: @escaping MessagesProvider = WatchLiveViewModel.defaultMessagesProvider,
        focusRestore: FocusRestore = {
            UserDefaults.standard.string(forKey: WatchLiveViewModel.lastFocusedKey)
        },
        focusPersist: @escaping FocusPersist = { id in
            if let id = id {
                UserDefaults.standard.set(id, forKey: WatchLiveViewModel.lastFocusedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: WatchLiveViewModel.lastFocusedKey)
            }
        }
    ) {
        self.mountsProvider = mountsProvider
        self.captureProvider = captureProvider
        self.streamSpawner = streamSpawner
        self.messagesProvider = messagesProvider
        self.persistFocus = focusPersist
        self.focusedThreadId = focusRestore()
    }

    /// Begin periodic refresh of both sidebar (every 5s) and focused pane
    /// (every 500ms). Idempotent — calling twice replaces the previous loops.
    func start() {
        sidebarTask?.cancel()
        sidebarTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSidebar()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        paneTask?.cancel()
        paneTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPane()
                // 2s (was 500ms) — refreshPane only drives the status pill
                // and the terminal-vs-placeholder gate now that SwiftTerm
                // renders content directly. 2s of stale "Live" pill after
                // session death is acceptable; before, polling was content
                // delivery and needed sub-second latency.
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Phase 3: poll the focused topic's JSONL transcript for new
        // user/assistant turns. 2s cadence matches the pane poll — the
        // transcript file appends a few lines per turn and the JSONL is
        // append-only, so re-parsing the whole file is cheap (under 10ms
        // for a 1000-turn session). Streaming via fs-watcher is a future
        // optimization; polling is dead-simple and works across renames.
        messagesTask?.cancel()
        messagesTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMessages()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Try streaming for whatever's focused now (might be restored from
        // UserDefaults — focus() isn't called again on init).
        attachStreamIfPossible()
    }

    func stop() {
        sidebarTask?.cancel()
        sidebarTask = nil
        paneTask?.cancel()
        paneTask = nil
        messagesTask?.cancel()
        messagesTask = nil
        teardownStream()
    }

    func focus(thread: String) {
        if focusedThreadId != thread {
            focusedThreadId = thread
            // Restore cached content immediately so the user doesn't see a
            // "Loading…" flash before refreshPane finishes for the new
            // thread. .unknown only when we've truly never seen this topic.
            if let cached = contentCache[thread] {
                paneStatus = .live(content: cached)
            } else {
                paneStatus = .unknown
            }
            // Clear stale messages so the user doesn't see the previous
            // topic's bubbles while refreshMessages catches up. One JSONL
            // poll cycle (≤2s) repopulates.
            messages = []
            persistFocus(thread)
            attachStreamIfPossible()
            Task { await refreshMessages() } // immediate refill, no 2s wait
        }
    }

    /// Single sidebar refresh. Public for tests and "Refresh" UI affordances.
    func refreshSidebar() async {
        let mounts: [CTAClient.MountJSON]
        do { mounts = try await mountsProvider() }
        catch { return }

        var newRows: [Row] = []
        for mount in mounts {
            // The "*" wildcard mount is a routing fallback for unmounted
            // topics — its tmux session isn't pre-spawned, so it always
            // shows as dead in the sidebar even when nothing's broken.
            // Hide it; user knows their actual topics by name.
            if mount.threadId.stringValue == "*" { continue }
            let key = mount.threadId.stringValue
            let preview: String
            let activity: Activity
            switch await captureProvider(key) {
            case .ok(let content):
                // Legacy capture-pane path. Phase 4 never lands here for
                // topic rows in production (cta watch always returns
                // sessionDead), but tests inject .ok content and this kept
                // the fakes simple. Cache + detect change for activity.
                contentCache[key] = content
                let plain = ANSIParser.strip(content)
                let last = WatchLiveViewModel.lastNonEmptyLine(plain)
                preview = last
                let previous = lastPreviewByThread[key]
                activity = (previous != nil && previous != last) ? .live : .idle
                lastPreviewByThread[key] = last
            case .sessionDead, .noMount, .error:
                // Phase 4: cta watch returns sessionDead for every topic
                // because there's no per-topic tmux session. Fall back to
                // JSONL mtime — that's the daemon's authoritative "did
                // anything happen?" signal.
                (preview, activity) = sidebarActivityForTopic(threadId: key, mountPath: mount.path)
            }
            newRows.append(Row(
                threadId: key,
                label: mount.topicName ?? mount.label ?? "topic-\(key)",
                preview: preview,
                activity: activity
            ))
        }

        // Synthetic "Poller log" row at the tail of the sidebar. Routes to
        // the poller tmux session via captureProvider's _poller branch.
        // Replaces the standalone "Watch poller log" menu item — Watch live
        // is now the single place to see any session, topic or system.
        let pollerKey = WatchLiveViewModel.pollerThreadId
        let pollerPreview: String
        let pollerActivity: Activity
        switch await captureProvider(pollerKey) {
        case .ok(let content):
            contentCache[pollerKey] = content
            let plain = ANSIParser.strip(content)
            let last = WatchLiveViewModel.lastNonEmptyLine(plain)
            pollerPreview = last
            let previous = lastPreviewByThread[pollerKey]
            pollerActivity = (previous != nil && previous != last) ? .live : .idle
            lastPreviewByThread[pollerKey] = last
        case .sessionDead, .noMount, .error:
            pollerPreview = ""
            pollerActivity = .dead
        }
        newRows.append(Row(
            threadId: pollerKey,
            label: "Poller log",
            preview: pollerPreview,
            activity: pollerActivity
        ))

        rows = newRows

        // GC preview history for mounts that disappeared.
        let liveIds = Set(newRows.map(\.threadId))
        lastPreviewByThread = lastPreviewByThread.filter { liveIds.contains($0.key) }

        // Auto-focus the most active row when nothing's focused, or when the
        // previously-focused mount is gone.
        if focusedThreadId == nil || !liveIds.contains(focusedThreadId!) {
            let pick = WatchLiveViewModel.mostActive(newRows)?.threadId
            focusedThreadId = pick
            paneStatus = .unknown
            persistFocus(pick)
            attachStreamIfPossible()
        }
    }

    /// Single pane refresh for the currently-focused topic. Public for tests.
    /// Skipped when a stream is producing content — stream owns paneStatus
    /// updates and polling would race against it. While stream is still
    /// warming up (subprocess started but no chunks yet), polling fills
    /// paneStatus so the user isn't stuck on "unknown"/.starting forever.
    func refreshPane() async {
        if streamThread != nil && streamHasContent { return }
        guard let id = focusedThreadId else {
            paneStatus = .unknown
            return
        }
        switch await captureProvider(id) {
        case .ok(let content):
            // E.1: tmux alive but no output yet → distinct "Starting" state
            // so the pill shows yellow and the pane explains the gap.
            // Stripped check because pure ANSI codes (color escapes with
            // no payload) shouldn't count as content either.
            let plain = ANSIParser.strip(content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paneStatus = plain.isEmpty ? .starting : .live(content: content)
            // Stash the captured content so topic switches can restore it
            // instantly without waiting for a fresh poll. Empty captures
            // also get stashed (empty string) so the next focus(thread:)
            // doesn't think this is a never-seen topic and revert to
            // .unknown / Loading.
            contentCache[id] = content
        case .sessionDead(let s):
            // Phase 4 daemon mode: there's no per-topic tmux session anymore.
            // `cta watch` returns sessionDead for every mounted topic because
            // the daemon lives inside the poller process, not in tmux.
            // Reinterpret for the UI:
            //   - poller-log row: actually missing tmux session → real Dead
            //   - topic w/ transcript: idle daemon, conversation history exists → Live
            //   - topic w/o transcript: daemon hasn't spawned yet (lazy on first msg) → Starting
            // Without this, every topic row's pill would render red "Dead"
            // even though the daemon is healthy on standby.
            if id == WatchLiveViewModel.pollerThreadId {
                paneStatus = .sessionDead(stderr: s)
            } else if !messages.isEmpty {
                let cached = contentCache[id] ?? ""
                paneStatus = .live(content: cached)
            } else {
                paneStatus = .starting
            }
        case .noMount(let s): paneStatus = .noMount(stderr: s)
        case .error(let m): paneStatus = .error(m)
        }
    }

    /// Phase 3 (JSONL view): refresh the message bubble list for the focused
    /// topic. Synthetic rows like "_poller" don't have a transcript — they
    /// keep `messages` empty (the view falls back to pane content for them).
    func refreshMessages() async {
        guard let id = focusedThreadId else {
            messages = []
            return
        }
        let next = await messagesProvider(id)
        // Avoid pointless publishes when content didn't change. Equality is
        // cheap because Message is value-typed and id-stable.
        if next.count != messages.count || next != messages {
            messages = next
        }
    }

    /// Default JSONL provider: resolve the focused topic's project_path +
    /// session UUID from mounts.json / $STATE_DIR/sessions, then read and
    /// parse the JSONL transcript. Synthetic threads (the "_poller" row)
    /// return empty so the JSONL section stays hidden for them.
    nonisolated static let defaultMessagesProvider: MessagesProvider = { threadId in
        if threadId == WatchLiveViewModel.pollerThreadId { return [] }
        // Look up the mount → project path. listMounts is sync I/O but
        // bounded (one file read); call it off-main to keep refreshMessages
        // non-blocking.
        let mounts: [CTAClient.MountJSON]
        do { mounts = try CTAClient.listMounts() } catch { return [] }
        guard let mount = mounts.first(where: { $0.threadId.stringValue == threadId }) else { return [] }
        // Session UUID lives at $STATE_DIR/sessions/<thread_id>. topic-wrapper.sh
        // writes it on first claude launch.
        let sessFile = "\(CTAClient.stateDir)/sessions/\(threadId)"
        guard let uuid = try? String(contentsOfFile: sessFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty
        else { return [] }
        let path = JsonlReader.transcriptPath(projectPath: mount.path, sessionUuid: uuid)
        return JsonlReader.parseTranscript(at: path)
    }

    /// Phase 4 sidebar activity for a topic row. Resolves the topic's
    /// JSONL transcript via session UUID, stats its mtime, and classifies:
    ///   - mtime changed since last poll → .live (daemon just wrote a turn)
    ///   - mtime unchanged → .idle (daemon healthy but quiet)
    ///   - JSONL missing / no session UUID → .idle (daemon never engaged,
    ///     not "dead" — it'll lazy-spawn on the next message)
    /// Preview = last assistant text line from the transcript (truncated).
    /// Returns ("", .idle) when no transcript exists yet.
    private func sidebarActivityForTopic(threadId: String, mountPath: String) -> (String, Activity) {
        let sessFile = "\(CTAClient.stateDir)/sessions/\(threadId)"
        guard let uuid = try? String(contentsOfFile: sessFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty
        else {
            // Daemon has never spawned for this topic (session-id file
            // hasn't been written yet). Show as idle/waiting.
            return ("", .idle)
        }
        let path = JsonlReader.transcriptPath(projectPath: mountPath, sessionUuid: uuid)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
        guard let mtime = attrs?[.modificationDate] as? Date else {
            return ("", .idle)
        }
        let prev = lastJsonlMtimeByThread[threadId]
        let activity: Activity = (prev != nil && prev != mtime) ? .live : .idle
        lastJsonlMtimeByThread[threadId] = mtime

        // Preview: last non-empty assistant turn, single-lined and truncated.
        // Reading the full JSONL every sidebar poll is bounded — sessions are
        // typically <1MB and we do it for ~5-20 rows max.
        let messages = JsonlReader.parseTranscript(at: path)
        let lastText = messages.reversed().first(where: { !$0.text.isEmpty })?.text ?? ""
        let preview = String(lastText.replacingOccurrences(of: "\n", with: " ").prefix(80))
        return (preview, activity)
    }

    // MARK: - Free helpers (static; exposed for testability)

    static func lastNonEmptyLine(_ s: String) -> String {
        for line in s.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed) }
        }
        return ""
    }

    /// Sidebar focus tiebreaker: prefer live > idle > dead. Within a tier,
    /// preserve mount-creation order (the order CTA hands us).
    static func mostActive(_ rows: [Row]) -> Row? {
        rows.first(where: { $0.activity == .live })
            ?? rows.first(where: { $0.activity == .idle })
            ?? rows.first
    }

    // MARK: - Streaming (Phase B.3)

    /// Start a streaming subprocess for the currently-focused topic when
    /// possible. Idempotent — tears down any previous stream first.
    /// Falls through silently when:
    ///   - no streamSpawner is configured (tests pass nil)
    ///   - the focused thread is in failedStreamThreads (exit 2 last time)
    ///   - the spawner returns nil (cta path not resolvable)
    /// In all those cases polling (refreshPane) keeps the pane up to date.
    ///
    /// Importantly, `streamHasContent` flips to true only when the first
    /// chunk actually arrives. Until then, polling continues to fill
    /// paneStatus. Defense-in-depth against the "stream subprocess starts
    /// but tail -F blocks because the log is empty" failure mode (which
    /// the original pipe-pane -O -o bug exposed).
    func attachStreamIfPossible() {
        teardownStream()
        guard let id = focusedThreadId,
              !failedStreamThreads.contains(id),
              let spawner = streamSpawner
        else { return }

        streamThread = id
        streamHasContent = false
        streamBuffer = ""

        streamCancel = spawner(
            id,
            { [weak self] chunk in
                Task { @MainActor [weak self] in
                    self?.handleStreamChunk(chunk, forThread: id)
                }
            },
            { [weak self] code in
                Task { @MainActor [weak self] in
                    self?.streamTerminated(code: code, forThread: id)
                }
            }
        )
        if streamCancel == nil {
            // Spawner failed to launch — drop pending state so polling
            // is the only active path.
            streamThread = nil
        }
    }

    func teardownStream() {
        streamCancel?()
        streamCancel = nil
        streamThread = nil
        streamHasContent = false
        streamBuffer = ""
    }

    /// First-chunk + subsequent-chunk handler. Marks the stream as producing
    /// (streamHasContent = true) on first chunk, which is when polling
    /// defers.
    private func handleStreamChunk(_ chunk: String, forThread thread: String) {
        guard streamThread == thread, focusedThreadId == thread else { return }
        streamHasContent = true
        streamBuffer.append(chunk)
        if streamBuffer.utf8.count > WatchLiveViewModel.streamMaxBytes {
            // Drop oldest bytes to bring back under the cap. Find a safe
            // utf8-boundary index by scanning forward to the next newline
            // (avoids splitting a multi-byte sequence mid-codepoint).
            let target = streamBuffer.utf8.count - WatchLiveViewModel.streamMaxBytes
            var dropped = 0
            var idx = streamBuffer.startIndex
            while dropped < target && idx < streamBuffer.endIndex {
                let c = streamBuffer[idx]
                dropped += c.utf8.count
                idx = streamBuffer.index(after: idx)
                if c == "\n" && dropped >= target { break }
            }
            streamBuffer = String(streamBuffer[idx...])
        }
        paneStatus = .live(content: streamBuffer)
    }

    private func streamTerminated(code: Int32, forThread thread: String) {
        // Ignore if focus moved on — old subprocess exit is irrelevant.
        guard streamThread == thread else { return }
        streamThread = nil
        streamHasContent = false
        streamCancel = nil
        if code == 2 {
            // No per-topic log file yet for this topic — record so future
            // focus() doesn't waste a spawn. Polling picks up via the
            // 500ms refreshPane loop.
            failedStreamThreads.insert(thread)
        }
        // For other exit codes (clean kill on focus change, error, etc.)
        // we just let the polling path take over on the next tick.
    }

    /// Default streaming spawner is DISABLED.
    ///
    /// Why nil: `tmux pipe-pane` writes claude's raw output stream — every
    /// byte claude printed, including cursor-positioning escapes (ESC[H,
    /// ESC[2J), screen clears, and the bytes from in-place TUI updates.
    /// Stripping SGR codes leaves all that movement chaos behind, which
    /// renders as "怪しい" (garbled) text in the WatchLive pane.
    ///
    /// `tmux capture-pane`, by contrast, returns the RENDERED pane content
    /// — what's actually on screen after claude finished updating. That's
    /// what the polling path uses (cta watch without --follow). Clean.
    ///
    /// The streaming infrastructure (typealias + handle code paths + tests)
    /// stays in the codebase; it's still useful for CLI users who want raw
    /// output via `cta watch --follow`, and for a future Pager iteration
    /// that overlays a terminal emulator. For now, polling wins.
    nonisolated static let defaultStreamSpawner: StreamSpawner? = nil
}
