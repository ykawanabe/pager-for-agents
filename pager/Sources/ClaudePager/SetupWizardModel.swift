import Foundation
import Combine

/// State + file-watch model for the onboarding wizard. Mirrors the bash
/// helpers in `cli/cta` (`_init_step1_token_ready`, etc.) — both wizards
/// derive "which step am I on" from the same on-disk files so they stay
/// in lock-step without a separate progress file. The CLI uses bash
/// predicates; this is the Swift counterpart.
///
/// Source-of-truth files:
///   - ~/.claude/channels/telegram/.env       (Telegram bot token)
///   - ~/.pager/agent.log                     (poller activity, inbound markers)
///   - ~/.pager/paired.json                   (paired chat + user)
///   - ~/.pager/mounts.json                   (wildcard "*" default mount)
///
/// Re-evaluation cadence: poll mtimes via Timer (2s). Cheap — these files
/// are tiny and the wizard is only open briefly during onboarding.
@MainActor
final class SetupWizardModel: ObservableObject {

    enum StepStatus: Equatable {
        case pending
        case done
    }

    struct StepState: Equatable {
        let number: Int
        let title: String
        let status: StepStatus
    }

    @Published private(set) var steps: [StepState] = []
    @Published private(set) var currentStep: Int = 1
    @Published private(set) var botUsername: String?

    /// True once every step is done — the wizard's "complete" screen.
    var isComplete: Bool { steps.allSatisfy { $0.status == .done } }

    private var timer: Timer?
    private let pollIntervalSec: TimeInterval = 2.0

    private let stateDir: URL
    private let pluginEnv: URL

    init(stateDir: URL? = nil, pluginEnvPath: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Honor CTA_STATE_DIR so dev / staging installs work.
        if let override = stateDir {
            self.stateDir = override
        } else if let env = ProcessInfo.processInfo.environment["CTA_STATE_DIR"], !env.isEmpty {
            self.stateDir = URL(fileURLWithPath: env)
        } else {
            self.stateDir = home.appendingPathComponent(".pager")
        }
        self.pluginEnv = pluginEnvPath ?? home
            .appendingPathComponent(".claude/channels/telegram/.env")
        refresh()
    }

    func start() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: pollIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = t
        // Refresh immediately so the UI never shows stale state on open.
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Compute step-state from disk. Idempotent. Called from the timer
    /// + from start(). Exposed for tests.
    func refresh() {
        let s1 = step1TokenReady()
        let s2 = s1   // /setprivacy has no machine signal — treat as done once we have a token
        let s3 = step3InboundSeen()
        let s4 = step4Paired()
        let s5 = step5DefaultMount()

        steps = [
            StepState(number: 1, title: "Bot token verified",        status: s1 ? .done : .pending),
            StepState(number: 2, title: "/setprivacy disabled",      status: s2 ? .done : .pending),
            StepState(number: 3, title: "First inbound received",    status: s3 ? .done : .pending),
            StepState(number: 4, title: "Chat paired",               status: s4 ? .done : .pending),
            StepState(number: 5, title: "Default project dir set",   status: s5 ? .done : .pending),
        ]
        // Current step = first pending; if all done, point past the last.
        currentStep = steps.first(where: { $0.status == .pending })?.number ?? 6
    }

    // MARK: - Step predicates

    /// Bot token present in plugin .env, non-empty, matches Telegram shape.
    /// Doesn't network — the wizard's "Verify" button hits Bot API getMe.
    func step1TokenReady() -> Bool {
        guard let raw = try? String(contentsOf: pluginEnv, encoding: .utf8) else {
            return false
        }
        for line in raw.split(separator: "\n") {
            guard line.hasPrefix("TELEGRAM_BOT_TOKEN=") else { continue }
            let value = line.dropFirst("TELEGRAM_BOT_TOKEN=".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return !value.isEmpty
        }
        return false
    }

    /// True once any inbound message has been routed by the poller. We
    /// scan agent.log for daemon-dispatch markers — both Phase 4
    /// (`daemon[N]`) and legacy (`update N →`) shapes accepted.
    func step3InboundSeen() -> Bool {
        // paired.json existing also implies inbound was seen.
        if step4Paired() { return true }
        let log = stateDir.appendingPathComponent("agent.log")
        guard let raw = try? String(contentsOf: log, encoding: .utf8) else { return false }
        if raw.contains("daemon[") { return true }
        // Legacy shape: "update <id> →" lines exist in pre-Phase-4 installs.
        return raw.range(of: #"update \d+ →"#, options: .regularExpression) != nil
    }

    /// paired.json has a chat_id.
    func step4Paired() -> Bool {
        let file = stateDir.appendingPathComponent("paired.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let id = json["chat_id"] as? Int { return id != 0 }
        if let id = json["chat_id"] as? Int64 { return id != 0 }
        if let s = json["chat_id"] as? String, !s.isEmpty, s != "0" { return true }
        return false
    }

    /// mounts.json has a wildcard ("*") thread_id entry.
    func step5DefaultMount() -> Bool {
        let file = stateDir.appendingPathComponent("mounts.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mounts = json["mounts"] as? [[String: Any]] else {
            return false
        }
        return mounts.contains { ($0["thread_id"] as? String) == "*" }
    }

    /// Verify the current token with Bot API getMe. Updates `botUsername`
    /// on success; returns nil + leaves it stale on failure. Network call;
    /// safe to invoke from a Task off the main actor by the caller.
    func verifyBotToken() async -> String? {
        guard let raw = try? String(contentsOf: pluginEnv, encoding: .utf8) else {
            return nil
        }
        var token = ""
        for line in raw.split(separator: "\n") {
            if line.hasPrefix("TELEGRAM_BOT_TOKEN=") {
                token = String(line.dropFirst("TELEGRAM_BOT_TOKEN=".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                break
            }
        }
        guard !token.isEmpty else { return nil }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getMe") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true,
                  let result = json["result"] as? [String: Any],
                  let username = result["username"] as? String else {
                return nil
            }
            await MainActor.run { self.botUsername = username }
            return username
        } catch {
            return nil
        }
    }
}
