import XCTest
@testable import ClaudePager

@MainActor
final class WatchLiveViewModelTests: XCTestCase {

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
        let vm = WatchLiveViewModel(
            mountsProvider: { mounts },
            captureProvider: { captures[$0] ?? .error("missing key") }
        )

        await vm.refreshSidebar()

        XCTAssertEqual(vm.rows.count, 3)
        XCTAssertEqual(vm.rows[0].threadId, "42")
        XCTAssertEqual(vm.rows[0].label, "IronFlow")             // topic_name preferred
        XCTAssertEqual(vm.rows[0].preview, "fresh line")
        XCTAssertEqual(vm.rows[1].label, "topic-7")              // no topic + no label → fallback
        XCTAssertEqual(vm.rows[1].preview, "only one line")
        XCTAssertEqual(vm.rows[2].activity, .dead)               // sessionDead
        XCTAssertEqual(vm.rows[2].preview, "")
    }

    func test_refreshSidebar_marksLiveWhenPreviewChanges() async {
        let mounts = [makeMount(thread: 42, label: nil, topic: "Plans")]
        var content = "first line"
        let vm = WatchLiveViewModel(
            mountsProvider: { mounts },
            captureProvider: { _ in .ok(content) }
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
        let vm = WatchLiveViewModel(
            mountsProvider: { mounts },
            captureProvider: { id in
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
        let vm = WatchLiveViewModel(
            mountsProvider: { mounts },
            captureProvider: { _ in .ok("stable") }
        )
        await vm.refreshSidebar()
        vm.focus(thread: "7")
        XCTAssertEqual(vm.focusedThreadId, "7")

        // Drop #7 from the mounts list — sidebar refresh should shift focus.
        mounts = [makeMount(thread: 8, label: nil, topic: "B")]
        await vm.refreshSidebar()

        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.focusedThreadId, "8")
    }

    func test_lastNonEmptyLine_skipsTrailingBlanks() {
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine("a\nb\nc"), "c")
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine("a\nb\n\n   \n"), "b")
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine(""), "")
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine("\n\n"), "")
        XCTAssertEqual(WatchLiveViewModel.lastNonEmptyLine("single"), "single")
    }

    func test_refreshPane_setsLiveOnOk() async {
        let vm = WatchLiveViewModel(
            mountsProvider: { [self.makeMount(thread: 42, label: nil, topic: "T")] },
            captureProvider: { _ in .ok("pane content here") }
        )
        await vm.refreshSidebar()    // sets focus to 42
        await vm.refreshPane()

        guard case let .live(content) = vm.paneStatus else {
            return XCTFail("expected .live, got \(vm.paneStatus)")
        }
        XCTAssertTrue(content.contains("pane content"))
    }

    func test_refreshPane_setsSessionDead() async {
        let vm = WatchLiveViewModel(
            mountsProvider: { [self.makeMount(thread: 42, label: nil, topic: "T")] },
            captureProvider: { _ in .sessionDead(stderr: "topic-42 not alive") }
        )
        await vm.refreshSidebar()
        await vm.refreshPane()

        XCTAssertEqual(vm.paneStatus, .sessionDead(stderr: "topic-42 not alive"))
    }

    func test_focus_clearsPaneStatusOnSwitch() async {
        let mounts = [
            makeMount(thread: 7, label: nil, topic: "A"),
            makeMount(thread: 8, label: nil, topic: "B"),
        ]
        let vm = WatchLiveViewModel(
            mountsProvider: { mounts },
            captureProvider: { _ in .ok("any") }
        )
        await vm.refreshSidebar()
        await vm.refreshPane()
        guard case .live = vm.paneStatus else { return XCTFail("setup precondition") }

        vm.focus(thread: "8")
        XCTAssertEqual(vm.paneStatus, .unknown,
                       "switching focus clears stale content until next refresh")
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
}
