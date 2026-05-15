/**
 * typing-keepalive — keeps Telegram's "typing…" bubble alive while claude
 * composes a reply.
 *
 * Background: Telegram's sendChatAction auto-clears after 5 seconds. The
 * poller previously fired it once at dispatch, so any claude turn longer
 * than 5s lost the indicator and the user couldn't tell the bot was still
 * working. This module re-fires sendChatAction on an interval until the
 * mcp-telegram side signals "done" by removing the marker file.
 *
 * Coordination is via a per-target file on disk:
 *   $STATE_DIR/typing/<chat_id>__<thread_id_or_dm>.token
 *
 * Contents = a per-dispatch token. The poller writes the file (and remembers
 * the token) when dispatching; mcp-telegram removes it after a successful
 * sendMessage. The keepalive loop stops when (a) the file is missing,
 * (b) the file's token no longer matches (a newer dispatch took over), or
 * (c) the hard timeout elapses.
 */
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

function typingDir(stateDir: string): string {
  return join(stateDir, "typing");
}

/**
 * The marker filename uses `__` as the chat/thread separator (not `/`) so it
 * stays a single path component, and `dm` as the no-topic sentinel so DM and
 * topic markers can't collide on the filesystem. Negative chat ids are
 * fine — they're valid filename characters.
 */
export function typingMarkerPath(
  stateDir: string,
  chatId: number | string,
  threadId?: number | string | null,
): string {
  const t =
    threadId == null || threadId === "" || threadId === "dm"
      ? "dm"
      : String(threadId);
  return join(typingDir(stateDir), `${chatId}__${t}.token`);
}

export function markTypingActive(
  stateDir: string,
  chatId: number,
  threadId?: number,
): string {
  mkdirSync(typingDir(stateDir), { recursive: true, mode: 0o700 });
  const token = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  writeFileSync(typingMarkerPath(stateDir, chatId, threadId), token, { mode: 0o600 });
  return token;
}

export function markTypingDone(
  stateDir: string,
  chatId: number | string,
  threadId?: number | string | null,
): void {
  try {
    unlinkSync(typingMarkerPath(stateDir, chatId, threadId));
  } catch {
    // File missing is the happy path on a second call. Other errors are
    // not actionable — we just stop trying.
  }
}

function readTypingToken(
  stateDir: string,
  chatId: number,
  threadId?: number,
): string | null {
  try {
    return readFileSync(typingMarkerPath(stateDir, chatId, threadId), "utf8");
  } catch {
    return null;
  }
}

export interface TypingKeepaliveOpts {
  stateDir: string;
  chatId: number;
  threadId?: number;
  token: string;
  send: () => Promise<void>;
  /** Re-fire interval. Telegram's typing action lasts ~5s, so 4s leaves a
   * small overlap. */
  intervalMs?: number;
  /** Hard upper bound so a runaway loop can't fire forever if the marker
   * never gets cleared (e.g. mcp-telegram crashes mid-reply). */
  maxMs?: number;
}

/**
 * Fires `send` immediately, then re-fires on `intervalMs` until the marker
 * file is missing or its token no longer matches, or `maxMs` elapses.
 * Fire-and-forget: errors inside `send` are the caller's responsibility (the
 * poller's sendTyping already swallows + logs them).
 */
export async function runTypingKeepalive(opts: TypingKeepaliveOpts): Promise<void> {
  const interval = opts.intervalMs ?? 4_000;
  const max = opts.maxMs ?? 10 * 60_000;
  const start = Date.now();
  await opts.send();
  while (Date.now() - start < max) {
    await new Promise((r) => setTimeout(r, interval));
    const current = readTypingToken(opts.stateDir, opts.chatId, opts.threadId);
    if (current !== opts.token) return;
    await opts.send();
  }
}
