#!/usr/bin/env bun
/**
 * Watches one topic's tmux pane for alt-screen entry/exit, which is how
 * claude signals it's showing an interactive picker (/effort, /model, file
 * picker, etc.). On transition the watcher pushes a Telegram message with
 * a snapshot of the picker so the user knows claude is waiting on UI input
 * that the bot CAN'T deliver directly — they need Pager's Watch live (or
 * any tmux client) to actually select.
 *
 * Why poll tmux instead of parsing the pipe-pane log:
 *
 *   tmux exposes `#{alternate_on}` per-pane (1 in alt-screen, 0 otherwise).
 *   Polling it is dramatically simpler than tracking `\x1b[?1049h` and
 *   `\x1b[?1049l` byte sequences in a raw stream where escape codes can
 *   split across reads, get interleaved with other escapes, or be nested
 *   inside other modes. The tmux probe is one fork+exit per tick and we
 *   only poll while a topic-wrapper is alive.
 *
 * Spawned by agent/topic-wrapper.sh as a background subprocess, killed via
 * an EXIT trap when the wrapper exits.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ─── env loading ─────────────────────────────────────────────────────────────

/**
 * Load TELEGRAM_BOT_TOKEN from the plugin's .env, same path pager-notify.sh
 * sources. Already-set process.env values win — lets tests inject a token
 * without touching the user's real .env. Returns true if a token is now
 * available, false if the watcher should give up early.
 */
function loadToken(): boolean {
  if (process.env.TELEGRAM_BOT_TOKEN) return true;
  const envFile = join(homedir(), ".claude/channels/telegram/.env");
  if (!existsSync(envFile)) return false;
  try {
    const content = readFileSync(envFile, "utf-8");
    for (const line of content.split("\n")) {
      const m = line.match(/^\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+?)\s*$/);
      if (m) {
        process.env.TELEGRAM_BOT_TOKEN = m[1].replace(/^["']|["']$/g, "");
        return true;
      }
    }
  } catch {
    /* fall through */
  }
  return false;
}

// ─── tmux probes ─────────────────────────────────────────────────────────────

const TMUX = process.env.PICKER_WATCHER_TMUX ?? "tmux";

/**
 * Returns true if the given tmux session's active pane is in alt-screen
 * mode. Errors (session missing, tmux missing) collapse to false — the
 * watcher should not crash if the session momentarily disappears (e.g.,
 * during a claude restart).
 */
export async function inAltScreen(session: string): Promise<boolean> {
  try {
    const proc = Bun.spawn([TMUX, "display-message", "-p", "-t", session, "#{alternate_on}"], {
      stdout: "pipe",
      stderr: "ignore",
    });
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    return out.trim() === "1";
  } catch {
    return false;
  }
}

/**
 * Snapshot of what's currently visible in the pane. Plain text (no -e flag),
 * so ANSI is stripped by tmux before we get the bytes. Trimmed to drop the
 * trailing whitespace tmux emits to fill the pane height.
 */
export async function capturePane(session: string): Promise<string> {
  try {
    const proc = Bun.spawn([TMUX, "capture-pane", "-p", "-t", session], {
      stdout: "pipe",
      stderr: "ignore",
    });
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    return out.replace(/\s+$/g, "");
  } catch {
    return "";
  }
}

// ─── transition pure function (testable) ─────────────────────────────────────

export type Transition = "enter" | "exit" | "none";

/** Pure: given previous + current alt-screen state, return the transition. */
export function detectTransition(prev: boolean, current: boolean): Transition {
  if (current && !prev) return "enter";
  if (!current && prev) return "exit";
  return "none";
}

// ─── Telegram send ───────────────────────────────────────────────────────────

const API_BASE = process.env.TELEGRAM_API_BASE;

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function apiBase(): string {
  if (API_BASE) return API_BASE;
  return `https://api.telegram.org/bot${process.env.TELEGRAM_BOT_TOKEN}`;
}

/**
 * Single-shot Telegram message. Best-effort: a failed send doesn't kill
 * the watcher. We just log to stderr; the next transition can retry.
 */
async function sendTelegram(text: string, chatId: string, threadId: string): Promise<void> {
  try {
    const body: Record<string, unknown> = {
      chat_id: chatId,
      text,
      parse_mode: "HTML",
    };
    if (threadId) body.message_thread_id = Number(threadId);
    const resp = await fetch(`${apiBase()}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!resp.ok) {
      process.stderr.write(`picker-watcher: telegram send failed: ${resp.status}\n`);
    }
  } catch (e) {
    process.stderr.write(`picker-watcher: telegram send error: ${(e as Error).message}\n`);
  }
}

// ─── message templates ───────────────────────────────────────────────────────

function pickerOpenMessage(snapshot: string): string {
  // Telegram caps a single message at 4096 chars. The header + decorations
  // are ~120 chars, so leave room — truncate the snapshot generously.
  const SNAPSHOT_MAX = 3500;
  let body = snapshot;
  if (body.length > SNAPSHOT_MAX) {
    body = body.slice(-SNAPSHOT_MAX) + "\n…(truncated)";
  }
  return [
    "🔘 <b>claude opened a picker</b>",
    "",
    `<pre>${escapeHtml(body)}</pre>`,
    "",
    "Use <b>Pager → Watch live</b> to select.",
  ].join("\n");
}

const PICKER_CLOSED = "✓ Picker closed — claude continuing.";

// ─── CLI / main loop ─────────────────────────────────────────────────────────

interface Args {
  session: string;
  chatId: string;
  threadId: string;
  intervalMs: number;
}

export function parseArgs(argv: string[]): Args {
  const out: Args = { session: "", chatId: "", threadId: "", intervalMs: 500 };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const val = argv[i + 1];
    switch (flag) {
      case "--session": out.session = val ?? ""; i++; break;
      case "--chat-id": out.chatId = val ?? ""; i++; break;
      case "--thread-id": out.threadId = val ?? ""; i++; break;
      case "--interval-ms": out.intervalMs = Number(val) || 500; i++; break;
    }
  }
  return out;
}

async function mainLoop(args: Args): Promise<void> {
  let inPicker = false;
  while (true) {
    const current = await inAltScreen(args.session);
    const transition = detectTransition(inPicker, current);
    if (transition === "enter") {
      // Brief settle delay — claude often clears the alt-screen and then
      // renders the picker over a few ticks. Snapshotting too early gives
      // a half-rendered or empty pane.
      await new Promise((r) => setTimeout(r, 200));
      const snap = await capturePane(args.session);
      await sendTelegram(pickerOpenMessage(snap), args.chatId, args.threadId);
      inPicker = true;
    } else if (transition === "exit") {
      await sendTelegram(PICKER_CLOSED, args.chatId, args.threadId);
      inPicker = false;
    }
    await new Promise((r) => setTimeout(r, args.intervalMs));
  }
}

// Run as CLI when invoked directly (not when imported by tests).
if (import.meta.path === Bun.main) {
  const args = parseArgs(process.argv.slice(2));
  if (!args.session || !args.chatId) {
    process.stderr.write(
      "usage: bun picker-watcher.ts --session topic-<id> --chat-id <id> [--thread-id <id>] [--interval-ms 500]\n"
    );
    process.exit(2);
  }
  if (!loadToken()) {
    process.stderr.write("picker-watcher: no TELEGRAM_BOT_TOKEN — exiting quietly\n");
    process.exit(0);
  }
  mainLoop(args).catch((e) => {
    process.stderr.write(`picker-watcher: fatal: ${(e as Error).message}\n`);
    process.exit(1);
  });
}
