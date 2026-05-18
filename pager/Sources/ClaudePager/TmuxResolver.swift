import Foundation

/// Locates the `tmux` binary at install-time-known paths. Pager runs as a
/// LaunchAgent (~/Library/LaunchAgents/com.claude-pager.plist) which inherits
/// a minimal PATH — Homebrew's `/opt/homebrew/bin` is NOT on it by default,
/// so we can't rely on bare `tmux` finding the binary when SwiftTerm spawns
/// a child process. Mirrors the resolution pattern in CTAClient.
///
/// Why install-time-known: even if Pager's user shell has `tmux` on PATH,
/// the LaunchAgent subprocess won't inherit that. We probe absolute paths,
/// cache the first hit, and pass that to SwiftTerm.
enum TmuxResolver {

    /// Candidate locations, in priority order. Apple Silicon Homebrew first
    /// (most current users), then Intel Homebrew, then MacPorts, then a
    /// system path (in case the user installed tmux via tarball).
    private static let candidates: [String] = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    /// First executable path found, or nil. Cached at first access — the
    /// install location does not move at runtime.
    static let path: String? = candidates.first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    /// PATH suitable for tmux child processes (e.g., when tmux internally
    /// invokes a helper). Pulls from the same candidates' parent directories
    /// plus the standard system dirs. Used as the `PATH=` entry when we hand
    /// SwiftTerm an environment array.
    static var pathEnv: String {
        let dirs = candidates.map { (path: String) -> String in
            (path as NSString).deletingLastPathComponent
        }
        // Unique-preserving order.
        var seen = Set<String>()
        let unique = dirs.filter { seen.insert($0).inserted }
        return unique.joined(separator: ":")
    }
}
