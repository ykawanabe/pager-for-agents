#!/usr/bin/env bun
/**
 * mount-store — read/write helper for $STATE_DIR/mounts.json.
 *
 * Phase 2 introduces dynamic topic mounts (replacing Phase 1's HARDCODED_*
 * env vars). This is the single source of truth that:
 *   - the poller imports to look up routing per message,
 *   - `cta mount/umount/list` shells out to for mutations,
 *   - start_agents.sh iterates to spawn per-topic tmux sessions,
 *   - Pager (Phase 4) reads via `cta list --json`.
 *
 * Why TS instead of bash + `flock`: macOS doesn't ship flock (it's util-linux).
 * We already run on bun for the poller and mcp-telegram; reusing bun keeps
 * the writer logic in one language with proper atomic-rename + a portable
 * O_EXCL-based mutex. Bash callers shell out via `bun run mount-store.ts <op>`.
 *
 * Schema (version 2 — current):
 *   {
 *     "version": 2,
 *     "mounts": [
 *       {
 *         "channel": "telegram",
 *         "thread_id": 42,
 *         "path": "~/projects/iron-flow",
 *         "label": "iron-flow",
 *         "session_id": "uuid-pinned",
 *         "tmux_session": "topic-42",
 *         "created_at": "2026-05-13T03:14:00.000Z"
 *       },
 *       {
 *         "channel": "telegram",
 *         "thread_id": "dm",
 *         "path": "~/claude-home",
 *         ...
 *       }
 *     ]
 *   }
 *
 * Schema v1 (legacy) is the same minus the `channel` field. readMounts
 * auto-upgrades v1 to v2 in memory by stamping `channel: "telegram"` on
 * each row; the file is rewritten to v2 only when a mutation occurs.
 *
 * `channel` is the messaging platform identifier ("telegram" today; "line",
 * "discord", etc. when added). Routing keys are scoped per-channel — two
 * different channels can share the same numeric `thread_id` without
 * collision. Cache lookup key is `<channel>:<thread_id>`.
 *
 * `thread_id` is channel-scoped: for Telegram it's the forum topic_id (or
 * "dm" sentinel for direct messages, or "*" wildcard for catch-all routing).
 * For LINE it will be the group_id / user_id string. The tmux session name
 * is `topic-<thread_id>` by default; collisions across channels are
 * prevented by also including the channel prefix when needed.
 *
 * Concurrency: every mutating op runs inside `withLock` which O_EXCL-opens
 * MOUNTS_JSON.lock. Readers don't lock — the file is replaced atomically
 * via tempfile+rename, so a concurrent reader either sees the old or new
 * version, never a partial write.
 *
 * Stale-lock detection: if the lock file is older than STALE_LOCK_MS we
 * assume the previous writer crashed and steal it. Conservative bound
 * (30s) chosen because no legitimate mutation should take more than a
 * couple ms — anything longer is a stuck process.
 */
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { mountsJson, stateDir } from "../lib/paths";

const STATE_DIR = stateDir();
const MOUNTS_JSON = mountsJson();
const LOCK_FILE = `${MOUNTS_JSON}.lock`;
const STALE_LOCK_MS = 30_000;
const LOCK_RETRY_MS = 50;
const LOCK_RETRY_MAX = 200; // ~10s total

/**
 * Thread identifiers come in three flavors:
 *   - positive integer: a real Telegram forum topic_id
 *   - "dm": sentinel for direct messages (no message_thread_id field)
 *   - "*": wildcard catch-all template. The poller falls back to a "*" mount
 *     when an incoming message hits a thread that has no specific entry,
 *     auto-spawning a real mount with the template's path. Set up at install
 *     time so users get reply-everywhere behavior without /mount-ing each
 *     topic. Specific /mount entries override the wildcard.
 */
export type ThreadId = number | "dm" | "*";

/**
 * Messaging platform identifier. New channels get added here as their
 * adapters land. The string is namespaced storage-side; downstream code
 * matches against this exact value.
 */
export type Channel = "telegram" | "line";

export const DEFAULT_CHANNEL: Channel = "telegram";

export interface Mount {
  channel: Channel;
  thread_id: ThreadId;
  path: string;
  label?: string;
  session_id: string;
  tmux_session: string;
  created_at: string;
  /**
   * Helper-mode marker. When true, the row was written by the poller's
   * spawnHelper path as a placeholder so subsequent messages route to
   * the helper-<thread_id> tmux session. cta mount replaces it with a
   * real entry; gcProvisional drops it if the helper tmux is dead.
   * Absent on all non-helper mounts.
   */
  provisional?: boolean;
}

export interface MountsFile {
  version: 2;
  mounts: Mount[];
}

const EMPTY: MountsFile = { version: 2, mounts: [] };

/**
 * Cache / lookup key for cross-channel uniqueness. Two channels can share
 * the same numeric thread_id without colliding (LINE 42 ≠ Telegram 42).
 */
export function mountKey(channel: Channel, thread_id: ThreadId): string {
  return `${channel}:${thread_id}`;
}

/**
 * Parse a CLI-supplied thread_id into our internal ThreadId type. Accepts
 * the literal string "dm" or any positive integer string. Anything else
 * throws — callers should let the error propagate to stderr.
 */
export function parseThreadId(raw: string): ThreadId {
  if (raw === "dm") return "dm";
  if (raw === "*") return "*";
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0 || !Number.isInteger(n)) {
    throw new Error(`invalid thread_id: ${JSON.stringify(raw)} — expected "dm", "*", or a positive integer`);
  }
  return n;
}

function threadIdsEqual(a: ThreadId, b: ThreadId): boolean {
  return String(a) === String(b);
}

function sameTarget(m: Mount, channel: Channel, thread_id: ThreadId): boolean {
  return m.channel === channel && threadIdsEqual(m.thread_id, thread_id);
}

// ─── locking ────────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function acquireLock(): Promise<number> {
  for (let i = 0; i < LOCK_RETRY_MAX; i++) {
    try {
      // O_EXCL — succeeds iff the file does not exist. Atomic on POSIX.
      return openSync(LOCK_FILE, "wx", 0o600);
    } catch (e) {
      // Stale-lock recovery: if the lock file exists and is older than the
      // bound, assume the previous writer is gone and remove it.
      try {
        const age = Date.now() - statSync(LOCK_FILE).mtimeMs;
        if (age > STALE_LOCK_MS) {
          unlinkSync(LOCK_FILE);
          continue;
        }
      } catch {
        // statSync may race with a legitimate release — fall through to retry.
      }
      await sleep(LOCK_RETRY_MS);
    }
  }
  throw new Error(`mount-store: could not acquire lock at ${LOCK_FILE} after ${LOCK_RETRY_MAX * LOCK_RETRY_MS}ms`);
}

async function withLock<T>(fn: () => Promise<T> | T): Promise<T> {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const fd = await acquireLock();
  try {
    return await fn();
  } finally {
    closeSync(fd);
    try { unlinkSync(LOCK_FILE); } catch { /* already gone */ }
  }
}

// ─── read / write ───────────────────────────────────────────────────────────

interface AnyMount {
  channel?: string;
  thread_id: ThreadId;
  path: string;
  label?: string;
  session_id: string;
  tmux_session: string;
  created_at: string;
  provisional?: boolean;
}

interface AnyMountsFile {
  version: 1 | 2;
  mounts: AnyMount[];
}

/**
 * Read mounts.json and return the v2 in-memory representation, upgrading
 * v1 on the fly. v1 → v2 maps every row to `channel: "telegram"` (the only
 * channel that existed in v1). The file on disk is left as v1 until the
 * next mutation rewrites it; this keeps reads idempotent and avoids
 * surprise writes from background processes.
 */
export function readMounts(): MountsFile {
  if (!existsSync(MOUNTS_JSON)) return { version: 2, mounts: [] };
  try {
    const raw = readFileSync(MOUNTS_JSON, "utf8");
    const parsed = JSON.parse(raw) as Partial<AnyMountsFile>;
    if (
      (parsed.version !== 1 && parsed.version !== 2) ||
      !Array.isArray(parsed.mounts)
    ) {
      throw new Error("mounts.json: unrecognized schema");
    }
    const mounts: Mount[] = (parsed.mounts as AnyMount[]).map((m) => ({
      channel: (m.channel as Channel) ?? DEFAULT_CHANNEL,
      thread_id: m.thread_id,
      path: m.path,
      label: m.label,
      session_id: m.session_id,
      tmux_session: m.tmux_session,
      created_at: m.created_at,
      ...(m.provisional ? { provisional: true } : {}),
    }));
    return { version: 2, mounts };
  } catch (e) {
    throw new Error(`mounts.json: ${e instanceof Error ? e.message : String(e)}`);
  }
}

function writeMountsAtomic(data: MountsFile): void {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const tmp = `${MOUNTS_JSON}.tmp.${process.pid}`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeFileSync(fd, `${JSON.stringify(data, null, 2)}\n`);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, MOUNTS_JSON);
}

// ─── mutations ──────────────────────────────────────────────────────────────

export async function addMount(args: {
  /**
   * Channel defaults to "telegram" so existing Telegram-only callers (cta,
   * poller pre-LINE) keep working without explicit threading.
   */
  channel?: Channel;
  thread_id: ThreadId;
  path: string;
  label?: string;
  /**
   * Optional. Overrides the default `topic-<thread_id>` tmux session
   * name. Set by `cta bind`, which pins the user's currently-running
   * tmux session as the routing target instead of spawning a fresh one.
   */
  tmux_session?: string;
  /**
   * Optional. Marks the row as a helper-mode placeholder (see Mount.provisional).
   * Used by the poller's spawnHelper path; cta mount replaces these with
   * real entries via replaceMount.
   */
  provisional?: boolean;
}): Promise<Mount> {
  const channel = args.channel ?? DEFAULT_CHANNEL;
  return withLock(() => {
    const data = readMounts();
    if (data.mounts.some((m) => sameTarget(m, channel, args.thread_id))) {
      throw new Error(`${channel}:${args.thread_id} is already mounted`);
    }
    const mount: Mount = {
      channel,
      thread_id: args.thread_id,
      path: args.path,
      label: args.label,
      session_id: randomUUID(),
      tmux_session: args.tmux_session ?? `topic-${args.thread_id}`,
      created_at: new Date().toISOString(),
      ...(args.provisional ? { provisional: true } : {}),
    };
    data.mounts.push(mount);
    writeMountsAtomic(data);
    return mount;
  });
}

/**
 * Atomic remove-and-add. The intended use is the helper-mode commit path:
 * `cta mount` detects an existing provisional row and overwrites it with
 * the user-chosen real path under a single lock acquisition. Unlike
 * addMount, this never throws on duplicate — it is the duplicate handler.
 */
export async function replaceMount(args: {
  channel?: Channel;
  thread_id: ThreadId;
  path: string;
  label?: string;
  tmux_session?: string;
}): Promise<Mount> {
  const channel = args.channel ?? DEFAULT_CHANNEL;
  return withLock(() => {
    const data = readMounts();
    const filtered = data.mounts.filter((m) => !sameTarget(m, channel, args.thread_id));
    const mount: Mount = {
      channel,
      thread_id: args.thread_id,
      path: args.path,
      label: args.label,
      session_id: randomUUID(),
      tmux_session: args.tmux_session ?? `topic-${args.thread_id}`,
      created_at: new Date().toISOString(),
    };
    filtered.push(mount);
    writeMountsAtomic({ ...data, mounts: filtered });
    return mount;
  });
}

/**
 * Drop provisional rows whose helper tmux session is dead. Called by the
 * poller at startup to clean up state left behind when a helper crashed,
 * a host rebooted mid-conversation, or `cta umount` partially ran. Real
 * (non-provisional) mounts are never touched. Returns the number dropped.
 *
 * `graceMs` (optional): preserve provisional rows whose `created_at` is
 * within this many ms of now, even if their tmux is dead. Closes D15
 * (cold-boot wipe): after a host reboot every helper-<id> tmux is gone,
 * but the row may have been written seconds ago by spawnHelper. Without
 * a grace window, the user's in-progress helper conversation is wiped.
 * The default (`undefined` / no grace) preserves the original behavior:
 * dead tmux → drop, regardless of age.
 */
export async function gcProvisional(
  isAlive: (tmuxSession: string) => boolean,
  graceMs?: number,
): Promise<number> {
  return withLock(() => {
    const data = readMounts();
    const now = Date.now();
    const kept = data.mounts.filter((m) => {
      if (!m.provisional) return true;
      if (graceMs != null && m.created_at) {
        const age = now - new Date(m.created_at).getTime();
        if (Number.isFinite(age) && age >= 0 && age < graceMs) return true;
      }
      if (!m.tmux_session) return false;
      return isAlive(m.tmux_session);
    });
    const dropped = data.mounts.length - kept.length;
    if (dropped > 0) writeMountsAtomic({ ...data, mounts: kept });
    return dropped;
  });
}

export async function removeMount(
  thread_id: ThreadId,
  channel: Channel = DEFAULT_CHANNEL,
): Promise<Mount | null> {
  return withLock(() => {
    const data = readMounts();
    const idx = data.mounts.findIndex((m) => sameTarget(m, channel, thread_id));
    if (idx < 0) return null;
    const [removed] = data.mounts.splice(idx, 1);
    writeMountsAtomic(data);
    return removed;
  });
}

/**
 * Atomically clear ALL mounts. Used by `cta unpair` (and the poller's
 * /unpair confirm handler) to wipe state on chat reset without bypassing
 * the lock. `rm -f mounts.json` worked but raced with concurrent `cta
 * mount` (mount mid-rename + unpair unlink → torn read). Writing an empty
 * file under withLock is atomic.
 */
export async function clearMounts(): Promise<void> {
  return withLock(() => {
    writeMountsAtomic({ version: 2, mounts: [] });
  });
}

export function findMount(channel: Channel, thread_id: ThreadId): Mount | null {
  return readMounts().mounts.find((m) => sameTarget(m, channel, thread_id)) ?? null;
}

/**
 * Telegram-specific shorthand. Equivalent to `findMount("telegram", id)`.
 * Kept so the existing poller / CLI call sites don't all need a channel
 * argument until LINE work begins.
 */
export function findMountByThreadId(thread_id: ThreadId): Mount | null {
  return findMount(DEFAULT_CHANNEL, thread_id);
}

// ─── CLI entry point ────────────────────────────────────────────────────────
// Bash callers do: `bun run mount-store.ts <op> [args]`. Output is JSON
// (machine-parseable) on stdout, errors to stderr with nonzero exit.

function bail(msg: string): never {
  process.stderr.write(`mount-store: ${msg}\n`);
  process.exit(1);
}

async function main(): Promise<void> {
  const [op, ...rest] = process.argv.slice(2);
  switch (op) {
    case "list": {
      process.stdout.write(`${JSON.stringify(readMounts(), null, 2)}\n`);
      return;
    }
    case "get": {
      try {
        const id = parseThreadId(rest[0] ?? "");
        process.stdout.write(`${JSON.stringify(findMountByThreadId(id))}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    case "add": {
      // Args: <thread_id> <path> [label] [tmux_session]
      // Flags: --provisional, --tmux-session <name> (alternative to positional)
      // tmux_session positional (4th arg) is used by `cta bind` to pin the
      // current pane's tmux name; absent → defaults to `topic-<thread_id>`.
      const provisional = rest.includes("--provisional");
      const tmuxFlagIdx = rest.indexOf("--tmux-session");
      const tmuxFromFlag = tmuxFlagIdx >= 0 ? rest[tmuxFlagIdx + 1] : undefined;
      const positional = rest.filter((a, i) =>
        !a.startsWith("--") && rest[i - 1] !== "--tmux-session"
      );
      const path = positional[1];
      const label = positional[2];
      // Empty 4th arg is treated as "not provided" — callers that want the
      // default `topic-<thread_id>` session name pass "" rather than omitting
      // the arg entirely (preserved for backward-compat with shell-quoting).
      const tmux_session = (tmuxFromFlag || positional[3]) || undefined;
      if (!path) bail("add: path is required");
      try {
        const id = parseThreadId(positional[0] ?? "");
        const m = await addMount({ thread_id: id, path, label, tmux_session, provisional });
        process.stdout.write(`${JSON.stringify(m)}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    case "replace": {
      // Args: <thread_id> <path> [label] [tmux_session]
      const path = rest[1];
      const label = rest[2];
      const tmux_session = rest[3] || undefined;
      if (!path) bail("replace: path is required");
      try {
        const id = parseThreadId(rest[0] ?? "");
        const m = await replaceMount({ thread_id: id, path, label, tmux_session });
        process.stdout.write(`${JSON.stringify(m)}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    case "remove": {
      try {
        const id = parseThreadId(rest[0] ?? "");
        const m = await removeMount(id);
        process.stdout.write(`${JSON.stringify(m)}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    case "gc-provisional": {
      // Optional --grace-ms <N> flag: preserve provisional rows whose
      // created_at is within N ms of now, even if tmux is dead. Used by
      // the poller to ride out cold-boot wipes (D15).
      const graceIdx = rest.indexOf("--grace-ms");
      const graceMs = graceIdx >= 0 ? Number(rest[graceIdx + 1]) : undefined;
      const dropped = await gcProvisional((s) => {
        try {
          const r = Bun.spawnSync(["tmux", "has-session", "-t", s]);
          return r.exitCode === 0;
        } catch {
          return false;
        }
      }, graceMs);
      process.stdout.write(`${JSON.stringify({ dropped })}\n`);
      return;
    }
    case "clear": {
      await clearMounts();
      process.stdout.write(`${JSON.stringify({ cleared: true })}\n`);
      return;
    }
    default:
      bail(`unknown op: ${op ?? "(none)"}. Try: list, get, add, replace, remove, gc-provisional, clear`);
  }
}

// `bun run path/to/mount-store.ts` makes import.meta.main true; importing
// from poller etc. keeps it false (no CLI side effects).
if (import.meta.main) {
  main().catch((e) => {
    process.stderr.write(`mount-store: ${e instanceof Error ? e.stack ?? e.message : String(e)}\n`);
    process.exit(1);
  });
}
