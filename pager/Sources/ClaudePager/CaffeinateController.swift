import Foundation
import IOKit.ps

/// Pager-side policy for "should the Mac stay awake?" The actual `caffeinate`
/// subprocess is owned by the agent (`cta config caffeinate on|off`) — Pager
/// just decides, the agent applies. Keeping the subprocess in cta means there
/// is one source of truth (one PID file, one process) regardless of whether
/// you control it from Pager, the CLI, or both. It also matches the broader
/// design rule: Pager is a thin UI over `cta`.
///
/// This controller's job is:
///   1. Read the two user settings — `enabled`, `onlyOnAC`.
///   2. Watch macOS power-source state (IOKit notifications, no polling).
///   3. Collapse the three into "should be on right now?" and call
///      `CTAClient.setCaffeinate(on:)` so the agent matches.
///
/// The actual liveness shown in the UI comes from `StatusMonitor.status
/// .caffeinateAlive` (cta's own JSON), so a manual `cta config caffeinate on`
/// outside Pager also reflects in the menu without any extra wiring.
final class CaffeinateController: ObservableObject {
    @Published private(set) var onACPower: Bool = true

    private var notificationSource: CFRunLoopSource?
    private var enabled: Bool = false
    private var onlyOnAC: Bool = true

    /// Pure decision function — separated from the side-effects so the unit
    /// test can pin every combination of (enabled, onlyOnAC, onAC) without
    /// touching IOKit or shelling out to cta.
    static func shouldRun(enabled: Bool, onlyOnAC: Bool, onAC: Bool) -> Bool {
        guard enabled else { return false }
        if onlyOnAC && !onAC { return false }
        return true
    }

    func configure(enabled: Bool, onlyOnAC: Bool) {
        self.enabled = enabled
        self.onlyOnAC = onlyOnAC
        evaluate()
    }

    /// Call once at app launch. Registers the power-source watcher and does
    /// the first evaluation. Idempotent — calling twice is safe.
    func start() {
        if notificationSource == nil {
            registerPowerWatcher()
        }
        evaluate()
    }

    /// Call on app quit. Tears down the IOKit source and forces caffeinate
    /// off — surprising for the user if the Mac stayed awake forever after
    /// they quit Pager.
    func stop() {
        unregisterPowerWatcher()
        applyToCTA(want: false)
    }

    private func evaluate() {
        onACPower = readPowerState()
        let want = Self.shouldRun(enabled: enabled, onlyOnAC: onlyOnAC, onAC: onACPower)
        applyToCTA(want: want)
    }

    /// Fire-and-forget call into the CLI. Errors are swallowed: a transient
    /// `cta` failure shouldn't crash Pager, and the next StatusMonitor poll
    /// will surface the real on/off state in the UI anyway.
    private func applyToCTA(want: Bool) {
        Task.detached(priority: .utility) {
            do {
                _ = try CTAClient.setCaffeinate(on: want)
            } catch {
                // Best-effort — silent. The UI reflects whatever cta reports.
            }
            await MainActor.run { StatusMonitor.shared.refreshNow() }
        }
    }

    private func readPowerState() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return true   // assume AC if IOKit doesn't know — safer than "battery, do nothing"
        }
        guard let typeRef = IOPSGetProvidingPowerSourceType(info) else {
            return true
        }
        let type = Unmanaged.fromOpaque(typeRef.toOpaque()).takeUnretainedValue() as CFString
        return (type as String) == kIOPMACPowerKey
    }

    private func registerPowerWatcher() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<CaffeinateController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.evaluate() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(cb, context)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        notificationSource = source
    }

    private func unregisterPowerWatcher() {
        if let src = notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        notificationSource = nil
    }
}
