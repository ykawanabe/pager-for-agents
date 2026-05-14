import SwiftUI

/// Reads + writes the canonical Telegram channel config files:
/// - ~/.claude/channels/telegram/.env       (TELEGRAM_BOT_TOKEN=...)
/// - ~/.claude/channels/telegram/access.json (allowlist policy)
final class TelegramConfig: ObservableObject {
    @Published var token: String = ""
    @Published var allowedIDs: [String] = []
    /// Emoji the bot reacts with on every inbound message so the user has a
    /// visible "received, processing" signal. Empty string = no reaction.
    /// Telegram only accepts a fixed whitelist of free-bot reaction emojis;
    /// invalid values are silently dropped by the plugin (`server.ts:946`).
    @Published var ackReaction: String = ""
    @Published var saveError: String? = nil

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
        allowedIDs = readAllowlist()
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

    private func readAllowlist() -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: accessPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let list = json["allowFrom"] as? [String] { return list }
        if let list = json["allowFrom"] as? [Int] { return list.map(String.init) }
        return []
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
        let trimmed = allowedIDs.map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
        dict["dmPolicy"] = trimmed.isEmpty ? "open" : "allowlist"
        dict["allowFrom"] = trimmed
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
                .tabItem { Label("Mounts", systemImage: "folder.badge.gearshape") }

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
                Text("With \"Start at login\" off, the Pager won't auto-launch — open this app manually. \"Stop the bot when Pager quits\" cascades a clean Quit (⌘Q) to the companion agent.")
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
                Text("Spawns `caffeinate -i` while Pager is running so the bot keeps polling Telegram. Leaving \"Only when plugged in\" on means battery is preserved when unplugged — the Mac will sleep normally on battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
    @State private var newID: String = ""

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
                Text("Reacts to every inbound message so you know the bot received it. To customize which emoji is used, edit access.json directly — Telegram only accepts its fixed whitelist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if config.allowedIDs.isEmpty {
                    LabeledContent("Status") {
                        Label("No allowlist set", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    ForEach(config.allowedIDs, id: \.self) { id in
                        LabeledContent(id) {
                            Button {
                                config.allowedIDs.removeAll { $0 == id }
                                config.save()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                LabeledContent("Add user") {
                    HStack {
                        TextField("Telegram user ID", text: $newID)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addID)
                        Button("Add", action: addID)
                            .disabled(newID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("Allowed users")
            } footer: {
                if let err = config.saveError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Only these Telegram users can DM the bot. Find your ID with @userinfobot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addID() {
        let trimmed = newID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isNumber }),
              !config.allowedIDs.contains(trimmed) else { return }
        config.allowedIDs.append(trimmed)
        config.save()
        newID = ""
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
    @State private var loadError: String? = nil
    @State private var newThreadId: String = ""
    @State private var newPath: String = ""
    @State private var newLabel: String = ""
    @State private var refreshTimer: Timer? = nil
    @State private var actionError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Table-style list. We use a Form so the styling matches the other
            // tabs; List would feel inconsistent inside a TabView with Form
            // children. Each row is a Section so the remove button can sit
            // inside its own footer for visual separation.
            Form {
                Section {
                    if mounts.isEmpty {
                        LabeledContent("Status") {
                            Label("No mounts yet", systemImage: "tray")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(mounts) { m in
                            LabeledContent(threadLabel(m)) {
                                HStack(spacing: 8) {
                                    Text(m.path)
                                        .truncationMode(.middle)
                                        .lineLimit(1)
                                        .foregroundStyle(.secondary)
                                        .help(m.path)
                                    if let lbl = m.label, !lbl.isEmpty {
                                        Text(lbl)
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.15))
                                            .cornerRadius(4)
                                    }
                                    Button {
                                        remove(thread: m.threadId.stringValue)
                                    } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                        .help("Unmount")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Current mounts")
                } footer: {
                    if let e = loadError {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("`*` = wildcard (catch-all); `dm` = DM / group root; numbers = forum topic IDs. The agent spawns one claude session per mount.")
                            Text("Topic names appear automatically once the bot sees the topic (creation or rename). Telegram's Bot API doesn't expose names retroactively, so topics that existed before the bot joined will show as bare IDs until renamed.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    // Stacked vertical layout — LabeledContent's left-label /
                    // right-content split squeezes the path field + Choose…
                    // button into an unusable column. Vertical stacks give each
                    // input the full row width.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Thread").font(.subheadline).foregroundStyle(.secondary)
                        TextField("dm, *, or topic id (e.g. 42)", text: $newThreadId)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Path").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("~/projects/foo", text: $newPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button("Choose…") { pickFolder() }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Label").font(.subheadline).foregroundStyle(.secondary)
                        TextField("optional, e.g. iron-flow", text: $newLabel)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Spacer()
                        Button("Add mount") { add() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(newThreadId.trimmingCharacters(in: .whitespaces).isEmpty
                                      || newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Add a mount")
                } footer: {
                    if let e = actionError {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("To find a topic id: open the topic in Telegram → tap topic name → the integer in the URL bar is the thread_id. For the bot's DM, use `dm`. For a default that auto-spawns on first message in any new topic, use `*`.")
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

    private func threadLabel(_ m: CTAClient.MountJSON) -> String {
        switch m.threadId {
        case .string("*"): return "* (wildcard)"
        case .string("dm"): return "dm"
        case .string(let s): return s
        case .number(let n):
            // Best-effort name lookup. Only the currently-paired chat's topics
            // are in topics.json (poller scopes them to chat_id/thread_id).
            // If the user is paired to a different group than the one this
            // mount belongs to, the name won't resolve — fall back to bare id.
            if let pairedChat = CTAClient.pairedState()?.chatId,
               let name = CTAClient.topicName(chatId: pairedChat, threadId: n) {
                return "\(name) (#\(n))"
            }
            return "topic \(n)"
        }
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try CTAClient.listMounts()
                DispatchQueue.main.async { mounts = list; loadError = nil }
            } catch {
                DispatchQueue.main.async { loadError = String(describing: error) }
            }
        }
    }

    private func add() {
        let thread = newThreadId.trimmingCharacters(in: .whitespaces)
        let path = (newPath as NSString).expandingTildeInPath
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        actionError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try CTAClient.addMount(thread: thread, path: path, label: label.isEmpty ? nil : label)
                DispatchQueue.main.async {
                    newThreadId = ""; newPath = ""; newLabel = ""
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
