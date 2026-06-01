/**
 * Persisted scheduler state for H2 daily digest.
 *
 * The scheduler MUST know "did we already fire for this thread today?" across
 * poller restarts (launchd respawn, install.sh, manual cta restart all happen
 * in normal operation — observed 3-30/day on the live host). In-memory state
 * is reset on every restart; an FS-event or reminder-time that lands inside
 * the restart window would otherwise re-fire.
 *
 * Shape on disk:
 *   {
 *     "version": 1,
 *     "firedToday": {
 *       "<threadId>:<YYYY-MM-DD>": <epoch_ms>,  // when we fired for that day
 *       ...
 *     }
 *   }
 *
 * Per-day key is `<threadId>:<YYYY-MM-DD>`. The date is computed in the
 * user's configured timezone (not system local) so a flight LAX→NRT mid-day
 * doesn't fire twice on the wall-clock "today" or skip a fire entirely.
 *
 * Write contract: BEFORE the runner spawns. A crash during the runner means
 * "already done today" — that's correct: don't retry the same day, the user
 * can `cta digest dry-run` for a manual retry.
 *
 * Atomic write: temp file + fsync + rename + parent-dir fsync. Tolerates
 * SIGKILL between any two steps (intermediate state is invalid and old file
 * is intact). Corrupted state (partial / unparseable JSON) → treat as empty
 * and rewrite on next markFiredToday.
 */

import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync, writeSync, existsSync, unlinkSync } from "node:fs";
import { dirname } from "node:path";
import { heartbeatStateFile } from "../../lib/paths";

export interface HeartbeatState {
  readonly version: 1;
  readonly firedToday: Readonly<Record<string, number>>;
}

const EMPTY_STATE: HeartbeatState = Object.freeze({ version: 1, firedToday: {} });

/** Compose the per-day dedupe key. Date format MUST be ISO YYYY-MM-DD so
 *  string sort = chronological sort (lets us prune old keys lexicographically). */
export function dayKey(threadId: string, ymd: string): string {
  return `${threadId}:${ymd}`;
}

/** Read state from disk. Corrupted / missing / wrong-version → empty state. */
export function readState(path = heartbeatStateFile()): HeartbeatState {
  if (!existsSync(path)) return EMPTY_STATE;
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return EMPTY_STATE;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return EMPTY_STATE;
  }
  if (!parsed || typeof parsed !== "object") return EMPTY_STATE;
  const obj = parsed as { version?: unknown; firedToday?: unknown };
  if (obj.version !== 1) return EMPTY_STATE;
  if (!obj.firedToday || typeof obj.firedToday !== "object") {
    return { version: 1, firedToday: {} };
  }
  // Filter values to numbers (defensive; ignore malformed entries).
  const clean: Record<string, number> = {};
  for (const [k, v] of Object.entries(obj.firedToday as Record<string, unknown>)) {
    if (typeof v === "number" && Number.isFinite(v)) clean[k] = v;
  }
  return { version: 1, firedToday: clean };
}

/** Write state atomically: write to temp, fsync, rename, fsync parent dir.
 *  A crash between any two steps leaves either the old file intact or a
 *  visible new file — never a partial line. */
export function writeState(state: HeartbeatState, path = heartbeatStateFile()): void {
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${path}.tmp.${process.pid}`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeSync(fd, JSON.stringify(state) + "\n");
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, path);
  // fsync the parent directory so the rename is durable. On macOS APFS the
  // parent-dir fsync is required for the rename to survive a power loss
  // (rename is atomic vs partial-write, not vs vanish-on-crash).
  try {
    const dfd = openSync(dir, "r");
    try { fsyncSync(dfd); } finally { closeSync(dfd); }
  } catch {
    // Directory fsync isn't supported on every filesystem; best-effort.
  }
}

/** Has this thread already fired today (in the user's TZ)? */
export function alreadyFiredToday(state: HeartbeatState, threadId: string, ymd: string): boolean {
  return Object.prototype.hasOwnProperty.call(state.firedToday, dayKey(threadId, ymd));
}

/** Record a fire and return the new state. Caller persists via writeState.
 *  Splitting the in-memory mutation from the disk write lets the scheduler
 *  do `state = markFiredToday(state, …); writeState(state)` as a single
 *  atomic-from-the-scheduler's-view operation. */
export function markFiredToday(state: HeartbeatState, threadId: string, ymd: string, when = Date.now()): HeartbeatState {
  return {
    version: 1,
    firedToday: { ...state.firedToday, [dayKey(threadId, ymd)]: when },
  };
}

/** Remove keys older than `keepDays` (default 30). Prevents the state file
 *  from growing unbounded across years of operation. Run from housekeep
 *  once per day max (cheap enough but no reason to do it every tick). */
export function pruneOldKeys(state: HeartbeatState, todayYmd: string, keepDays = 30): HeartbeatState {
  // YMD is ISO sortable, so we can compute a cutoff key prefix and drop
  // anything lexicographically earlier.
  const todayMs = parseYmd(todayYmd);
  if (todayMs === null) return state;
  const cutoffMs = todayMs - keepDays * 86_400_000;
  const cutoffYmd = formatYmd(new Date(cutoffMs));
  const kept: Record<string, number> = {};
  for (const [key, value] of Object.entries(state.firedToday)) {
    const colonIdx = key.lastIndexOf(":");
    if (colonIdx < 0) continue; // malformed key, drop
    const keyYmd = key.slice(colonIdx + 1);
    if (keyYmd >= cutoffYmd) kept[key] = value;
  }
  return { version: 1, firedToday: kept };
}

/** Parse "YYYY-MM-DD" → epoch ms at UTC midnight. Returns null on malformed. */
function parseYmd(ymd: string): number | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(ymd)) return null;
  const ms = Date.parse(ymd + "T00:00:00Z");
  return Number.isFinite(ms) ? ms : null;
}

/** Format Date → "YYYY-MM-DD" in UTC. Internal helper; for user-TZ-aware
 *  formatting see quiet-hours.ts:`todayInTz`. */
function formatYmd(d: Date): string {
  return d.toISOString().slice(0, 10);
}

/** Test-only helper: forcibly delete the state file. Production code goes
 *  through writeState. */
export function _resetStateForTest(path = heartbeatStateFile()): void {
  try { unlinkSync(path); } catch { /* already absent */ }
}
