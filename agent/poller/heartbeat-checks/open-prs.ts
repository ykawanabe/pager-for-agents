/**
 * open-prs heartbeat check.
 *
 * Surfaces the user's own open PRs that have been quiet for >24h. The intent
 * is the daily digest reminder "PR #42 is still waiting on review, three
 * days now" rather than a wake-the-user ALERT.
 *
 * Safety properties (Design A):
 * - Argv is a static array literal. No string concatenation, no user-
 *   controlled segments. `shell: false` is implicit in Bun.spawn (Bun.spawn
 *   never invokes /bin/sh).
 * - cwd is `mount.path` so `gh` infers the repo from the worktree's
 *   `origin` remote. No `--repo owner/name` flag → no place to inject a
 *   third-party repo URL.
 * - Output is JSON-only (`--json …`). Parse failure returns `error`, never
 *   crashes the run.
 */

import type { CheckHandler, CheckResult, HandlerContext } from "./registry";

interface GhPrRaw {
  number: number;
  title: string;
  url: string;
  updatedAt: string;
  isDraft: boolean;
}

export interface OpenPrsItem {
  number: number;
  title: string;
  url: string;
  ageHours: number;
}

const DEFAULT_TIMEOUT_MS = 10_000;
const STALE_THRESHOLD_HOURS = 24;
const RESULT_LIMIT = 30;

/**
 * Tiny structural alias for the slice of Bun.spawn we use. Lets the tests
 * inject a fake spawn without depending on the full Bun.spawn surface or
 * its Subprocess type (which differs across bun versions).
 */
export interface SpawnLike {
  (opts: {
    cmd: string[];
    cwd?: string;
    stdout: "pipe";
    stderr: "pipe";
    signal?: AbortSignal;
  }): {
    stdout: ReadableStream<Uint8Array> | null;
    stderr: ReadableStream<Uint8Array> | null;
    exited: Promise<number>;
    kill?: (sig?: number | NodeJS.Signals) => void;
    killed?: boolean;
  };
}

export const runOpenPrs: CheckHandler = async (ctx) => {
  return await runWithSpawn(ctx, Bun.spawn as unknown as SpawnLike);
};

/**
 * Test seam: same behavior as runOpenPrs but accepts an injected spawn so
 * unit tests can drive the handler without a real `gh` on PATH. Exported
 * for the test file only; production callers go through `runOpenPrs`.
 */
export async function runWithSpawn(ctx: HandlerContext, spawn: SpawnLike): Promise<CheckResult> {
  const timeoutMs = ctx.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);

  let proc: ReturnType<SpawnLike> | null = null;
  try {
    proc = spawn({
      cmd: [
        "gh", "pr", "list",
        "--author", "@me",
        "--state", "open",
        "--json", "number,title,url,updatedAt,isDraft",
        "--limit", String(RESULT_LIMIT),
      ],
      cwd: ctx.mountPath,
      stdout: "pipe",
      stderr: "pipe",
      signal: ctrl.signal,
    });

    const exitCode = await proc.exited;
    clearTimeout(timer);

    if (ctrl.signal.aborted) {
      return {
        status: "timeout",
        items: [],
        errorMessage: `gh pr list timed out after ${timeoutMs}ms`,
      };
    }

    if (exitCode !== 0) {
      const stderr = proc.stderr ? await new Response(proc.stderr).text() : "";
      return {
        status: "error",
        items: [],
        errorMessage: `gh pr list exited ${exitCode}: ${stderr.trim().slice(0, 200)}`,
      };
    }

    const stdout = proc.stdout ? await new Response(proc.stdout).text() : "";
    let raw: GhPrRaw[];
    try {
      raw = JSON.parse(stdout) as GhPrRaw[];
    } catch (e) {
      return {
        status: "error",
        items: [],
        errorMessage: `gh pr list output parse failed: ${e instanceof Error ? e.message : String(e)}`,
      };
    }
    if (!Array.isArray(raw)) {
      return {
        status: "error",
        items: [],
        errorMessage: `gh pr list returned non-array: ${typeof raw}`,
      };
    }

    const now = Date.now();
    const stale: OpenPrsItem[] = [];
    for (const p of raw) {
      if (p.isDraft) continue;
      const updatedMs = new Date(p.updatedAt).getTime();
      if (Number.isNaN(updatedMs)) continue; // malformed timestamp from gh
      const ageHours = Math.floor((now - updatedMs) / 3_600_000);
      if (ageHours < STALE_THRESHOLD_HOURS) continue;
      stale.push({ number: p.number, title: p.title, url: p.url, ageHours });
    }

    return {
      status: stale.length > 0 ? "ok" : "empty",
      items: stale,
    };
  } finally {
    clearTimeout(timer);
    if (proc && proc.killed === false && proc.kill) {
      try { proc.kill(); } catch { /* race with natural exit, accept */ }
    }
  }
}
