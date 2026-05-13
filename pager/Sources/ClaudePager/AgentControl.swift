import Foundation

/// Lifecycle wrapper around the companion `claude-telegram-agent`.
///
/// As of v0.1.0 this is a thin pass-through to `cta start` / `cta stop` —
/// the agent's CLI owns the actual launchctl/tmux choreography. Pager
/// shouldn't know which tmux sessions exist or where the plist lives.
///
/// `setAutoStartAtLogin` still touches Pager's *own* LaunchAgent
/// (`com.claude-pager`), which is internal to this app — different concern
/// from controlling the bot.
enum AgentControl {
    static let pagerPlistPath = ("~/Library/LaunchAgents/com.claude-pager.plist" as NSString).expandingTildeInPath

    /// Best-effort: start the agent. Idempotent on the cta side. Returns
    /// quietly if cta isn't installed yet (user hasn't run `install.sh`
    /// for the agent repo).
    static func ensureBotRunning() {
        guard CTAClient.isInstalled else { return }
        _ = try? CTAClient.start()
    }

    /// Stop the agent. Idempotent.
    static func stopBot() {
        guard CTAClient.isInstalled else { return }
        _ = try? CTAClient.stop()
    }

    /// Enable / disable the Pager LaunchAgent for next login. Doesn't kill
    /// the currently running Pager — just controls whether launchd will
    /// re-spawn at the next user-login. This manages Pager's own plist,
    /// not the agent's, so no `cta` involvement.
    static func setAutoStartAtLogin(_ on: Bool) {
        guard FileManager.default.fileExists(atPath: pagerPlistPath) else { return }
        _ = run("/bin/launchctl", [on ? "load" : "unload", pagerPlistPath])
    }

    /// True if the Pager LaunchAgent is currently loaded in launchd.
    static var isAutoStartAtLoginOn: Bool {
        let out = run("/bin/launchctl", ["list"]).stdout
        return out.contains("com.claude-pager")
    }

    // MARK: - Internals (Pager's own LaunchAgent management only)

    private struct ProcessResult { let stdout: String; let exitCode: Int32 }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return ProcessResult(stdout: "", exitCode: -1)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcessResult(stdout: String(data: data, encoding: .utf8) ?? "", exitCode: p.terminationStatus)
    }
}
