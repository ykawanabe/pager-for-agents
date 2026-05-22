import SwiftUI

/// Reads + writes the canonical Telegram channel config files:
/// - ~/.claude/channels/telegram/.env       (TELEGRAM_BOT_TOKEN=...)
/// - ~/.claude/channels/telegram/access.json (allowlist policy)
final class TelegramConfig: ObservableObject {
    @Published var token: String = ""
    /// Emoji the bot reacts with on every inbound message so the user has a
    /// visible "received, processing" signal. Empty string = no reaction.
    /// Telegram only accepts a fixed whitelist of free-bot reaction emojis;
    /// invalid values are silently dropped by the plugin (`server.ts:946`).
    @Published var ackReaction: String = ""
    @Published var saveError: String? = nil
    // Note: `allowFrom` / `dmPolicy` are no longer surfaced by Pager. In
    // MULTI_TOPIC mode the poller only honors paired.json's `user_id` — the
    // access.json allowlist is dead in that path. Single-source-of-truth for
    // "who can drive this bot" is the paired user. Removed UI 2026-05-16.

    let envPath: String
    let accessPath: String
    private var debounceTask: Task<Void, Never>?

    /// Paths default to the user's `~/.claude/channels/telegram/` directory
    /// in production. Tests pass tmp paths to verify the read/write logic
    /// without touching the real config.
    init(
        envPath: String = ("~/.claude/channels/telegram/.env" as NSString).expandingTildeInPath,
        accessPath: String = ("~/.claude/channels/telegram/access.json" as NSString).expandingTildeInPath
    ) {
        self.envPath = envPath
        self.accessPath = accessPath
        load()
    }

    func load() {
        token = readToken() ?? ""
        ackReaction = readAckReaction()
    }

    /// Debounced auto-save — used for typed fields like the token so we don't
    /// hit the disk on every keystroke. Allowlist add/remove calls `save()`
    /// directly since those are discrete user actions.
    func scheduleAutoSave() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveError = nil
        do {
            try writeEnv()
            try writeAccess()
        } catch {
            saveError = String(describing: error)
        }
    }

    private func readToken() -> String? {
        guard let envText = try? String(contentsOfFile: envPath, encoding: .utf8) else { return nil }
        for raw in envText.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TELEGRAM_BOT_TOKEN=") else { continue }
            var value = String(line.dropFirst("TELEGRAM_BOT_TOKEN=".count))
            if value.hasPrefix("\"") && value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    private func readAckReaction() -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: accessPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        return (json["ackReaction"] as? String) ?? ""
    }

    private func writeEnv() throws {
        var lines: [String] = []
        var replaced = false
        if let existing = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in existing.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("TELEGRAM_BOT_TOKEN=") {
                    lines.append("TELEGRAM_BOT_TOKEN=\(token)")
                    replaced = true
                } else {
                    lines.append(String(line))
                }
            }
        }
        if !replaced { lines.append("TELEGRAM_BOT_TOKEN=\(token)") }

        let dir = (envPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(toFile: envPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envPath)
    }

    private func writeAccess() throws {
        var dict: [String: Any]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: accessPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = json
        } else {
            dict = ["groups": [:], "pending": [:]]
        }
        // We no longer touch `dmPolicy` / `allowFrom` here — the poller only
        // honors paired.json's `user_id` in MULTI_TOPIC mode, so writing the
        // allowlist from Pager would give users a misleading sense of access
        // control. Leave whatever's in access.json alone.
        // Empty string → remove the key entirely so the plugin falls back to
        // its default (no reaction). Storing "" would still be falsy in JS
        // but explicit omission keeps the file clean.
        let ack = ackReaction.trimmingCharacters(in: .whitespaces)
        if ack.isEmpty {
            dict.removeValue(forKey: "ackReaction")
        } else {
            dict["ackReaction"] = ack
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: accessPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accessPath)
    }
}

/// Default emoji written to access.json when the user flips the reaction
/// toggle on. Picked for the "I received your message" use case — eyes reads
/// as "seen" and is in Telegram's free-bot reaction whitelist. Users who
/// want a different emoji can edit access.json directly; the toggle here
/// only flips between this default and off.
let kDefaultAckEmoji = "👀"

struct SettingsView: View {
    @StateObject private var config = TelegramConfig()
    @ObservedObject var caffeinate: CaffeinateController
    @ObservedObject var monitor: StatusMonitor

    var body: some View {
        TabView {
            // App-level (Mac side): launchd, sleep prevention, Quit behavior.
            // No Telegram concepts here so users have a clear place to look
            // for "macOS app preferences" vs "bot configuration".
            PagerTab(caffeinate: caffeinate, monitor: monitor)
                .tabItem { Label("Pager", systemImage: "macbook") }

            // Bot identity + access: token, allowlist, ack reaction. Everything
            // that ends up in ~/.claude/channels/telegram/{env,access.json}.
            TelegramTab(config: config)
                .tabItem { Label("Telegram", systemImage: "paperplane") }

            PairingTab()
                .tabItem { Label("Pairing", systemImage: "link") }

            MountsTab()
                .tabItem { Label("Projects", systemImage: "folder.badge.gearshape") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 600)
    }
}

// MARK: - Pager tab (Mac app-level prefs)

private struct PagerTab: View {
    @ObservedObject var caffeinate: CaffeinateController
    @ObservedObject var monitor: StatusMonitor
    @AppStorage("stopBotOnQuit") private var stopBotOnQuit = true
    @AppStorage("autoStartAtLogin") private var autoStartAtLogin = true
    @AppStorage("caffeinateEnabled") private var caffeinateEnabled = false
    @AppStorage("caffeinateOnlyOnAC") private var caffeinateOnlyOnAC = true

    // Idle-daemon eviction is agent state (settings.json via cta), not a Mac
    // app pref — so it's @State loaded from cta, not @AppStorage. 0 = off.
    @State private var idleEvictMinutes: Int = 0
    private let idleEvictPresets = [15, 30, 60, 120]
    private let defaultIdleEvictMinutes = 30

    var body: some View {
        Form {
            Section {
                Toggle("Start Pager at login", isOn: $autoStartAtLogin)
                    .onChange(of: autoStartAtLogin) { _, on in
                        AgentControl.setAutoStartAtLogin(on)
                    }
                Toggle("Stop the bot when Pager quits", isOn: $stopBotOnQuit)
            } header: {
                Text("Launch behavior")
            } footer: {
                Text("With \"Start at login\" off, open Pager yourself each time. \"Stop the bot when Pager quits\" also shuts the bot down on ⌘Q, so it isn't left running in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep Mac awake while Pager is running", isOn: Binding(
                    get: { caffeinateEnabled },
                    set: { on in
                        caffeinateEnabled = on
                        caffeinate.configure(enabled: caffeinateEnabled, onlyOnAC: caffeinateOnlyOnAC)
                    }
                ))
                Toggle("Only when plugged in (recommended)", isOn: Binding(
                    get: { caffeinateOnlyOnAC },
                    set: { on in
                        caffeinateOnlyOnAC = on
                        caffeinate.configure(enabled: caffeinateEnabled, onlyOnAC: caffeinateOnlyOnAC)
                    }
                ))
                .disabled(!caffeinateEnabled)
                LabeledContent("Current state") {
                    Text(sleepStateLabel)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Sleep prevention")
            } footer: {
                Text("Keeps the Mac awake while Pager runs so the bot stays connected to Telegram. With \"Only when plugged in\" on, the Mac sleeps normally on battery to save power.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Reset long idle conversations (saves key context first)", isOn: Binding(
                    get: { idleEvictMinutes > 0 },
                    set: { on in setIdleEvict(on ? defaultIdleEvictMinutes : 0) }
                ))
                if idleEvictMinutes > 0 {
                    Picker("After idle for", selection: Binding(
                        get: { idleEvictMinutes },
                        set: { setIdleEvict($0) }
                    )) {
                        ForEach(idleEvictPresets, id: \.self) { m in
                            Text(idleEvictLabel(m)).tag(m)
                        }
                        // Reflect a custom value set via `cta config idle-evict`
                        // so the menu shows reality instead of going blank.
                        if !idleEvictPresets.contains(idleEvictMinutes) {
                            Text(idleEvictLabel(idleEvictMinutes)).tag(idleEvictMinutes)
                        }
                    }
                }
            } header: {
                Text("Idle sessions")
            } footer: {
                Text("When a topic stays quiet this long, its Claude session closes to free memory — your next message resumes the same conversation after a short delay. If the conversation has grown large, it's also reset to a fresh session so replies stay fast and cheap; the bot saves the important context to its memory first, so it doesn't forget what matters. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadIdleEvict() }
    }

    /// Load the current idle-eviction threshold from settings.json (off main).
    private func reloadIdleEvict() {
        DispatchQueue.global(qos: .userInitiated).async {
            let m = CTAClient.idleEvictMinutes()
            DispatchQueue.main.async { idleEvictMinutes = m }
        }
    }

    /// Persist a new threshold via `cta config idle-evict` (off main). Updates
    /// local state immediately for a responsive toggle; the poller catches up
    /// within a poll loop. On failure, re-read so the UI reflects reality.
    private func setIdleEvict(_ minutes: Int) {
        idleEvictMinutes = minutes
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try CTAClient.setIdleEvict(minutes: minutes)
            } catch {
                let actual = CTAClient.idleEvictMinutes()
                DispatchQueue.main.async { idleEvictMinutes = actual }
            }
        }
    }

    private func idleEvictLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let h = minutes / 60
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        return "\(minutes) min"
    }

    /// Same three-state model as the menu label, written for the longer
    /// Settings line. "Active" comes from cta's reported state (agent owns
    /// the subprocess), not from our local intent — so a stale or failed
    /// cta call shows up honestly here.
    private var sleepStateLabel: String {
        if !caffeinateEnabled { return "Off" }
        if monitor.status.caffeinateAlive { return "Active — Mac will not idle-sleep" }
        if caffeinateOnlyOnAC && !caffeinate.onACPower {
            return "Paused — on battery, idle sleep allowed"
        }
        return "Idle"   // toggle on but cta didn't (yet) start — usually transient
    }
}

// MARK: - Telegram tab (bot identity + access)

private struct TelegramTab: View {
    @ObservedObject var config: TelegramConfig

    var body: some View {
        Form {
            Section {
                LabeledContent("Bot token") {
                    SecureField("from @BotFather", text: $config.token)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: config.token) { _, _ in config.scheduleAutoSave() }
                }
            } header: {
                Text("Bot identity")
            } footer: {
                Text("Get a bot token from @BotFather. Stored at ~/.claude/channels/telegram/.env (mode 600). Changes apply when the bot restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Acknowledge received messages", isOn: Binding(
                    get: { !config.ackReaction.isEmpty },
                    set: { on in
                        config.ackReaction = on ? kDefaultAckEmoji : ""
                        config.save()
                    }
                ))
            } header: {
                Text("Message reactions")
            } footer: {
                if let err = config.saveError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Reacts to every inbound message so you know the bot received it. To customize which emoji is used, edit access.json directly — Telegram only accepts its fixed whitelist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Authorized user") {
                    Text("Set when you /pair")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Access")
            } footer: {
                Text("The bot only responds to the account you paired with (see the Pairing tab). To hand control to another account, unpair and pair again from that account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Pairing tab

/// Read-mostly view of the current paired chat + buttons for the host-side
/// pairing flow (pair-code, unpair). The actual /pair <code> message is sent
/// from Telegram by the user; this tab exists so the operator can see at a
/// glance which chat owns the bot and copy the code without dropping to a
/// terminal.
private struct PairingTab: View {
    @State private var paired: CTAClient.PairedStateJSON? = nil
    @State private var code: String = ""
    @State private var status: String? = nil
    @State private var statusIsError: Bool = false
    @State private var refreshTimer: Timer? = nil

    var body: some View {
        Form {
            Section {
                if let p = paired {
                    LabeledContent("Chat ID") { Text(String(p.chatId)).monospacedDigit() }
                    LabeledContent("User ID") { Text(String(p.userId)).monospacedDigit() }
                    LabeledContent("Paired at") { Text(p.pairedAt).foregroundStyle(.secondary).font(.caption) }
                    Button("Unpair (clears mounts)", role: .destructive) {
                        runAsync { _ = try CTAClient.unpair(keepMounts: false); reload() }
                    }
                    Button("Unpair (keep mounts)") {
                        runAsync { _ = try CTAClient.unpair(keepMounts: true); reload() }
                    }
                } else {
                    LabeledContent("Status") {
                        Label("Not paired", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Current pairing")
            } footer: {
                Text("Switching chats: from the paired user account, send `/pair` (no code needed) in the chat you want to claim. The bot moves there instantly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Code") {
                    HStack {
                        Text(code.isEmpty ? "—" : code)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            status = "Code copied to clipboard"; statusIsError = false
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .disabled(code.isEmpty)
                            .help("Copy code")
                    }
                }
                HStack {
                    Button("Show current code") {
                        runAsync { code = try CTAClient.pairCode(reset: false) }
                    }
                    Button("Regenerate") {
                        runAsync { code = try CTAClient.pairCode(reset: true) }
                    }
                }
            } header: {
                Text("Pairing code")
            } footer: {
                Text("First-time pairing: run nothing here — just add the bot to a chat and it'll tell you to send `/pair YOUR-CODE` back. The code persists until consumed by a successful pair.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let s = status {
                Section {
                    Label(s, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? .red : .green)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
            // Auto-refresh paired state so external changes (cta pair / unpair
            // from terminal, /pair from Telegram) reflect without manual reload.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in reload() }
        }
        .onDisappear { refreshTimer?.invalidate(); refreshTimer = nil }
    }

    private func reload() {
        paired = CTAClient.pairedState()
    }

    /// Tiny helper: run a throwing closure off the main thread, surface result
    /// in the `status` label. Swift-Concurrency-light because the actions are
    /// snappy and we'd rather show errors inline than crash on threadingbugs.
    private func runAsync(_ block: @escaping () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try block()
                DispatchQueue.main.async { status = nil; reload() }
            } catch {
                DispatchQueue.main.async {
                    status = String(describing: error)
                    statusIsError = true
                }
            }
        }
    }
}

// MARK: - Mounts tab

/// Per-topic project bindings. Each mount maps a Telegram thread_id (forum
/// topic / DM root / wildcard) to a Mac directory; the agent spawns one
/// `topic-<id>` claude session per mount. Wildcard "*" mounts get auto-spawned
/// the first time a thread without a specific mount sees traffic.
private struct MountsTab: View {
    @State private var mounts: [CTAClient.MountJSON] = []
    // Cached inputs for the picker, refreshed on the reload timer. Computing
    // these inside a render-time `var` (the old design) hit disk on every
    // SwiftUI render + every 3s tick, which churned the list and made the
    // picker feel unstable. Caching in @State keeps render pure.
    @State private var knownTopics: [(threadId: Int, name: String)] = []
    @State private var isGroup: Bool = false
    @State private var loadError: String? = nil
    @State private var newThreadId: String = ""
    @State private var newPath: String = ""
    @State private var newLabel: String = ""
    @State private var refreshTimer: Timer? = nil
    @State private var actionError: String? = nil
    @State private var showHelp: Bool = false

    /// Picker selection. The custom sentinel (MountsPresentation.customSentinel)
    /// swaps the dropdown for a free-text field — covers topics the bot hasn't
    /// observed yet (Telegram can't enumerate topics created before it joined).
    @State private var threadSelection: String = ""

    /// Picker options, derived purely from cached @State (no disk I/O at render).
    private var threadOptions: [MountsPresentation.ThreadOption] {
        MountsPresentation.threadOptions(
            mountedIds: Set(mounts.map { $0.threadId.stringValue }),
            knownTopics: knownTopics,
            isGroup: isGroup
        )
    }
    private var effectiveNewThreadId: String {
        threadSelection == MountsPresentation.customSentinel || threadSelection.isEmpty
            ? newThreadId.trimmingCharacters(in: .whitespaces)
            : threadSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // What this screen is for, in one plain sentence.
                Section {
                    Text("Map each Telegram topic to the Mac folder it works in.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Current bindings, each shown as `Topic → Folder`.
                Section {
                    if mounts.isEmpty {
                        Label("No projects yet", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mounts) { m in
                            let lbl = MountsPresentation.rowLabel(
                                threadId: m.threadId, topicName: m.topicName, isGroup: isGroup)
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(lbl.primary)
                                    if let sub = lbl.subtitle {
                                        Text(sub).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Image(systemName: "arrow.right")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(m.path)
                                    .truncationMode(.middle).lineLimit(1)
                                    .foregroundStyle(.secondary).help(m.path)
                                if let l = m.label, !l.isEmpty {
                                    Text(l)
                                        .font(.caption)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(4)
                                }
                                Spacer()
                                Button { remove(thread: m.threadId.stringValue) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Current projects")
                        Spacer()
                        Button { showHelp.toggle() } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("What these mean")
                        .popover(isPresented: $showHelp, arrowEdge: .bottom) { helpPopover }
                    }
                } footer: {
                    if let e = loadError {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    // Stacked vertical layout so each input gets the full row
                    // width (LabeledContent's split squeezes the path + button).
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Topic").font(.subheadline).foregroundStyle(.secondary)
                        Picker("", selection: $threadSelection) {
                            ForEach(threadOptions) { opt in
                                Text(opt.label).tag(opt.value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        if threadSelection == MountsPresentation.customSentinel {
                            TextField("topic id (e.g. 42), dm, or *", text: $newThreadId)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Folder").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("~/projects/foo", text: $newPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button("Choose…") { pickFolder() }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Label (optional)").font(.subheadline).foregroundStyle(.secondary)
                        TextField("e.g. iron-flow", text: $newLabel)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Spacer()
                        Button("Add") { add() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(effectiveNewThreadId.isEmpty
                                      || newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Add a project")
                } footer: {
                    if let e = actionError {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("If the topic you want isn't listed, send one message in it and it'll show up here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            reload()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in reload() }
        }
        .onDisappear { refreshTimer?.invalidate(); refreshTimer = nil }
    }

    /// Glossary popover behind the "?" in the section header — replaces the old
    /// wall of footer text. De-jargons the plain-language labels for anyone who
    /// wants the underlying detail.
    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What these mean").font(.headline)
            Text("**General / DM** — messages with no topic (Telegram sends these without a topic id). Shows as General in a group, DM in a private chat.")
            Text("**Default for new topics (catch-all)** — the folder used by any topic that doesn't have its own binding.")
            Text("**Topic** — a forum topic. Its name appears once the bot has seen it (Telegram can't list topics created before the bot joined, so those stay as numbers until a message arrives).")
        }
        .font(.callout)
        .padding()
        .frame(width: 360)
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try CTAClient.listMounts()
                // Cache the picker inputs here (off-main) so render stays pure
                // and the 3s tick doesn't hit disk on the main thread.
                let topics = CTAClient.knownTopics()
                let group = (CTAClient.pairedState()?.chatId ?? 0) < 0
                DispatchQueue.main.async {
                    mounts = list
                    knownTopics = topics
                    isGroup = group
                    loadError = nil
                    // Selection stability: keep a valid pick across the reload,
                    // default an empty selection to the first option.
                    let opts = threadOptions
                    threadSelection = threadSelection.isEmpty
                        ? (opts.first?.value ?? "")
                        : MountsPresentation.survivingSelection(current: threadSelection, in: opts)
                }
            } catch {
                DispatchQueue.main.async { loadError = String(describing: error) }
            }
        }
    }

    private func add() {
        let thread = effectiveNewThreadId
        let path = (newPath as NSString).expandingTildeInPath
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        actionError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try CTAClient.addMount(thread: thread, path: path, label: label.isEmpty ? nil : label)
                DispatchQueue.main.async {
                    newThreadId = ""; newPath = ""; newLabel = ""
                    threadSelection = ""
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    actionError = String(describing: error)
                }
            }
        }
    }

    private func remove(thread: String) {
        actionError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try CTAClient.removeMount(thread: thread)
                DispatchQueue.main.async { reload() }
            } catch {
                DispatchQueue.main.async { actionError = String(describing: error) }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick the project directory this Telegram thread should bind to"
        if panel.runModal() == .OK, let url = panel.url {
            newPath = url.path
        }
    }
}

private struct AboutTab: View {
    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        return dict?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    private let repoURL = URL(string: "https://github.com/ykawanabe/pager-for-agents/tree/main/pager")!
    private let agentURL = URL(string: "https://github.com/ykawanabe/pager-for-agents")!

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 8)
            Image(systemName: "paperplane.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text("Claude Pager")
                    .font(.title2.weight(.semibold))
                Text("v\(appVersion) (\(buildNumber))")
                    .foregroundStyle(.secondary)
            }

            Text("Menu bar status for the Claude Code Telegram agent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            VStack(spacing: 6) {
                Link("GitHub — Claude Pager", destination: repoURL)
                Link("GitHub — claude-telegram-agent", destination: agentURL)
            }
            .font(.callout)
            .foregroundStyle(.primary)

            Spacer()

            Text("MIT License · © 2026 Yusuke Kawanabe")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
