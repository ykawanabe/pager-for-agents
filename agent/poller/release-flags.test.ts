/**
 * Tests for the β handoff flag-file IPC:
 *   - request file <thread>           = "release the daemon"
 *   - ack file     <thread>.ack       = poller's response (released)
 *   - delete ack                       = reacquire (lazy spawn on next message)
 *
 * Strategy: drive the registry directly without the full poller loop. We
 * test the file-state side-effects, not Telegram or network I/O.
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, rmSync, statSync, writeFileSync, renameSync, readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { ClaudeDaemonRegistry } from "./claude-daemon-registry";

const FIXTURE = join(import.meta.dir, "fixtures/fake-claude-daemon.sh");

describe("β handoff flag file IPC", () => {
  let tmpDir: string;
  let flagDir: string;
  let reg: ClaudeDaemonRegistry | null = null;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "pager-relflag-"));
    flagDir = join(tmpDir, "release-flags");
    mkdirSync(flagDir, { recursive: true });
  });

  afterEach(async () => {
    if (reg) { await reg.shutdown(); reg = null; }
    try { rmSync(tmpDir, { recursive: true, force: true }); } catch { /* best effort */ }
  });

  test("flag file rename atomically renames request → .ack", async () => {
    // Sanity test for the file-system protocol we depend on. We use
    // renameSync so the .ack appears atomically — readers polling for
    // it never see a half-written file. Filesystem-level concern, but
    // worth pinning so future changes don't break the contract.
    const requestPath = join(flagDir, "42");
    const ackPath = join(flagDir, "42.ack");
    writeFileSync(requestPath, "");
    expect(existsSync(requestPath)).toBe(true);
    expect(existsSync(ackPath)).toBe(false);

    renameSync(requestPath, ackPath);
    expect(existsSync(requestPath)).toBe(false);
    expect(existsSync(ackPath)).toBe(true);
  });

  test("releaseForTerminal puts daemon in released state, queue accepts new messages silently", async () => {
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: () => {},
      onFlush: () => {},
    });

    reg.enqueue("42", "boot");
    // Wait for spawn + first flush
    await waitFor(() => reg!.daemonCount >= 1, 5000);

    await reg.releaseForTerminal("42");
    expect(reg.getStatus("42")).toBe("released");

    // Subsequent messages should land in the queue silently — flagged
    // via snapshotQueues, not via daemonRegistry.send().
    reg.enqueue("42", "while in TUI");
    const snap = reg.snapshotQueues();
    const entry = snap.find(([t]) => t === "42");
    expect(entry).toBeDefined();
    expect(entry![1]).toContain("while in TUI");
  });

  test("reacquireFromTerminal flips state back, queued messages flush", async () => {
    const flushed: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: () => {},
      onFlush: (_t, combined) => flushed.push(combined),
    });

    reg.enqueue("42", "boot");
    await waitFor(() => flushed.length >= 1, 5000);

    await reg.releaseForTerminal("42");
    expect(reg.getStatus("42")).toBe("released");

    reg.enqueue("42", "queued during TUI");
    // Released → no flush yet.
    await new Promise((r) => setTimeout(r, 200));
    expect(flushed.length).toBe(1); // still just boot

    // Reacquire → debounce + flush of the queued message.
    await reg.reacquireFromTerminal("42");
    await waitFor(() => flushed.length >= 2, 5000);
    expect(flushed[1]).toContain("queued during TUI");
  });

  test("snapshotQueues includes empty queues for visibility into released-but-idle topics", async () => {
    // The poller's processReleaseFlags reads snapshotQueues to find
    // topics in "released" state. Empty queues must still appear so
    // the reacquire branch can see them.
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: () => {},
    });

    reg.enqueue("42", "first");
    await waitFor(() => reg!.daemonCount >= 1, 5000);
    await reg.releaseForTerminal("42");
    // Queue is empty now (first turn flushed before release).
    const snap = reg.snapshotQueues();
    const entry = snap.find(([t]) => t === "42");
    expect(entry).toBeDefined();
    // Don't assert empty — flush timing may leave residue; just confirm
    // the topic is enumerable so processReleaseFlags can find it.
    expect(reg.getStatus("42")).toBe("released");
  });
});

async function waitFor(cond: () => boolean, timeoutMs: number): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > timeoutMs) throw new Error(`waitFor timed out after ${timeoutMs}ms`);
    await new Promise((r) => setTimeout(r, 20));
  }
}
