/**
 * Tests for ClaudeDaemonRegistry — the per-topic long-lived-daemon manager.
 *
 * Responsibilities under test:
 *   - lazy-spawn a ClaudeDaemon on first message for a topic
 *   - 2s debounce: collapse rapid user messages into a single claude turn
 *   - per-topic serialization (queue mid-turn)
 *   - text streaming to the caller's onText callback
 *   - "released for terminal" lifecycle (β handoff)
 *   - crash recovery via the on('crash') hook (with backoff handled inside)
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { ClaudeDaemonRegistry } from "./claude-daemon-registry";

const FIXTURE = join(import.meta.dir, "fixtures/fake-claude-daemon.sh");

describe("ClaudeDaemonRegistry basic dispatch", () => {
  let reg: ClaudeDaemonRegistry | null = null;
  afterEach(async () => { if (reg) { await reg.shutdown(); reg = null; } });

  test("enqueue spawns a daemon on first message + streams text to onText", async () => {
    const texts: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,                       // fast debounce for tests
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: (_thread, t) => texts.push(t),
    });

    reg.enqueue("topic-42", "hello");
    await waitFor(() => texts.length > 0, 5000);

    expect(texts[0]).toBe("You said: hello");
    expect(reg.daemonCount).toBe(1);
  });

  test("subsequent messages reuse the warm daemon (no respawn)", async () => {
    const texts: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: (_thread, t) => texts.push(t),
    });

    reg.enqueue("topic-42", "first");
    await waitFor(() => texts.length >= 1, 5000);
    const firstSpawnCount = reg.spawnedCount;

    reg.enqueue("topic-42", "second");
    await waitFor(() => texts.length >= 2, 5000);

    // Same daemon used for both turns — spawn counter never advanced.
    expect(reg.spawnedCount).toBe(firstSpawnCount);
    expect(reg.daemonCount).toBe(1);
  });

  test("messages to different topics get separate daemons", async () => {
    const texts: Array<{ thread: string; text: string }> = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: (thread, t) => texts.push({ thread, text: t }),
    });

    reg.enqueue("topic-42", "from A");
    reg.enqueue("topic-99", "from B");
    await waitFor(() => texts.length >= 2, 5000);

    expect(reg.daemonCount).toBe(2);
    expect(texts.some((m) => m.thread === "topic-42" && m.text.includes("from A"))).toBe(true);
    expect(texts.some((m) => m.thread === "topic-99" && m.text.includes("from B"))).toBe(true);
  });
});

describe("ClaudeDaemonRegistry debounce", () => {
  let reg: ClaudeDaemonRegistry | null = null;
  afterEach(async () => { if (reg) { await reg.shutdown(); reg = null; } });

  test("rapid consecutive enqueues collapse into one turn (with combined text)", async () => {
    const sentToDaemon: string[] = [];
    const texts: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 300,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: (_t, s) => texts.push(s),
      onFlush: (_t, combinedText) => sentToDaemon.push(combinedText),
    });

    reg.enqueue("topic-42", "first part");
    reg.enqueue("topic-42", "second part");
    reg.enqueue("topic-42", "third part");

    // Wait past debounce window so the flush fires.
    await waitFor(() => sentToDaemon.length > 0, 2000);
    await waitFor(() => texts.length > 0, 5000);

    expect(sentToDaemon.length).toBe(1);
    // Combined text contains all three parts.
    expect(sentToDaemon[0]).toContain("first part");
    expect(sentToDaemon[0]).toContain("second part");
    expect(sentToDaemon[0]).toContain("third part");
    // And only one assistant reply for the whole batch.
    expect(texts.length).toBe(1);
  });

  test("enqueue mid-turn defers the next flush until the turn completes", async () => {
    const sentToDaemon: string[] = [];
    const texts: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp", env: { FAKE_CLAUDE_MODE: "slow" } }),
      onText: (_t, s) => texts.push(s),
      onFlush: (_t, combinedText) => sentToDaemon.push(combinedText),
    });

    // Slow fake claude takes ~1s per turn. Send msg 1, then msg 2 immediately —
    // msg 2 should NOT be sent to claude until msg 1's turn finishes.
    reg.enqueue("topic-42", "msg one");
    await waitFor(() => sentToDaemon.length >= 1, 5000);
    expect(sentToDaemon[0]).toContain("msg one");

    reg.enqueue("topic-42", "msg two");
    // Verify msg 2 doesn't fire while turn 1 still in progress.
    await new Promise((r) => setTimeout(r, 200));
    expect(sentToDaemon.length).toBe(1); // still just msg one

    // Wait for first turn to finish + debounce window for msg 2. Generous
    // ceiling because the fake-claude-daemon shell fixture spawns python3
    // for JSON escaping, and python3's cold-start on macOS under load can
    // stretch each turn well past the "slow"-mode nominal ~1s. Don't
    // tighten this without understanding the fixture's load envelope.
    await waitFor(() => sentToDaemon.length >= 2, 15000);
    expect(sentToDaemon[1]).toContain("msg two");
  });
});

describe("ClaudeDaemonRegistry terminal handoff (β)", () => {
  let reg: ClaudeDaemonRegistry | null = null;
  afterEach(async () => { if (reg) { await reg.shutdown(); reg = null; } });

  test("releaseForTerminal kills daemon + queues incoming messages", async () => {
    const sentToDaemon: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: () => {},
      onFlush: (_t, combinedText) => sentToDaemon.push(combinedText),
    });

    // Spawn the daemon.
    reg.enqueue("topic-42", "boot");
    await waitFor(() => sentToDaemon.length >= 1, 5000);

    await reg.releaseForTerminal("topic-42");
    expect(reg.getStatus("topic-42")).toBe("released");
    expect(reg.daemonCount).toBe(0);

    // Messages during release-for-terminal go into the queue but DON'T fire.
    reg.enqueue("topic-42", "while terminal open");
    await new Promise((r) => setTimeout(r, 300));
    expect(sentToDaemon.length).toBe(1); // unchanged

    // Reacquire respawns daemon + flushes queued messages.
    await reg.reacquireFromTerminal("topic-42");
    await waitFor(() => sentToDaemon.length >= 2, 5000);
    expect(sentToDaemon[1]).toContain("while terminal open");
  });
});

describe("ClaudeDaemonRegistry resetTopic (/clear semantics)", () => {
  let reg: ClaudeDaemonRegistry | null = null;
  afterEach(async () => { if (reg) { await reg.shutdown(); reg = null; } });

  test("resetTopic stops the daemon, drops queue, removes handle (next enqueue lazy-spawns)", async () => {
    let optsCalls = 0;
    const sentToDaemon: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => {
        optsCalls++;
        return { cwd: "/tmp" };
      },
      onText: () => {},
      onFlush: (_t, combinedText) => sentToDaemon.push(combinedText),
    });

    // Spawn the daemon for the topic.
    reg.enqueue("topic-42", "first turn");
    await waitFor(() => sentToDaemon.length >= 1, 5000);
    expect(reg.daemonCount).toBe(1);
    expect(optsCalls).toBe(1);

    // Enqueue something that's still pending (in queue or in flight).
    reg.enqueue("topic-42", "should be dropped by reset");

    // Reset: daemon stopped, queue dropped, handle cleared.
    await reg.resetTopic("topic-42");
    expect(reg.getStatus("topic-42")).toBe("absent");
    expect(reg.daemonCount).toBe(0);

    // Next enqueue must lazy-spawn a NEW daemon — daemonOptsFor called again.
    reg.enqueue("topic-42", "fresh start");
    await waitFor(() => sentToDaemon.length >= 2, 5000);
    expect(optsCalls).toBe(2);
    expect(sentToDaemon[1]).toContain("fresh start");
    expect(sentToDaemon[1]).not.toContain("should be dropped");
  });

  test("resetTopic on unknown thread is a no-op", async () => {
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: () => {},
    });
    await reg.resetTopic("never-existed");
    expect(reg.getStatus("never-existed")).toBe("absent");
  });
});

describe("ClaudeDaemonRegistry crash recovery", () => {
  let reg: ClaudeDaemonRegistry | null = null;
  afterEach(async () => { if (reg) { await reg.shutdown(); reg = null; } });

  test("daemon crash triggers automatic respawn on next enqueue (lazy)", async () => {
    const texts: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp", env: { FAKE_CLAUDE_MODE: "crash-on-turn-2" } }),
      onText: (_t, s) => texts.push(s),
    });

    reg.enqueue("topic-42", "turn 1");
    await waitFor(() => texts.length >= 1, 5000);
    const initialSpawnCount = reg.spawnedCount;

    // Turn 2 makes the fake claude exit 1 after sending its reply.
    reg.enqueue("topic-42", "turn 2 will crash");
    await waitFor(() => texts.length >= 2, 5000);

    // Wait for the crash to settle (state flips to "crashed").
    await waitFor(() => reg.getStatus("topic-42") === "crashed" || reg.getStatus("topic-42") === "idle", 3000);

    // Now the NEXT enqueue should trigger a respawn. Lazy by design —
    // an idle assistant doesn't burn CPU in a respawn loop when claude
    // code is genuinely broken (network down, subscription suspended, etc.).
    reg.enqueue("topic-42", "after crash");
    await waitFor(() => reg.spawnedCount > initialSpawnCount, 5000);

    expect(reg.spawnedCount).toBeGreaterThan(initialSpawnCount);
  });
});

describe("ClaudeDaemonRegistry self-heal (incident 2026-05-21)", () => {
  let reg: ClaudeDaemonRegistry | null = null;
  afterEach(async () => { if (reg) { await reg.shutdown(); reg = null; } });

  test("orphaned 'released' topic self-heals on enqueue after releaseMaxMs (terminal died, never reacquired)", async () => {
    const sentToDaemon: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      releaseMaxMs: 200,                    // short orphan TTL for the test
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: () => {},
      onFlush: (_t, combined) => sentToDaemon.push(combined),
    });

    // Spawn, then release for terminal (Open in Terminal). No reacquire ever
    // arrives — the real incident: the .ack file lingered after the terminal
    // claude exited, so the poller never signaled reacquire.
    reg.enqueue("topic-42", "boot");
    await waitFor(() => sentToDaemon.length >= 1, 5000);
    await reg.releaseForTerminal("topic-42");
    expect(reg.getStatus("topic-42")).toBe("released");

    // A message arriving BEFORE the TTL stays queued and does NOT fire — the
    // terminal might be legitimately in use; we don't yank the daemon back.
    reg.enqueue("topic-42", "early");
    await new Promise((r) => setTimeout(r, 100));
    expect(sentToDaemon.length).toBe(1);
    expect(reg.getStatus("topic-42")).toBe("released");

    // Past the TTL the orphan is assumed abandoned: the next message
    // self-heals (auto-reacquire) and flushes the backlog instead of
    // swallowing it forever.
    await new Promise((r) => setTimeout(r, 200));
    reg.enqueue("topic-42", "after ttl");
    await waitFor(() => sentToDaemon.length >= 2, 5000);
    expect(sentToDaemon[1]).toContain("early");
    expect(sentToDaemon[1]).toContain("after ttl");
  });

  test("inFlight turn that goes silent (no turn-end, no crash) self-heals via inactivity watchdog", async () => {
    const sentToDaemon: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      inFlightTimeoutMs: 300,               // short inactivity window for the test
      daemonOptsFor: () => ({ cwd: "/tmp", env: { FAKE_CLAUDE_MODE: "hang-no-result" } }),
      onText: () => {},
      onFlush: (_t, c) => sentToDaemon.push(c),
    });

    // Turn 1: daemon posts text then hangs with no result event. The registry
    // enters inFlight and — without the watchdog — stays stuck there forever
    // (the General incident: text posted as msg 3012, no turn-end recorded).
    // Gate on onFlush (fires synchronously when the turn is dispatched) rather
    // than on a text event, so the test doesn't race the daemon's stdout.
    reg.enqueue("topic-42", "first");
    await waitFor(() => sentToDaemon.length >= 1, 5000);
    expect(reg.getStatus("topic-42")).toBe("inFlight");
    const spawnsBefore = reg.spawnedCount;

    // Queue a follow-up while inFlight. After inFlightTimeoutMs of silence the
    // watchdog kills the wedged daemon; the crash path respawns and flushes
    // the backlog.
    reg.enqueue("topic-42", "second");
    await waitFor(() => reg.spawnedCount > spawnsBefore, 8000);
    await waitFor(() => sentToDaemon.length >= 2, 8000);
    expect(sentToDaemon[1]).toContain("second");
  });
});

// ─── helpers ─────────────────────────────────────────────────────────────────

async function waitFor(cond: () => boolean, timeoutMs: number): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > timeoutMs) throw new Error(`waitFor timed out after ${timeoutMs}ms`);
    await new Promise((r) => setTimeout(r, 20));
  }
}
