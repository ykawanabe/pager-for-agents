/**
 * Heartbeat check registry — Design A safety model.
 *
 * Each heartbeat check is a hand-written TypeScript handler that queries
 * external state (gh, git, filesystem) via direct `execFile`-style spawns
 * with `shell: false`. There is intentionally no Bash escape hatch: the
 * model that produces the digest runs with `--tools "Read,Glob,Grep"` and
 * has no shell access (Design A "Safety guards").
 *
 * HEARTBEAT.md lists check IDs (one per line). The runner parses the list,
 * dispatches each handler in parallel via `runCheck()`, and feeds the
 * results to the model as stdin JSON.
 *
 * Adding a new check = adding a handler file + one registry entry. Each
 * handler is statically verifiable for safety because there is no shell
 * interpretation between argv and the underlying tool.
 */

import { runOpenPrs } from "./open-prs";

/** Context passed to every handler. Read-only; handlers must not mutate. */
export interface HandlerContext {
  /** mount.path — the worktree the check runs in. Becomes `cwd` for spawns. */
  readonly mountPath: string;
  /** thread_id from mount — used in error messages and log lines only. */
  readonly threadId: string;
  /** Per-handler timeout in ms. Defaults to 10s when omitted. */
  readonly timeoutMs?: number;
}

/** Uniform result shape every handler returns. */
export interface CheckResult {
  /**
   * `ok`      — handler ran, produced ≥1 item worth surfacing.
   * `empty`   — handler ran, no items to surface (the common "nothing today" case).
   * `error`   — handler failed (gh missing, network down, parse error). Non-fatal:
   *             the runner still spawns the model with this result attached.
   * `timeout` — handler exceeded `timeoutMs`. Reported same as error.
   */
  readonly status: "ok" | "empty" | "error" | "timeout";
  /** Items to surface in the digest. Shape is per-handler; the model reads
   *  the JSON via stdin context, not via typed knowledge. */
  readonly items: readonly unknown[];
  /** Human-readable error detail when `status` is `error` or `timeout`. */
  readonly errorMessage?: string;
}

export type CheckHandler = (ctx: HandlerContext) => Promise<CheckResult>;

/**
 * Registry: ID (used in HEARTBEAT.md) → handler. The dispatch layer is
 * intentionally NOT user-extensible at runtime; new checks require a code
 * change so each one passes through review.
 */
export const registry: Readonly<Record<string, CheckHandler>> = Object.freeze({
  "open-prs": runOpenPrs,
});

/**
 * Dispatch a single check by ID. Wraps unknown IDs and thrown errors as
 * non-fatal error results so the model can surface the misconfiguration in
 * the digest without aborting the run. This is the single integration point
 * the runner calls — handlers never appear in dispatch sites directly.
 */
export async function runCheck(id: string, ctx: HandlerContext): Promise<CheckResult> {
  const handler = registry[id];
  if (!handler) {
    return {
      status: "error",
      items: [],
      errorMessage: `unknown check id: ${id} (registry has: ${Object.keys(registry).join(", ")})`,
    };
  }
  try {
    return await handler(ctx);
  } catch (e) {
    return {
      status: "error",
      items: [],
      errorMessage: `${id}: ${e instanceof Error ? e.message : String(e)}`,
    };
  }
}
