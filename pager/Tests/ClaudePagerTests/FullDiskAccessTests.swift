import XCTest
@testable import ClaudePager

/// The FDA onboarding action: open the Full Disk Access pane and reveal
/// Claude Pager.app (the app macOS attributes the agent's file access to, since
/// the poller runs via Pager's launcher). The pure bits — which app to reveal +
/// the pane URL — are unit-tested; NSWorkspace.open is build/manual-verified.
final class FullDiskAccessTests: XCTestCase {

    func test_resolvePagerApp_picksFirstExistingCandidate() {
        let r = FullDiskAccess.resolvePagerApp(
            candidates: ["/a/Claude Pager.app", "/b/Claude Pager.app"],
            exists: { $0 == "/b/Claude Pager.app" })
        XCTAssertEqual(r, "/b/Claude Pager.app")
    }

    func test_resolvePagerApp_nilWhenNoneExist() {
        XCTAssertNil(FullDiskAccess.resolvePagerApp(candidates: ["/a/Claude Pager.app"], exists: { _ in false }))
    }

    func test_defaultPagerAppCandidates_prefersUserApplications() {
        XCTAssertTrue(FullDiskAccess.defaultPagerAppCandidates.first?.hasSuffix("/Applications/Claude Pager.app") ?? false,
                      "expected ~/Applications first, got \(FullDiskAccess.defaultPagerAppCandidates)")
    }

    func test_settingsURL_pointsAtFullDiskAccessPane() {
        XCTAssertTrue(FullDiskAccess.settingsURL.absoluteString.contains("Privacy_AllFiles"),
                      "expected the Full Disk Access pane URL, got \(FullDiskAccess.settingsURL)")
    }
}
