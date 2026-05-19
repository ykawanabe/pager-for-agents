import XCTest
@testable import ClaudePager

@MainActor
final class WatchLiveViewModelTests: XCTestCase {

    /// Build a test ViewModel that DOESN'T touch UserDefaults or spawn a
    /// real streaming subprocess. Every test wants this; calling the
    /// production init pulls in the default UserDefaults-backed focus
    /// restore and the real `cta watch --follow` spawner, both of which
    /// make tests order-dependent and slow.
    private func makeVM(
        mounts: @escaping WatchLiveViewModel.MountsProvider,
        capture: @escaping WatchLiveViewModel.CaptureProvider,
        streamSpawner: WatchLiveViewModel.StreamSpawner? = nil,
        // Default to a no-op so tests that don't care about JSONL don't
        // accidentally invoke the production provider (which would shell
        // out to `cta list`).
        messages: @escaping WatchLiveViewModel.MessagesProvider = { _ in [] },
        restoredFocus: String? = nil
    ) -> WatchLiveViewModel {
        WatchLiveViewModel(
            mountsProvider: mounts,
            captureProvider: capture,
            streamSpawner: streamSpawner,
            messagesProvider: messages,
            focusRestore: { restoredFocus },
            focusPersist: { _ in }
        )
    }

    func test_refreshSidebar_buildsRowsFromMounts() async {
        let mounts = [
            makeMount(thread: 42, label: "iron-flow", topic: "IronFlow"),
            makeMount(thread: 7, label: nil, topic: nil),
            makeMount(thread: "dm", label: "general", topic: "General"),
        ]
        let captures: [String: CTAClient.WatchResult] = [
            "42": .ok("hello\nfresh line"),
            "7":  .ok("only one line"),
            "dm": .sessionDead(stderr: "topic-dm not alive"),
        ]
        let vm = makeVM(
            mounts: { mounts },
            capture: { captures[$0] ?? .error("missing key") }
        )

        await vm.refreshSidebar()

        // 3 mounts + 1 synthetic Poller row appended at the tail.
        XCTAssertEqual(vm.rows.count, 4)
        XCTAssertEqual(vm.rows[0].threadId, "42")
        XCTAssertEqual(vm.rows[0].label, "IronFlow")             // topic_name preferred
        XCTAssertEqual(vm.rows[0].preview, "fresh line")
        XCTAssertEqual(vm.rows[1].label, "topic-7")              // no topic + no label → fallback
        XCTAssertEqual(vm.rows[1].preview, "only one line")
        XCTAssertEqual(vm.rows[2].activity, .dead)               // sessionDead
        XCTAssertEqual(vm.rows[2].preview, "")
        // Poller row is always last, threadId == "_poller". captureProvider
        // here returns .error for "_poller" (not in our test map) so it
        // shows as dead — pins the contract that the row appears regardless
        // of system-session liveness.
        XCTAssertEqual(vm.rows[3].threadId, WatchLiveViewModel.pollerThreadId)
        XCTAssertEqual(vm.rows[3].label, "Poller log")
    }

    func test_refreshSidebar_marksLiveWhenPreviewChanges() async {
        let mounts = [makeMount(thread: 42, label: nil, topic: "Plans")]
        var content = "first line"
        let vm = makeVM(
            mounts: { mounts },
            capture: { _ in .ok(content) }
        )

        await vm.refreshSidebar()
        XCTAssertEqual(vm.rows.first?.activity, .idle,
                       "first poll has no previous to compare → idle")

        content = "second line"
        await vm.refreshSidebar()
        XCTAssertEqual(vm.rows.first?.activity, .live,
                       "content changed since previous → live")

        await vm.refreshSidebar()
        XCTAssertEqual(vm.rows.first?.activity, .idle,
                       "content stable → back to idle")
    }

    func test_autoFocus_picksMostActive() async {
        let mounts = [
            makeMount(thread: 7, label: nil, topic: "A"),
            makeMount(thread: 8, label: nil, topic: "B"),
        ]
        // B's content changes between polls → B becomes the live row.
        var pollCount = 0
        let vm = makeVM(
            mounts: { mounts },
            capture: { id in
                pollCount += 1
                if id == "8" && pollCount > 2 { return .ok("changed") }
                return .ok("same")
            }
        )

        await vm.refreshSidebar()        // first poll: both idle, focus = 7 (first)
        XCTAssertEqual(vm.focusedThreadId, "7")

        await vm.refreshSidebar()        // second poll: B changes → live
        XCTAssertEqual(vm.rows.first(where: { $0.threadId == "8" })?.activity, .live)
        // Auto-focus only kicks in when current focus is missing — once set, stays.
        XCTAssertEqual(vm.focusedThreadId, "7")
    }

    func test_removedMount_shiftsFocusToSurvivor() async {
        var mounts = [
            makeMount(thread: 7, label: nil, topic: "A"),
            makeMount(thread: 8, label: nil, topic: "B"),
        ]
        let vm = makeVM(
            mounts: { mounts },
            capture: { _ in .ok("stable") }
        )
        await vm.refreshSidebar()
        vm.focus(thread: "7")
        XCTAssertEqual(vm.focusedThreadId, "7")

        // Drop #7 from the mounts list — sidebar refresh should shift focus.
        mounts = [makeMount(thread: 8, label: nil, topic: "B")]
        await vm.refreshSidebar()

        // 1 mount + 1 synthetic Poller row.
        XCTAssertEqual(vm.rows.count, 2)
        XCTAssertEqual(vm.focusedThreadId, "8",
                       "focus shifts to the surviving real mount, not the synthetic Poller row")
    }

    func test_lastNonEmptyLine_skipsTrailingBlanks() {
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine("a\nb\nc"), "c")
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine("a\nb\n\n   \n"), "b")
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine(""), "")
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine("\n\n"), "")
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine("single"), "single")
    }

    func test_refreshPane_setsLiveOnOk() async {
        let vm = makeVM(
            mounts: { [self.makeMount(thread: 42, label: nil, topic: "T")] },
            capture: { _ in .ok("pane content here") }
        )
        await vm.refreshSidebar()    // sets focus to 42
        await vm.refreshPane()

        guard case let .live(content) = vm.paneStatus else {
            return XCTFail("expected .live, got \(vm.paneStatus)")
        }
        XCTAssertTrue(content.contains("pane content"))
    }

    func test_refreshPane_setsSessionDead() async {
        let vm = makeVM(
            mounts: { [self.makeMount(thread: 42, label: nil, topic: "T")] },
            capture: { _ in .sessionDead(stderr: "topic-42 not alive") }
        )
        await vm.refreshSidebar()
        await vm.refreshPane()

        XCTAssertEqual(vm.paneStatus, .sessionDead(stderr: "topic-42 not alive"))
    }

    func test_refreshPane_daemonModeSessionDeadWithMessagesShowsLive() async {
        // Phase 4 daemon mode: `cta watch` returns sessionDead because there
        // IS no per-topic tmux session anymore. But the topic has a JSONL
        // transcript with messages — meaning the daemon is healthy, just
        // idle. The status pill should say "Live", not "Dead".
        let fakeMessages: [JsonlReader.Message] = [
            JsonlReader.Message(
                id: "m1",
                role: .assistant,
                text: "hello",
                toolNames: [],
                timestamp: Date()
            )
        ]
        let vm = makeVM(
            mounts: { [self.makeMount(thread: 42, label: nil, topic: "T")] },
            capture: { _ in .sessionDead(stderr: "topic-42 not alive") },
            messages: { _ in fakeMessages }
        )
        await vm.refreshSidebar()
        vm.focus(thread: "42")
        await vm.refreshMessages()
        await vm.refreshPane()

        // .live (not .sessionDead) — content is the cached pane content
        // (empty in this test since no .ok capture ever happened).
        if case .live = vm.paneStatus {
            // good
        } else {
            XCTFail("expected .live for daemon-mode topic with messages, got \(vm.paneStatus)")
        }
    }

    func test_refreshPane_sessionDeadWithNoMessagesStaysDead() async {
        // True "Dead" — mount exists but the daemon has never produced a
        // turn (no JSONL transcript). User needs to know this topic isn't
        // working. Don't mask it as .live just because we're in daemon mode.
        let vm = makeVM(
            mounts: { [self.makeMount(thread: 99, label: nil, topic: "U")] },
            capture: { _ in .sessionDead(stderr: "topic-99 not alive") },
            messages: { _ in [] }
        )
        await vm.refreshSidebar()
        vm.focus(thread: "99")
        await vm.refreshMessages()
        await vm.refreshPane()

        XCTAssertEqual(vm.paneStatus, .sessionDead(stderr: "topic-99 not alive"))
    }

    func test_focus_restoresCachedContentOnSwitch() async {
        // refreshSidebar populates contentCache for ALL mounts as part of
        // its preview poll (it captures every topic to fill activity dots).
        // Once warmed, focus(thread:) should restore the cached content
        // immediately instead of flashing "Loading…" — that's what
        // contentCache exists for.
        let mounts = [
            makeMount(thread: 7, label: nil, topic: "A"),
            makeMount(thread: 8, label: nil, topic: "B"),
        ]
        let vm = makeVM(
            mounts: { mounts },
            capture: { _ in .ok("cached-payload") }
        )
        await vm.refreshSidebar() // warms contentCache for "7" AND "8"

        vm.focus(thread: "8")
        guard case .live(let c) = vm.paneStatus else {
            return XCTFail("focus(thread:) should restore cached .live, got \(vm.paneStatus)")
        }
        XCTAssertEqual(c, "cached-payload",
                       "switching focus restores the per-thread cached content")
    }

    func test_focus_unknownWhenNoCachedContent() async {
        // First-ever focus on a topic the cache has never seen falls back
        // to .unknown (the Text view shows "Loading…" until refreshPane
        // fills it). Pins the contract that cache-miss is still graceful.
        let vm = makeVM(
            mounts: { [] },
            capture: { _ in .ok("never-seen") }
        )
        vm.focus(thread: "999")
        XCTAssertEqual(vm.paneStatus, .unknown,
                       "fresh focus on uncached thread stays .unknown until refresh")
    }

    // MARK: - Streaming (Phase B.3)

    func test_stream_appendsChunks_setsLive() async {
        let mounts = [makeMount(thread: 42, label: nil, topic: "T")]
        var onContent: ((String) -> Void)?
        let spawner: WatchLiveViewModel.StreamSpawner = { _, content, _ in
            onContent = content
            return { /* cancel no-op */ }
        }
        let vm = makeVM(
            mounts: { mounts },
            capture: { _ in .ok("polled") },
            streamSpawner: spawner
        )
        await vm.refreshSidebar()    // sets focus → attach (pending, no content yet)
        await vm.refreshPane()       // polling fills paneStatus while stream warms up
        // That's the new robustness contract — user never sees a stuck pane
        // even when the stream subprocess starts but tail -F blocks.
        if case .live(let pre) = vm.paneStatus {
            XCTAssertEqual(pre, "polled",
                           "polling should fill while stream is still pending")
        } else {
            return XCTFail("expected polling .live before stream chunks, got \(vm.paneStatus)")
        }

        // Now the stream produces — should take over from polling.
        onContent?("first line\n")
        onContent?("second line\n")
        await Task.yield()

        guard case let .live(content) = vm.paneStatus else {
            return XCTFail("expected .live after chunks, got \(vm.paneStatus)")
        }
        XCTAssertTrue(content.contains("first line"))
        XCTAssertTrue(content.contains("second line"))
    }

    func test_polling_keeps_running_until_stream_produces() async {
        // Defense in depth: stream subprocess starts but tail -F blocks
        // (empty log). User shouldn't be stuck — polling fills paneStatus.
        let mounts = [makeMount(thread: 42, label: nil, topic: "T")]
        let spawner: WatchLiveViewModel.StreamSpawner = { _, _, _ in
            return { /* cancel */ }   // never emits content, never exits
        }
        let vm = makeVM(
            mounts: { mounts },
            capture: { _ in .ok("polled snapshot") },
            streamSpawner: spawner
        )
        await vm.refreshSidebar()
        await vm.refreshPane()
        guard case let .live(content) = vm.paneStatus else {
            return XCTFail("expected polling .live, got \(vm.paneStatus)")
        }
        XCTAssertEqual(content, "polled snapshot")
    }

    func test_stream_exit2_falls_back_to_polling() async {
        let mounts = [makeMount(thread: 42, label: nil, topic: "T")]
        var onExit: ((Int32) -> Void)?
        let spawner: WatchLiveViewModel.StreamSpawner = { _, _, exit in
            onExit = exit
            return { /* cancel */ }
        }
        let vm = makeVM(
            mounts: { mounts },
            capture: { _ in .ok("polled content") },
            streamSpawner: spawner
        )
        await vm.refreshSidebar()    // focus + stream attached
        onExit?(2)                   // stream signals "no log file"
        await Task.yield()

        // Stream is now considered failed for this thread; polling takes
        // over. refreshPane should set .live from the polling provider.
        await vm.refreshPane()
        guard case let .live(content) = vm.paneStatus else {
            return XCTFail("expected polling .live after stream exit 2, got \(vm.paneStatus)")
        }
        XCTAssertEqual(content, "polled content")
    }

    func test_stream_focus_change_kills_old_starts_new() async {
        let mounts = [
            makeMount(thread: 7, label: nil, topic: "A"),
            makeMount(thread: 8, label: nil, topic: "B"),
        ]
        var cancelCount = 0
        var spawnedThreads: [String] = []
        let spawner: WatchLiveViewModel.StreamSpawner = { thread, _, _ in
            spawnedThreads.append(thread)
            return { cancelCount += 1 }
        }
        let vm = makeVM(
            mounts: { mounts },
            capture: { _ in .ok("static") },
            streamSpawner: spawner,
            restoredFocus: nil
        )
        await vm.refreshSidebar()    // focus → 7 → spawn for 7
        XCTAssertEqual(spawnedThreads, ["7"])

        vm.focus(thread: "8")        // should cancel 7's stream + spawn 8
        XCTAssertEqual(cancelCount, 1, "old stream cancelled")
        XCTAssertEqual(spawnedThreads, ["7", "8"], "new stream for 8")
    }

    func test_stream_skipped_when_spawner_nil() async {
        // The default-test path: streamSpawner=nil means streaming is
        // disabled entirely. refreshPane should drive paneStatus via the
        // polling provider.
        let vm = makeVM(
            mounts: { [self.makeMount(thread: 42, label: nil, topic: "T")] },
            capture: { _ in .ok("hello") }
        )
        await vm.refreshSidebar()
        await vm.refreshPane()
        guard case let .live(content) = vm.paneStatus else {
            return XCTFail("expected .live, got \(vm.paneStatus)")
        }
        XCTAssertEqual(content, "hello")
    }

    // MARK: - Helpers

    /// Build a MountJSON via JSON decode (no public memberwise init exists).
    private func makeMount(
        thread: Any,
        label: String?,
        topic: String?
    ) -> CTAClient.MountJSON {
        let threadField: String
        switch thread {
        case let i as Int: threadField = String(i)
        case let s as String: threadField = "\"\(s)\""
        default: fatalError("thread must be Int or String, got \(thread)")
        }
        let labelField  = label.map { "\"\($0)\"" } ?? "null"
        let topicField  = topic.map { "\"\($0)\"" } ?? "null"
        let tmuxSession = (thread is Int) ? "topic-\(thread)" : "topic-\(thread)"

        let json = """
        {
          "thread_id": \(threadField),
          "path": "/tmp/x",
          "label": \(labelField),
          "session_id": null,
          "tmux_session": "\(tmuxSession)",
          "created_at": "2026-05-18T00:00:00Z",
          "topic_name": \(topicField)
        }
        """
        return try! JSONDecoder().decode(
            CTAClient.MountJSON.self,
            from: json.data(using: .utf8)!
        )
    }

    // MARK: - Phase 3: JSONL message refresh

    func test_refreshMessages_populatesFromProvider() async {
        // Provider returns 2 messages keyed off the focused thread. After
        // refreshMessages runs, vm.messages should mirror what the provider
        // returned. focused thread is set via restoredFocus.
        let stubMessages: [JsonlReader.Message] = [
            .init(id: "u1", role: .user,      text: "hi",     toolNames: [],    timestamp: nil),
            .init(id: "a1", role: .assistant, text: "hello",  toolNames: ["Read"], timestamp: nil),
        ]
        let vm = makeVM(
            mounts: { [] },
            capture: { _ in .ok("") },
            messages: { thread in thread == "42" ? stubMessages : [] },
            restoredFocus: "42"
        )

        await vm.refreshMessages()

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].text, "hi")
        XCTAssertEqual(vm.messages[1].toolNames, ["Read"])
    }

    func test_refreshMessages_emptyWhenNoFocus() async {
        let vm = makeVM(
            mounts: { [] },
            capture: { _ in .ok("") },
            messages: { _ in
                XCTFail("provider should not be called when nothing is focused")
                return []
            },
            restoredFocus: nil
        )

        await vm.refreshMessages()

        XCTAssertTrue(vm.messages.isEmpty)
    }

    func test_focusSwitch_clearsStaleMessagesImmediately() async {
        let messagesByThread: [String: [JsonlReader.Message]] = [
            "42": [.init(id: "u1", role: .user, text: "old topic", toolNames: [], timestamp: nil)],
            "7":  [.init(id: "u2", role: .user, text: "new topic", toolNames: [], timestamp: nil)],
        ]
        let vm = makeVM(
            mounts: { [] },
            capture: { _ in .ok("") },
            messages: { thread in messagesByThread[thread] ?? [] },
            restoredFocus: "42"
        )

        await vm.refreshMessages()
        XCTAssertEqual(vm.messages.first?.text, "old topic")

        vm.focus(thread: "7")
        // Synchronous part of focus() clears stale messages so the user
        // doesn't see the previous topic's bubbles flash. Async refresh
        // task then repopulates from the provider.
        XCTAssertTrue(vm.messages.isEmpty,
                      "focus should clear stale messages synchronously")
    }
}
