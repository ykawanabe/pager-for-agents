import Foundation

/// Agent-launcher mode for the Pager binary.
///
/// P6c runs the poller as a launchd job. To make macOS show "Claude Pager" in
/// the Full Disk Access list (instead of the bare, scary "bun") WITHOUT bundling
/// a third-party binary, start_agents.sh execs THIS binary
/// (`ClaudePager --agent-launcher <poller.ts>`) and it spawns `bun <poller.ts>`
/// as a child. Because this binary lives inside Claude Pager.app, TCC attributes
/// the bun child's file access to com.claude-pager — verified by spike. bun
/// stays on $PATH, un-bundled; the FDA grant persists (stable bundle id).
///
/// The launcher becomes the launchd job's main process, so it must exit with the
/// child's status (KeepAlive respawns on crash) and forward SIGTERM/SIGINT so a
/// clean `cta stop` lets the poller flush + release locks.
enum AgentLauncher {

    static func isLauncherInvocation(_ args: [String]) -> Bool {
        args.contains("--agent-launcher")
    }

    /// The poller.ts path is the argument immediately after the flag.
    static func pollerPath(from args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--agent-launcher"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var defaultBunCandidates: [String] {
        [
            NSHomeDirectory() + "/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ]
    }

    static func resolveBun(candidates: [String], exists: (String) -> Bool) -> String? {
        candidates.first(where: exists)
    }

    /// Spawn `bun <pollerPath>` as a child, forward termination signals, wait,
    /// and exit with the child's status. Never returns. Inherits our environment
    /// (start_agents.sh sourced .env into it) and stdio (→ agent.log).
    static func run(pollerPath: String) -> Never {
        let bun = resolveBun(candidates: defaultBunCandidates,
                             exists: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "bun"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bun)
        proc.arguments = [pollerPath]

        // Forward SIGTERM/SIGINT to the poller child so a clean `cta stop` /
        // launchctl unload lets it flush JSONL + release per-session locks.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let forward = { if proc.isRunning { proc.terminate() } }
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        term.setEventHandler(handler: forward)
        intr.setEventHandler(handler: forward)
        term.resume()
        intr.resume()

        do {
            try proc.run()
        } catch {
            FileHandle.standardError.write(Data("agent-launcher: failed to spawn bun (\(bun)): \(error)\n".utf8))
            exit(127)
        }
        proc.waitUntilExit()
        exit(proc.terminationStatus)
    }
}
