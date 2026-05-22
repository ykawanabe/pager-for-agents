import AppKit

/// Full Disk Access onboarding action.
///
/// The poller runs via Claude Pager.app's launcher (`ClaudePager
/// --agent-launcher`, which spawns bun), so macOS attributes the agent's file
/// access to com.claude-pager. The user therefore grants **"Claude Pager"** Full
/// Disk Access — one recognizable, already-known app — and it covers the agent.
/// We can't grant it programmatically (TCC requires the user), so we open the
/// pane and reveal Claude Pager.app for them to drag in (it's in ~/Applications,
/// easy to find, but the reveal saves a step).
enum FullDiskAccess {

    /// Deep link to System Settings → Privacy & Security → Full Disk Access.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Claude Pager.app locations, in resolution order (where pager/install.sh
    /// puts it first).
    static var defaultPagerAppCandidates: [String] {
        [
            NSHomeDirectory() + "/Applications/Claude Pager.app",
            "/Applications/Claude Pager.app",
        ]
    }

    /// First candidate that exists, or nil. Pure (injected existence check) for
    /// testability.
    static func resolvePagerApp(candidates: [String], exists: (String) -> Bool) -> String? {
        candidates.first(where: exists)
    }

    static func pagerAppPath() -> String? {
        resolvePagerApp(candidates: defaultPagerAppCandidates) { FileManager.default.fileExists(atPath: $0) }
    }

    /// Open the Full Disk Access settings pane.
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Reveal Claude Pager.app in Finder so the user can drag it into the FDA
    /// list. No-op if it can't be located (then the user adds it from
    /// ~/Applications themselves).
    static func revealPagerAppInFinder() {
        guard let p = pagerAppPath() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
}
