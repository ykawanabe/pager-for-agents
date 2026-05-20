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
import { addMount, mountKey, readMounts, removeMount, type Mount, type ThreadId } from "../mount-store/mount-store";
import {
  aggregateCostFromJsonl,
  contextWindowFor,
  fetchUsageStats,
  formatCostMessage,
  formatUsageMessage,
  jsonlPathForSession,
  lastContextFromJsonl,
  resolveCredentialToken,
} from "./slash-commands";
import { ClaudeDaemonRegistry } from "./claude-daemon-registry";
import type { ClaudeDaemonOptions } from "./claude-daemon";

// Poller-side cache key for Telegram updates. Hardcoded "telegram" because
// this file is the Telegram adapter; the LINE adapter (when added) will
// build keys with "line" instead.
function tgKey(thread_id: ThreadId): string {
  return mountKey("telegram", thread_id);
}
import { markTypingActive, markTypingDone, runTypingKeepalive } from "./typing-keepalive";
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

/**
 * Two-stage delivery semantics by **state transition on a single reaction**
 * (Telegram Bot API only allows ONE reaction per bot per message — multi-
 * emoji arrays get silently rejected). Initial `reactToMessage` sets 👀
 * ("delivered, poller queued it"); this one REPLACES 👀 with 👌
 * ("read, LLM started processing"). Replace-semantics give a useful
 * negative signal: if the user sees 👀 stuck without becoming 👌, something
 * downstream (daemon crash, queue stuck) prevented the LLM from reading.
 *
 * onFlush in `ClaudeDaemonRegistry` fires when the batch is written to
 * claude's stdin, which is the earliest point where "the LLM definitely
 * has it" is true. Failures after that (daemon crash mid-turn) don't roll
 * back the 👌 — it still means "we put it in front of the LLM."
 *
 * The read emoji is hard-coded for now. Could become a second config field
 * (`readReaction`) if a user wants a different "read" emoji. 👌 was picked
 * because it IS in the bot whitelist and reads naturally as "got it / read."
 * ✅ is NOT in the whitelist (silently rejected).
 */
const READ_REACTION_EMOJI = "👌";

async function markMessageRead(chat_id: number, message_id: number): Promise<void> {
  if (!ackReactionCache) return; // delivered-ack off → read off too (paired toggle)
  try {
    // Bots are limited to ONE reaction per message — replace 👀 with the
    // read marker (👌) rather than appending. See doc on READ_REACTION_EMOJI.
    await fetch(`${getApiBase()}/setMessageReaction`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id,
        message_id,
        reaction: [{ type: "emoji", emoji: READ_REACTION_EMOJI }],
      }),
    });
  } catch (e) {
    process.stderr.write(`poller: markMessageRead failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

/** Per-topic queue of msg refs awaiting the "read" ack. Drained on onFlush. */
const pendingReadAcks: Map<string, Array<{ chat_id: number; message_id: number }>> = new Map();

function trackPendingRead(threadIdStr: string, chat_id: number, message_id: number): void {
  let list = pendingReadAcks.get(threadIdStr);
  if (!list) { list = []; pendingReadAcks.set(threadIdStr, list); }
  list.push({ chat_id, message_id });
}

/** Registry onFlush hook: the batch just got written to claude's stdin, so
 *  every queued message in this turn is now "read" by the LLM. */
function onDaemonFlush(threadIdStr: string, _combinedText: string): void {
  const list = pendingReadAcks.get(threadIdStr);
  if (!list || list.length === 0) return;
  pendingReadAcks.delete(threadIdStr);
  for (const { chat_id, message_id } of list) {
    void markMessageRead(chat_id, message_id);
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

// Telegram-friendliness instructions appended via --append-system-prompt
// on every daemon spawn (Phase 4). No picker-avoidance section because
// `claude -p --input-format stream-json` has no interactive arrow-key
// pickers at all. Plain text replies come back via the stream-json
// `result` event; `send_telegram(buttons=...)` is the right tool for
// inline keyboards because there's no way to express button choices
// in plain prose.
const DAEMON_APPEND_SYSTEM_PROMPT = `You are responding through a Telegram bot. The user is on Telegram; your terminal output is NOT visible to them.

For plain text replies, just write your reply — the bot reads your final text and posts it. You do NOT need to call send_telegram for text replies.

When you need the user to choose between a small fixed set of options (Yes/No, A/B/C, two paths forward), call \`mcp__telegram__send_telegram(buttons=["Option A","Option B",...])\` (up to 8 buttons, each ≤50 chars). The user taps one and the chosen label is dispatched back as their next message. Do NOT use AskUserQuestion — it opens a local modal that the user cannot see or answer.

Telegram renders replies as plain text, so do NOT use Markdown syntax (no **bold**, no headers, no - bullets, no backtick code fences) — those characters appear literally. Prefer 1-3 short paragraphs over walls of text. Write code or commands on plain lines without fences. Users are typically on phones; readability beats completeness.

You also have access to ~/.pager/shared-context.md — a cross-session memory file shared with every other Pager-bot claude session on this host. Read it when the user references prior context, or near the start of substantive conversations. Append durable notes there (user preferences, ongoing concerns, decisions, recurring patterns) so future sessions across other topics/projects benefit. Keep entries short and avoid duplication.

IMPORTANT — Telegram pairing / access is handled by claude-telegram-agent, NOT by the official @claude-plugins-official/telegram plugin. If the user asks about pairing, unpair, allowlist, or access changes, DO NOT invoke skills named \`telegram:access\`, \`telegram:configure\`, or anything from \`@claude-plugins-official/telegram\`. Instead:
  - To unpair the current chat: tell the user to send \`/unpair confirm\` in the Telegram chat, OR to run \`cta unpair\` in their terminal.
  - To re-pair to a different chat: unpair first, then either invite the bot to a new chat (auto-pair prompt fires) or send \`/pair <code>\` (code visible via \`cta pair-code\` on the host).
  - To mount a project to a topic: \`/mount <path>\` inside that topic.`;

// ─── daemon dispatch (Phase 4) ─────────────────────────────────────────────
// Per-topic long-lived claude subprocess. No more tmux interactive TUI on
// the bot's hot path. ClaudeDaemonRegistry owns the lifecycle (spawn,
// debounce, queue, crash respawn); poller wires only the chat side.

/** Build the --mcp-config JSON. Daemon keeps mcp-telegram wired so claude
 *  can call `send_telegram(buttons=...)` for inline keyboards — plain text
 *  replies come back via the stream-json result event and don't need MCP. */
function buildMcpConfig(threadId: number | "dm"): string | null {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) return null;
  const chatId = effectiveChatId();
  if (!chatId) return null;
  const serverPath = process.env.TOPIC_WRAPPER_MCP_PATH
    ?? join(installAgentDir(), "mcp-telegram/server.ts");
  const cfg = {
    mcpServers: {
      telegram: {
        command: "bun",
        args: [serverPath],
        env: {
          TELEGRAM_BOT_TOKEN: token,
          TELEGRAM_CHAT_ID: chatId,
          TELEGRAM_THREAD_ID: String(threadId),
          CTA_STATE_DIR: STATE_DIR,
        },
      },
    },
  };
  return JSON.stringify(cfg);
}

/** Per-topic stable MCP config path. Daemon re-reads on respawn; we
 *  overwrite each spawn (chat_id might have changed via /pair switch). */
function mcpConfigPathFor(threadId: number | "dm"): string {
  const dir = join(STATE_DIR, "tmp");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return join(dir, `mcp-config-${threadId}.json`);
}

/** Write the per-topic MCP config to disk. Idempotent. Returns the path,
 *  or null if env is missing (no bot token / chat) — caller skips --mcp-config. */
function ensureMcpConfig(threadId: number | "dm"): string | null {
  const json = buildMcpConfig(threadId);
  if (!json) return null;
  const path = mcpConfigPathFor(threadId);
  writeFileSync(path, json, { mode: 0o600 });
  return path;
}

/**
 * Build the daemon options for a topic. Resolves project_path from the
 * mount cache, session UUID from $STATE_DIR/sessions/<thread_id>, and
 * MCP config path. Called by the registry on every spawn (including
 * crash respawns) so config stays in sync with mount changes.
 */
// ─── per-topic --effort level ────────────────────────────────────────────────
// Valid claude --effort levels. "auto" is NOT a thing — these are the only
// values claude accepts.
const VALID_EFFORTS = new Set(["low", "medium", "high", "xhigh", "max"]);
// Bot-wide default. Overridable via PAGER_EFFORT in ~/.pager/.env. Deliberately
// independent of the user's GLOBAL settings.json effortLevel (which also drives
// their desktop claude) — the bot defaults to "high" for snappier phone replies.
const DEFAULT_EFFORT =
  process.env.PAGER_EFFORT && VALID_EFFORTS.has(process.env.PAGER_EFFORT)
    ? process.env.PAGER_EFFORT
    : "high";
function effortDir(): string { return join(STATE_DIR, "effort"); }
/** Per-topic effort override (set via /effort), else the bot default. */
function resolveEffort(key: number | "dm"): string {
  try {
    const v = readFileSync(join(effortDir(), String(key)), "utf8").trim();
    if (VALID_EFFORTS.has(v)) return v;
  } catch { /* no override → default */ }
  return DEFAULT_EFFORT;
}

// ─── per-topic --model ───────────────────────────────────────────────────────
// Accept aliases (opus/sonnet/haiku/…) or a full claude-* id. Loose validation
// (claude itself rejects truly bogus names at spawn); we just block shell-junk.
const MODEL_RE = /^[A-Za-z0-9._:-]{2,64}$/;
function modelDir(): string { return join(STATE_DIR, "model"); }
/** Per-topic model override (set via /model), else CLAUDE_MODEL env, else
 *  undefined → claude's own default. */
function resolveModel(key: number | "dm"): string | undefined {
  try {
    const v = readFileSync(join(modelDir(), String(key)), "utf8").trim();
    if (MODEL_RE.test(v)) return v;
  } catch { /* no override */ }
  return process.env.CLAUDE_MODEL || undefined;
}

function buildDaemonOpts(threadIdStr: string): Omit<ClaudeDaemonOptions, "claudeBin"> {
  const key: number | "dm" = threadIdStr === "dm" ? "dm" : Number(threadIdStr);
  const mount = mountsCache.get(tgKey(key));
  if (!mount) throw new Error(`buildDaemonOpts: no mount for ${threadIdStr}`);

  // Per-topic session UUID. Generate on first launch; re-use on subsequent.
  const sessFile = join(sessionsDir(), String(key));
  let uuid: string;
  if (existsSync(sessFile)) {
    uuid = readFileSync(sessFile, "utf8").trim();
    if (!uuid) uuid = randomUUID();
  } else {
    uuid = randomUUID();
    mkdirSync(sessionsDir(), { recursive: true });
    writeFileSync(sessFile, uuid + "\n", { mode: 0o600 });
  }
  // --resume needs JSONL to exist; otherwise --session-id starts fresh.
  const jsonlExists = existsSync(jsonlPathForSession(mount.path, uuid));

  const mcpConfigPath = ensureMcpConfig(key);
  const hooksPath = process.env.TOPIC_WRAPPER_HOOKS_PATH
    ?? join(process.env.CTA_INSTALL_DIR ?? join(homedir(), ".local/share/pager"), "bot-hooks.json");

  return {
    cwd: mount.path,
    sessionUuid: uuid,
    resumeExisting: jsonlExists,
    mcpConfigPath: mcpConfigPath ?? undefined,
    settingsPath: existsSync(hooksPath) ? hooksPath : undefined,
    appendSystemPrompt: process.env.BOT_APPEND_SYSTEM_PROMPT ?? DAEMON_APPEND_SYSTEM_PROMPT,
    effort: resolveEffort(key),
    model: resolveModel(key),
  };
}

// /effort <level> over Telegram: set the per-topic --effort level and respawn
// the topic's daemon so it takes effect immediately. No arg → show current +
// valid levels.
async function handleEffort(msg: TgMessage, args: string): Promise<void> {
  const dest = { chat_id: msg.chat.id, thread_id: msg.message_thread_id };
  const key: number | "dm" = msg.message_thread_id != null ? msg.message_thread_id : "dm";
  const level = args.trim().toLowerCase().split(/\s+/)[0];

  if (!level) {
    await reply(dest, `effort for this topic: ${resolveEffort(key)} (default ${DEFAULT_EFFORT})\nUsage: /effort <low|medium|high|xhigh|max>`);
    return;
  }
  if (!VALID_EFFORTS.has(level)) {
    await reply(dest, `"${level}" is not valid. Choose: low, medium, high, xhigh, max.`);
    return;
  }
  try {
    mkdirSync(effortDir(), { recursive: true, mode: 0o700 });
    writeFileSync(join(effortDir(), String(key)), level + "\n", { mode: 0o600 });
  } catch (e) {
    await reply(dest, `Couldn't save effort: ${e instanceof Error ? e.message : String(e)}`);
    return;
  }
  // Respawn the daemon so the new --effort applies on the next turn.
  try {
    if (daemonRegistry) await daemonRegistry.resetTopic(String(key));
  } catch (e) {
    process.stderr.write(`poller: handleEffort resetTopic failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
  await reply(dest, `effort set to ${level} for this topic (applies on your next message).`);
}

// /model <alias|id> over Telegram: set the per-topic model and respawn the
// topic's daemon. No arg → show current.
async function handleModel(msg: TgMessage, args: string): Promise<void> {
  const dest = { chat_id: msg.chat.id, thread_id: msg.message_thread_id };
  const key: number | "dm" = msg.message_thread_id != null ? msg.message_thread_id : "dm";
  const name = args.trim().split(/\s+/)[0];

  if (!name) {
    await reply(dest, `model for this topic: ${resolveModel(key) ?? "(claude default)"}\nUsage: /model <opus|sonnet|haiku|full-id>`);
    return;
  }
  if (!MODEL_RE.test(name)) {
    await reply(dest, `"${name}" doesn't look like a model name. Use an alias (opus/sonnet/haiku) or a full id (claude-…).`);
    return;
  }
  try {
    mkdirSync(modelDir(), { recursive: true, mode: 0o700 });
    writeFileSync(join(modelDir(), String(key)), name + "\n", { mode: 0o600 });
  } catch (e) {
    await reply(dest, `Couldn't save model: ${e instanceof Error ? e.message : String(e)}`);
    return;
  }
  try {
    if (daemonRegistry) await daemonRegistry.resetTopic(String(key));
  } catch (e) {
    process.stderr.write(`poller: handleModel resetTopic failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
  await reply(dest, `model set to ${name} for this topic (applies on your next message). If it's an invalid name, claude will fail to start — send /model with a valid one.`);
}

// /context over Telegram: approximate current context-window usage from the
// transcript's last turn.
async function handleContext(msg: TgMessage): Promise<void> {
  const thread_id = msg.message_thread_id;
  const key: number | "dm" = thread_id != null ? thread_id : "dm";
  const dest = { chat_id: msg.chat.id, thread_id };
  const mount = mountsCache.get(tgKey(key));
  if (!mount) { await reply(dest, "No mount in this topic — `/mount <path>` first."); return; }
  const jsonl = jsonlPathForMount(mount);
  const ctx = jsonl ? lastContextFromJsonl(jsonl) : null;
  if (!ctx) { await reply(dest, "No turns recorded yet — send a message in this topic first."); return; }
  const win = contextWindowFor(ctx.model);
  const pct = Math.round((ctx.tokens / win) * 100);
  await reply(dest, `context: ~${ctx.tokens.toLocaleString()} / ${win.toLocaleString()} tokens (${pct}%) · ${ctx.model}\n(approx — last turn's prompt size)`);
}

/** Parse a registry threadId (string) back into the TG numeric form. */
function parseRegistryThreadId(threadIdStr: string): number | undefined {
  return threadIdStr === "dm" ? undefined : Number(threadIdStr);
}

/**
 * Singleton ClaudeDaemonRegistry. Initialized in main() after env setup so
 * the daemon-opts factory has access to the live MAIN_CHAT_ID / paired
 * state. Module-level let so daemonDispatch can reference it without
 * passing it through dispatchUpdate's stack.
 */
let daemonRegistry: ClaudeDaemonRegistry | null = null;

/**
 * Wiring: pump each assistant text block out to Telegram. multi-message
 * UX is automatic because claude code emits one assistant event per
 * text/tool_use block during a turn.
 */
function postTelegramTextFromDaemon(threadIdStr: string, text: string): void {
  const chatIdStr = effectiveChatId();
  if (!chatIdStr) return;
  const chat_id = Number(chatIdStr);
  if (!Number.isFinite(chat_id)) return;
  void reply({ chat_id, thread_id: parseRegistryThreadId(threadIdStr) }, text);
}

/** Turn-end hook: clear typing keepalive (mcp-telegram normally does this
 *  on send_telegram; in daemon mode plain-text replies bypass MCP so we
 *  must clear ourselves), log cost. */
function onDaemonTurnEnd(threadIdStr: string, info: { costUsd: number | null; sessionId: string | null }): void {
  const chatIdStr = effectiveChatId();
  if (chatIdStr) {
    const chat_id = Number(chatIdStr);
    if (Number.isFinite(chat_id)) {
      markTypingDone(STATE_DIR, chat_id, parseRegistryThreadId(threadIdStr) ?? "dm");
    }
  }
  if (typeof info.costUsd === "number") {
    process.stdout.write(`[${new Date().toISOString()}] daemon turn-end cost: $${info.costUsd.toFixed(4)} (session=${info.sessionId}, thread=${threadIdStr})\n`);
  }
}

/** Initialize the daemon registry. Called once in main(). */
function initDaemonRegistry(): void {
  if (daemonRegistry) return;
  daemonRegistry = new ClaudeDaemonRegistry({
    debounceMs: Number(process.env.PAGER_DAEMON_DEBOUNCE_MS ?? "2000"),
    // Test seam: e2e scenarios point this at fixtures/fake-claude-daemon.sh so
    // a turn can run without spawning real `claude`. Unset in production →
    // registry defaults to "claude".
    claudeBin: process.env.PAGER_CLAUDE_BIN || undefined,
    daemonOptsFor: buildDaemonOpts,
    onText: postTelegramTextFromDaemon,
    onFlush: onDaemonFlush,
    onTurnEnd: onDaemonTurnEnd,
  });
}

/**
 * Phase 4 dispatch: hand the message to the registry. Registry handles
 * spawn-if-needed, debounce, per-topic queue, turn streaming, and crash
 * recovery. Fire-and-forget — replies flow back via the onText callback,
 * not via this function's return value.
 */
function daemonDispatch(threadIdStr: string, msg: TgMessage): void {
  const text = msg.text ?? msg.caption ?? "";
  if (!text) return;
  if (!daemonRegistry) {
    process.stderr.write("poller: daemonDispatch called before initDaemonRegistry — initializing on demand\n");
    initDaemonRegistry();
  }
  // Fire typing keepalive + delivered ack (👀) in parallel — they're fast
  // Bot API calls. mcp-telegram clears the typing marker if claude calls
  // send_telegram; otherwise onDaemonTurnEnd clears it on the result event.
  // The "read" ack (👀+✅) fires later via onDaemonFlush when the registry
  // actually writes this batch to claude's stdin.
  void startTypingKeepalive(msg.chat.id, msg.message_thread_id);
  void reactToMessage(msg.chat.id, msg.message_id);
  trackPendingRead(threadIdStr, msg.chat.id, msg.message_id);

  daemonRegistry!.enqueue(threadIdStr, text);
}

/** Public API for cta / Pager IPC — kill the daemon for a topic so the
 *  user can attach a TUI via `claude --resume <uuid>`. Awaited by callers. */
export async function releaseDaemonForTerminal(threadId: number | "dm"): Promise<void> {
  if (!daemonRegistry) return;
  await daemonRegistry.releaseForTerminal(String(threadId));
}

/** Public API: re-acquire daemon after user closes their TUI. */
export async function reacquireDaemonFromTerminal(threadId: number | "dm"): Promise<void> {
  if (!daemonRegistry) return;
  await daemonRegistry.reacquireFromTerminal(String(threadId));
}

/** Public API: full reset for /clear — stop the running daemon and drop
 *  the topic's registry entry so the next enqueue lazy-spawns fresh
 *  (picking up the rotated session UUID written by handleClear). */
export async function resetDaemonTopic(threadId: number | "dm"): Promise<void> {
  if (!daemonRegistry) return;
  await daemonRegistry.resetTopic(String(threadId));
}

// ─── β handoff (Open in Terminal) IPC ────────────────────────────────────────
// Pager / `cta release-daemon` write flag files into $STATE_DIR/release-flags/
// to request that a topic's daemon yield its claude session lock so the user
// can attach via `claude --resume <uuid>`. We poll the dir every loop tick
// (cheap — usually empty). Protocol:
//   <thread_id>            written by caller → release the daemon, then
//                          rename to <thread_id>.ack so the caller's polling
//                          loop knows the kill completed.
//   <thread_id>.ack        the release ack — its presence means "released".
//                          The caller deletes this to signal reacquire.
//
// On poller restart, any stale .ack files left behind by a prior run get
// cleaned up so the new poller doesn't think topics are stuck released.

const RELEASE_FLAG_DIR = join(STATE_DIR, "release-flags");

function ensureReleaseFlagDir(): void {
  try { mkdirSync(RELEASE_FLAG_DIR, { recursive: true, mode: 0o700 }); } catch { /* best effort */ }
}

/** Snapshot every entry in release-flags/ once per tick. Cheap when empty;
 *  in steady state nobody's clicking "Open in Terminal" so this is a single
 *  readdir on a directory with zero entries.
 *
 *  Behavior:
 *  - bare `<thread_id>` file (no .ack sibling) → release daemon, rename to .ack
 *  - missing `<thread_id>` AND missing `.ack` → if registry says "released",
 *    reacquire (the caller deleted both files).
 *  - .ack alone → status quo, do nothing. */
async function processReleaseFlags(): Promise<void> {
  if (!daemonRegistry) return;
  let names: string[];
  try {
    names = require("node:fs").readdirSync(RELEASE_FLAG_DIR) as string[];
  } catch {
    return; // dir doesn't exist yet; ensure on startup
  }
  // Build per-thread state: did we see the request file, the ack file, both,
  // or neither?
  const states = new Map<string, { request: boolean; ack: boolean }>();
  for (const name of names) {
    const isAck = name.endsWith(".ack");
    const thread = isAck ? name.slice(0, -4) : name;
    const cur = states.get(thread) ?? { request: false, ack: false };
    if (isAck) cur.ack = true;
    else cur.request = true;
    states.set(thread, cur);
  }
  const justReleased = new Set<string>();
  for (const [thread, { request, ack }] of states) {
    if (request && !ack) {
      try {
        await daemonRegistry.releaseForTerminal(thread);
        renameSync(join(RELEASE_FLAG_DIR, thread), join(RELEASE_FLAG_DIR, `${thread}.ack`));
        justReleased.add(thread);
        process.stdout.write(`[${new Date().toISOString()}] β: released daemon for thread ${thread}\n`);
      } catch (e) {
        process.stderr.write(`poller: release-flag processing failed for ${thread}: ${e instanceof Error ? e.message : String(e)}\n`);
      }
    }
  }
  // Detect reacquire: registry has a topic in "released" state but no .ack
  // file present. Caller deleted the ack to signal "TUI is closed, bring
  // the daemon back". Skip topics we JUST released this tick — their .ack
  // exists on disk but our local `states` map is stale (built before the
  // rename), so we'd incorrectly think the caller deleted the ack.
  for (const [thread] of daemonRegistry.snapshotQueues()) {
    if (justReleased.has(thread)) continue;
    if (daemonRegistry.getStatus(thread) !== "released") continue;
    // Re-stat instead of trusting the stale states map.
    const ackPath = join(RELEASE_FLAG_DIR, `${thread}.ack`);
    if (existsSync(ackPath)) continue;
    try {
      await daemonRegistry.reacquireFromTerminal(thread);
      process.stdout.write(`[${new Date().toISOString()}] β: reacquired daemon for thread ${thread}\n`);
    } catch (e) {
      process.stderr.write(`poller: reacquire failed for ${thread}: ${e instanceof Error ? e.message : String(e)}\n`);
    }
  }
}

/** Clean stale .ack files on startup so a poller restart while flags are
 *  set doesn't leave topics stuck released. */
function cleanupStaleReleaseFlags(): void {
  try {
    const names = require("node:fs").readdirSync(RELEASE_FLAG_DIR) as string[];
    for (const name of names) {
      try { unlinkSync(join(RELEASE_FLAG_DIR, name)); } catch { /* best effort */ }
    }
  } catch { /* dir missing, nothing to clean */ }
}

// ─── Watch-live input IPC (Phase 4 daemon mode) ──────────────────────────────
// Pager's "Watch live" input field and `cta send` deliver text into a topic by
// dropping a file into $STATE_DIR/inject/. In Phase 4 the daemon's stdin is
// owned by this poller (there's no per-topic tmux session to paste into
// anymore — the old `cta send` tmux path is dead), so an external caller can't
// reach the daemon directly; it hands off through this drop-dir instead.
//
// Filename: `<thread_id>__<nonce>.txt` (thread_id is "dm" or numeric — never
// contains "__"). cta writes atomically (`.tmp` then rename) so we never read a
// partial file. We delete each file BEFORE enqueueing so a crash drops rather
// than re-injects (same durability stance as the getUpdates offset).
//
// Latency: an fs.watch fires processing instantly even while the getUpdates
// long-poll is blocked; the per-tick poll in the main loop is the fallback in
// case a watch event is missed.
const INJECT_DIR = join(STATE_DIR, "inject");

function ensureInjectDir(): void {
  try { mkdirSync(INJECT_DIR, { recursive: true, mode: 0o700 }); } catch { /* best effort */ }
}

let injectProcessing = false;
async function processInjectFlags(): Promise<void> {
  if (!daemonRegistry) return;
  if (injectProcessing) return; // re-entrancy guard (watch + loop can overlap)
  injectProcessing = true;
  try {
    const fs = require("node:fs");
    let names: string[];
    try {
      names = (fs.readdirSync(INJECT_DIR) as string[])
        .filter((n) => n.endsWith(".txt"))
        .sort(); // ts-prefixed nonce → rough FIFO ordering
    } catch {
      return; // dir missing; ensured on startup
    }
    for (const name of names) {
      const full = join(INJECT_DIR, name);
      const sep = name.indexOf("__");
      if (sep <= 0) { try { fs.unlinkSync(full); } catch { /* */ } continue; }
      const threadId = name.slice(0, sep);
      let text: string;
      try { text = fs.readFileSync(full, "utf8"); } catch { continue; }
      try { fs.unlinkSync(full); } catch { /* */ } // delete before enqueue
      const trimmed = text.replace(/\s+$/, "");
      if (!trimmed) continue;
      daemonRegistry.enqueue(threadId, trimmed);
      process.stdout.write(`[${new Date().toISOString()}] inject: thread ${threadId} (${trimmed.length} chars)\n`);
    }
  } finally {
    injectProcessing = false;
  }
}

let injectWatcher: { close(): void } | null = null;
function startInjectWatcher(): void {
  if (injectWatcher) return;
  try {
    injectWatcher = require("node:fs").watch(INJECT_DIR, () => { void processInjectFlags(); });
  } catch (e) {
    // fs.watch unsupported on this filesystem — the per-tick loop poll still
    // drains the dir, just at long-poll cadence instead of instantly.
    process.stderr.write(`poller: inject fs.watch unavailable (${e instanceof Error ? e.message : String(e)}); using loop-poll fallback\n`);
  }
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

  // P6a: mount-choice button (`mnt:<thread>:<idx>`) — link the topic to the
  // chosen project dir, then prompt the user to resend. Replaces the tmux
  // mount-helper. Index references the deterministic mountCandidates() list.
  if (cb.data.startsWith("mnt:")) {
    if (!pairedCache || cb.from.id !== pairedCache.user_id) {
      await answerCallback(cb.id, "Only the paired user can answer.", true);
      return;
    }
    if (!cb.message) { await answerCallback(cb.id); return; }
    const rest = cb.data.slice(4);
    const ci = rest.indexOf(":");
    if (ci < 0) { await answerCallback(cb.id); return; }
    const tidStr = rest.slice(0, ci);
    const idx = Number(rest.slice(ci + 1));
    const thread_id_raw = tidStr === "dm" ? undefined : Number(tidStr);
    const dir = mountCandidates()[idx];
    if (!dir) {
      await answerCallback(cb.id, "That option expired — send /mount <path>.", true);
      return;
    }
    await answerCallback(cb.id);
    try {
      await addMount({ thread_id: tidStr === "dm" ? "dm" : Number(tidStr), path: dir, label: mountBasename(dir) });
      refreshMountsIfChanged();
    } catch (e) {
      await reply({ chat_id: cb.message.chat.id, thread_id: thread_id_raw }, `Couldn't link: ${e instanceof Error ? e.message : String(e)}`);
      return;
    }
    const original = cb.message.text ?? "";
    void editMessageText(cb.message.chat.id, cb.message.message_id, `${original}\n\n↳ linked to ${dir}`);
    await reply({ chat_id: cb.message.chat.id, thread_id: thread_id_raw }, `Linked this topic to ${dir}. Send your message again and I'll start the session.`);
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

  // Rotate per-topic session UUID. The new daemon (spawned by the registry
  // on the next enqueue) reads this file at start and uses --session-id with
  // a fresh UUID → no --resume → cold conversation.
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

  // Reset the registry entry so the running daemon stops and the next
  // enqueue lazy-spawns a fresh one with the rotated UUID. Without this,
  // the alive daemon keeps using the OLD UUID and /clear has no effect
  // until the poller restarts.
  if (daemonRegistry) {
    try {
      await daemonRegistry.resetTopic(String(key));
    } catch (e) {
      process.stderr.write(`poller: handleClear resetTopic failed: ${e instanceof Error ? e.message : String(e)}\n`);
    }
  }

  await reply(
    { chat_id, thread_id: thread_id_raw },
    "Cleared. New session starts on the next message (cold-start adds ~5–15s).",
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

// ─── bot-side slash command handlers (stream-json migration Phase 1) ────────
// Replaces the picker-watcher's screen-scrape relay of /cost, /usage etc.
// — that approach was fragile across claude TUI version bumps (Format A's
// `⎿` marker vs Format B's `────` divider). Each of these handlers computes
// the answer directly from claude's on-disk state instead of parsing pane text.

/**
 * Resolve the JSONL transcript for the topic that produced this message.
 * Mirrors topic-wrapper.sh's resolution chain:
 *   1. Mount → project_path
 *   2. $STATE_DIR/sessions/<thread_id> → session UUID
 *   3. ~/.claude/projects/<encoded_cwd>/<uuid>.jsonl
 * Returns null if no mount or no session UUID is on disk yet (the topic
 * hasn't started its first claude turn, so there's nothing to bill).
 */
function jsonlPathForMount(mount: Mount): string | null {
  const key = mount.thread_id;
  const sessFile = join(sessionsDir(), String(key));
  if (!existsSync(sessFile)) return null;
  let uuid: string;
  try {
    uuid = readFileSync(sessFile, "utf8").trim();
  } catch { return null; }
  if (!uuid) return null;
  return jsonlPathForSession(mount.path, uuid);
}

async function handleCost(msg: TgMessage): Promise<void> {
  const thread_id = msg.message_thread_id;
  const key: number | "dm" = thread_id != null ? thread_id : "dm";
  const mount = mountsCache.get(tgKey(key));
  if (!mount) {
    await reply(
      { chat_id: msg.chat.id, thread_id },
      "No mount in this topic — nothing to bill. `/mount <path>` first.",
    );
    return;
  }
  const jsonl = jsonlPathForMount(mount);
  if (!jsonl) {
    await reply(
      { chat_id: msg.chat.id, thread_id },
      "Session hasn't started yet — send any message in this topic first, then try `/cost` again.",
    );
    return;
  }
  const summary = aggregateCostFromJsonl(jsonl);
  await reply({ chat_id: msg.chat.id, thread_id }, formatCostMessage(summary));
}

// 60s cache for /usage — Anthropic's Usage API is rate-limited and the
// number doesn't move that fast. Identical pattern to teleclaw's 60s cache.
let usageCache: { stats: import("./slash-commands").UsageStats; expires: number } | null = null;
const USAGE_CACHE_MS = 60_000;

async function handleUsage(msg: TgMessage): Promise<void> {
  let stats: import("./slash-commands").UsageStats;
  if (usageCache && usageCache.expires > Date.now()) {
    stats = usageCache.stats;
  } else {
    const token = await resolveCredentialToken();
    if (!token) {
      await reply(
        { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
        "Couldn't find claude code credentials on the host. Make sure you're signed in (`claude /login` on the Mac).",
      );
      return;
    }
    stats = await fetchUsageStats(token);
    usageCache = { stats, expires: Date.now() + USAGE_CACHE_MS };
  }
  await reply({ chat_id: msg.chat.id, thread_id: msg.message_thread_id }, formatUsageMessage(stats));
}

/**
 * Kill the topic's tmux session — the wrapper's restart loop (or the
 * watchdog's kick_dead_topic_sessions) brings up a fresh claude that resumes
 * from the same session UUID. Different from `/clear`, which also rotates
 * the UUID for a brand-new conversation.
 */
async function handleRestartCmd(msg: TgMessage): Promise<void> {
  const thread_id = msg.message_thread_id;
  const key: number | "dm" = thread_id != null ? thread_id : "dm";
  const mount = mountsCache.get(tgKey(key));
  if (!mount) {
    await reply(
      { chat_id: msg.chat.id, thread_id },
      "Nothing to restart — no mount in this topic.",
    );
    return;
  }
  if (daemonRegistry) {
    try {
      await daemonRegistry.resetTopic(String(key));
    } catch (e) {
      process.stderr.write(`poller: handleRestart resetTopic failed: ${e instanceof Error ? e.message : String(e)}\n`);
    }
  }
  await reply(
    { chat_id: msg.chat.id, thread_id },
    "Restarting claude in this topic. First reply may take 5–15s while it cold-starts.",
  );
}

/**
 * Run `cta status` and post its output. The cta CLI knows about every
 * component (LaunchAgent, poller heartbeat, MCP, watchdog) — this is the
 * source of truth for "is the bot alive."
 */
async function handleStatusCmd(msg: TgMessage): Promise<void> {
  // cta lives at $HOME/.local/bin/cta in install.sh's layout; allow override
  // for tests. Plain status (no flags) prints the same checklist Pager menu
  // bar shows.
  const ctaPath = process.env.CTA_BIN ?? join(homedir(), ".local/bin/cta");
  const r = spawnSync(ctaPath, ["status"], { encoding: "utf8", timeout: 5000 });
  if (r.status !== 0 && !r.stdout) {
    await reply(
      { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
      `Couldn't run cta status: ${(r.stderr ?? "").trim() || `exit ${r.status}`}`,
    );
    return;
  }
  // cta status uses unicode glyphs (✓/✗) and color escapes; strip ANSI before
  // sending to Telegram. Cap to 3500 chars (Telegram plain text limit margin).
  let body = (r.stdout ?? "").replace(/\x1b\[[0-9;]*m/g, "");
  if (body.length > 3500) body = body.slice(0, 3500) + "\n…(truncated)";
  await reply(
    { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
    `cta status\n${body}`,
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
    await resetPerTopicStateOnPairSwitch();
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

/** Tear down per-topic state when the paired chat changes. Daemons spawned
 * before the pair switch have the previous chat_id pinned in mcp-telegram's
 * env; the next message respawns them via the registry's lazy-spawn path,
 * picking up the new paired.json's chat_id. We also kill any leftover
 * `topic-*` tmux sessions from a stale pre-Phase-4 install (defensive). */
async function resetPerTopicStateOnPairSwitch(): Promise<void> {
  // Snapshot any in-flight queues before shutdown — otherwise a pair switch
  // mid-conversation silently drops the user's pending text. Map<threadId, []>
  // captures every non-empty queue across topics; we replay each into the
  // fresh registry below so respawn picks them up with the new chat_id.
  const queueSnapshot = new Map<string, string[]>();
  if (daemonRegistry) {
    for (const [threadId, queue] of daemonRegistry.snapshotQueues()) {
      if (queue.length > 0) queueSnapshot.set(threadId, queue);
    }
    // Shut down all daemons — they hold the old chat_id in their MCP env.
    // shutdown() awaits SIGTERM completion so claude releases its session
    // lock file cleanly before the next message re-spawns it.
    await daemonRegistry.shutdown();
    initDaemonRegistry(); // fresh registry, lazy respawn on next enqueue
    // Replay snapshotted messages into the new registry. Each enqueue arms
    // the debounce; the first inbound after pair switch combines with any
    // recovered text. Order within each topic is preserved.
    if (daemonRegistry !== null) {
      for (const [threadId, queue] of queueSnapshot) {
        for (const text of queue) {
          (daemonRegistry as ClaudeDaemonRegistry).enqueue(threadId, text);
        }
      }
    }
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
  // Release. paired.json is owned solely by the poller, so unlink is safe;
  // mounts.json is shared with cta — use the mount-store `clear` op so the
  // wipe goes through the file lock (no torn writes if a concurrent
  // `cta mount` is mid-rename).
  try { unlinkSync(PAIRED_STATE_FILE); } catch { /* already gone */ }
  try {
    spawnSync("bun", ["run", installMountStoreTs(), "clear"], { encoding: "utf8" });
  } catch (e) {
    process.stderr.write(`poller: handleUnpair clearMounts failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
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
      "Mount commands:",
      "  /mount <path>   — bind THIS forum topic to a project dir on the Mac",
      "  /dm <path>      — bind your DM with the bot to a project dir",
      "  /unmount        — remove the mount for THIS topic (or DM)",
      "  /list           — show current mounts",
      "  /unpair confirm — release this chat so another can claim me",
      "",
      "Session commands (run on the topic's claude):",
      "  /cost           — token usage + estimated cost for this session",
      "  /usage          — Anthropic 5h/7d subscription usage",
      "  /clear          — reset the conversation (new session UUID)",
      "  /effort <level> — set reasoning effort for this topic (low|medium|high|xhigh|max)",
      "  /model <name>   — set model for this topic (opus|sonnet|haiku|full-id)",
      "  /context        — approx context-window usage for this topic",
      "  /restart        — restart claude on this topic (keep session)",
      "  /status         — show bot/daemon health (cta status output)",
      "",
      "Any non-command message is forwarded to the claude session for that mount.",
    ].join("\n"),
  );
}

// TUI command registry (P3.10 / Principle 6).
//
// Three dispositions for Claude Code TUI commands that arrive over Telegram:
//
//   translated  — has a poller-side handler that implements the semantic
//                 over Telegram. Pager owns the meaning; claude TUI's
//                 internal behavior is irrelevant.
//   hidden      — TUI-only command with no Telegram analog. Reply with a
//                 per-command reason so the user knows where to go on
//                 their Mac (vs. the previous generic "local UI command"
//                 message that gave no actionable guidance).
//   forwarded   — safe to forward to claude (default, no entry needed).
//                 User-defined skills like `/qa`, `/codex` rely on this.
//
// Adding a new command is one row. Future Claude Code releases that add
// commands need a one-line registry update — vs. the old hand-grown
// CLAUDE_BUILTIN_BLOCKLIST that silently fell out of sync.
type CommandSpec =
  | { disposition: "translated"; handler: (msg: TgMessage) => Promise<void> }
  | { disposition: "hidden"; reason: string };

const TUI_COMMANDS: Record<string, CommandSpec> = {
  // ── translated: bot-side handlers ─────────────────────────────────────────
  // Each computes the answer from claude's on-disk state (JSONL transcript,
  // keychain credentials, tmux session liveness) instead of screen-scraping
  // claude TUI output. See agent/poller/slash-commands.ts.
  "/clear":   { disposition: "translated", handler: (m) => handleClear(m) },
  "/cost":    { disposition: "translated", handler: (m) => handleCost(m) },
  "/usage":   { disposition: "translated", handler: (m) => handleUsage(m) },
  "/restart": { disposition: "translated", handler: (m) => handleRestartCmd(m) },
  "/status":  { disposition: "translated", handler: (m) => handleStatusCmd(m) },
  "/context": { disposition: "translated", handler: (m) => handleContext(m) },

  // ── hidden: TUI-only commands with no Telegram analog ─────────────────────
  "/config":      { disposition: "hidden", reason: "Edit `~/.pager/.env` directly, then `cta restart`." },
  "/agents":      { disposition: "hidden", reason: "Project agents live in `.claude/agents/` on disk." },
  "/permissions": { disposition: "hidden", reason: "Bot runs with `--dangerously-skip-permissions`; tools are constrained via `agent/helper-permissions.json`." },
  "/compact":     { disposition: "hidden", reason: "Claude Code auto-compacts; on-demand /compact isn't triggerable in the daemon (stream-json) mode. Use /clear to reset the conversation." },
  "/output-style":{ disposition: "hidden", reason: "Telegram renders plain text — output styles are TUI-only." },
  "/init":        { disposition: "hidden", reason: "Run on your Mac in the project directory." },
  "/exit":        { disposition: "hidden", reason: "Use `/clear` to reset the conversation, or `cta stop` / `cta start` on your Mac." },
  "/quit":        { disposition: "hidden", reason: "Use `/clear` to reset the conversation, or `cta stop` / `cta start` on your Mac." },
  "/logout":      { disposition: "hidden", reason: "The Telegram bot has no logout. `cta unpair` releases the chat for re-pairing." },
  "/login":       { disposition: "hidden", reason: "The Telegram bot has no login. Run `cta pair-code` on your Mac, then send `/pair <code>` here." },
};

async function handleHiddenTuiCommand(msg: TgMessage, command: string, reason: string): Promise<void> {
  await reply(
    { chat_id: msg.chat.id, thread_id: msg.message_thread_id },
    `\`${command}\` is a Claude Code TUI command — ${reason}`,
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
    case "/list":  await handleList(msg); return true;
    case "/effort": await handleEffort(msg, args); return true;
    case "/model": await handleModel(msg, args); return true;
    case "/help":  await handleHelp(msg); return true;
    default: {
      // TUI command framework: translated → run handler, hidden → reply,
      // forwarded (no entry) → fall through to claude.
      const spec = TUI_COMMANDS[command];
      if (spec?.disposition === "translated") {
        await spec.handler(msg);
        return true;
      }
      if (spec?.disposition === "hidden") {
        await handleHiddenTuiCommand(msg, command, spec.reason);
        return true;
      }
      return false; // unknown /x → let claude see it (user skills etc.)
    }
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
 * Persist a wildcard-derived mount for a thread_id that hit the `*` template.
 * Phase 4: only the mount-store record is created — there is no per-topic tmux
 * session to spawn, since claude lives inside the poller's ClaudeDaemonRegistry
 * and gets lazy-spawned on the next enqueue. Subsequent messages route directly
 * via the specific mount (wildcard is only consulted for unmounted threads).
 *
 * Returns the persisted `tmux_session` field (still recorded in mount-store
 * for legacy schema compatibility) on success, null on failure.
 */
function autoSpawnFromWildcard(thread_id: number | "dm", templatePath: string): string | null {
  const servicesDir = process.env.MOUNT_STORE_PATH
    ? join(process.env.MOUNT_STORE_PATH, "..", "..")
    : installAgentDir();
  const storePath = join(servicesDir, "mount-store/mount-store.ts");

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

  // Refresh local cache so subsequent messages find the new mount directly.
  refreshMountsIfChanged();
  process.stdout.write(`[${new Date().toISOString()}] wildcard auto-mount: thread ${thread_id} → ${templatePath} (${mount.tmux_session})\n`);
  return mount.tmux_session;
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

// P6a: when a topic has no mount (and no wildcard), the poller offers a
// buttons prompt of known project dirs instead of spawning an interactive
// tmux mount-helper. No claude/helper daemon, no chicken-and-egg.
function mountBasename(p: string): string {
  return p.replace(/\/+$/, "").split("/").pop() || p;
}
/** Deterministic candidate dir list (re-derived identically on the callback,
 *  so callback_data can index into it). Distinct existing mount paths + the
 *  default CLAUDE_CWD, capped for a tidy keyboard. */
function mountCandidates(): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const add = (p?: string) => { if (p && !seen.has(p)) { seen.add(p); out.push(p); } };
  for (const m of mountsCache.values()) add(m.path);
  add(process.env.CLAUDE_CWD);
  return out.slice(0, 6);
}
async function promptMountChoice(thread_id: number | "dm", chat_id: number, threadIdRaw: number | undefined): Promise<void> {
  const cands = mountCandidates();
  const tid = String(thread_id);
  if (cands.length === 0) {
    await reply({ chat_id, thread_id: threadIdRaw }, "This topic isn't linked to a project yet. Send `/mount <path>` (e.g. `/mount ~/projects/foo`), or set it in Pager.");
    return;
  }
  const buttons = cands.map((p, i) => [{ text: mountBasename(p), callback_data: `mnt:${tid}:${i}` }]);
  await sendInlineKeyboard(chat_id, "This topic isn't linked to a project yet. Pick one, or send `/mount <path>`:", buttons);
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

  const text0 = msg.text ?? msg.caption ?? "";
  if (text0.length === 0) {
    process.stderr.write(`poller: update ${u.update_id}: empty text/caption, dropping\n`);
    return;
  }

  // Resolve which mount this message belongs to. routeMessage handles the
  // chat/user gating and returns a session name; we also need the Mount
  // itself for stream-json dispatch. Mount cache and routeMessage share
  // a lookup by tgKey, so do it once here.
  const expectedChat = effectiveChatId();
  if (expectedChat == null || String(msg.chat.id) !== expectedChat) {
    // routeMessage logs the drop reason. Just call it for the side-effect
    // of logging, then return.
    void routeMessage(msg);
    return;
  }
  const expectedUser = effectiveUserId();
  if (expectedUser != null && msg.from?.id !== expectedUser) {
    void routeMessage(msg);
    return;
  }
  const routeKey: number | "dm" = msg.message_thread_id != null ? msg.message_thread_id : "dm";
  let mount = mountsCache.get(tgKey(routeKey));
  if (!mount) {
    // No specific mount — try wildcard auto-spawn (existing behavior).
    const wildcard = mountsCache.get(tgKey("*"));
    if (wildcard) {
      const spawned = autoSpawnFromWildcard(routeKey, wildcard.path);
      if (spawned) {
        mount = mountsCache.get(tgKey(routeKey)); // refreshMountsIfChanged ran inside autoSpawn
      }
    }
  }
  if (!mount) {
    // P6a: no mount and no wildcard — offer a buttons prompt of known project
    // dirs (poller-only) instead of spawning the interactive tmux mount-helper.
    // The user taps a dir (or sends /mount), then resends their message.
    await promptMountChoice(routeKey, msg.chat.id, msg.message_thread_id);
    return;
  }

  // Phase 4: single dispatch path through the ClaudeDaemonRegistry.
  // The registry owns spawn-if-needed, 2s debounce, per-topic queue, and
  // crash respawn. Reply text streams back asynchronously via the
  // postTelegramTextFromDaemon callback wired in initDaemonRegistry().
  daemonDispatch(String(routeKey), msg);
  process.stdout.write(`[${new Date().toISOString()}] update ${u.update_id} → daemon[${routeKey}] (${text0.length} chars)\n`);
}

// ─── main loop ───────────────────────────────────────────────────────────────

/** fetch with a hard client-side timeout. Telegram long-poll only sets a
 *  SERVER-side timeout; without a client abort, a half-open/stalled TCP
 *  connection (Wi-Fi flap, NAT drop) makes `await fetch` hang forever and
 *  wedges the poll loop — alive but stuck, heartbeat frozen. AbortController
 *  bounds it so the call throws and the loop's retry path recovers. */
export async function fetchWithTimeout(url: string, timeoutMs: number, init?: RequestInit): Promise<Response> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function getUpdates(offset: number): Promise<TgUpdate[]> {
  // Default getUpdates does NOT include my_chat_member or callback_query.
  // Pass allowed_updates explicitly so the auto-pair flow can fire. Telegram
  // remembers the last allowed_updates per-bot, but we pass it every call so
  // a fresh deploy works correctly without any server-side state assumption.
  const allowed = encodeURIComponent(JSON.stringify([
    "message", "edited_message", "my_chat_member", "callback_query",
  ]));
  const url = `${getApiBase()}/getUpdates?timeout=${POLL_TIMEOUT_SEC}&offset=${offset}&allowed_updates=${allowed}`;
  // Client timeout = server long-poll window + 15s slack. A stalled connection
  // aborts here instead of hanging the loop forever.
  const resp = await fetchWithTimeout(url, (POLL_TIMEOUT_SEC + 15) * 1000);
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
    const resp = await fetchWithTimeout(`${getApiBase()}/getMe`, 15_000);
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
  // Install signal handlers BEFORE any work — if SIGTERM arrives during
  // preflight/initDaemonRegistry, default node behavior is silent exit,
  // which would orphan partly-spawned daemons holding session locks.
  // The handler is null-safe against `daemonRegistry` not being constructed
  // yet because the void-IIFE checks `if (daemonRegistry)`.
  for (const sig of ["SIGTERM", "SIGINT"] as const) {
    process.on(sig, () => {
      process.stdout.write(`[${new Date().toISOString()}] poller: ${sig} received — shutting down daemons\n`);
      void (async () => {
        if (daemonRegistry) await daemonRegistry.shutdown();
        process.exit(0);
      })();
    });
  }

  if (!process.env.TELEGRAM_BOT_TOKEN) {
    process.stderr.write("poller: TELEGRAM_BOT_TOKEN must be set\n");
    process.exit(1);
  }
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  ensureReleaseFlagDir();
  cleanupStaleReleaseFlags();
  ensureInjectDir();
  await preflightBotToken();
  let offset = readOffset();
  refreshMountsIfChanged();
  refreshPairedIfChanged();
  refreshAckReactionIfChanged();
  initDaemonRegistry();
  startInjectWatcher();
  await processInjectFlags(); // drain anything dropped before this poller started

  const startupChat = effectiveChatId() ?? "(unpaired — awaiting /pair)";
  process.stdout.write(`[${new Date().toISOString()}] poller starting (Phase 4 daemon mode), offset=${offset}, chat=${startupChat}, mounts=${mountsCache.size}\n`);

  for (;;) {
    touchHeartbeat();
    refreshMountsIfChanged();
    refreshPairedIfChanged();
    refreshAckReactionIfChanged();
    // β handoff: process any release / reacquire flag files written by
    // `cta release-daemon` / Pager. Cheap when the dir is empty (steady
    // state — nobody clicks "Open in Terminal" most of the time).
    await processReleaseFlags();
    // Watch-live input: drain any inject files (fallback to the fs.watch path).
    await processInjectFlags();
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
