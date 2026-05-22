import AppKit

/// Full Disk Access onboarding action.
///
/// P6c made the agent launchd-direct; its file-accessing runtime is `bun`
/// (`bun poller.ts`, which also spawns claude). macOS prompts for `bun` when it
/// touches protected resources, and a per-folder grant doesn't cover everything
/// — so the clean fix is to add `bun` to Full Disk Access once. We can't grant
/// it programmatically (TCC requires the user), so we open the pane and reveal
/// the bun binary (it lives in a hidden ~/.bun path) for the user to drag in.
enum FullDiskAccess {

    /// Deep link to System Settings → Privacy & Security → Full Disk Access.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// bun resolution order, mirroring start_agents.sh's PATH (~/.bun/bin first).
    /// The dev-Mac prompt named ~/.bun/bin/bun specifically.
    static var defaultBunCandidates: [String] {
        [
            NSHomeDirectory() + "/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ]
    }

    /// First candidate that exists, or nil. Pure (injected existence check) so
    /// the ordering is testable without a real bun install.
    static func resolveBun(candidates: [String], exists: (String) -> Bool) -> String? {
        candidates.first(where: exists)
    }

    static func bunPath() -> String? {
        resolveBun(candidates: defaultBunCandidates) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Open the Full Disk Access settings pane.
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Reveal the bun binary in Finder so the user can drag it into the FDA list
    /// (its ~/.bun path is otherwise hard to reach in the add-file picker).
    /// No-op if bun can't be located.
    static func revealBunInFinder() {
        guard let p = bunPath() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
}
