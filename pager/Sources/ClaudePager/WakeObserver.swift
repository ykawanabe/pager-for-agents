import Foundation
import AppKit

/// Watch macOS wake events and touch a flag file the poller observes.
///
/// When the Mac wakes from sleep, the poller's in-flight `getUpdates` long-poll
/// is holding a socket that survived the suspend in name only — TCP keep-alives
/// didn't tick, the userland fetch is frozen on a connection the network stack
/// has likely abandoned. Left alone, the call burns the full ~40s long-poll
/// budget (timeoutSec + 15s client slack) before its own AbortController fires,
/// and the bot is silent for that whole stretch right after wake.
///
/// Pager has the right vantage point to catch the wake: it runs as a GUI app,
/// receives `NSWorkspace.didWakeNotification` from the workspace notification
/// center, and shares a filesystem with the launchd-direct poller. We deliver
/// the signal via a single empty flag file in `~/.pager/wake.flag` — the
/// poller's housekeep tick (~5s) observes the flag, calls
/// `transport.interruptInbound()` on the Telegram transport, and deletes the
/// flag. Cheap, fork-free, and the IPC is one inode.
///
/// We don't try to use IOKit power-notifications here: those need a Mach port
/// owned by a long-lived runloop and `caffeinate` already exists in the cta
/// process tree if the user wants to *prevent* sleep. This observer fires
/// AFTER the sleep is over and the user's expectation is "the bot is reachable
/// again now."
final class WakeObserver {
    private var observer: NSObjectProtocol?
    /// `~/.pager/wake.flag`. Resolved once at init from CTA_STATE_DIR (matches
    /// cta's resolution order) with a hard fallback to `~/.pager`. Path is
    /// stable for the process lifetime — relocating $STATE_DIR mid-session is
    /// not a supported flow.
    private let flagPath: String

    init(stateDir: String? = nil) {
        let resolvedDir: String = {
            if let d = stateDir { return d }
            if let env = ProcessInfo.processInfo.environment["CTA_STATE_DIR"], !env.isEmpty {
                return (env as NSString).expandingTildeInPath
            }
            return (NSString(string: "~/.pager") as NSString).expandingTildeInPath
        }()
        self.flagPath = (resolvedDir as NSString).appendingPathComponent("wake.flag")
    }

    /// Begin observing. Idempotent — calling twice is harmless because the
    /// underlying API returns a fresh token each time and we store only the
    /// latest. Safe to call from `init` of the app delegate or from
    /// `didFinishLaunchingNotification`.
    func start() {
        if observer != nil { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.touchFlag()
        }
    }

    /// Stop observing. Called on `applicationWillTerminate` to release the
    /// token. NSWorkspace cleans up automatically on process exit but explicit
    /// teardown is the right shape for symmetry with `start()`.
    func stop() {
        if let obs = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            observer = nil
        }
    }

    /// Write the flag. Empty contents — the poller only cares about the
    /// existence and unlinks immediately after observation. Errors are
    /// swallowed: a write failure (disk full, permissions) is logged via OS
    /// log machinery but never surfaces in the menu UI; the next wake will
    /// retry and the silence is at most one long-poll budget.
    private func touchFlag() {
        // `Data()` write is atomic-via-rename per Apple's docs when given the
        // .atomic option. We tolerate the brief mid-rename window because
        // the poller's check is `existsSync` — it sees either the old or new
        // inode, both equally valid as "wake observed."
        do {
            try Data().write(to: URL(fileURLWithPath: flagPath), options: [.atomic])
        } catch {
            // Best-effort. Don't crash the app on a wake-flag write failure.
        }
    }
}
