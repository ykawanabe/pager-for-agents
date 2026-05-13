import Foundation
import Combine

/// Snapshot of the agent's health, sampled every `pollInterval` seconds.
struct AgentStatus: Equatable {
    var launchAgentLoaded: Bool = false
    var claudePid: Int? = nil
    var claudeMemMB: Int? = nil
    var telegramMcpAlive: Bool = false
    var tmuxClaudeAlive: Bool = false
    var tmuxWatchdogAlive: Bool = false
    /// True iff cta reports `caffeinate.alive=true`. The agent owns the
    /// subprocess and PID file; Pager just renders the result.
    var caffeinateAlive: Bool = false
    var lastActivity: Date? = nil

    /// True when `cta` itself is missing — agent isn't installed or is on a
    /// pre-v0.1.0 build. Surfaced in the menu so users get a real message
    /// instead of just red dots.
    var ctaInstalled: Bool = true

    /// Schema mismatch between Pager and the agent's cta. Agent shipped a
    /// newer cta than this Pager knows how to parse (or vice versa).
    var schemaMismatch: (got: Int, expected: Int)? = nil

    /// Overall traffic light. Green = everything up. Yellow = one issue. Red = bot is down.
    enum Color { case green, yellow, red }

    var color: Color {
        // Distinguishable failure modes:
        // - cta missing: agent not installed → red.
        // - schema mismatch: we can't trust the data → red.
        // Both surface their own copy in MenuView so user knows what to do.
        if !ctaInstalled || schemaMismatch != nil { return .red }

        let bot = launchAgentLoaded && claudePid != nil && telegramMcpAlive
        let infra = tmuxClaudeAlive && tmuxWatchdogAlive
        if bot && infra { return .green }
        if claudePid == nil || !telegramMcpAlive { return .red }
        return .yellow
    }

    // Equatable can't auto-synthesize for tuple fields. Hand-roll it.
    static func == (lhs: AgentStatus, rhs: AgentStatus) -> Bool {
        lhs.launchAgentLoaded == rhs.launchAgentLoaded
            && lhs.claudePid == rhs.claudePid
            && lhs.claudeMemMB == rhs.claudeMemMB
            && lhs.telegramMcpAlive == rhs.telegramMcpAlive
            && lhs.tmuxClaudeAlive == rhs.tmuxClaudeAlive
            && lhs.tmuxWatchdogAlive == rhs.tmuxWatchdogAlive
            && lhs.caffeinateAlive == rhs.caffeinateAlive
            && lhs.lastActivity == rhs.lastActivity
            && lhs.ctaInstalled == rhs.ctaInstalled
            && lhs.schemaMismatch?.got == rhs.schemaMismatch?.got
            && lhs.schemaMismatch?.expected == rhs.schemaMismatch?.expected
    }
}

final class StatusMonitor: ObservableObject {
    /// Shared instance — SwiftUI's @main App can init twice during startup,
    /// which would otherwise spawn two pollers. Singleton keeps a single source
    /// of truth for the @Published status.
    static let shared = StatusMonitor()

    @Published private(set) var status = AgentStatus()

    private let pollInterval: TimeInterval = 5
    private var task: Task<Void, Never>?

    private init() {}

    /// Idempotent — calling twice replaces the running task.
    func start() {
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let interval = self.pollInterval
            while !Task.isCancelled {
                let next = Self.sample()
                await MainActor.run { self.status = next }
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Trigger an out-of-band poll. Useful after the user toggles something
    /// via Pager (e.g. caffeinate) — the status doesn't have to wait up to
    /// `pollInterval` seconds for the UI label to catch up. Detached so
    /// callers can fire-and-forget from the UI thread.
    func refreshNow() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let next = Self.sample()
            await MainActor.run { self.status = next }
        }
    }

    /// Synchronous sampler — called from a background task. Delegates to the
    /// agent's `cta status --json` and maps the JSON into our local model.
    /// Process spawn is small (~5ms) and the JSON is tiny, so total cost is
    /// well under the 5s poll interval.
    static func sample() -> AgentStatus {
        var s = AgentStatus()

        guard CTAClient.isInstalled else {
            s.ctaInstalled = false
            return s
        }

        do {
            let j = try CTAClient.status()
            s.launchAgentLoaded = j.launchAgent.loaded
            s.claudePid = j.claude.pid
            s.claudeMemMB = j.claude.rssMb
            s.telegramMcpAlive = j.telegramMcp.alive
            s.tmuxClaudeAlive = j.tmux.claude.alive
            s.tmuxWatchdogAlive = j.tmux.watchdog.alive
            s.caffeinateAlive = j.caffeinate?.alive ?? false
            s.lastActivity = parseISO8601(j.lastActivity)
            return s
        } catch CTAClient.CTAError.unsupportedSchema(let got, let expected) {
            s.schemaMismatch = (got: got, expected: expected)
            return s
        } catch {
            // Any other failure (parse error, non-zero exit): leave fields at
            // their default falsy values. color computes to red because
            // claudePid is nil, which is the right signal.
            return s
        }
    }

    /// Parse the agent's `last_activity` ISO8601 string. Returns nil for nil
    /// input or malformed strings (treated identically — both mean "no signal").
    private static func parseISO8601(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        return f.date(from: s)
    }
}
