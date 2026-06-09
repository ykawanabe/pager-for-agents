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
 * Schema (version 3 — current, 2026-06-01):
 *   {
 *     "version": 3,
 *     "mounts": [
 *       {
 *         "channel": "telegram",
 *         "thread_id": 42,
 *         "path": "~/projects/iron-flow",
 *         "label": "iron-flow",
 *         "session_id": "uuid-pinned",
 *         "tmux_session": "topic-42",
 *         "created_at": "2026-05-13T03:14:00.000Z",
 *         "digest": { "enabled": true, "sendOnEmpty": false }
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
 * v3 added the optional per-mount `digest` field for H2 daily digest. v2
 * differs only in the absence of `digest`. v1 (legacy) lacks the `channel`
 * field; readMounts stamps `channel: "telegram"` on each row.
 *
 * Read accepts v1, v2, v3. Write always emits v3. The file on disk is left
 * at its original version until the next mutation rewrites it (read is
 * idempotent — background readers don't surprise-write). Unknown per-mount
 * fields (e.g. a hypothetical v4 field) are preserved verbatim through
 * read+write cycles via Mount's [extraField] forward-compat carrier.
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
import type { Channel } from "../channels/types";

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
// The string arm is an opaque per-platform routing slug (Slack/Discord/LINE),
// emitted by the adapter's routingKey() and NEVER field-parsed here — mount-store
// treats it as an atomic key. Telegram keeps the numeric topic_id. "dm"/"*" are
// the cross-platform sentinels. (TS collapses the union to `string | number`; the
// literals are retained for documentation + Telegram-path readability.)
export type ThreadId = number | "dm" | "*" | string;

/**
 * Messaging platform identifier. The canonical definition lives in the
 * ChatTransport contract (`channels/types.ts`) so the storage layer and the
 * transport layer can never drift — re-exported here for mount-store consumers.
 * (P3: the v2 schema already added the explicit `channel` field; this just
 * makes its type authoritative, so a future adapter — discord, etc. — is
 * accepted without a parallel edit here. No schema-version bump needed.)
 */
export type { Channel };

export const DEFAULT_CHANNEL: Channel = "telegram";

/**
 * Per-mount H2 daily-digest config. Absent on a mount → digest disabled for
 * this mount. v3 schema addition (2026-06-01).
 */
export interface DigestConfig {
  enabled: boolean;
  /** When true, send the digest even when the model returned NOTHING_TO_REPORT.
   *  Default false (skip the send entirely on empty days). */
  sendOnEmpty?: boolean;
}

/**
 * Per-mount agentic 秘書 mode (proactive watch-and-act). Absent → off.
 * When enabled alongside `digest`, the daily check's findings are handed to the
 * gated agentic executor (auto-do reversible, ask before risky) instead of just
 * being reported read-only. Additive v3 field — preserved by the forward-compat
 * carrier on read, written verbatim on write (no schema-version bump).
 */
export interface AgenticConfig {
  enabled: boolean;
}

export interface Mount {
  channel: Channel;
  thread_id: ThreadId;
  path: string;
  label?: string;
  session_id: string;
  tmux_session: string;
  created_at: string;
  /** v3: per-mount digest config. Absent → disabled. */
  digest?: DigestConfig;
  /** v3: per-mount agentic (proactive) config. Absent → disabled. */
  agentic?: AgenticConfig;
  /**
   * Forward-compat carrier: any unknown per-mount field read from disk is
   * preserved here and written back verbatim. A future v4 field added by a
   * newer agent will survive a v3 writer (the v3 writer doesn't drop it).
   * Per the autoplan 2026-06-01 finding "all writers upgraded together AND
   * unknown per-mount fields preserved". Typed `unknown` so a careless
   * read of `mount.someFutureField` is a TS error, not a silent any.
   */
  [extraField: string]: unknown;
}

export interface MountsFile {
  version: 3;
  mounts: Mount[];
}

const EMPTY: MountsFile = { version: 3, mounts: [] };

/**
 * Cache / lookup key for cross-channel uniqueness. Two channels can share
 * the same numeric thread_id without colliding (LINE 42 ≠ Telegram 42).
 */
export function mountKey(channel: Channel, thread_id: ThreadId): string {
  return `${channel}:${thread_id}`;
}

/** Opaque-slug acceptance pattern for non-Telegram channels. Filename-safe by
 *  construction: no `/` (used in sessions/<key> + release-flag paths). The `__`
 *  reservation (inject filenames) is the ADAPTER's concern when it composes the
 *  slug in routingKey() — mount-store only guards the storage boundary. */
const THREAD_SLUG_RE = /^[A-Za-z0-9._:-]+$/;

/**
 * Parse a CLI-supplied thread_id into our internal ThreadId type. Channel-aware:
 *   - telegram (default): "dm", "*", or a positive integer (strict — catches typos).
 *   - non-telegram: "dm", "*", or an opaque filename-safe slug (the adapter owns
 *     its composition; mount-store stores it atomically, never field-parses it).
 * Anything else throws — callers should let the error propagate to stderr.
 */
export function parseThreadId(raw: string, channel: Channel = DEFAULT_CHANNEL): ThreadId {
  if (raw === "dm") return "dm";
  if (raw === "*") return "*";
  if (channel === "telegram") {
    const n = Number(raw);
    if (!Number.isFinite(n) || n <= 0 || !Number.isInteger(n)) {
      throw new Error(`invalid thread_id: ${JSON.stringify(raw)} — expected "dm", "*", or a positive integer`);
    }
    return n;
  }
  if (!THREAD_SLUG_RE.test(raw)) {
    throw new Error(`invalid thread_id: ${JSON.stringify(raw)} — expected "dm", "*", or a slug matching ${THREAD_SLUG_RE} (no "/")`);
  }
  return raw;
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
  digest?: DigestConfig;
  // Plus any unknown forward-compat fields.
  [extraField: string]: unknown;
}

interface AnyMountsFile {
  version: 1 | 2 | 3;
  mounts: AnyMount[];
}

/**
 * Read mounts.json and return the v3 in-memory representation. Accepts v1,
 * v2, v3 on read; emits v3 on every write. The file on disk is left at its
 * original version until the next mutation rewrites it (read is idempotent —
 * background readers don't surprise-write).
 *
 * v1 → v3: every row gets `channel: "telegram"` (the only channel that
 * existed in v1). No digest field on legacy rows.
 * v2 → v3: pure schema bump. Rows pass through. No digest field on v2 rows.
 * v3 → v3: identity. digest field round-trips. Unknown per-mount fields
 *          (e.g. a hypothetical v4 field written by a newer agent) are
 *          preserved verbatim — see Mount.[extraField] forward-compat
 *          carrier.
 */
export function readMounts(): MountsFile {
  if (!existsSync(MOUNTS_JSON)) return { version: 3, mounts: [] };
  try {
    const raw = readFileSync(MOUNTS_JSON, "utf8");
    const parsed = JSON.parse(raw) as Partial<AnyMountsFile>;
    if (
      (parsed.version !== 1 && parsed.version !== 2 && parsed.version !== 3) ||
      !Array.isArray(parsed.mounts)
    ) {
      throw new Error("mounts.json: unrecognized schema");
    }
    const mounts: Mount[] = (parsed.mounts as AnyMount[]).map((m) => {
      // Spread first so unknown forward-compat fields survive. Then overlay
      // the known fields with their normalized values. `channel` defaults to
      // telegram for v1 rows. `digest` (v3) round-trips if present.
      const out: Mount = {
        ...m,
        channel: (m.channel as Channel) ?? DEFAULT_CHANNEL,
        thread_id: m.thread_id,
        path: m.path,
        label: m.label,
        session_id: m.session_id,
        tmux_session: m.tmux_session,
        created_at: m.created_at,
      };
      return out;
    });
    return { version: 3, mounts };
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
    };
    data.mounts.push(mount);
    writeMountsAtomic(data);
    return mount;
  });
}

/**
 * Atomic remove-and-add: overwrite any existing mount for the target under a
 * single lock acquisition. Unlike addMount, this never throws on duplicate —
 * it is the duplicate handler.
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
 * Set or clear the H2 digest config on a single mount. Caller passes either
 * the full DigestConfig (sets enabled and sendOnEmpty) or null (removes the
 * field entirely so the row goes back to "digest disabled" — the absence
 * of digest is the canonical disabled state).
 *
 * Returns the updated Mount, or null if no mount with that thread_id+channel
 * exists. Idempotent: calling with the same config is a no-op write (still
 * rewrites the file but produces the same content).
 */
export async function setDigest(args: {
  thread_id: ThreadId;
  channel?: Channel;
  /** null → remove the digest field entirely. */
  digest: DigestConfig | null;
}): Promise<Mount | null> {
  const ch = args.channel ?? DEFAULT_CHANNEL;
  return withLock(() => {
    const data = readMounts();
    const idx = data.mounts.findIndex((m) => sameTarget(m, ch, args.thread_id));
    if (idx < 0) return null;
    const existing = data.mounts[idx];
    const updated: Mount = { ...existing };
    if (args.digest === null) {
      delete updated.digest;
    } else {
      updated.digest = args.digest;
    }
    data.mounts[idx] = updated;
    writeMountsAtomic(data);
    return updated;
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
    writeMountsAtomic({ version: 3, mounts: [] });
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
      // Flags: --tmux-session <name> (alternative to positional)
      // tmux_session positional (4th arg) is used by `cta bind` to pin the
      // current pane's tmux name; absent → defaults to `topic-<thread_id>`.
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
        const m = await addMount({ thread_id: id, path, label, tmux_session });
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
    case "set-digest": {
      // Args: <thread_id> on|off [--send-on-empty]
      // Toggles the v3 digest field on a mount. Off removes the field
      // entirely (digest disabled = canonical absence). `cta digest`
      // shells out to this verb.
      const val = rest[1];
      if (val !== "on" && val !== "off") {
        bail("set-digest: second arg must be 'on' or 'off'");
      }
      try {
        const id = parseThreadId(rest[0] ?? "");
        const sendOnEmpty = rest.includes("--send-on-empty");
        const digest = val === "on" ? { enabled: true, sendOnEmpty } : null;
        const m = await setDigest({ thread_id: id, digest });
        if (m === null) bail(`set-digest: no mount for thread_id ${JSON.stringify(rest[0])}`);
        process.stdout.write(`${JSON.stringify(m)}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    case "clear": {
      await clearMounts();
      process.stdout.write(`${JSON.stringify({ cleared: true })}\n`);
      return;
    }
    default:
      bail(`unknown op: ${op ?? "(none)"}. Try: list, get, add, replace, remove, clear`);
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
