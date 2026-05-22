import XCTest
@testable import ClaudePager

/// The FDA onboarding action: open the Full Disk Access settings pane and reveal
/// the `bun` binary (the agent runtime macOS prompts for) so the user can drag
/// it into the list. The pure bits — which binary to reveal + the pane URL — are
/// unit-tested; the actual NSWorkspace.open is build/manual-verified.
final class FullDiskAccessTests: XCTestCase {

    func test_resolveBun_picksFirstExistingCandidate() {
        let r = FullDiskAccess.resolveBun(candidates: ["/a/bun", "/b/bun"], exists: { $0 == "/b/bun" })
        XCTAssertEqual(r, "/b/bun")
    }

    func test_resolveBun_nilWhenNoneExist() {
        XCTAssertNil(FullDiskAccess.resolveBun(candidates: ["/a/bun"], exists: { _ in false }))
    }

    func test_defaultBunCandidates_prefersDotBunBinFirst() {
        // The prompt named ~/.bun/bin/bun; that's the launchd agent's bun and
        // must be the first candidate we reveal.
        XCTAssertTrue(FullDiskAccess.defaultBunCandidates.first?.hasSuffix("/.bun/bin/bun") ?? false,
                      "expected ~/.bun/bin/bun first, got \(FullDiskAccess.defaultBunCandidates)")
    }

    func test_settingsURL_pointsAtFullDiskAccessPane() {
        XCTAssertTrue(FullDiskAccess.settingsURL.absoluteString.contains("Privacy_AllFiles"),
                      "expected the Full Disk Access pane URL, got \(FullDiskAccess.settingsURL)")
    }
}
