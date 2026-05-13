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
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, statSync, unlinkSync, utimesSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { addMount, readMounts, type Mount, type ThreadId } from "../mount-store/mount-store";

// ─── env ─────────────────────────────────────────────────────────────────────

// Env reads happen lazily so importing this module for tests doesn't require
// a real bot token. Tests override CTA_STATE_DIR to redirect state files
// and TELEGRAM_API_BASE to route outbound calls at a mock server.

const ENV_MAIN_CHAT_ID = process.env.MAIN_CHAT_ID; // optional Phase 2 override
const POLL_TIMEOUT_SEC = Number(process.env.POLL_TIMEOUT_SEC ?? "25");

const STATE_DIR = process.env.CTA_STATE_DIR ?? join(homedir(), ".claude-telegram-agent");
const OFFSET_FILE = join(STATE_DIR, "poller-offset");
const HEARTBEAT_FILE = join(STATE_DIR, "heartbeat-poller");
const MOUNTS_JSON = join(STATE_DIR, "mounts.json");
const PAIRING_CODE_FILE = join(STATE_DIR, "pairing-code");
const PAIRED_STATE_FILE = join(STATE_DIR, "paired.json");

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
  message?: { chat: { id: number }; message_id: number };
  data?: string;
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
  const storePath = process.env.MOUNT_STORE_PATH ?? join(homedir(), ".local/share/claude-telegram-agent/services/mount-store/mount-store.ts");
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
  const storePath = process.env.MOUNT_STORE_PATH ?? join(homedir(), ".local/share/claude-telegram-agent/services/mount-store/mount-store.ts");
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
  const storePath = process.env.MOUNT_STORE_PATH ?? join(homedir(), ".local/share/claude-telegram-agent/services/mount-store/mount-store.ts");
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
  const lines = data.mounts.map((m) => `• thread ${m.thread_id} → ${m.path}${m.label ? ` (${m.label})` : ""}`);
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

/**
 * Attempt to handle a message as an in-chat command. Returns true if the
 * message was consumed by command handling (so normal tmux dispatch should
 * be skipped). Returns false to fall through to normal routing.
 *
 * Pre-pair: only /pair is accepted from any chat. Everything else returns
 * false (which then drops because there's no MAIN_CHAT_ID yet).
 * Post-pair: only the paired user_id gets commands honored; others fall
 * through. Unknown /commands also fall through (claude can handle them).
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
    case "/list":  await handleList(msg); return true;
    case "/help":  await handleHelp(msg); return true;
    default: return false; // unknown /x → let claude see it
  }
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
    : join(homedir(), ".local/share/claude-telegram-agent/services");
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
    : join(homedir(), ".local/share/claude-telegram-agent/services");
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
  const specific = mountsCache.get(String(key));
  if (specific) return specific.tmux_session;

  // No specific mount — try the wildcard. Auto-spawns a real per-thread
  // mount + tmux session using the wildcard's path as the project dir.
  const wildcard = mountsCache.get("*");
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

  // Commands run first. Pre-pair /pair messages bypass MAIN_CHAT_ID gating
  // (that's the whole point — we don't know the chat yet). Post-pair commands
  // are gated by paired user_id inside tryHandleCommand.
  if (await tryHandleCommand(msg)) return;

  const target = routeMessage(msg);
  if (!target) return;

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
    const mount = mountsCache.get(String(key));
    if (mount && respawnTopicSession(mount)) {
      r = tmuxDispatch(target, text);
    }
  }
  if (!r.ok) {
    process.stderr.write(`poller: update ${u.update_id}: dispatch to ${target} failed: ${r.stderr}\n`);
  } else {
    process.stdout.write(`[${new Date().toISOString()}] update ${u.update_id} → ${target} (${text.length} chars)\n`);
  }
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
  refreshPairedIfChanged();
  const startupChat = effectiveChatId() ?? "(unpaired — awaiting /pair)";
  process.stdout.write(`[${new Date().toISOString()}] poller starting, offset=${offset}, chat=${startupChat}, mounts=${mountsCache.size}\n`);

  for (;;) {
    touchHeartbeat();
    refreshMountsIfChanged();
    refreshPairedIfChanged();
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
  effectiveChatId,
  effectiveUserId,
  type TgMessage,
  type PairedState,
};
