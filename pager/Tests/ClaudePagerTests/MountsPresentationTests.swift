import XCTest
@testable import ClaudePager

/// Part A of the Mounts→Projects redesign: the picker options + row labels are
/// pure functions of (mounts, known topics, chat type), and the add-form
/// selection must survive background reloads. These tests pin the plain-language
/// labeling + the selection-stability rule without driving SwiftUI.
final class MountsPresentationTests: XCTestCase {

    typealias TID = CTAClient.MountJSON.ThreadIdValue

    // ── row labels: plain language, id demoted to subtitle ──────────────────

    func test_rowLabel_wildcard_isPlainLanguage_noRawAsterisk() {
        let r = MountsPresentation.rowLabel(threadId: .string("*"), topicName: nil, isGroup: true)
        XCTAssertFalse(r.primary.contains("*"), "wildcard primary should be plain language, got \(r.primary)")
        XCTAssertNotNil(r.subtitle, "wildcard should explain catch-all in the subtitle")
    }

    func test_rowLabel_dm_groupSaysGeneral() {
        let r = MountsPresentation.rowLabel(threadId: .string("dm"), topicName: nil, isGroup: true)
        XCTAssertTrue(r.primary.contains("General"), "dm in a group should read General, got \(r.primary)")
    }

    func test_rowLabel_dm_privateChatSaysDM() {
        let r = MountsPresentation.rowLabel(threadId: .string("dm"), topicName: nil, isGroup: false)
        XCTAssertTrue(r.primary.uppercased().contains("DM"), "dm in a private chat should read DM, got \(r.primary)")
    }

    func test_rowLabel_numericTopic_nameIsPrimary_idIsSubtitle() {
        let r = MountsPresentation.rowLabel(threadId: .number(140), topicName: "Iron Flow", isGroup: true)
        XCTAssertEqual(r.primary, "Iron Flow")
        XCTAssertEqual(r.subtitle, "#140", "the bare id belongs in the subtitle, not the primary label")
    }

    func test_rowLabel_numericTopic_noName_fallsBackWithoutJargon() {
        let r = MountsPresentation.rowLabel(threadId: .number(140), topicName: nil, isGroup: true)
        XCTAssertFalse(r.primary.contains("thread_id"), "no raw thread_id jargon")
        XCTAssertTrue(r.primary.contains("140"), "should still surface the id when no name is known")
    }

    // ── picker options: exclude already-mounted, keep a manual escape hatch ──

    func test_threadOptions_excludesAlreadyMounted_andOffersManual() {
        let opts = MountsPresentation.threadOptions(
            mountedIds: ["dm"],   // dm already mounted
            knownTopics: [(threadId: 140, name: "Iron Flow")],
            isGroup: true
        )
        let values = opts.map(\.value)
        XCTAssertFalse(values.contains("dm"), "already-mounted dm must not be offered again")
        XCTAssertTrue(values.contains("140"), "unmounted known topic should be offered")
        XCTAssertTrue(values.contains("__custom__"), "manual escape hatch always present")
        let topicOpt = opts.first { $0.value == "140" }
        XCTAssertTrue(topicOpt?.label.hasPrefix("Iron Flow") ?? false,
                      "topic option should lead with its name, got \(topicOpt?.label ?? "nil")")
    }

    // ── selection stability: a background reload must not yank the user's pick ─

    func test_survivingSelection_keepsValidSelectionAcrossReload() {
        let opts = MountsPresentation.threadOptions(
            mountedIds: [], knownTopics: [(threadId: 140, name: "Iron Flow")], isGroup: true)
        XCTAssertEqual(MountsPresentation.survivingSelection(current: "140", in: opts), "140")
    }

    func test_survivingSelection_manualSentinelAlwaysSurvives() {
        let opts = MountsPresentation.threadOptions(mountedIds: [], knownTopics: [], isGroup: false)
        XCTAssertEqual(MountsPresentation.survivingSelection(current: "__custom__", in: opts), "__custom__")
    }

    func test_survivingSelection_vanishedSelectionFallsBackToFirst() {
        // User had 140 selected, then it got mounted elsewhere → no longer an
        // option. Don't leave the picker on a dead value; fall back to first.
        let opts = MountsPresentation.threadOptions(
            mountedIds: ["140"], knownTopics: [(threadId: 140, name: "Iron Flow")], isGroup: true)
        let survivor = MountsPresentation.survivingSelection(current: "140", in: opts)
        XCTAssertNotEqual(survivor, "140", "a vanished selection should not stick")
        XCTAssertEqual(survivor, opts.first?.value, "falls back to the first available option")
    }

    func test_survivingSelection_emptyStaysEmptyWhenNoOptions() {
        XCTAssertEqual(MountsPresentation.survivingSelection(current: "", in: []), "")
    }
}
