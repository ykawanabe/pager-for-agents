#!/usr/bin/env bun
/**
 * bind-helper — companion to `cta bind`.
 *
 * Why this exists separately from mount-store.ts: `mount-store add` always
 * generates `tmux_session = "topic-<thread_id>"`. `cta bind` needs to pin
 * the *currently running* tmux session name (whatever the user named their
 * working session) so the poller dispatches into the live claude instead
 * of spawning a new wrapper. This script does the same locked write
 * mount-store does, but with the tmux_session field provided by the caller.
 *
 * Usage (called from scripts/cta):
 *   bun run bind-helper.ts <thread_id|dm> <path> <tmux_session> [label]
 *
 * Output: the mount JSON on stdout, errors on stderr with nonzero exit.
 */
import { readMounts, parseThreadId } from "./mount-store";
import { writeFileSync, openSync, closeSync, fsyncSync, renameSync, unlinkSync, mkdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";

const STATE_DIR = process.env.CTA_STATE_DIR ?? join(homedir(), ".claude-telegram-agent");
const MOUNTS_JSON = join(STATE_DIR, "mounts.json");
const LOCK_FILE = `${MOUNTS_JSON}.lock`;
const STALE_LOCK_MS = 30_000;

async function withLock<T>(fn: () => T): Promise<T> {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  for (let i = 0; i < 200; i++) {
    let fd: number;
    try {
      fd = openSync(LOCK_FILE, "wx", 0o600);
    } catch {
      try {
        const age = Date.now() - statSync(LOCK_FILE).mtimeMs;
        if (age > STALE_LOCK_MS) { unlinkSync(LOCK_FILE); continue; }
      } catch {}
      await new Promise((r) => setTimeout(r, 50));
      continue;
    }
    try { return fn(); }
    finally { closeSync(fd); try { unlinkSync(LOCK_FILE); } catch {} }
  }
  throw new Error("bind-helper: could not acquire mounts.json lock");
}

function writeAtomic(data: unknown): void {
  const tmp = `${MOUNTS_JSON}.tmp.${process.pid}`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeFileSync(fd, `${JSON.stringify(data, null, 2)}\n`);
    fsyncSync(fd);
  } finally { closeSync(fd); }
  renameSync(tmp, MOUNTS_JSON);
}

async function main(): Promise<void> {
  const [rawThread, path, tmuxSession, label] = process.argv.slice(2);
  if (!rawThread || !path || !tmuxSession) {
    process.stderr.write("bind-helper: usage: <thread_id> <path> <tmux_session> [label]\n");
    process.exit(1);
  }
  const thread_id = parseThreadId(rawThread);

  const mount = await withLock(() => {
    const data = readMounts();
    if (data.mounts.some((m) => String(m.thread_id) === String(thread_id))) {
      throw new Error(`thread_id ${thread_id} is already mounted (use \`cta umount\` first)`);
    }
    const m = {
      thread_id,
      path,
      label: label || undefined,
      session_id: randomUUID(),
      tmux_session: tmuxSession,
      created_at: new Date().toISOString(),
    };
    data.mounts.push(m);
    writeAtomic(data);
    return m;
  });

  process.stdout.write(`${JSON.stringify(mount)}\n`);
}

main().catch((e) => {
  process.stderr.write(`bind-helper: ${e instanceof Error ? e.message : String(e)}\n`);
  process.exit(1);
});
