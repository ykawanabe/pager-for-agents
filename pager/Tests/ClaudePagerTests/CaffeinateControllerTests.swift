import XCTest
@testable import ClaudePager

/// CaffeinateController is mostly side-effects (subprocess, IOKit
/// notifications). The one piece worth unit-testing is the decision function
/// that maps (enabled, onlyOnAC, onAC) → should we be caffeinating right now.
/// Pure arithmetic — no mocking needed.
final class CaffeinateControllerTests: XCTestCase {

    // Off → never caffeinates, regardless of AC state.
    func test_disabled_neverRuns() {
        XCTAssertFalse(CaffeinateController.shouldRun(enabled: false, onlyOnAC: true,  onAC: true))
        XCTAssertFalse(CaffeinateController.shouldRun(enabled: false, onlyOnAC: true,  onAC: false))
        XCTAssertFalse(CaffeinateController.shouldRun(enabled: false, onlyOnAC: false, onAC: true))
        XCTAssertFalse(CaffeinateController.shouldRun(enabled: false, onlyOnAC: false, onAC: false))
    }

    // Enabled + onlyOnAC + on AC → run. The default-checked path.
    func test_enabled_acOnly_onAC_runs() {
        XCTAssertTrue(CaffeinateController.shouldRun(enabled: true, onlyOnAC: true, onAC: true))
    }

    // Enabled + onlyOnAC + on battery → pause. Battery-preservation goal.
    func test_enabled_acOnly_onBattery_pauses() {
        XCTAssertFalse(CaffeinateController.shouldRun(enabled: true, onlyOnAC: true, onAC: false))
    }

    // Enabled + always (onlyOnAC=false) → run regardless of power source.
    // Power-user path: "I want the bot always responsive, accept the battery cost."
    func test_enabled_always_runsOnBattery() {
        XCTAssertTrue(CaffeinateController.shouldRun(enabled: true, onlyOnAC: false, onAC: false))
        XCTAssertTrue(CaffeinateController.shouldRun(enabled: true, onlyOnAC: false, onAC: true))
    }
}
