/**
 * Tests for the open-prs heartbeat check handler.
 *
 * Strategy: inject a fake spawn via `runWithSpawn` — no real `gh` binary
 * needed. The injected spawn yields canned stdout/stderr/exit; the test
 * asserts the handler's parse + filter + result shape.
 *
 * Safety-critical assertions (Design A invariants):
 *  - argv is an array literal; no string concatenation, no shell metachars
 *    in any single argv element (a separate sanity check rather than a
 *    full audit — full safety comes from `shell: false`, not from
 *    metachar absence).
 */

import { describe, expect, test } from "bun:test";
import type { HandlerContext } from "./registry";
import { runWithSpawn, type SpawnLike, type OpenPrsItem } from "./open-prs";

function makeCtx(overrides?: Partial<HandlerContext>): HandlerContext {
  return {
    mountPath: "/tmp/fake-mount",
    threadId: "42",
    timeoutMs: 1_000,
    ...overrides,
  };
}

/** Yields a fake Subprocess-shaped object the handler can consume. */
function fakeSpawnReturning(stdout: string, stderr: string, exitCode: number): SpawnLike {
  return ((_opts) => ({
    stdout: new Response(stdout).body,
    stderr: new Response(stderr).body,
    exited: Promise.resolve(exitCode),
    kill: () => {},
    killed: false,
  })) as SpawnLike;
}

/** Returns a fake spawn AND a capture array of cmd[]s it was called with. */
function fakeSpawnCapturing(stdout: string, stderr: string, exitCode: number) {
  const captured: string[][] = [];
  const fn: SpawnLike = ((opts) => {
    captured.push(opts.cmd);
    return {
      stdout: new Response(stdout).body,
      stderr: new Response(stderr).body,
      exited: Promise.resolve(exitCode),
      kill: () => {},
      killed: false,
    };
  }) as SpawnLike;
  return { fn, captured };
}

describe("runWithSpawn — open-prs", () => {
  test("returns ok with items for stale open PRs (>24h, not draft)", async () => {
    const fortyEightHoursAgo = new Date(Date.now() - 48 * 3_600_000).toISOString();
    const json = JSON.stringify([
      { number: 1, title: "Old PR", url: "https://github.com/a/b/pull/1", updatedAt: fortyEightHoursAgo, isDraft: false },
      { number: 2, title: "Draft PR", url: "https://github.com/a/b/pull/2", updatedAt: fortyEightHoursAgo, isDraft: true },
    ]);
    const result = await runWithSpawn(makeCtx(), fakeSpawnReturning(json, "", 0));
    expect(result.status).toBe("ok");
    expect(result.items).toHaveLength(1);
    const item = result.items[0] as OpenPrsItem;
    expect(item.number).toBe(1);
    expect(item.title).toBe("Old PR");
    expect(item.ageHours).toBeGreaterThanOrEqual(48);
  });

  test("returns empty when no PRs cross the 24h threshold", async () => {
    const oneHourAgo = new Date(Date.now() - 1 * 3_600_000).toISOString();
    const json = JSON.stringify([
      { number: 5, title: "Fresh PR", url: "u5", updatedAt: oneHourAgo, isDraft: false },
    ]);
    const result = await runWithSpawn(makeCtx(), fakeSpawnReturning(json, "", 0));
    expect(result.status).toBe("empty");
    expect(result.items).toHaveLength(0);
  });

  test("returns empty for empty PR list", async () => {
    const result = await runWithSpawn(makeCtx(), fakeSpawnReturning("[]", "", 0));
    expect(result.status).toBe("empty");
    expect(result.items).toHaveLength(0);
  });

  test("filters out draft PRs even when stale", async () => {
    const stale = new Date(Date.now() - 72 * 3_600_000).toISOString();
    const json = JSON.stringify([
      { number: 9, title: "Stale draft", url: "u9", updatedAt: stale, isDraft: true },
    ]);
    const result = await runWithSpawn(makeCtx(), fakeSpawnReturning(json, "", 0));
    expect(result.status).toBe("empty");
  });

  test("returns error with stderr excerpt on non-zero exit", async () => {
    const result = await runWithSpawn(
      makeCtx(),
      fakeSpawnReturning("", "gh: not authenticated. Run `gh auth login`.\n", 4),
    );
    expect(result.status).toBe("error");
    expect(result.errorMessage).toContain("exited 4");
    expect(result.errorMessage).toContain("gh auth login");
  });

  test("returns error on malformed JSON output", async () => {
    const result = await runWithSpawn(makeCtx(), fakeSpawnReturning("definitely not json", "", 0));
    expect(result.status).toBe("error");
    expect(result.errorMessage).toContain("parse failed");
  });

  test("returns error on non-array JSON output", async () => {
    const result = await runWithSpawn(makeCtx(), fakeSpawnReturning('{"oops": true}', "", 0));
    expect(result.status).toBe("error");
    expect(result.errorMessage).toContain("non-array");
  });

  test("skips items with unparseable updatedAt without crashing", async () => {
    const stale = new Date(Date.now() - 48 * 3_600_000).toISOString();
    const json = JSON.stringify([
      { number: 1, title: "Bad timestamp", url: "u1", updatedAt: "not-a-date", isDraft: false },
      { number: 2, title: "Good", url: "u2", updatedAt: stale, isDraft: false },
    ]);
    const result = await runWithSpawn(makeCtx(), fakeSpawnReturning(json, "", 0));
    expect(result.status).toBe("ok");
    expect(result.items).toHaveLength(1);
    expect((result.items[0] as OpenPrsItem).number).toBe(2);
  });

  test("argv is a literal array (no string concat, no shell metachars)", async () => {
    const { fn, captured } = fakeSpawnCapturing("[]", "", 0);
    await runWithSpawn(makeCtx(), fn);
    expect(captured).toHaveLength(1);
    const cmd = captured[0];
    // First element is the bin name, not a full command string
    expect(cmd[0]).toBe("gh");
    // Each element individually free of shell metachars (defense-in-depth;
    // shell: false in Bun.spawn already neutralizes them, but the test
    // pins the construction style against future "let me just template
    // this in" regressions).
    for (const arg of cmd) {
      expect(arg).not.toMatch(/[;&|`$<>()]/);
      expect(arg).not.toContain("&&");
      expect(arg).not.toContain("||");
    }
    // Confirm the expected flags are present
    expect(cmd).toContain("--author");
    expect(cmd).toContain("@me");
    expect(cmd).toContain("--state");
    expect(cmd).toContain("open");
    expect(cmd).toContain("--json");
  });

  test("cwd is set to mountPath (so gh infers the repo from the worktree)", async () => {
    let capturedCwd: string | undefined;
    const fn: SpawnLike = ((opts) => {
      capturedCwd = opts.cwd;
      return {
        stdout: new Response("[]").body,
        stderr: new Response("").body,
        exited: Promise.resolve(0),
        kill: () => {},
        killed: false,
      };
    }) as SpawnLike;
    await runWithSpawn(makeCtx({ mountPath: "/some/specific/mount" }), fn);
    expect(capturedCwd).toBe("/some/specific/mount");
  });

  test("aborted (timeout) returns status='timeout'", async () => {
    // Simulate: signal aborts, exit resolves AFTER abort. Real Bun.spawn
    // would reject exited on SIGTERM but our handler treats aborted +
    // any exit as timeout. Mirror that contract here.
    const fn: SpawnLike = ((opts) => ({
      stdout: new Response("").body,
      stderr: new Response("").body,
      exited: new Promise<number>((resolve) => {
        opts.signal?.addEventListener("abort", () => resolve(143), { once: true });
      }),
      kill: () => {},
      killed: false,
    })) as SpawnLike;
    const result = await runWithSpawn(makeCtx({ timeoutMs: 20 }), fn);
    expect(result.status).toBe("timeout");
    expect(result.errorMessage).toContain("timed out");
  });
});
