import SwiftUI
import AppKit

@main
struct ClaudePagerApp: App {
    // ObservedObject — StateObject is for SwiftUI-owned lifetimes; the
    // StatusMonitor is a long-lived singleton elsewhere.
    @ObservedObject private var monitor = StatusMonitor.shared
    @ObservedObject private var caffeinate = CaffeinateController()
    @AppStorage("stopBotOnQuit") private var stopBotOnQuit = true
    @AppStorage("caffeinateEnabled") private var caffeinateEnabled = false
    @AppStorage("caffeinateOnlyOnAC") private var caffeinateOnlyOnAC = true

    init() {
        // LSUIElement=true in Info.plist already makes us an accessory app —
        // calling setActivationPolicy(.accessory) on top was reported to
        // conflict with MenuBarExtra registration on some macOS versions.
        // Leave activation to Info.plist; keep init lean.

        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            StatusMonitor.shared.start()
            AgentControl.ensureBotRunning()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [caffeinate] _ in
            // Always drop the caffeinate assertion when Pager goes away.
            // Surprising for the user if the Mac stayed awake forever after
            // they quit Pager. Idempotent — cta returns "Not running" cleanly.
            caffeinate.stop()
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
                .onAppear { syncCaffeinate() }
        }

        // Singleton "watch live" window. Opened via openWindow(id:) from the
        // menu bar. Closing it leaves the window registered with id —
        // re-opening from the menu focuses or recreates the singleton.
        Window("Watch live", id: "watch-live") {
            WatchLiveView()
        }
        .defaultSize(width: 1000, height: 600)
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
