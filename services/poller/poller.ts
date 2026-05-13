#!/usr/bin/env bun
/**
 * poller — single-instance Telegram long-poll loop.
 *
 * Replaces the official plugin's inbound side. The bot has exactly one
 * `getUpdates` consumer (per the Bot API's 409 Conflict rule — concurrent
 * pollers race and silently drop messages). We fan out by `message_thread_id`
 * to per-topic tmux sessions running `claude`.
 *
 * Phase 1 (MVP) carries a hardcoded routing table:
 *   - HARDCODED_THREAD_ID → tmux session `topic-<id>`
 *   - everything else → silently dropped
 * Phase 2 replaces this with mounts.json lookup.
 *
 * Dispatch primitive: `tmux load-buffer` + `paste-buffer -d` + `send-keys Enter`.
 * Settled in eng review (2026-05-13) over send-keys-with-Enter-separators
 * because paste-buffer survives multiline, code blocks, emoji, and quotes
 * without any shell-escaping. The trailing send-keys Enter is the prompt
 * submit; literal newlines in the payload remain literal newlines.
 *
 * Offset persistence: atomic tempfile + fsync + rename, written BEFORE
 * dispatching the batch. Crash-during-dispatch then drops the batch on
 * restart rather than re-delivering it (less surprising for the user than
 * doubled messages).
 *
 * Heartbeat: touches ~/.claude-telegram-agent/heartbeat-poller every loop
 * iteration so the watchdog can detect a hung poller.
 */
import { spawnSync } from "node:child_process";
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, statSync, utimesSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { readMounts, type Mount, type ThreadId } from "../mount-store/mount-store";

// ─── env ─────────────────────────────────────────────────────────────────────

const TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const MAIN_CHAT_ID = process.env.MAIN_CHAT_ID; // the one chat we listen to
const POLL_TIMEOUT_SEC = Number(process.env.POLL_TIMEOUT_SEC ?? "25");

if (!TOKEN || !MAIN_CHAT_ID) {
  process.stderr.write(
    "poller: TELEGRAM_BOT_TOKEN and MAIN_CHAT_ID must be set\n"
  );
  process.exit(1);
}

const STATE_DIR = join(homedir(), ".claude-telegram-agent");
const OFFSET_FILE = join(STATE_DIR, "poller-offset");
const HEARTBEAT_FILE = join(STATE_DIR, "heartbeat-poller");
const MOUNTS_JSON = join(STATE_DIR, "mounts.json");
const API_BASE = `https://api.telegram.org/bot${TOKEN}`;

mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });

// ─── offset persistence ──────────────────────────────────────────────────────

/**
 * Read the last persisted update offset, or 0 if missing/corrupt. The Bot
 * API treats `offset` as "the smallest unseen update id minus 1" — passing
 * 0 means "from the beginning of the queue" (whatever's still in the 24h
 * server-side retention). Acceptable on fresh install.
 */
function readOffset(): number {
  try {
    const raw = readFileSync(OFFSET_FILE, "utf8").trim();
    const n = Number(raw);
    return Number.isFinite(n) && n >= 0 ? n : 0;
  } catch {
    return 0;
  }
}

/**
 * Atomic offset write: tempfile + fsync + rename. fsync forces the kernel
 * to flush the data before the rename publishes it. Without fsync, a sleep
 * or power loss mid-write can leave us with a partially-written tempfile
 * AND a successful rename of an empty file. Belt-and-suspenders.
 */
function writeOffset(value: number): void {
  const tmp = `${OFFSET_FILE}.tmp.${process.pid}`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeFileSync(fd, `${value}\n`);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, OFFSET_FILE);
}

function touchHeartbeat(): void {
  if (!existsSync(HEARTBEAT_FILE)) {
    const fd = openSync(HEARTBEAT_FILE, "w", 0o600);
    closeSync(fd);
  }
  const now = new Date();
  utimesSync(HEARTBEAT_FILE, now, now);
}

// ─── tmux dispatch ───────────────────────────────────────────────────────────

/**
 * Deliver text to a tmux pane. `load-buffer -` reads from stdin; `paste-buffer
 * -d` pastes the buffer into the target pane and deletes it from the buffer
 * stack so successive messages don't pile up. Trailing `send-keys Enter`
 * submits the prompt — claude's TUI treats Enter as "send."
 *
 * Multiline content is pasted as-is (newlines remain newlines, not multiple
 * submits). Code blocks survive. Emoji survives. Quotes survive.
 */
function tmuxDispatch(session: string, text: string): { ok: boolean; stderr: string } {
  const load = spawnSync("tmux", ["load-buffer", "-"], { input: text, encoding: "utf8" });
  if (load.status !== 0) return { ok: false, stderr: `load-buffer: ${load.stderr}` };

  const paste = spawnSync("tmux", ["paste-buffer", "-d", "-t", session], { encoding: "utf8" });
  if (paste.status !== 0) return { ok: false, stderr: `paste-buffer: ${paste.stderr}` };

  const enter = spawnSync("tmux", ["send-keys", "-t", session, "Enter"], { encoding: "utf8" });
  if (enter.status !== 0) return { ok: false, stderr: `send-keys Enter: ${enter.stderr}` };

  return { ok: true, stderr: "" };
}

// ─── update routing ──────────────────────────────────────────────────────────

interface TgUser { id: number; }
interface TgChat { id: number; }
interface TgMessage {
  message_id: number;
  from?: TgUser;
  chat: TgChat;
  message_thread_id?: number;
  text?: string;
  caption?: string;
}
interface TgUpdate {
  update_id: number;
  message?: TgMessage;
  edited_message?: TgMessage;
}
interface TgResp { ok: boolean; result?: TgUpdate[]; description?: string; }

// ─── mounts cache ────────────────────────────────────────────────────────────
// Hot-reload on mtime change so `cta mount/umount` is picked up without
// restarting the poller. Each iteration of the main loop calls
// refreshMountsIfChanged() — bounded work (one stat per loop), no inotify
// dependency, no polling thread.

let mountsCache: Map<string, Mount> = new Map();
let mountsMtimeMs = 0;

function refreshMountsIfChanged(): void {
  let mtimeMs = 0;
  try { mtimeMs = statSync(MOUNTS_JSON).mtimeMs; } catch { /* missing file → mtime stays 0 */ }
  if (mtimeMs === mountsMtimeMs) return;
  try {
    const data = readMounts();
    const next = new Map<string, Mount>();
    for (const m of data.mounts) next.set(String(m.thread_id), m);
    mountsCache = next;
    mountsMtimeMs = mtimeMs;
    process.stdout.write(`[${new Date().toISOString()}] mounts reloaded (${next.size} entries)\n`);
  } catch (e) {
    process.stderr.write(`poller: mounts.json reload failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

/**
 * Look up the tmux session for an incoming message, or null to drop. Routing
 * keys:
 *   - forum topic → mount with thread_id == msg.message_thread_id
 *   - DM (no thread_id) → mount with thread_id == "dm"
 *
 * Chat-level allowlist (MAIN_CHAT_ID) is enforced first — replaces the
 * official plugin's allowFrom semantics in v0.
 */
function routeMessage(msg: TgMessage): string | null {
  if (String(msg.chat.id) !== String(MAIN_CHAT_ID)) return null;
  const key: ThreadId = msg.message_thread_id != null ? msg.message_thread_id : "dm";
  const mount = mountsCache.get(String(key));
  return mount?.tmux_session ?? null;
}

function dispatchUpdate(u: TgUpdate): void {
  const msg = u.message ?? u.edited_message;
  if (!msg) return;
  const target = routeMessage(msg);
  if (!target) return;

  const text = msg.text ?? msg.caption ?? "";
  if (text.length === 0) {
    process.stderr.write(`poller: update ${u.update_id}: empty text/caption, dropping\n`);
    return;
  }

  const r = tmuxDispatch(target, text);
  if (!r.ok) {
    process.stderr.write(`poller: update ${u.update_id}: dispatch to ${target} failed: ${r.stderr}\n`);
  } else {
    process.stdout.write(`[${new Date().toISOString()}] update ${u.update_id} → ${target} (${text.length} chars)\n`);
  }
}

// ─── main loop ───────────────────────────────────────────────────────────────

async function getUpdates(offset: number): Promise<TgUpdate[]> {
  const url = `${API_BASE}/getUpdates?timeout=${POLL_TIMEOUT_SEC}&offset=${offset}`;
  const resp = await fetch(url);
  const json = (await resp.json()) as TgResp;
  if (!json.ok) {
    throw new Error(`getUpdates: ${json.description ?? "(no description)"}`);
  }
  return json.result ?? [];
}

async function main(): Promise<void> {
  let offset = readOffset();
  refreshMountsIfChanged();
  process.stdout.write(`[${new Date().toISOString()}] poller starting, offset=${offset}, chat=${MAIN_CHAT_ID}, mounts=${mountsCache.size}\n`);

  for (;;) {
    touchHeartbeat();
    refreshMountsIfChanged();
    let updates: TgUpdate[];
    try {
      updates = await getUpdates(offset);
    } catch (e) {
      process.stderr.write(`poller: getUpdates failed: ${e instanceof Error ? e.message : String(e)}\n`);
      await new Promise((r) => setTimeout(r, 5_000));
      continue;
    }
    if (updates.length === 0) continue;

    // Persist offset BEFORE dispatching, per eng review: prefer dropping
    // a batch on mid-dispatch crash over re-delivering duplicates.
    const maxId = updates[updates.length - 1].update_id;
    writeOffset(maxId + 1);
    offset = maxId + 1;

    for (const u of updates) {
      dispatchUpdate(u);
    }
  }
}

main().catch((e) => {
  process.stderr.write(`poller: fatal: ${e instanceof Error ? e.stack ?? e.message : String(e)}\n`);
  process.exit(1);
});
