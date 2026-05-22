import XCTest
@testable import ClaudePager

/// The agent-launcher mode: when the Pager binary is run as
/// `ClaudePager --agent-launcher <poller.ts>` (by start_agents.sh under
/// launchd), it spawns + supervises `bun <poller.ts>` as a CHILD. Because the
/// launcher binary lives in Claude Pager.app, macOS attributes the bun child's
/// file access to com.claude-pager — so Full Disk Access shows "Claude Pager",
/// not "bun", and nothing third-party is bundled (bun stays on $PATH).
///
/// The pure arg-parsing + bun-resolution are unit-tested; the spawn/signal/wait
/// supervision is integration (verified by running the real launchd job).
final class AgentLauncherTests: XCTestCase {

    func test_isLauncherInvocation_detectsFlag() {
        XCTAssertTrue(AgentLauncher.isLauncherInvocation(["ClaudePager", "--agent-launcher", "/p/poller.ts"]))
        XCTAssertFalse(AgentLauncher.isLauncherInvocation(["ClaudePager"]))
    }

    func test_pollerPath_isArgAfterFlag() {
        XCTAssertEqual(AgentLauncher.pollerPath(from: ["x", "--agent-launcher", "/p/poller.ts"]), "/p/poller.ts")
    }

    func test_pollerPath_nilWhenMissing() {
        XCTAssertNil(AgentLauncher.pollerPath(from: ["x", "--agent-launcher"]))
        XCTAssertNil(AgentLauncher.pollerPath(from: ["x"]))
    }

    func test_resolveBun_firstExisting() {
        XCTAssertEqual(AgentLauncher.resolveBun(candidates: ["/a/bun", "/b/bun"], exists: { $0 == "/b/bun" }), "/b/bun")
        XCTAssertNil(AgentLauncher.resolveBun(candidates: ["/a/bun"], exists: { _ in false }))
    }

    func test_defaultBunCandidates_prefersDotBunBin() {
        XCTAssertTrue(AgentLauncher.defaultBunCandidates.first?.hasSuffix("/.bun/bin/bun") ?? false)
    }
}
