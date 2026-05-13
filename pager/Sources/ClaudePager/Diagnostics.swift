import Foundation

/// End-to-end diagnostic: walks the bot pipeline from local config → Telegram
/// API round-trip → local runtime processes, and reports per-step pass/fail.
///
/// Each step explains *what* it checks and (on failure) *what to do*, so the
/// user can act on the result without context-switching to the README.
enum Diagnostics {
    struct Step: Equatable {
        let label: String
        let ok: Bool
        let detail: String
    }

    /// Pipeline order is intentional: read config → contact Telegram → check
    /// the local runtime. Each later step assumes the earlier ones passed; we
    /// still report all of them so the user sees the full picture, but skipped
    /// steps say so explicitly rather than masquerading as failures.
    static func run() async -> [Step] {
        var out: [Step] = []

        // 1. Token present in .env.
        let token = readToken()
        if let t = token, !t.isEmpty {
            out.append(.init(
                label: "Bot token configured",
                ok: true,
                detail: maskToken(t)
            ))
        } else {
            out.append(.init(
                label: "Bot token configured",
                ok: false,
                detail: "Set the token in Settings → Telegram bot."
            ))
        }

        // 2. Token accepted by Telegram (getMe round-trip). Validates both
        //    the credential and our outbound network path.
        if let t = token, !t.isEmpty {
            let r = await verifyToken(t)
            out.append(.init(
                label: "Telegram accepts token (getMe)",
                ok: r.ok,
                detail: r.detail
            ))
        } else {
            out.append(.init(
                label: "Telegram accepts token (getMe)",
                ok: false,
                detail: "skipped — no token"
            ))
        }

        // 3. Recipient configured.
        let chatID = readFirstAllowedID()
        if let cid = chatID {
            out.append(.init(
                label: "Allowed user configured",
                ok: true,
                detail: "chat_id=\(cid)"
            ))
        } else {
            out.append(.init(
                label: "Allowed user configured",
                ok: false,
                detail: "Add a Telegram user ID in Settings → Allowed users."
            ))
        }

        // 4. Outbound delivery — bot → user. Exercises the full send path.
        if let t = token, !t.isEmpty, let cid = chatID {
            let r = await sendTest(token: t, chatID: cid)
            out.append(.init(
                label: "Test message delivered",
                ok: r.ok,
                detail: r.detail
            ))
        } else {
            out.append(.init(
                label: "Test message delivered",
                ok: false,
                detail: "skipped — missing token or recipient"
            ))
        }

        // 5-8. Local runtime — reuses the same sampler the menu bar status
        //      relies on, so the diagnostic agrees with the icon's verdict.
        let s = StatusMonitor.sample()
        out.append(.init(
            label: "LaunchAgent loaded",
            ok: s.launchAgentLoaded,
            detail: s.launchAgentLoaded ? "com.claude-agent" : "Run install.sh again."
        ))
        out.append(.init(
            label: "claude process running",
            ok: s.claudePid != nil,
            detail: s.claudePid.map { "PID \($0)\(s.claudeMemMB.map { " (\($0) MB)" } ?? "")" }
                ?? "Use 'Restart bot' from the menu."
        ))
        out.append(.init(
            label: "MCP plugin (bun) alive",
            ok: s.telegramMcpAlive,
            detail: s.telegramMcpAlive
                ? "bun server.ts running"
                : "Watchdog will restart claude in <30s if it stays missing."
        ))
        out.append(.init(
            label: "tmux sessions: claude + watchdog",
            ok: s.tmuxClaudeAlive && s.tmuxWatchdogAlive,
            detail: "claude=\(mark(s.tmuxClaudeAlive)) watchdog=\(mark(s.tmuxWatchdogAlive))"
        ))

        return out
    }

    /// Multi-line monospaced report suitable for an NSAlert informativeText.
    /// Aligns labels in a column so users can scan pass/fail at a glance.
    static func formatReport(_ steps: [Step]) -> String {
        let labelWidth = steps.map { $0.label.count }.max() ?? 0
        return steps.map { step in
            let icon = step.ok ? "✓" : "✗"
            let padded = step.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            return "\(icon) \(padded)   \(step.detail)"
        }.joined(separator: "\n")
    }

    // MARK: - Network helpers

    private struct CheckResult {
        let ok: Bool
        let detail: String
    }

    private static func verifyToken(_ token: String) async -> CheckResult {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getMe") else {
            return CheckResult(ok: false, detail: "bad URL")
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return CheckResult(ok: false, detail: "no HTTP response")
            }
            if http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let username = result["username"] as? String {
                return CheckResult(ok: true, detail: "@\(username)")
            }
            let raw = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
            return CheckResult(ok: false, detail: "HTTP \(http.statusCode): \(raw)")
        } catch {
            return CheckResult(ok: false, detail: "\(error.localizedDescription)")
        }
    }

    private static func sendTest(token: String, chatID: String) async -> CheckResult {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            return CheckResult(ok: false, detail: "bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "chat_id": chatID,
            "text": "🧪 Claude Pager diagnostic — full pipeline check.",
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return CheckResult(ok: false, detail: "no HTTP response")
            }
            if http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let messageID = result["message_id"] as? Int {
                return CheckResult(ok: true, detail: "message_id=\(messageID)")
            }
            let raw = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
            return CheckResult(ok: false, detail: "HTTP \(http.statusCode): \(raw)")
        } catch {
            return CheckResult(ok: false, detail: "\(error.localizedDescription)")
        }
    }

    // MARK: - File helpers. Read the same canonical paths TelegramConfig
    // writes to; kept here so Diagnostics has no dependency on the UI layer.

    private static func readToken() -> String? {
        let path = ("~/.claude/channels/telegram/.env" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in text.components(separatedBy: "\n") {
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

    private static func readFirstAllowedID() -> String? {
        let path = ("~/.claude/channels/telegram/access.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let list = json["allowFrom"] as? [String], let first = list.first { return first }
        if let list = json["allowFrom"] as? [Int], let first = list.first { return String(first) }
        return nil
    }

    /// Mask a Telegram token for display. Telegram tokens are `<id>:<secret>`;
    /// we keep the id (it's not a secret on its own) and the last 4 chars so
    /// the user can verify they're looking at the right token.
    static func maskToken(_ token: String) -> String {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return "(invalid format)" }
        let id = String(parts[0])
        let secret = String(parts[1])
        let tail = secret.suffix(4)
        return "\(id):****\(tail)"
    }

    private static func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
}
