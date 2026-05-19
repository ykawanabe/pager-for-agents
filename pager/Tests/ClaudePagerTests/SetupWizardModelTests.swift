import Foundation
import XCTest
@testable import ClaudePager

/// Tests for SetupWizardModel — the file-state predicates that drive the
/// onboarding wizard. Mirrors the bash `_init_step{1,2,3,4,5}_*` helpers
/// in `cli/cta`; the two implementations MUST agree on what counts as
/// done at each step so the CLI and Pager wizards stay in lock-step.
@MainActor
final class SetupWizardModelTests: XCTestCase {

    private var tmpDir: URL!
    private var stateDir: URL!
    private var pluginEnv: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Each test gets its own sandbox so file writes don't bleed between
        // cases or contaminate ~/.pager on the dev machine.
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pager-wizard-tests-\(UUID().uuidString)")
        stateDir = tmpDir.appendingPathComponent("state")
        pluginEnv = tmpDir.appendingPathComponent("plugin/.env")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginEnv.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func makeModel() -> SetupWizardModel {
        SetupWizardModel(stateDir: stateDir, pluginEnvPath: pluginEnv)
    }

    // MARK: - step1: bot token presence

    func test_step1_falseWhenPluginEnvMissing() {
        let model = makeModel()
        XCTAssertFalse(model.step1TokenReady())
    }

    func test_step1_falseWhenEnvHasNoTokenLine() throws {
        try "OTHER=value".write(to: pluginEnv, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.refresh()
        XCTAssertFalse(model.step1TokenReady())
    }

    func test_step1_trueWhenTokenPresent() throws {
        try "TELEGRAM_BOT_TOKEN=12345:abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
            .write(to: pluginEnv, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.refresh()
        XCTAssertTrue(model.step1TokenReady())
    }

    func test_step1_falseWhenTokenIsEmptyString() throws {
        try "TELEGRAM_BOT_TOKEN=".write(to: pluginEnv, atomically: true, encoding: .utf8)
        let model = makeModel()
        XCTAssertFalse(model.step1TokenReady())
    }

    // MARK: - step3: first inbound seen

    func test_step3_falseWhenNoPairedAndNoLog() {
        let model = makeModel()
        XCTAssertFalse(model.step3InboundSeen())
    }

    func test_step3_trueWhenAgentLogHasDaemonDispatch() throws {
        let log = stateDir.appendingPathComponent("agent.log")
        try "[2026-05-19T00:18:23Z] update 42 → daemon[260] (63 chars)\n"
            .write(to: log, atomically: true, encoding: .utf8)
        let model = makeModel()
        XCTAssertTrue(model.step3InboundSeen())
    }

    func test_step3_trueWhenAgentLogHasLegacyUpdateMarker() throws {
        let log = stateDir.appendingPathComponent("agent.log")
        try "[2026-05-15T10:00:00Z] update 99 → topic-42 (...)\n"
            .write(to: log, atomically: true, encoding: .utf8)
        let model = makeModel()
        XCTAssertTrue(model.step3InboundSeen())
    }

    func test_step3_trueWhenPairedJsonExists() throws {
        let paired = stateDir.appendingPathComponent("paired.json")
        try #"{"version":1,"chat_id":-1001,"user_id":42,"paired_at":"x"}"#
            .write(to: paired, atomically: true, encoding: .utf8)
        let model = makeModel()
        XCTAssertTrue(model.step3InboundSeen())
    }

    // MARK: - step4: paired chat

    func test_step4_falseWhenNoPairedJson() {
        XCTAssertFalse(makeModel().step4Paired())
    }

    func test_step4_trueWhenChatIdPresent() throws {
        let paired = stateDir.appendingPathComponent("paired.json")
        try #"{"version":1,"chat_id":-1001,"user_id":42}"#
            .write(to: paired, atomically: true, encoding: .utf8)
        XCTAssertTrue(makeModel().step4Paired())
    }

    func test_step4_falseWhenChatIdMissing() throws {
        let paired = stateDir.appendingPathComponent("paired.json")
        try #"{"version":1}"#
            .write(to: paired, atomically: true, encoding: .utf8)
        XCTAssertFalse(makeModel().step4Paired())
    }

    // MARK: - step5: default mount

    func test_step5_falseWhenNoMountsJson() {
        XCTAssertFalse(makeModel().step5DefaultMount())
    }

    func test_step5_falseWhenOnlySpecificMounts() throws {
        let mounts = stateDir.appendingPathComponent("mounts.json")
        try #"{"version":2,"mounts":[{"channel":"telegram","thread_id":42,"path":"/tmp","tmux_session":"topic-42"}]}"#
            .write(to: mounts, atomically: true, encoding: .utf8)
        XCTAssertFalse(makeModel().step5DefaultMount())
    }

    func test_step5_trueWhenWildcardMountPresent() throws {
        let mounts = stateDir.appendingPathComponent("mounts.json")
        try #"{"version":2,"mounts":[{"channel":"telegram","thread_id":"*","path":"/tmp/proj","tmux_session":"topic-wild"}]}"#
            .write(to: mounts, atomically: true, encoding: .utf8)
        XCTAssertTrue(makeModel().step5DefaultMount())
    }

    // MARK: - aggregate state

    func test_refresh_buildsStepListWithFiveEntries() {
        let model = makeModel()
        model.refresh()
        XCTAssertEqual(model.steps.count, 5)
        XCTAssertEqual(model.steps.map(\.number), [1, 2, 3, 4, 5])
    }

    func test_refresh_currentStepPointsAtFirstPending() throws {
        // Steps 1-3 done, 4-5 pending → currentStep = 4.
        try "TELEGRAM_BOT_TOKEN=12345:abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
            .write(to: pluginEnv, atomically: true, encoding: .utf8)
        let log = stateDir.appendingPathComponent("agent.log")
        try "[ts] update 1 → daemon[42] (10 chars)\n"
            .write(to: log, atomically: true, encoding: .utf8)

        let model = makeModel()
        model.refresh()
        XCTAssertEqual(model.currentStep, 4)
    }

    func test_refresh_currentStepGoesPastWhenAllDone() throws {
        try "TELEGRAM_BOT_TOKEN=12345:abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
            .write(to: pluginEnv, atomically: true, encoding: .utf8)
        let log = stateDir.appendingPathComponent("agent.log")
        try "[ts] update 1 → daemon[42] (10 chars)\n"
            .write(to: log, atomically: true, encoding: .utf8)
        try #"{"version":1,"chat_id":-1001,"user_id":42}"#
            .write(to: stateDir.appendingPathComponent("paired.json"),
                   atomically: true, encoding: .utf8)
        try #"{"version":2,"mounts":[{"channel":"telegram","thread_id":"*","path":"/tmp","tmux_session":"x"}]}"#
            .write(to: stateDir.appendingPathComponent("mounts.json"),
                   atomically: true, encoding: .utf8)

        let model = makeModel()
        model.refresh()
        XCTAssertTrue(model.isComplete)
        XCTAssertEqual(model.currentStep, 6)
    }
}
