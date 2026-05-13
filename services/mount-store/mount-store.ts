#!/usr/bin/env bun
/**
 * mount-store — read/write helper for ~/.claude-telegram-agent/mounts.json.
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
 * Schema (version 1):
 *   {
 *     "version": 1,
 *     "mounts": [
 *       {
 *         "thread_id": 42,
 *         "path": "~/projects/iron-flow",
 *         "label": "iron-flow",
 *         "session_id": "uuid-pinned",
 *         "tmux_session": "topic-42",
 *         "created_at": "2026-05-13T03:14:00.000Z"
 *       }
 *     ],
 *     "dm_mount_path": "~/claude-home"
 *   }
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
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

const STATE_DIR = process.env.CTA_STATE_DIR ?? join(homedir(), ".claude-telegram-agent");
const MOUNTS_JSON = join(STATE_DIR, "mounts.json");
const LOCK_FILE = `${MOUNTS_JSON}.lock`;
const STALE_LOCK_MS = 30_000;
const LOCK_RETRY_MS = 50;
const LOCK_RETRY_MAX = 200; // ~10s total

export interface Mount {
  thread_id: number;
  path: string;
  label?: string;
  session_id: string;
  tmux_session: string;
  created_at: string;
}

export interface MountsFile {
  version: 1;
  mounts: Mount[];
  dm_mount_path?: string;
}

const EMPTY: MountsFile = { version: 1, mounts: [] };

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

export function readMounts(): MountsFile {
  if (!existsSync(MOUNTS_JSON)) return { ...EMPTY };
  try {
    const raw = readFileSync(MOUNTS_JSON, "utf8");
    const parsed = JSON.parse(raw) as Partial<MountsFile>;
    if (parsed.version !== 1 || !Array.isArray(parsed.mounts)) {
      throw new Error("mounts.json: unrecognized schema");
    }
    return {
      version: 1,
      mounts: parsed.mounts as Mount[],
      dm_mount_path: parsed.dm_mount_path,
    };
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
  thread_id: number;
  path: string;
  label?: string;
}): Promise<Mount> {
  return withLock(() => {
    const data = readMounts();
    if (data.mounts.some((m) => m.thread_id === args.thread_id)) {
      throw new Error(`thread_id ${args.thread_id} is already mounted`);
    }
    const mount: Mount = {
      thread_id: args.thread_id,
      path: args.path,
      label: args.label,
      session_id: randomUUID(),
      tmux_session: `topic-${args.thread_id}`,
      created_at: new Date().toISOString(),
    };
    data.mounts.push(mount);
    writeMountsAtomic(data);
    return mount;
  });
}

export async function removeMount(thread_id: number): Promise<Mount | null> {
  return withLock(() => {
    const data = readMounts();
    const idx = data.mounts.findIndex((m) => m.thread_id === thread_id);
    if (idx < 0) return null;
    const [removed] = data.mounts.splice(idx, 1);
    writeMountsAtomic(data);
    return removed;
  });
}

export async function setDmPath(path: string | null): Promise<void> {
  return withLock(() => {
    const data = readMounts();
    if (path === null) delete data.dm_mount_path;
    else data.dm_mount_path = path;
    writeMountsAtomic(data);
  });
}

export function findMountByThreadId(thread_id: number): Mount | null {
  return readMounts().mounts.find((m) => m.thread_id === thread_id) ?? null;
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
      const id = Number(rest[0]);
      if (!Number.isFinite(id)) bail("get: thread_id must be a number");
      const m = findMountByThreadId(id);
      process.stdout.write(`${JSON.stringify(m)}\n`);
      return;
    }
    case "add": {
      const id = Number(rest[0]);
      const path = rest[1];
      const label = rest[2];
      if (!Number.isFinite(id)) bail("add: thread_id must be a number");
      if (!path) bail("add: path is required");
      try {
        const m = await addMount({ thread_id: id, path, label });
        process.stdout.write(`${JSON.stringify(m)}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    case "remove": {
      const id = Number(rest[0]);
      if (!Number.isFinite(id)) bail("remove: thread_id must be a number");
      const m = await removeMount(id);
      process.stdout.write(`${JSON.stringify(m)}\n`);
      return;
    }
    case "dm-set": {
      const path = rest[0];
      if (!path) bail("dm-set: path is required (use dm-clear to remove)");
      await setDmPath(path);
      process.stdout.write("ok\n");
      return;
    }
    case "dm-clear": {
      await setDmPath(null);
      process.stdout.write("ok\n");
      return;
    }
    case "dm-get": {
      process.stdout.write(`${readMounts().dm_mount_path ?? ""}\n`);
      return;
    }
    default:
      bail(`unknown op: ${op ?? "(none)"}. Try: list, get, add, remove, dm-set, dm-clear, dm-get`);
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
