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
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, utimesSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

// ─── env ─────────────────────────────────────────────────────────────────────

const TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const MAIN_CHAT_ID = process.env.MAIN_CHAT_ID; // the one chat we listen to
const HARDCODED_THREAD_ID = process.env.HARDCODED_THREAD_ID; // Phase 1 only
const HARDCODED_TMUX = process.env.HARDCODED_TMUX ?? "topic-1";
const POLL_TIMEOUT_SEC = Number(process.env.POLL_TIMEOUT_SEC ?? "25");

if (!TOKEN || !MAIN_CHAT_ID || !HARDCODED_THREAD_ID) {
  process.stderr.write(
    "poller: TELEGRAM_BOT_TOKEN, MAIN_CHAT_ID, HARDCODED_THREAD_ID must all be set\n"
  );
  process.exit(1);
}

const STATE_DIR = join(homedir(), ".claude-telegram-agent");
const OFFSET_FILE = join(STATE_DIR, "poller-offset");
const HEARTBEAT_FILE = join(STATE_DIR, "heartbeat-poller");
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

/**
 * Phase 1 routing: hardcoded one-topic OR DM mapping. Returns the tmux
 * session name to dispatch to, or null to drop the message. Phase 2 replaces
 * this with a mounts.json lookup.
 *
 * Special value `HARDCODED_THREAD_ID="dm"` accepts DMs (messages with no
 * message_thread_id). Pulled forward from Phase 3 so users without a forum
 * group can smoke-test Phase 1 with their existing bot DM. Phase 3 generalizes
 * this via a real DM mount entry in mounts.json.
 */
function routeMessage(msg: TgMessage): string | null {
  // Lock to the one chat we listen to. allowFrom is checked by the official
  // plugin in v0; here we re-implement chat-level allowlist directly.
  if (String(msg.chat.id) !== String(MAIN_CHAT_ID)) return null;

  const isDmMode = HARDCODED_THREAD_ID === "dm";
  const hasThread = msg.message_thread_id != null;

  if (isDmMode && !hasThread) {
    // Phase 1 DM smoke-test path: any DM in the right chat → HARDCODED_TMUX.
    return HARDCODED_TMUX;
  }
  if (!isDmMode && hasThread && String(msg.message_thread_id) === String(HARDCODED_THREAD_ID)) {
    return HARDCODED_TMUX;
  }
  return null;
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
  process.stdout.write(`[${new Date().toISOString()}] poller starting, offset=${offset}, chat=${MAIN_CHAT_ID}, thread=${HARDCODED_THREAD_ID} → ${HARDCODED_TMUX}\n`);

  for (;;) {
    touchHeartbeat();
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
