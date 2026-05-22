import Foundation

/// Pure presentation logic for the Projects (formerly "Mounts") settings tab.
///
/// Extracted from the SwiftUI view so the plain-language labeling, the picker
/// option list, and the selection-stability rule can be unit-tested without
/// driving SwiftUI. The view (`MountsTab`) caches the raw inputs in @State and
/// calls these; nothing here touches disk or AppKit.
enum MountsPresentation {

    /// One choice in the "add a project" thread picker.
    struct ThreadOption: Identifiable, Hashable {
        let value: String   // thread_id string written to mounts.json ("dm", "*", "140", "__custom__")
        let label: String   // plain-language menu text
        var id: String { value }
    }

    /// Sentinel value for "I'll type the topic id myself" — kept distinct from
    /// any real thread_id so the view can swap in a free-text field.
    static let customSentinel = "__custom__"

    /// Plain-language label for a current-project row: a primary line and an
    /// optional grey subtitle. De-jargoned — no raw `*` / `dm` / `thread_id`
    /// tokens as the primary text; the bare numeric id moves to the subtitle.
    static func rowLabel(threadId: CTAClient.MountJSON.ThreadIdValue,
                         topicName: String?,
                         isGroup: Bool) -> (primary: String, subtitle: String?) {
        switch threadId {
        case .string("*"):
            return ("新しいトピックの初期設定",
                    "個別の割り当てがないトピックはここが使われます (catch-all)")
        case .string("dm"):
            // Telegram sends General-topic + DM messages without a topic id, so
            // both share the "dm" sentinel; the label depends on chat type.
            return (isGroup ? "General" : "DM", nil)
        case .string(let s):
            return (s, nil)
        case .number(let n):
            if let name = topicName, !name.isEmpty {
                return (name, "#\(n)")
            }
            return ("トピック \(n)", nil)
        }
    }

    /// Options for the "add a project" thread picker. Excludes already-mounted
    /// threads (no double-binding), leads each known topic with its name, and
    /// always appends a manual escape hatch for topics the bot hasn't observed
    /// yet (Telegram can't enumerate topics created before the bot joined).
    static func threadOptions(mountedIds: Set<String>,
                              knownTopics: [(threadId: Int, name: String)],
                              isGroup: Bool) -> [ThreadOption] {
        var opts: [ThreadOption] = []
        if !mountedIds.contains("dm") {
            opts.append(.init(value: "dm", label: isGroup ? "General" : "DM"))
        }
        for t in knownTopics where !mountedIds.contains(String(t.threadId)) {
            opts.append(.init(value: String(t.threadId), label: "\(t.name) (#\(t.threadId))"))
        }
        if !mountedIds.contains("*") {
            opts.append(.init(value: "*", label: "新しいトピックの初期設定 (catch-all)"))
        }
        opts.append(.init(value: customSentinel, label: "別のトピックを手動で指定…"))
        return opts
    }

    /// Selection-stability rule applied after a background reload recomputes the
    /// option list: keep the user's current pick if it's still valid (or the
    /// manual sentinel, which is always valid); otherwise fall back to the first
    /// available option so the picker never sits on a dead value. This is the
    /// fix for the "unstable picker" symptom — a 3s reload must not yank the
    /// selection out from under the user mid-add.
    static func survivingSelection(current: String, in options: [ThreadOption]) -> String {
        if current == customSentinel { return current }
        if options.contains(where: { $0.value == current }) { return current }
        return options.first?.value ?? current
    }
}
