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

    typealias MountsProvider = () async throws -> [CTAClient.MountJSON]
    typealias CaptureProvider = (String) async -> CTAClient.WatchResult
    typealias FocusPersist = (String?) -> Void
    typealias FocusRestore = () -> String?

    private let mountsProvider: MountsProvider
    private let captureProvider: CaptureProvider
    private let persistFocus: FocusPersist
    private var lastPreviewByThread: [String: String] = [:]
    private var sidebarTask: Task<Void, Never>?
    private var paneTask: Task<Void, Never>?

    /// UserDefaults key for the last-selected thread_id (Phase E.3).
    /// Restored on init; persisted whenever focus changes. Survives Pager
    /// restarts so the user doesn't lose their place. Nonisolated so the
    /// default init closures can read it without crossing actor boundaries.
    nonisolated static let lastFocusedKey = "watchLive.lastFocusedThreadId"

    init(
        mountsProvider: @escaping MountsProvider = { try CTAClient.listMounts() },
        // ansi:true preserves escape codes so the View can render colors via
        // ANSIParser. The default lines=200 matches the cta CLI default.
        captureProvider: @escaping CaptureProvider = { CTAClient.watch(thread: $0, lines: 200, ansi: true) },
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
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        sidebarTask?.cancel()
        sidebarTask = nil
        paneTask?.cancel()
        paneTask = nil
    }

    func focus(thread: String) {
        if focusedThreadId != thread {
            focusedThreadId = thread
            paneStatus = .unknown
            persistFocus(thread)
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
                // captureProvider returns content with ANSI codes (ansi:true)
                // so the main pane can color it. Sidebar previews want plain
                // text — strip via ANSIParser to stay consistent with the
                // renderer used by the main pane.
                let plain = ANSIParser.strip(content)
                let last = WatchLiveViewModel.lastNonEmptyLine(plain)
                preview = last
                let previous = lastPreviewByThread[key]
                activity = (previous != nil && previous != last) ? .live : .idle
                lastPreviewByThread[key] = last
            case .sessionDead, .noMount, .error:
                preview = ""
                activity = .dead
            }
            newRows.append(Row(
                threadId: key,
                label: mount.topicName ?? mount.label ?? "topic-\(key)",
                preview: preview,
                activity: activity
            ))
        }

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
        }
    }

    /// Single pane refresh for the currently-focused topic. Public for tests.
    func refreshPane() async {
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
        case .sessionDead(let s): paneStatus = .sessionDead(stderr: s)
        case .noMount(let s): paneStatus = .noMount(stderr: s)
        case .error(let m): paneStatus = .error(m)
        }
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
}
