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
 * Heartbeat: touches $STATE_DIR/heartbeat-poller every loop
 * iteration so the watchdog can detect a hung poller.
 */
import { spawnSync } from "node:child_process";
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, statSync, unlinkSync, utimesSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import { addMount, gcProvisional, mountKey, readMounts, removeMount, type Mount, type ThreadId } from "../mount-store/mount-store";

// Poller-side cache key for Telegram updates. Hardcoded "telegram" because
// this file is the Telegram adapter; the LINE adapter (when added) will
// build keys with "line" instead.
function tgKey(thread_id: ThreadId): string {
  return mountKey("telegram", thread_id);
}
import { markTypingActive, runTypingKeepalive } from "./typing-keepalive";
import { stateDir, pollerOffsetFile, heartbeatFile, mountsJson, pairingCodeFile, pairedStateFile, topicsJson, sessionsDir, installAgentDir, installMountStoreTs } from "../lib/paths";

// ─── env ─────────────────────────────────────────────────────────────────────

// Env reads happen lazily so importing this module for tests doesn't require
// a real bot token. Tests override CTA_STATE_DIR to redirect state files
// and TELEGRAM_API_BASE to route outbound calls at a mock server.

const ENV_MAIN_CHAT_ID = process.env.MAIN_CHAT_ID; // optional Phase 2 override
const POLL_TIMEOUT_SEC = Number(process.env.POLL_TIMEOUT_SEC ?? "25");

const STATE_DIR = stateDir();
const OFFSET_FILE = pollerOffsetFile();
const HEARTBEAT_FILE = heartbeatFile();
const MOUNTS_JSON = mountsJson();
const PAIRING_CODE_FILE = pairingCodeFile();
const PAIRED_STATE_FILE = pairedStateFile();
// Pager writes the ack-reaction toggle here as `ackReaction: "👀"` (or absent
// for "off"). Single source of truth — Pager-driven config the poller reads.
const ACCESS_JSON = process.env.ACCESS_JSON ?? join(homedir(), ".claude/channels/telegram/access.json");
// Topic-name cache: poller writes, Pager reads. Updated when we see a
// forum_topic_created / forum_topic_edited service message fly past. Key is
// "<chat_id>/<message_thread_id>" so multi-chat installs don't collide on
// numeric thread ids.
const TOPICS_JSON = topicsJson();

function getApiBase(): string {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN must be set");
  return process.env.TELEGRAM_API_BASE ?? `https://api.telegram.org/bot${token}`;
}

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

// ─── paired state ────────────────────────────────────────────────────────────
// Phase 3 zero-config onboarding: instead of MAIN_CHAT_ID in .env, the user
// pairs the bot in-chat by sending `/pair <code>`. The poller writes the
// resulting chat_id + user_id to paired.json. MAIN_CHAT_ID env (Phase 2
// holdover) is honored as a fallback for users upgrading from the manual
// flow — paired.json wins if both exist.

interface PairedState {
  version: 1;
  chat_id: number;
  user_id: number;
  paired_at: string;
  chat_title?: string;
}

let pairedCache: PairedState | null = null;
let pairedMtimeMs = 0;

function refreshPairedIfChanged(): void {
  let mtimeMs = 0;
  try { mtimeMs = statSync(PAIRED_STATE_FILE).mtimeMs; } catch { /* missing */ }
  if (mtimeMs === pairedMtimeMs) return;
  try {
    if (mtimeMs === 0) {
      pairedCache = null;
    } else {
      const raw = readFileSync(PAIRED_STATE_FILE, "utf8");
      const parsed = JSON.parse(raw) as PairedState;
      if (parsed.version !== 1) throw new Error("paired.json: unknown version");
      pairedCache = parsed;
    }
    pairedMtimeMs = mtimeMs;
    process.stdout.write(`[${new Date().toISOString()}] paired state reloaded (${pairedCache ? `chat=${pairedCache.chat_id} user=${pairedCache.user_id}` : "unpaired"})\n`);
  } catch (e) {
    process.stderr.write(`poller: paired.json reload failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

function writePairedAtomic(state: PairedState): void {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const tmp = `${PAIRED_STATE_FILE}.tmp.${process.pid}`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeFileSync(fd, `${JSON.stringify(state, null, 2)}\n`);
    fsyncSync(fd);
  } finally { closeSync(fd); }
  renameSync(tmp, PAIRED_STATE_FILE);
}

function effectiveChatId(): string | null {
  if (pairedCache) return String(pairedCache.chat_id);
  if (ENV_MAIN_CHAT_ID) return ENV_MAIN_CHAT_ID;
  return null;
}

function effectiveUserId(): number | null {
  return pairedCache?.user_id ?? null;
}

// ─── outbound reply ──────────────────────────────────────────────────────────
// Direct Bot API call for command replies. Separate from mcp-telegram, which
// is per-topic and only reachable from claude. The poller needs its own
// outbound for `/pair`/`/mount` confirmations — no claude in the loop.

async function reply(
  target: { chat_id: number | string; thread_id?: number },
  text: string,
): Promise<void> {
  const body: Record<string, unknown> = { chat_id: target.chat_id, text };
  if (target.thread_id != null) body.message_thread_id = target.thread_id;
  try {
    const resp = await fetch(`${getApiBase()}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const json = (await resp.json()) as { ok: boolean; description?: string };
    if (!json.ok) {
      process.stderr.write(`poller: reply failed: ${json.description ?? "(no description)"}\n`);
    }
  } catch (e) {
    process.stderr.write(`poller: reply fetch failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

// ─── ack reaction (👀) + typing indicator ────────────────────────────────────
// Two lightweight UX signals fired on every dispatched message:
//   1. setMessageReaction with a configurable emoji ("seen" signal).
//      Toggle controlled by access.json's `ackReaction` field. Pager writes it;
//      poller reads it. Empty / absent = no reaction.
//   2. sendChatAction "typing" so the user sees the bot "typing..." while
//      claude is composing the reply. Telegram auto-clears typing at 5s, so
//      a per-target keepalive loop re-fires it every ~4s. mcp-telegram clears
//      the marker file after a successful sendMessage, which stops the loop.
//      See typing-keepalive.ts.

let ackReactionCache: string | null = null;
let accessMtimeMs = 0;

function refreshAckReactionIfChanged(): void {
  let mtimeMs = 0;
  try { mtimeMs = statSync(ACCESS_JSON).mtimeMs; } catch { /* missing */ }
  if (mtimeMs === accessMtimeMs) return;
  accessMtimeMs = mtimeMs;
  if (mtimeMs === 0) { ackReactionCache = null; return; }
  try {
    const raw = readFileSync(ACCESS_JSON, "utf8");
    const parsed = JSON.parse(raw) as { ackReaction?: unknown };
    const v = typeof parsed.ackReaction === "string" ? parsed.ackReaction.trim() : "";
    ackReactionCache = v.length > 0 ? v : null;
    process.stdout.write(`[${new Date().toISOString()}] ack reaction reloaded: ${ackReactionCache ?? "(off)"}\n`);
  } catch (e) {
    process.stderr.write(`poller: access.json read failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

async function reactToMessage(chat_id: number, message_id: number): Promise<void> {
  if (!ackReactionCache) return; // toggled off
  try {
    await fetch(`${getApiBase()}/setMessageReaction`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id,
        message_id,
        reaction: [{ type: "emoji", emoji: ackReactionCache }],
      }),
    });
    // Telegram returns ok:false for invalid emojis (free-bot whitelist). Don't
    // surface — just skip silently; the operator picks emoji via Pager UI.
  } catch (e) {
    process.stderr.write(`poller: setMessageReaction failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

// ─── topic name cache ────────────────────────────────────────────────────────
// Bot API has no getForumTopic / getForumTopicByID, so the only way to learn
// a forum topic's user-set name is to observe forum_topic_created or
// forum_topic_edited service messages as they fly past. We persist what we
// see to topics.json so the Pager UI can display "topic 42 (Plans)" instead
// of bare "topic 42".
//
// Limitation surfaced in Pager UI: topics created BEFORE the bot joined the
// group are invisible — until someone renames them (forum_topic_edited fires).

interface TopicsFile {
  version: 1;
  topics: Record<string, { name: string; captured_at: string }>;
}

function readTopics(): TopicsFile {
  try {
    const raw = readFileSync(TOPICS_JSON, "utf8");
    const parsed = JSON.parse(raw) as TopicsFile;
    if (parsed.version === 1 && typeof parsed.topics === "object") return parsed;
  } catch { /* missing or unparseable — start empty */ }
  return { version: 1, topics: {} };
}

function writeTopics(data: TopicsFile): void {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const tmp = `${TOPICS_JSON}.tmp.${process.pid}`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeFileSync(fd, JSON.stringify(data, null, 2) + "\n");
    fsyncSync(fd);
  } finally { closeSync(fd); }
  renameSync(tmp, TOPICS_JSON);
}

/** Record a topic name observed from a forum_topic_{created,edited} service
 * message. Keyed by `<chat_id>/<thread_id>` so the same numeric thread id in
 * different chats doesn't collide. No-ops if name is empty. */
function recordTopicName(chat_id: number, thread_id: number, name: string): void {
  const key = `${chat_id}/${thread_id}`;
  const trimmed = name.trim();
  if (!trimmed) return;
  const data = readTopics();
  const existing = data.topics[key];
  if (existing?.name === trimmed) return; // no change; skip the disk write
  data.topics[key] = { name: trimmed, captured_at: new Date().toISOString() };
  try {
    writeTopics(data);
    process.stdout.write(`[${new Date().toISOString()}] topic name captured: ${key} → ${trimmed}\n`);
  } catch (e) {
    process.stderr.write(`poller: topics.json write failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

async function sendTyping(chat_id: number, thread_id?: number): Promise<void> {
  const body: Record<string, unknown> = { chat_id, action: "typing" };
  if (thread_id != null) body.message_thread_id = thread_id;
  try {
    await fetch(`${getApiBase()}/sendChatAction`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (e) {
    process.stderr.write(`poller: sendChatAction failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

// Tunables. Defaults: 4s between fires (Telegram clears typing at 5s, so this
// leaves ~1s of overlap), 10 minutes hard cap so a crashed mcp-telegram can't
// leave the loop spinning forever. Env overrides exist for tests + operator
// tuning; production should leave them alone.
const TYPING_INTERVAL_MS = Number(process.env.TYPING_INTERVAL_MS ?? "4000");
const TYPING_MAX_MS = Number(process.env.TYPING_MAX_MS ?? `${10 * 60_000}`);

/**
 * Writes the per-target marker, then runs the keepalive loop. Fire-and-
 * forget from the caller's perspective — the loop returns when the marker
 * is cleared (by mcp-telegram on reply), replaced (by a newer dispatch
 * taking over), or the hard cap elapses.
 */
async function startTypingKeepalive(chat_id: number, thread_id?: number): Promise<void> {
  const token = markTypingActive(STATE_DIR, chat_id, thread_id);
  await runTypingKeepalive({
    stateDir: STATE_DIR,
    chatId: chat_id,
    threadId: thread_id,
    token,
    send: () => sendTyping(chat_id, thread_id),
    intervalMs: TYPING_INTERVAL_MS,
    maxMs: TYPING_MAX_MS,
  });
}

// ─── tmux dispatch ───────────────────────────────────────────────────────────

/**
 * Deliver text to a tmux pane. `load-buffer -b <name> -` reads from stdin into
 * a NAMED buffer; `paste-buffer -b <name> -d -t <session>` pastes it into the
 * target pane and deletes the named buffer afterward.
 *
 * Why named: the default (unnamed) tmux buffer is server-wide. Two concurrent
 * dispatches targeting different sessions race — call B's load-buffer can
 * overwrite the default before call A's paste-buffer fires, so A's pane
 * receives B's text. A unique buffer name per call eliminates the race
 * structurally regardless of which processes might race (poller, watchdog
 * kick, cta send, helper spawn).
 *
 * Trailing `send-keys Enter` submits the prompt — claude's TUI treats Enter
 * as "send." Multiline content, code blocks, emoji, quotes all survive the
 * paste-buffer transport (it preserves bytes verbatim).
 */
function tmuxDispatch(session: string, text: string): { ok: boolean; stderr: string } {
  const buf = `pager-${session}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;

  const load = spawnSync("tmux", ["load-buffer", "-b", buf, "-"], { input: text, encoding: "utf8" });
  if (load.status !== 0) return { ok: false, stderr: `load-buffer: ${load.stderr}` };

  const paste = spawnSync("tmux", ["paste-buffer", "-b", buf, "-d", "-t", session], { encoding: "utf8" });
  if (paste.status !== 0) {
    // Cleanup the orphaned named buffer if paste failed (load already created it).
    spawnSync("tmux", ["delete-buffer", "-b", buf], { encoding: "utf8" });
    return { ok: false, stderr: `paste-buffer: ${paste.stderr}` };
  }

  const enter = spawnSync("tmux", ["send-keys", "-t", session, "Enter"], { encoding: "utf8" });
  if (enter.status !== 0) return { ok: false, stderr: `send-keys Enter: ${enter.stderr}` };

  return { ok: true, stderr: "" };
}

// ─── auto-pair via bot invite (Phase 5) ──────────────────────────────────────
// Replaces "user must type /pair <code>" with "bot detects when it's added
// to a chat, sends an inline-keyboard prompt asking the inviter to confirm".
// The user never copies a code — Telegram already tells us who invited the
// bot, we just ask them to tap a button.

let botUserId: number | null = null; // captured from preflight (getMe)
let pendingPair: { chat_id: number; inviter_user_id: number; expires_at: number } | null = null;
const PENDING_PAIR_TTL_MS = 5 * 60 * 1000; // 5 minutes

interface TgChatMemberUpdated {
  chat: { id: number; title?: string };
  from: { id: number; first_name?: string; username?: string };
  new_chat_member: { user: { id: number; is_bot: boolean }; status: string };
  old_chat_member: { user: { id: number; is_bot: boolean }; status: string };
}

interface TgCallbackQuery {
  id: string;
  from: { id: number; first_name?: string };
  message?: { chat: { id: number }; message_id: number; message_thread_id?: number; text?: string };
  data?: string;
}

/**
 * Edit a sent message's text in-place. Per Telegram Bot API semantics, omitting
 * reply_markup also drops any inline keyboard attached to the original — so
 * one call covers "append the user's choice + remove the buttons" for a
 * send_telegram(buttons=...) prompt the user just answered. Best-effort: if
 * the edit fails, the worst outcome is a stale button — not a delivery loss.
 */
async function editMessageText(
  chat_id: number,
  message_id: number,
  text: string,
): Promise<void> {
  try {
    await fetch(`${getApiBase()}/editMessageText`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id, message_id, text }),
    });
  } catch (e) {
    process.stderr.write(`poller: editMessageText failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

async function sendInlineKeyboard(
  chat_id: number,
  text: string,
  buttons: Array<Array<{ text: string; callback_data: string }>>,
): Promise<{ message_id: number } | null> {
  try {
    const resp = await fetch(`${getApiBase()}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id, text, reply_markup: { inline_keyboard: buttons } }),
    });
    const json = (await resp.json()) as { ok: boolean; result?: { message_id: number }; description?: string };
    if (!json.ok) {
      process.stderr.write(`poller: sendInlineKeyboard failed: ${json.description}\n`);
      return null;
    }
    return json.result ?? null;
  } catch (e) {
    process.stderr.write(`poller: sendInlineKeyboard fetch failed: ${e instanceof Error ? e.message : String(e)}\n`);
    return null;
  }
}

async function answerCallback(callback_query_id: string, text?: string, alert?: boolean): Promise<void> {
  try {
    await fetch(`${getApiBase()}/answerCallbackQuery`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ callback_query_id, text, show_alert: alert ?? false }),
    });
  } catch (e) {
    process.stderr.write(`poller: answerCallback failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

/**
 * Telegram fires this when the bot's status in a chat changes. We care about
 * the case where the bot was just added (old status ∈ {left,kicked} →
 * new status ∈ {member,administrator}) AND we don't have a paired chat yet.
 */
export async function handleMyChatMember(mcm: TgChatMemberUpdated): Promise<void> {
  if (mcm.new_chat_member.user.id !== botUserId) return; // not us
  const oldS = mcm.old_chat_member.status;
  const newS = mcm.new_chat_member.status;
  const justAdded = (oldS === "left" || oldS === "kicked") &&
                    (newS === "member" || newS === "administrator");
  if (!justAdded) {
    // Other transitions: log if interesting (kicked from paired chat etc).
    if ((newS === "kicked" || newS === "banned") && pairedCache?.chat_id === mcm.chat.id) {
      process.stderr.write(`poller: WARNING bot was ${newS} from paired chat ${mcm.chat.id}. Operator should investigate.\n`);
    }
    return;
  }
  if (pairedCache) {
    await reply(
      { chat_id: mcm.chat.id },
      [
        "I'm already paired with another chat — I can't claim two at once.",
        "",
        "To re-pair with this chat instead:",
        "  • In the existing paired chat, send `/unpair confirm`, OR",
        "  • Run `cta unpair` on the host.",
        "Then kick + re-add me here and send `/pair <CODE>` (get it via `cta pair-code` on the host).",
      ].join("\n"),
    );
    return;
  }
  // Deterministic pairing flow: ask the user to send `/pair <code>` rather
  // than the inline-keyboard callback_query dance. The callback flow depended
  // on bot membership state being settled (callback_query delivery requires
  // the bot to see the user's tap), which created a chicken-and-egg with
  // privacy/admin caches in forum groups — failing pairs left the bot
  // unpairable without a kick+re-add cycle. /pair <code> is a `/command`,
  // which Telegram delivers even to non-admin privacy-enabled bots.
  // Group-vs-DM: in groups, Telegram caches the bot's "privacy mode" at
  // invite time. If privacy was on when the bot was added, only `/commands`
  // come through — plain text gets dropped server-side. Admin status
  // overrides this cache. So for groups, tell the user explicitly.
  const isGroup = mcm.chat.id < 0; // negative chat_id = group / supergroup / channel
  const introLines = [
    "👋 Hi! To finish setup:",
    "",
    "1. On your Mac, run: `cta pair-code`",
    "2. Send the code back here as: `/pair YOUR-CODE`",
  ];
  if (isGroup) {
    introLines.push(
      "",
      "⚠ For me to see plain text in this group, please promote me to admin (any minimal permission works). Without admin, I only see /commands.",
    );
  }
  introLines.push(
    "",
    "Already paired with another chat? Just send `/pair` here (no code needed) and I'll switch.",
  );
  await reply({ chat_id: mcm.chat.id }, introLines.join("\n"));
  process.stdout.write(`[${new Date().toISOString()}] pair intro sent: chat=${mcm.chat.id} inviter=${mcm.from.id}${isGroup ? " (group)" : ""}\n`);
}

export async function handleCallbackQuery(cb: TgCallbackQuery): Promise<void> {
  if (!cb.data) { await answerCallback(cb.id); return; }

  // Inline-keyboard answer to a send_telegram(buttons=...) prompt. callback_data
  // shape: `ans:<thread_id>:<label>` (thread_id is "dm" or a numeric forum
  // topic). We synthesize a TgMessage carrying the label and route it through
  // the normal dispatch path — claude sees it exactly as if the user had typed
  // the option text. The paired-user check matches the same enforcement
  // routeMessage applies to typed messages.
  if (cb.data.startsWith("ans:")) {
    if (!pairedCache || cb.from.id !== pairedCache.user_id) {
      await answerCallback(cb.id, "Only the paired user can answer.", true);
      return;
    }
    if (!cb.message) { await answerCallback(cb.id); return; }
    const rest = cb.data.slice(4);
    const colonIdx = rest.indexOf(":");
    if (colonIdx < 0) { await answerCallback(cb.id); return; }
    const tidStr = rest.slice(0, colonIdx);
    const label = rest.slice(colonIdx + 1);
    const thread_id = tidStr === "dm" ? undefined : Number(tidStr);
    await answerCallback(cb.id);
    // Immediate visual ack: append the chosen label to the original prompt
    // and drop the inline keyboard (one editMessageText call does both per
    // Bot API semantics). User sees "↳ <choice>" the instant they tap, even
    // while claude is still composing a reply.
    const originalText = cb.message.text ?? "";
    void editMessageText(cb.message.chat.id, cb.message.message_id, `${originalText}\n\n↳ ${label}`);
    await dispatchUpdate({
      update_id: 0,
      message: {
        message_id: cb.message.message_id,
        from: { id: cb.from.id },
        chat: { id: cb.message.chat.id },
        message_thread_id: thread_id,
        text: label,
      },
    });
    return;
  }

  // Pending pair expired or never set → tell the user and ack the callback.
  if (!pendingPair || pendingPair.expires_at < Date.now()) {
    pendingPair = null;
    await answerCallback(cb.id, "That prompt has expired. Remove and re-add me to try again.", true);
    return;
  }
  // Only the original inviter can answer.
  if (cb.from.id !== pendingPair.inviter_user_id) {
    await answerCallback(cb.id, "Only the user who invited me can confirm.", true);
    return;
  }

  if (cb.data === "pair-confirm") {
    const state: PairedState = {
      version: 1,
      chat_id: pendingPair.chat_id,
      user_id: pendingPair.inviter_user_id,
      paired_at: new Date().toISOString(),
    };
    writePairedAtomic(state);
    pairedCache = state;
    try { pairedMtimeMs = statSync(PAIRED_STATE_FILE).mtimeMs; } catch { /* ignore */ }
    pendingPair = null;
    await ensureWildcardMount();
    await answerCallback(cb.id, "Paired!");
    if (cb.message) {
      await reply(
        { chat_id: cb.message.chat.id },
        [
          "✓ Paired with this chat. Only you can issue commands from now on.",
          "",
          "Any message you send in a topic auto-routes to claude. To bind a topic to a specific Mac directory, send `/mount ~/path` in that topic.",
        ].join("\n"),
      );
    }
    process.stdout.write(`[${new Date().toISOString()}] auto-pair confirmed: chat=${state.chat_id} user=${state.user_id}\n`);
  } else if (cb.data === "pair-cancel") {
    pendingPair = null;
    await answerCallback(cb.id, "Pairing cancelled.");
    if (cb.message) {
      await reply(
        { chat_id: cb.message.chat.id },
        "Pairing cancelled. Remove me and re-add when you're ready, or use `/pair <code>` (run `cta pair-code` on the host to see it).",
      );
    }
  }
}

/** Test hook so unit tests can stage the bot's user id without preflight. */
export function _setBotUserIdForTest(id: number | null): void { botUserId = id; }

/**
 * Ensure a wildcard mount (`thread_id = "*"`) exists pointing at CLAUDE_CWD.
 * Called after auto-pair confirm and /pair success — without this, a
 * fresh-paired chat has no mounts.json entry, so the very first message
 * arrives, finds nothing in routeMessage, and silently drops. install.sh
 * creates the wildcard on first install but `cta unpair` clears mounts.json
 * (without --keep-mounts), so the next re-pair would start empty.
 */
async function ensureWildcardMount(): Promise<void> {
  const cwd = process.env.CLAUDE_CWD;
  if (!cwd) return; // nothing to default to; user must `cta mount` manually
  const current = readMounts();
  if (current.mounts.some((m) => m.thread_id === "*")) return;
  try {
    await addMount({ thread_id: "*", path: cwd, label: "default" });
    process.stdout.write(`[${new Date().toISOString()}] wildcard mount auto-created: * → ${cwd}\n`);
  } catch (e) {
    process.stderr.write(`poller: wildcard mount auto-create failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

// ─── mount-helper (auto-mount) ───────────────────────────────────────────────
// When an unmounted topic receives a message AND no wildcard exists AND the
// kill-switch is unset, spawn a one-shot helper claude in $HOME. Helper finds
// a real project directory via send_telegram conversation, then commits via
// `cta mount`. Cancellation: user sends `/cancel`. Cleanup: gcOrphanedProvisionals
// runs at startup to drop rows whose helper tmux is dead.

const HELPER_DISABLED = process.env.PAGER_DISABLE_HELPER === "1";

function tmuxHasSession(name: string): boolean {
  return spawnSync("tmux", ["has-session", "-t", name], { encoding: "utf8" }).status === 0;
}

function readTopicNameFromCache(thread_id: number | "dm"): string | null {
  if (thread_id === "dm") return null;
  try {
    const cache = readTopics();
    const chat = effectiveChatId();
    if (!chat) return null;
    const key = `${chat}/${thread_id}`;
    return cache.topics?.[key]?.name ?? null;
  } catch {
    return null;
  }
}

async function sendImmediateAck(thread_id: number | "dm", topic_name: string | null): Promise<void> {
  const chat_id = effectiveChatId();
  if (!chat_id) return;
  const text = topic_name
    ? `Looking for projects matching "${topic_name}"…`
    : "Setting up this topic — what project should it point to?";
  const body: Record<string, unknown> = { chat_id, text };
  if (typeof thread_id === "number") body.message_thread_id = thread_id;
  try {
    await fetch(`${getApiBase()}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (e) {
    process.stderr.write(`poller: sendImmediateAck failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

async function spawnHelper(thread_id: number | "dm"): Promise<string | null> {
  if (HELPER_DISABLED) return null;
  const tmuxSession = `helper-${thread_id}`;

  // Idempotent: existing helper tmux means a helper is already mid-conversation.
  if (tmuxHasSession(tmuxSession)) return tmuxSession;

  const topicName = readTopicNameFromCache(thread_id);
  // Immediate ack first — claude cold-start takes ~5-15s; without this the
  // user stares at silence and assumes the bot is dead.
  await sendImmediateAck(thread_id, topicName);

  const home = process.env.HOME ?? "/tmp";
  try {
    await addMount({
      thread_id,
      path: home,
      label: topicName ?? `helper-${thread_id}`,
      tmux_session: tmuxSession,
      provisional: true,
    });
  } catch (e) {
    process.stderr.write(`poller: spawnHelper addMount failed for ${thread_id}: ${e instanceof Error ? e.message : String(e)}\n`);
    return null;
  }

  const servicesDir = process.env.MOUNT_STORE_PATH
    ? join(process.env.MOUNT_STORE_PATH, "..", "..")
    : installAgentDir();
  const wrapperPath = join(servicesDir, "topic-wrapper.sh");
  const cmd = [wrapperPath, String(thread_id), home, tmuxSession, "helper"]
    .map((arg) => `'${arg.replace(/'/g, "'\\''")}'`)
    .join(" ");

  // Pass PAGER_TOPIC_NAME through tmux's send-environment list isn't reliable;
  // simpler to wrap the cmd in `env PAGER_TOPIC_NAME=...` so it gets to the
  // helper-wrapper without polluting the poller's environment.
  const safeName = (topicName ?? "").replace(/'/g, "'\\''");
  const cmdWithEnv = `env PAGER_TOPIC_NAME='${safeName}' ${cmd}`;

  spawnSync("tmux", ["kill-session", "-t", tmuxSession], { encoding: "utf8" });
  const newSession = spawnSync(
    "tmux",
    ["new-session", "-d", "-s", tmuxSession, cmdWithEnv],
    { encoding: "utf8" },
  );
  if (newSession.status !== 0) {
    process.stderr.write(`poller: spawnHelper tmux new-session failed for ${thread_id}: ${newSession.stderr}\n`);
    // Roll back the provisional mount so a retry can re-attempt cleanly.
    try { await removeMount(thread_id); } catch { /* best effort */ }
    return null;
  }

  refreshMountsIfChanged();
  process.stdout.write(`[${new Date().toISOString()}] mount-helper spawned: thread ${thread_id} → ${tmuxSession} (topic_name=${topicName ?? "(unknown)"})\n`);
  return tmuxSession;
}

// Grace window for cold-boot resilience (D15): after a host reboot every
// helper-<id> tmux is dead, but provisional rows may have been written
// seconds ago by spawnHelper before the reboot. Without grace, the user's
// in-progress helper conversation gets wiped at poller startup. 10 min
// is a balance: long enough to survive a normal reboot cycle (login,
// LaunchAgent startup, mount of $HOME, etc.) but short enough that
// genuinely abandoned helpers don't accumulate forever. Override via
// PAGER_PROVISIONAL_GRACE_MS env if needed.
const PROVISIONAL_GRACE_MS = Number(process.env.PAGER_PROVISIONAL_GRACE_MS ?? `${10 * 60_000}`);

async function gcOrphanedProvisionals(): Promise<void> {
  try {
    const dropped = await gcProvisional((s) => tmuxHasSession(s), PROVISIONAL_GRACE_MS);
    if (dropped > 0) {
      process.stdout.write(`[${new Date().toISOString()}] poller: gc dropped ${dropped} orphaned provisional mount(s)\n`);
      refreshMountsIfChanged();
    }
  } catch (e) {
    process.stderr.write(`poller: gcOrphanedProvisionals failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

// /clear over Telegram: rotate the per-topic session UUID and kill the
// topic's tmux session. The watchdog (kick_dead_topic_sessions) and the
// wrapper's restart loop respawn claude with the new UUID, so the next
// message starts a fresh conversation.
//
// Why we own this rather than forwarding to claude TUI: /clear is caught
// by the TUI layer, never reaches the model. Forwarding via tmux send-keys
// would clear claude's context but produce no send_telegram call — typing-
// keepalive would run to its 10-min cap with no user-visible feedback.
// We own the semantic so the user gets an explicit ack.
async function handleClear(msg: TgMessage): Promise<void> {
  const chat_id = msg.chat.id;
  const thread_id_raw = msg.message_thread_id;
  const key: number | "dm" = thread_id_raw != null ? thread_id_raw : "dm";
  const mount = mountsCache.get(tgKey(key));

  if (!mount) {
    await reply(
      { chat_id, thread_id: thread_id_raw },
      "Nothing to clear — no mount in this topic. Send a message to start a mount-helper session, or `cta mount` from your Mac.",
    );
    return;
  }

  if (mount.provisional) {
    await reply(
      { chat_id, thread_id: thread_id_raw },
      "This topic is in mount-helper mode (no project session running yet). Send `/cancel` to abort the helper instead.",
    );
    return;
  }

  // Rotate per-topic session UUID. topic-wrapper.sh reads this file at
  // each restart and resumes whatever UUID is there — a fresh UUID means
  // no --resume → fresh claude session.
  const sessFile = join(sessionsDir(), String(key));
  const newUuid = randomUUID();
  try {
    mkdirSync(sessionsDir(), { recursive: true });
    writeFileSync(sessFile, newUuid + "\n");
  } catch (e) {
    process.stderr.write(`poller: handleClear UUID rotate failed: ${e instanceof Error ? e.message : String(e)}\n`);
    await reply(
      { chat_id, thread_id: thread_id_raw },
      "Couldn't rotate the session UUID. Run `cta start` from your Mac to recover.",
    );
    return;
  }

  // Kill the topic tmux session. kick_dead_topic_sessions (watchdog) or
  // the wrapper's own restart loop will respawn it; new claude reads the
  // rotated UUID file and starts fresh.
  const targetSession = mount.tmux_session ?? `topic-${key}`;
  spawnSync("tmux", ["kill-session", "-t", targetSession], { encoding: "utf8" });

  await reply(
    { chat_id, thread_id: thread_id_raw },
    "Cleared. New session starting — first reply may take 5–15s while claude cold-starts.",
  );
}

async function handleCancel(msg: TgMessage): Promise<void> {
  const chat_id = msg.chat.id;
  const thread_id_raw = msg.message_thread_id;
  const key: number | "dm" = thread_id_raw != null ? thread_id_raw : "dm";
  const mount = mountsCache.get(tgKey(key));
  if (!mount?.provisional) {
    await reply(
      { chat_id, thread_id: thread_id_raw },
      "Nothing to cancel — this topic isn't in mount-helper mode.",
    );
    return;
  }
  const helperSession = mount.tmux_session ?? `helper-${key}`;
  spawnSync("tmux", ["kill-session", "-t", helperSession], { encoding: "utf8" });
  try {
    await removeMount(key);
  } catch (e) {
    process.stderr.write(`poller: handleCancel removeMount failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
  refreshMountsIfChanged();
  await reply(
    { chat_id, thread_id: thread_id_raw },
    "Cancelled. Send any message here to start over, or use `cta mount` from your Mac to point this topic at a project directly.",
  );
}

// ─── in-chat commands (Phase 3) ──────────────────────────────────────────────
// The bot listens for /pair, /mount, /unmount, /list, /help in any message.
// Pre-pair state: only /pair <code> accepted, from any chat — once it matches
// the pairing code, we claim that chat as MAIN_CHAT_ID and that user as the
// allowlisted operator. Post-pair: only commands from the paired user are
// honored; everything else falls through to normal claude dispatch.

async function handlePair(msg: TgMessage, args: string): Promise<void> {
  if (!msg.from) return; // channel post; can't pair

  // Already-paired path: same operator (user_id) can re-pair anywhere with
  // no code — they've already proven ownership. /pair in a new chat just
  // switches the bot to that chat. /pair in the same chat is a no-op.
  if (pairedCache) {
    if (msg.from.id !== pairedCache.user_id) {
      // Different user trying to claim while paired. Stay silent.
      return;
    }
    if (msg.chat.id === pairedCache.chat_id) {
      await reply(
        { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
        "✓ Already paired here. Send any message to talk to claude.",
      );
      return;
    }
    // Switch to this chat. Old topic-* sessions still have the previous
    // chat_id pinned in their mcp-telegram env, so kill them — they'll
    // respawn on next dispatch via auto-respawn, picking up the new
    // paired.json's chat_id.
    const previousChatId = pairedCache.chat_id;
    const newState: PairedState = { ...pairedCache, chat_id: msg.chat.id, paired_at: new Date().toISOString() };
    writePairedAtomic(newState);
    pairedCache = newState;
    pairedMtimeMs = statSync(PAIRED_STATE_FILE).mtimeMs;
    killAllTopicSessions();
    await ensureWildcardMount();
    await reply(
      { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
      `✓ Switched to this chat (was chat ${previousChatId}). Send any message to talk to claude.`,
    );
    return;
  }

  // First-time pairing: requires a matching code from `cta pair-code`.
  let storedCode = "";
  try { storedCode = readFileSync(PAIRING_CODE_FILE, "utf8").trim(); } catch { /* fall through */ }
  if (!storedCode) {
    // No code on disk → either pairing already happened (and code was consumed)
    // or install hasn't run pair-code --init. Don't reveal which: stay silent.
    return;
  }
  const supplied = args.trim().toUpperCase();
  if (supplied !== storedCode.toUpperCase()) {
    await reply(
      { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
      "Pairing code did not match. Lost it? Run `cta pair-code --reset` on the host.",
    );
    return;
  }
  // Match. Claim this chat + user, persist, delete the consumed code.
  const newState: PairedState = {
    version: 1,
    chat_id: msg.chat.id,
    user_id: msg.from.id,
    paired_at: new Date().toISOString(),
  };
  writePairedAtomic(newState);
  try { unlinkSync(PAIRING_CODE_FILE); } catch { /* already gone */ }
  pairedCache = newState;
  pairedMtimeMs = statSync(PAIRED_STATE_FILE).mtimeMs;
  await ensureWildcardMount();
  await reply(
    { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
    "✓ Paired. Send any message to talk to claude. To switch chats later, just send /pair in the new chat.",
  );
}

/** Kill every tmux session named `topic-*`. Used when the paired chat
 * changes so stale mcp-telegram env (chat_id pinned at spawn) gets dropped
 * and the next message re-spawns with the current paired chat_id. */
function killAllTopicSessions(): void {
  const ls = spawnSync("tmux", ["list-sessions", "-F", "#{session_name}"], { encoding: "utf8" });
  if (ls.status !== 0) return; // no tmux server, nothing to kill
  const names = ls.stdout.split("\n").filter((n) => n.startsWith("topic-"));
  for (const name of names) {
    spawnSync("tmux", ["kill-session", "-t", name], { encoding: "utf8" });
  }
  if (names.length > 0) {
    process.stdout.write(`[${new Date().toISOString()}] killed ${names.length} topic-* session(s) on pair switch\n`);
  }
}

async function handleMount(msg: TgMessage, args: string): Promise<void> {
  const path = args.trim().replace(/^~/, homedir());
  if (!path) {
    await reply({ chat_id: msg.chat.id, thread_id: msg.message_thread_id }, "Usage: `/mount <path>` — e.g. `/mount ~/projects/iron-flow`");
    return;
  }
  if (!existsSync(path) || !statSync(path).isDirectory()) {
    await reply(
      { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
      `Path \`${path}\` is not a directory on the Mac. Check spelling and that it exists locally.`,
    );
    return;
  }
  const thread_id = msg.message_thread_id ?? null;
  if (thread_id == null) {
    await reply(
      { chat_id: msg.chat.id },
      "Send `/mount` inside a forum topic, or use `/dm <path>` here in DM.",
    );
    return;
  }
  // Reuse the mount-store CLI via subprocess — keeps the locking single-sourced.
  const storePath = process.env.MOUNT_STORE_PATH ?? installMountStoreTs();
  const r = spawnSync("bun", ["run", storePath, "add", String(thread_id), path], { encoding: "utf8" });
  if (r.status !== 0) {
    await reply(
      { chat_id: msg.chat.id, thread_id },
      `Mount failed: ${(r.stderr ?? "").trim() || "(no error)"}`,
    );
    return;
  }
  await reply(
    { chat_id: msg.chat.id, thread_id },
    [
      `✓ Mounted thread ${thread_id} → ${path}`,
      ``,
      `Send any message in this topic to start the claude session. \`cta start\` may be needed on the host if no poller is live yet (this one is, so you should be good).`,
    ].join("\n"),
  );
  // Trigger an immediate mounts.json reload (mtime-based; poller will pick
  // it up on next iter anyway, but explicit refresh shortens the window).
  refreshMountsIfChanged();
}

async function handleDm(msg: TgMessage, args: string): Promise<void> {
  // Equivalent to /mount but pins thread_id="dm" sentinel.
  const path = args.trim().replace(/^~/, homedir());
  if (!path) {
    await reply({ chat_id: msg.chat.id }, "Usage: `/dm <path>` — sets the DM mount to the given Mac path.");
    return;
  }
  if (!existsSync(path) || !statSync(path).isDirectory()) {
    await reply({ chat_id: msg.chat.id }, `Path \`${path}\` is not a directory on the Mac.`);
    return;
  }
  const storePath = process.env.MOUNT_STORE_PATH ?? installMountStoreTs();
  const r = spawnSync("bun", ["run", storePath, "add", "dm", path], { encoding: "utf8" });
  if (r.status !== 0) {
    await reply({ chat_id: msg.chat.id }, `DM mount failed: ${(r.stderr ?? "").trim()}`);
    return;
  }
  await reply({ chat_id: msg.chat.id }, `✓ DM mount → ${path}. Send any message here to start the claude session.`);
  refreshMountsIfChanged();
}

async function handleUnmount(msg: TgMessage): Promise<void> {
  const thread_id = msg.message_thread_id;
  const key = thread_id != null ? String(thread_id) : "dm";
  const storePath = process.env.MOUNT_STORE_PATH ?? installMountStoreTs();
  const r = spawnSync("bun", ["run", storePath, "remove", key], { encoding: "utf8" });
  if (r.status !== 0) {
    await reply({ chat_id: msg.chat.id, thread_id }, `Unmount failed: ${(r.stderr ?? "").trim()}`);
    return;
  }
  if ((r.stdout ?? "").trim() === "null") {
    await reply({ chat_id: msg.chat.id, thread_id }, `Thread ${key} was not mounted.`);
    return;
  }
  await reply({ chat_id: msg.chat.id, thread_id }, `✓ Unmounted thread ${key}.`);
  refreshMountsIfChanged();
}

async function handleList(msg: TgMessage): Promise<void> {
  const data = readMounts();
  if (data.mounts.length === 0) {
    await reply({ chat_id: msg.chat.id, thread_id: msg.message_thread_id }, "No mounts yet. Send `/mount <path>` in a topic to add one.");
    return;
  }
  // Join with topics.json so users see "thread 42 (Plans)" instead of bare
  // "thread 42". Mirrors cta list's TOPIC column. Topics created before the
  // bot joined the group remain anonymous until renamed — Telegram API gap.
  const topics = readTopics().topics;
  const chatId = pairedCache?.chat_id;
  const isGroup = chatId !== undefined && chatId < 0;
  const lines = data.mounts.map((m) => {
    let nameSuffix = "";
    if (typeof m.thread_id === "number" && chatId !== undefined) {
      const cachedName = topics[`${chatId}/${m.thread_id}`]?.name;
      if (cachedName) nameSuffix = ` "${cachedName}"`;
    } else if (m.thread_id === "dm" && isGroup) {
      // In a group, "dm" mount catches messages from the General topic
      // (Telegram omits message_thread_id for General). Label it as such
      // so users don't see "DM" in a group context.
      nameSuffix = ` "General"`;
    }
    return `• thread ${m.thread_id}${nameSuffix} → ${m.path}${m.label ? ` (${m.label})` : ""}`;
  });
  await reply({ chat_id: msg.chat.id, thread_id: msg.message_thread_id }, `Current mounts:\n${lines.join("\n")}`);
}

// Telegram-convention: every bot's first-touch UX is /start. Telegram clients
// auto-send /start when a user opens a new bot chat. Without a handler the
// bot looks dead to a first-time user.
async function handleStart(msg: TgMessage): Promise<void> {
  if (pairedCache) {
    if (msg.from?.id === pairedCache.user_id) {
      // Paired owner came back. Just remind them of available commands.
      return handleHelp(msg);
    }
    // Random user opened the paired bot. Stay silent — don't leak that
    // anything exists.
    return;
  }
  // Unpaired. Tell them how to claim it.
  await reply(
    { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
    [
      "👋 Hi. I'm a claude-code Telegram proxy waiting to be paired.",
      "",
      "If you installed me, your host should have shown an 8-char pairing code.",
      "Send `/pair YOUR-CODE` here to claim me.",
      "",
      "Lost the code? Run `cta pair-code --reset` on the host and try again.",
    ].join("\n"),
  );
}

async function handleUnpair(msg: TgMessage, args: string): Promise<void> {
  // Two-step confirmation. `/unpair confirm` actually releases; bare /unpair
  // just explains. Prevents accidental release if someone fat-fingers the
  // command in a busy chat.
  if (args.trim().toLowerCase() !== "confirm") {
    await reply(
      { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
      [
        "Unpair releases this chat so a different chat can claim the bot.",
        "Mounts are wiped. To proceed, send: `/unpair confirm`",
        "",
        "Or run `cta unpair` on the host (with --keep-mounts to preserve mounts).",
      ].join("\n"),
    );
    return;
  }
  // Release.
  try { unlinkSync(PAIRED_STATE_FILE); } catch { /* already gone */ }
  try { unlinkSync(MOUNTS_JSON); } catch { /* already gone */ }
  pairedCache = null;
  pairedMtimeMs = 0;
  refreshMountsIfChanged();
  await reply(
    { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
    "✓ Unpaired. Re-add me to a chat for the auto-pair prompt, or send `/pair <code>` (run `cta pair-code` on the host).",
  );
}

async function handleHelp(msg: TgMessage): Promise<void> {
  await reply(
    { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
    [
      "Commands:",
      "  /mount <path>   — bind THIS forum topic to a project dir on the Mac",
      "  /dm <path>      — bind your DM with the bot to a project dir",
      "  /unmount        — remove the mount for THIS topic (or DM)",
      "  /list           — show current mounts",
      "  /unpair confirm — release this chat so another can claim me",
      "  /help           — this message",
      "",
      "Any non-command message is forwarded to the claude session for that mount.",
    ].join("\n"),
  );
}

// Claude Code's own slash commands that open modal UI, terminate the
// session, or otherwise produce no chat reply. If we forward these to the
// claude tmux pane, they either get stuck on a modal that swallows
// subsequent input or silently change session state. Intercept here and
// tell the user. Unknown `/foo` not in this set still falls through —
// that's how user skills (e.g. `/qa`, `/codex`) work over Telegram.
// `/clear` is intentionally NOT here — it has a dedicated handler
// (handleClear) that rotates the session UUID and respawns the topic.
// See D14 in docs/plans/multi-topic-stability-plan.md for why blocklist-
// only handling is unsafe (typing-keepalive runs to 10min cap).
const CLAUDE_BUILTIN_BLOCKLIST = new Set([
  "/status", "/config", "/agents", "/permissions", "/model",
  "/output-style", "/init",
  "/exit", "/quit", "/logout", "/login",
]);

async function handleClaudeBuiltin(msg: TgMessage, command: string): Promise<void> {
  await reply(
    { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
    `\`${command}\` is a Claude Code local UI command and can't run over Telegram. Use the bot's commands (\`/help\`) or send any message to talk to Claude.`,
  );
}

/**
 * Attempt to handle a message as an in-chat command. Returns true if the
 * message was consumed by command handling (so normal tmux dispatch should
 * be skipped). Returns false to fall through to normal routing.
 *
 * Pre-pair: only /pair is accepted from any chat. Everything else returns
 * false (which then drops because there's no MAIN_CHAT_ID yet).
 * Post-pair: only the paired user_id gets commands honored; others fall
 * through. Unknown /commands also fall through (claude can handle them)
 * except for the blocklist of UI-only built-ins.
 */
async function tryHandleCommand(msg: TgMessage): Promise<boolean> {
  const text = msg.text ?? "";
  if (!text.startsWith("/")) return false;
  // `/pair@MyBot AB7K-...` → strip @-suffix from command word
  const firstSpace = text.indexOf(" ");
  const head = firstSpace < 0 ? text : text.slice(0, firstSpace);
  const command = head.split("@")[0].toLowerCase();
  const args = firstSpace < 0 ? "" : text.slice(firstSpace + 1);

  // Pre-pair: only /start and /pair are meaningful. Everything else falls
  // through (which then drops because there's no MAIN_CHAT_ID yet).
  if (!pairedCache && !ENV_MAIN_CHAT_ID) {
    if (command === "/pair") { await handlePair(msg, args); return true; }
    if (command === "/start") { await handleStart(msg); return true; }
    return false;
  }

  // Post-pair authorization: paired user_id only.
  if (pairedCache && msg.from?.id !== pairedCache.user_id) {
    // Silently drop — don't reveal command surface to unauthorized users.
    return command.startsWith("/"); // claim handled to suppress claude dispatch
  }

  switch (command) {
    case "/start": await handleStart(msg); return true;
    case "/pair":  await handlePair(msg, args); return true;
    case "/unpair": await handleUnpair(msg, args); return true;
    case "/mount": await handleMount(msg, args); return true;
    case "/dm":    await handleDm(msg, args); return true;
    case "/unmount": await handleUnmount(msg); return true;
    case "/cancel": await handleCancel(msg); return true;
    case "/clear":  await handleClear(msg); return true;
    case "/list":  await handleList(msg); return true;
    case "/help":  await handleHelp(msg); return true;
    default:
      if (CLAUDE_BUILTIN_BLOCKLIST.has(command)) {
        await handleClaudeBuiltin(msg, command);
        return true;
      }
      return false; // unknown /x → let claude see it (user skills etc.)
  }
}

// ─── update routing ──────────────────────────────────────────────────────────

interface TgUser { id: number; }
interface TgChat { id: number; }
interface TgForumTopicCreated { name: string; icon_color?: number; icon_custom_emoji_id?: string; }
interface TgForumTopicEdited { name?: string; icon_custom_emoji_id?: string; }
interface TgMessage {
  message_id: number;
  from?: TgUser;
  chat: TgChat;
  message_thread_id?: number;
  text?: string;
  caption?: string;
  // Service messages carrying forum topic lifecycle events. Telegram emits
  // these inside the topic itself (message_thread_id is the new topic id) when
  // a topic is created or renamed. There's no Bot API getForumTopic, so this
  // is the *only* way to learn topic names — meaning we can only know about
  // topics created / renamed *after* the bot joined the group.
  forum_topic_created?: TgForumTopicCreated;
  forum_topic_edited?: TgForumTopicEdited;
}
interface TgUpdate {
  update_id: number;
  message?: TgMessage;
  edited_message?: TgMessage;
  my_chat_member?: TgChatMemberUpdated;
  callback_query?: TgCallbackQuery;
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
    for (const m of data.mounts) next.set(mountKey(m.channel, m.thread_id), m);
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
/**
 * Auto-spawn a topic tmux session for a thread_id that hit the wildcard
 * template. Persists a real mount via mount-store, then spawns the per-
 * topic claude wrapper. Subsequent messages route directly via the specific
 * mount (wildcard is only consulted for unmounted threads).
 *
 * Returns the new tmux_session name on success, null on failure.
 */
function autoSpawnFromWildcard(thread_id: number | "dm", templatePath: string): string | null {
  const servicesDir = process.env.MOUNT_STORE_PATH
    ? join(process.env.MOUNT_STORE_PATH, "..", "..")
    : installAgentDir();
  const storePath = join(servicesDir, "mount-store/mount-store.ts");
  const wrapperPath = join(servicesDir, "topic-wrapper.sh");

  // Persist the new mount so subsequent restarts pick it up.
  const addResult = spawnSync("bun", ["run", storePath, "add", String(thread_id), templatePath, "auto"], { encoding: "utf8" });
  if (addResult.status !== 0) {
    process.stderr.write(`poller: wildcard auto-mount add failed for ${thread_id}: ${addResult.stderr}\n`);
    return null;
  }
  let mount: { tmux_session: string };
  try {
    mount = JSON.parse(addResult.stdout);
  } catch (e) {
    process.stderr.write(`poller: wildcard auto-mount: unparseable mount-store output: ${addResult.stdout}\n`);
    return null;
  }

  // Spawn the tmux session. The wrapper script picks up the session UUID from
  // sessions/<thread_id> (which mount-store didn't create — we let topic-wrapper
  // generate one on first launch). printf %q to survive paths with spaces.
  const cmd = [wrapperPath, String(thread_id), templatePath, mount.tmux_session]
    .map((arg) => `'${arg.replace(/'/g, "'\\''")}'`)
    .join(" ");
  spawnSync("tmux", ["kill-session", "-t", mount.tmux_session], { encoding: "utf8" }); // no-op if absent
  const newSession = spawnSync("tmux", ["new-session", "-d", "-s", mount.tmux_session, cmd], { encoding: "utf8" });
  if (newSession.status !== 0) {
    process.stderr.write(`poller: wildcard auto-spawn tmux failed for ${thread_id}: ${newSession.stderr}\n`);
    return null;
  }

  // Refresh local cache so subsequent messages find the new mount directly.
  refreshMountsIfChanged();
  process.stdout.write(`[${new Date().toISOString()}] wildcard auto-mount: thread ${thread_id} → ${templatePath} (${mount.tmux_session})\n`);
  return mount.tmux_session;
}

/**
 * Re-spawn a tmux topic session for a mount whose previous session has died
 * (claude crashed, operator killed it, OS restarted, etc.). Distinct from
 * autoSpawnFromWildcard because no new mount is created — we already have a
 * persisted mount; we just need the underlying tmux session resurrected.
 *
 * Returns true on success.
 */
function respawnTopicSession(mount: Mount): boolean {
  const servicesDir = process.env.MOUNT_STORE_PATH
    ? join(process.env.MOUNT_STORE_PATH, "..", "..")
    : installAgentDir();
  const wrapperPath = join(servicesDir, "topic-wrapper.sh");
  const cmd = [wrapperPath, String(mount.thread_id), mount.path, mount.tmux_session]
    .map((arg) => `'${arg.replace(/'/g, "'\\''")}'`)
    .join(" ");
  spawnSync("tmux", ["kill-session", "-t", mount.tmux_session], { encoding: "utf8" });
  const r = spawnSync("tmux", ["new-session", "-d", "-s", mount.tmux_session, cmd], { encoding: "utf8" });
  if (r.status !== 0) {
    process.stderr.write(`poller: respawn tmux failed for ${mount.thread_id}: ${r.stderr}\n`);
    return false;
  }
  process.stdout.write(`[${new Date().toISOString()}] respawned tmux session: ${mount.tmux_session} (thread ${mount.thread_id})\n`);
  return true;
}

function routeMessage(msg: TgMessage): string | null {
  const expectedChat = effectiveChatId();
  if (expectedChat == null) {
    process.stderr.write(`poller: drop msg from chat=${msg.chat.id} user=${msg.from?.id} thread=${msg.message_thread_id ?? "-"} text=${JSON.stringify((msg.text ?? msg.caption ?? "").slice(0,40))} reason=unpaired-no-env\n`);
    return null;
  }
  if (String(msg.chat.id) !== expectedChat) {
    process.stderr.write(`poller: drop msg from chat=${msg.chat.id} user=${msg.from?.id} thread=${msg.message_thread_id ?? "-"} text=${JSON.stringify((msg.text ?? msg.caption ?? "").slice(0,40))} reason=wrong-chat (expected ${expectedChat})\n`);
    return null;
  }
  // Per-user enforcement: when paired, only the paired user's messages reach claude.
  const expectedUser = effectiveUserId();
  if (expectedUser != null && msg.from?.id !== expectedUser) {
    process.stderr.write(`poller: drop msg from chat=${msg.chat.id} user=${msg.from?.id} thread=${msg.message_thread_id ?? "-"} text=${JSON.stringify((msg.text ?? msg.caption ?? "").slice(0,40))} reason=wrong-user (expected ${expectedUser})\n`);
    return null;
  }
  const key: number | "dm" = msg.message_thread_id != null ? msg.message_thread_id : "dm";
  const specific = mountsCache.get(tgKey(key));
  if (specific) return specific.tmux_session;

  // No specific mount — try the wildcard. Auto-spawns a real per-thread
  // mount + tmux session using the wildcard's path as the project dir.
  const wildcard = mountsCache.get(tgKey("*"));
  if (wildcard) {
    return autoSpawnFromWildcard(key, wildcard.path);
  }
  return null;
}

async function dispatchUpdate(u: TgUpdate): Promise<void> {
  // Auto-pair flow events first — neither requires a paired chat to exist.
  if (u.my_chat_member) { await handleMyChatMember(u.my_chat_member); return; }
  if (u.callback_query) { await handleCallbackQuery(u.callback_query); return; }

  const msg = u.message ?? u.edited_message;
  if (!msg) return;

  // Topic-name harvest: forum service messages can pop up at any time and
  // we want them recorded regardless of whether the chat is paired or the
  // message is dropped downstream. The Pager UI relies on this opportunistic
  // capture for the "topic 42 (Plans)" display.
  if (msg.message_thread_id != null) {
    const created = msg.forum_topic_created?.name;
    const edited = msg.forum_topic_edited?.name;
    const name = created ?? edited;
    if (name) recordTopicName(msg.chat.id, msg.message_thread_id, name);
  }

  // Commands run first. Pre-pair /pair messages bypass MAIN_CHAT_ID gating
  // (that's the whole point — we don't know the chat yet). Post-pair commands
  // are gated by paired user_id inside tryHandleCommand.
  if (await tryHandleCommand(msg)) return;

  let target = routeMessage(msg);
  if (!target) {
    // No specific mount, no wildcard. Try the mount-helper before dropping.
    // Helper is skipped if PAGER_DISABLE_HELPER=1 — falls back to legacy
    // silent-drop behavior for users who opt out.
    const text0 = msg.text ?? msg.caption ?? "";
    if (text0.length === 0) return;
    const key: number | "dm" = msg.message_thread_id != null ? msg.message_thread_id : "dm";
    const helperSession = await spawnHelper(key);
    if (!helperSession) return; // disabled or spawn failed; original drop
    // Brief delay for tmux+helper-wrapper to come up before dispatching the
    // user's original message. Helper claude greets via its system prompt
    // even if this dispatch loses the text — at worst the user re-types.
    await new Promise((r) => setTimeout(r, 2000));
    target = helperSession;
  }

  const text = msg.text ?? msg.caption ?? "";
  if (text.length === 0) {
    process.stderr.write(`poller: update ${u.update_id}: empty text/caption, dropping\n`);
    return;
  }

  let r = tmuxDispatch(target, text);
  if (!r.ok && /can't find pane|session not found|no server running/i.test(r.stderr)) {
    // Stale mount: the tmux session named in mounts.json has died (claude
    // crashed, operator killed it, host rebooted between mount-create and
    // first message). Find the mount and respawn from its persisted path.
    // One retry — if respawn fails we drop the message and surface the error.
    const key: number | "dm" = msg.message_thread_id != null ? msg.message_thread_id : "dm";
    const mount = mountsCache.get(tgKey(key));
    if (mount && respawnTopicSession(mount)) {
      r = tmuxDispatch(target, text);
    }
  }
  if (!r.ok) {
    process.stderr.write(`poller: update ${u.update_id}: dispatch to ${target} failed: ${r.stderr}\n`);
    return;
  }
  process.stdout.write(`[${new Date().toISOString()}] update ${u.update_id} → ${target} (${text.length} chars)\n`);

  // UX signals fired in parallel with claude composing the reply. Fire-and-
  // forget — if Telegram is slow we'd rather deliver the reply on time than
  // block on the typing/ack outbound. Errors are logged inside each helper.
  // The typing keepalive runs until mcp-telegram clears the marker on reply.
  void startTypingKeepalive(msg.chat.id, msg.message_thread_id);
  void reactToMessage(msg.chat.id, msg.message_id);
}

// ─── main loop ───────────────────────────────────────────────────────────────

async function getUpdates(offset: number): Promise<TgUpdate[]> {
  // Default getUpdates does NOT include my_chat_member or callback_query.
  // Pass allowed_updates explicitly so the auto-pair flow can fire. Telegram
  // remembers the last allowed_updates per-bot, but we pass it every call so
  // a fresh deploy works correctly without any server-side state assumption.
  const allowed = encodeURIComponent(JSON.stringify([
    "message", "edited_message", "my_chat_member", "callback_query",
  ]));
  const url = `${getApiBase()}/getUpdates?timeout=${POLL_TIMEOUT_SEC}&offset=${offset}&allowed_updates=${allowed}`;
  const resp = await fetch(url);
  const json = (await resp.json()) as TgResp;
  if (!json.ok) {
    throw new Error(`getUpdates: ${json.description ?? "(no description)"}`);
  }
  return json.result ?? [];
}

/**
 * Verify the bot token works before entering the long-poll loop. Without this
 * preflight, a bad token causes getUpdates to 401-loop silently in the
 * 5-second retry — the user sees "Waiting for /pair..." that never resolves
 * because the bot can't actually fetch messages. Surface the failure once,
 * with a remediation hint, then exit and let launchd respawn.
 */
async function preflightBotToken(): Promise<void> {
  try {
    const resp = await fetch(`${getApiBase()}/getMe`);
    const json = (await resp.json()) as { ok: boolean; result?: { id?: number; username?: string }; description?: string };
    if (!json.ok) {
      process.stderr.write(`poller: bot token rejected by Bot API: ${json.description ?? "(no description)"}\n`);
      process.stderr.write(`poller: edit $HOME/.claude/channels/telegram/.env and rerun ./install.sh\n`);
      process.exit(1);
    }
    botUserId = json.result?.id ?? null; // captured for my_chat_member filtering
    process.stdout.write(`[${new Date().toISOString()}] preflight ok: @${json.result?.username ?? "?"} (id=${botUserId})\n`);
  } catch (e) {
    // Network failure → don't exit (transient). Just warn.
    process.stderr.write(`poller: getMe preflight failed (will retry in main loop): ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

export async function main(): Promise<void> {
  if (!process.env.TELEGRAM_BOT_TOKEN) {
    process.stderr.write("poller: TELEGRAM_BOT_TOKEN must be set\n");
    process.exit(1);
  }
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  await preflightBotToken();
  let offset = readOffset();
  refreshMountsIfChanged();
  // Clean up orphaned provisional mounts from prior helper sessions whose
  // tmux is no longer alive (host reboot, claude crash, manual kill). Real
  // mounts are not touched. Must run AFTER the first mountsCache load so the
  // refresh below sees the post-GC state.
  await gcOrphanedProvisionals();
  refreshPairedIfChanged();
  refreshAckReactionIfChanged();
  const startupChat = effectiveChatId() ?? "(unpaired — awaiting /pair)";
  process.stdout.write(`[${new Date().toISOString()}] poller starting, offset=${offset}, chat=${startupChat}, mounts=${mountsCache.size}, helper=${HELPER_DISABLED ? "disabled" : "enabled"}\n`);

  for (;;) {
    touchHeartbeat();
    refreshMountsIfChanged();
    refreshPairedIfChanged();
    refreshAckReactionIfChanged();
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
      await dispatchUpdate(u);
    }
  }
}

// Tests import this module to drive command handlers directly. Only run the
// main loop when executed via `bun run …/poller.ts`, not on import.
if (import.meta.main) {
  main().catch((e) => {
    process.stderr.write(`poller: fatal: ${e instanceof Error ? e.stack ?? e.message : String(e)}\n`);
    process.exit(1);
  });
}

// Test surface: handlers + state-refresh exported so tests can drive the
// command pipeline without spinning up getUpdates. Keep export list narrow.
export {
  tryHandleCommand,
  handlePair,
  handleUnpair,
  handleMount,
  handleDm,
  handleUnmount,
  handleList,
  handleHelp,
  refreshPairedIfChanged,
  refreshMountsIfChanged,
  refreshAckReactionIfChanged,
  reactToMessage,
  sendTyping,
  startTypingKeepalive,
  effectiveChatId,
  effectiveUserId,
  type TgMessage,
  type PairedState,
};
