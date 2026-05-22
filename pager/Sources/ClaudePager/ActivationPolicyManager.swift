import AppKit

/// Menu-bar (LSUIElement / `.accessory`) apps are excluded from the Dock AND
/// the Command+Tab switcher by design. That's right for the steady state, but
/// it means an open window (Settings / Watch live / Setup) can't be reached via
/// Command+Tab and gets buried behind whatever's frontmost. This flips the app
/// to `.regular` while any such window is open — so it shows in Command+Tab +
/// the Dock and can be re-focused — and back to `.accessory` when the last one
/// closes.
///
/// The flip is done at runtime, not at launch: calling `setActivationPolicy` at
/// startup was reported to conflict with MenuBarExtra registration (see
/// `ClaudePagerApp.init`), but post-launch changes are fine and standard for
/// menu-bar apps that also show real windows.
///
/// Wired via each window content view's `.onAppear` / `.onDisappear`. A counter
/// (not a bool) so closing one window while another stays open doesn't revert
/// the policy early.
enum ActivationPolicyManager {
    private static var openWindowCount = 0

    /// Call from a window content view's `.onAppear`.
    static func windowOpened() {
        openWindowCount += 1
        if openWindowCount == 1 {
            NSApp.setActivationPolicy(.regular)
            // The Command+Tab switcher is a most-recently-used stack, and it
            // does NOT re-sort within the same runloop tick the activation
            // policy changed on. A synchronous activate() here lands the
            // freshly-promoted app at the TAIL of the switcher (the reported
            // "Settings shows up last in Command+Tab" bug) — visually frontmost
            // but last in the MRU order. Defer activation one runloop tick so
            // the app registers as frontmost AFTER the policy takes effect and
            // shows at the front of Command+Tab.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            // Already .regular (another window was open) — no policy change, so
            // the MRU timing quirk doesn't apply; activate immediately.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Call from a window content view's `.onDisappear`.
    static func windowClosed() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
