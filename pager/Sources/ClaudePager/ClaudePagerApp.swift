import SwiftUI
import AppKit

/// Process entry point. The same Pager binary serves two roles:
///   - normal: the menu-bar app (SwiftUI).
///   - `--agent-launcher <poller.ts>`: a headless supervisor that spawns + waits
///     on `bun <poller.ts>`. start_agents.sh execs us this way under launchd so
///     macOS attributes the poller's file access to Claude Pager.app (Full Disk
///     Access shows "Claude Pager", not "bun"; bun stays un-bundled on $PATH).
///     This branch never starts SwiftUI.
@main
struct PagerMain {
    static func main() {
        let args = CommandLine.arguments
        if AgentLauncher.isLauncherInvocation(args) {
            guard let poller = AgentLauncher.pollerPath(from: args) else {
                FileHandle.standardError.write(Data("agent-launcher: missing poller.ts path\n".utf8))
                exit(2)
            }
            AgentLauncher.run(pollerPath: poller)  // never returns
        }
        ClaudePagerApp.main()  // SwiftUI app (App protocol's default main)
    }
}

struct ClaudePagerApp: App {
    // ObservedObject — StateObject is for SwiftUI-owned lifetimes; the
    // StatusMonitor is a long-lived singleton elsewhere.
    @ObservedObject private var monitor = StatusMonitor.shared
    @ObservedObject private var caffeinate = CaffeinateController()
    private let wakeObserver = WakeObserver()
    @AppStorage("stopBotOnQuit") private var stopBotOnQuit = true
    // Default OFF: caffeinate (`-i`, idle-sleep assertion) does NOT keep the
    // poller alive through standby/powernap on Apple Silicon — those freeze
    // the process ~15 of every ~16 min regardless, so the real silence fix is
    // `sudo pmset -a powernap 0 standby 0`, not caffeinate. Leaving it on by
    // default just held the Mac awake (battery drain) and leaked orphan
    // caffeinates on power-state churn for no reliability gain. Users who
    // still want it can flip it on in Settings; `onlyOnAC=true` then bounds
    // battery drain to when the Mac is plugged in.
    @AppStorage("caffeinateEnabled") private var caffeinateEnabled = false
    @AppStorage("caffeinateOnlyOnAC") private var caffeinateOnlyOnAC = true

    init() {
        // LSUIElement=true in Info.plist already makes us an accessory app —
        // calling setActivationPolicy(.accessory) on top was reported to
        // conflict with MenuBarExtra registration on some macOS versions.
        // Leave activation to Info.plist; keep init lean.

        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [wakeObserver] _ in
            StatusMonitor.shared.start()
            AgentControl.ensureBotRunning()
            // Surface macOS wake events to the poller so a stale-after-sleep
            // long-poll socket aborts immediately instead of burning the full
            // ~40s timeout budget while the user waits for a reply.
            wakeObserver.start()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [caffeinate, wakeObserver] _ in
            // Always drop the caffeinate assertion when Pager goes away.
            // Surprising for the user if the Mac stayed awake forever after
            // they quit Pager. Idempotent — cta returns "Not running" cleanly.
            caffeinate.stop()
            wakeObserver.stop()
            if UserDefaults.standard.object(forKey: "stopBotOnQuit") as? Bool ?? true {
                AgentControl.stopBot()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("Claude Pager", systemImage: symbolName) {
            MenuView(monitor: monitor, caffeinate: caffeinate)
                .onAppear { syncCaffeinate() }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(caffeinate: caffeinate, monitor: monitor)
                .onAppear { syncCaffeinate(); ActivationPolicyManager.windowOpened() }
                .onDisappear { ActivationPolicyManager.windowClosed() }
        }

        // Singleton "watch live" window. Opened via openWindow(id:) from the
        // menu bar. Closing it leaves the window registered with id —
        // re-opening from the menu focuses or recreates the singleton.
        Window("Watch live", id: "watch-live") {
            WatchLiveView()
                .onAppear { ActivationPolicyManager.windowOpened() }
                .onDisappear { ActivationPolicyManager.windowClosed() }
        }
        .defaultSize(width: 1000, height: 600)
        .windowResizability(.contentMinSize)

        // Setup wizard window. Re-runnable from the menu; auto-shown on
        // first launch when no plugin .env exists (see init() observer).
        Window("Pager Setup", id: "setup-wizard") {
            SetupWizardView()
                .onAppear { ActivationPolicyManager.windowOpened() }
                .onDisappear { ActivationPolicyManager.windowClosed() }
        }
        .defaultSize(width: 600, height: 520)
        .windowResizability(.contentMinSize)
    }

    /// Re-apply the two @AppStorage values to the controller. Cheap; safe to
    /// call from multiple onAppear sites. The controller itself drives the
    /// subprocess + power watcher.
    private func syncCaffeinate() {
        caffeinate.start()   // idempotent
        caffeinate.configure(enabled: caffeinateEnabled, onlyOnAC: caffeinateOnlyOnAC)
    }

    private var symbolName: String {
        // SF Symbols catalog has no `paperplane.slash` — using
        // `exclamationmark.triangle.fill` for the offline state matches macOS
        // menu bar warning conventions (e.g. iCloud sync failures).
        switch monitor.status.color {
        case .green:  return "paperplane.fill"
        case .yellow: return "paperplane"
        case .red:    return "exclamationmark.triangle.fill"
        }
    }
}
