import SwiftUI
import AppKit

/// Onboarding wizard — visual mirror of `cta init`. Shows a checklist of
/// the 5 setup steps with current status, deep-links into BotFather and
/// the host CLI, and explains what to do next. The CLI does the heavy
/// lifting (token validation, atomic writes, pairing); this view just
/// reflects state and points the user at the right tool.
///
/// Open via:
///   - Menu bar → "Setup Wizard…"
///   - Auto-shown on first launch when no plugin .env exists (handled in
///     ClaudePagerApp).
struct SetupWizardView: View {
    @StateObject private var model = SetupWizardModel()
    @State private var verifyResult: String?
    @State private var pairingCode: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            stepList
            Spacer(minLength: 8)
            Divider()
            actions
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 480, idealHeight: 520)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - sections

    @ViewBuilder
    private var header: some View {
        if model.isComplete {
            VStack(alignment: .leading, spacing: 4) {
                Text("Setup complete")
                    .font(.title)
                Text(model.botUsername.map { "Your bot @\($0) is paired. Send a message to start." }
                    ?? "Your bot is paired. Send a message to start.")
                    .foregroundColor(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pager setup — step \(model.currentStep) of 5")
                    .font(.title)
                Text("Each step is checked from disk; re-runnable any time. Follow the CLI for the interactive bits — `cta init` walks you through them with prompts.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var stepList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.steps, id: \.number) { step in
                stepRow(step)
            }
            // Optional, non-blocking: file access (Full Disk Access). Shown below
            // the 5 required steps; never gates completion.
            Divider().padding(.vertical, 2)
            fileAccessRow
        }
    }

    @ViewBuilder
    private var fileAccessRow: some View {
        let granted = model.fileAccessGranted
        HStack(spacing: 10) {
            Image(systemName: granted == true ? "checkmark.circle.fill"
                            : (granted == false ? "exclamationmark.triangle.fill" : "circle.dotted"))
                .foregroundColor(granted == true ? .green : (granted == false ? .orange : .secondary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("File access (optional)").font(.body)
                Text(fileAccessDetail(granted)).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if granted != true {
                Button("Grant…") {
                    // Reveal Claude Pager.app THEN open the pane, so the user has
                    // the app ready to drag into the Full Disk Access list.
                    FullDiskAccess.revealPagerAppInFinder()
                    FullDiskAccess.openSettings()
                }
            }
        }
    }

    private func fileAccessDetail(_ granted: Bool?) -> String {
        switch granted {
        case .some(true):
            return "Full Disk Access granted — the bot can work in protected folders."
        case .some(false):
            return "To work in Documents / Desktop / Downloads / iCloud, add Claude Pager to Full Disk Access (not needed if your projects live in ~/ghq etc.)."
        case .none:
            return "Unknown — will show once the agent has been updated."
        }
    }

    @ViewBuilder
    private func stepRow(_ step: SetupWizardModel.StepState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: step.status == .done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(step.status == .done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(step.number) — \(step.title)")
                    .font(.body)
                if let detail = stepDetail(step) {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            stepAction(step)
        }
    }

    private func stepDetail(_ step: SetupWizardModel.StepState) -> String? {
        if step.status == .done {
            switch step.number {
            case 1: return model.botUsername.map { "Verified @\($0)" } ?? "Token present (run Verify for username)."
            case 4: return "paired.json has chat_id."
            default: return nil
            }
        }
        switch step.number {
        case 1: return "Paste your bot token in Terminal: `cta init`. Already pasted? Click Verify →"
        case 2: return "In @BotFather, /setprivacy → pick your bot → Disable. Without this the bot can't see non-command messages in groups."
        case 3: return "Send any message to your bot from the chat you want to pair."
        case 4: return "Send `/pair <code>` from the chat. Pairing code shown by Show pairing code →"
        case 5: return "Pick a default project dir for new topics: `cta init` step 5."
        default: return nil
        }
    }

    @ViewBuilder
    private func stepAction(_ step: SetupWizardModel.StepState) -> some View {
        if step.status == .done { EmptyView() }
        else {
            switch step.number {
            case 1:
                Button("Verify") {
                    Task {
                        let username = await model.verifyBotToken()
                        verifyResult = username.map { "✓ @\($0)" } ?? "❌ getMe failed"
                    }
                }
                .help("Calls Telegram getMe to check the token. Doesn't write anything.")
            case 2:
                Button("Open @BotFather") { openURL("tg://resolve?domain=BotFather") }
            case 4:
                Button("Show pairing code") {
                    pairingCode = readPairingCode()
                }
            default:
                Button("Run `cta init`") { openTerminalWithCTA() }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            if let verifyResult = verifyResult {
                Text(verifyResult)
                    .font(.callout)
                    .foregroundColor(verifyResult.hasPrefix("✓") ? .green : .red)
            }
            if let code = pairingCode {
                HStack(spacing: 4) {
                    Text("Pairing code:").foregroundColor(.secondary)
                    Text(code).font(.system(.body, design: .monospaced))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
            Spacer()
            Button("Open Terminal: cta init") { openTerminalWithCTA() }
                .help("Drops you into `cta init` — the wizard prompts for each step interactively.")
            Button(model.isComplete ? "Done" : "Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - actions

    private func openURL(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// Open Terminal.app with `cta init`. Falls back to opening Terminal
    /// without a command if osascript isn't available (it always is on
    /// macOS, but defensive — never hang or crash from a missing dep).
    private func openTerminalWithCTA() {
        let ctaPath = NSHomeDirectory() + "/.local/bin/cta"
        let script = """
        tell application "Terminal"
            activate
            do script "\(ctaPath) init"
        end tell
        """
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    private func readPairingCode() -> String? {
        // `cta pair-code` reads or generates the code. We don't shell out
        // here — read directly from the file the CLI manages.
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".pager/pairing-code")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
