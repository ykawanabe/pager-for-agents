/**
 * Telegram outbound wire — the Bot API egress, extracted from poller.ts in
 * Phase 1 of the ChatTransport migration (see docs/plans/chat-transport-interface.md §9).
 *
 * Scope (P1, this slice): the OUTBOUND egress only — every send/react/typing/
 * button/edit/answer the poller fires. These take primitives, so there is no
 * inbound-type graph to drag along. `getUpdates`/`getMe` and the inbound Tg*
 * types stay in poller for now; they move in P2 alongside types.ts.
 *
 * Design rules this file obeys:
 *   - Pure functions; reads env LAZILY (TELEGRAM_BOT_TOKEN / TELEGRAM_API_BASE)
 *     so importing it for tests needs no real token, and tests can repoint
 *     egress at a mock server by setting TELEGRAM_API_BASE before first call.
 *   - NO imports from poller.ts → no import cycle (poller imports THIS, never
 *     the reverse). The adapter knows how to talk to Telegram; it holds no
 *     product policy.
 *   - Policy stays in the poller: whether to ack and with which glyph
 *     (access.json), the typing keepalive loop, the long-poll offset cursor.
 *     This file is the dumb wire those policies drive.
 *
 * Log strings are preserved verbatim from the poller originals ("poller: …
 * failed") so this extraction is a zero-observable-change refactor.
 */

/**
 * Bot API base URL. Tests set TELEGRAM_API_BASE to a local mock server; prod
 * builds the canonical `https://api.telegram.org/bot<token>` form. Read lazily
 * on every call so the env override applies regardless of import order.
 */
export function getApiBase(): string {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN must be set");
  return process.env.TELEGRAM_API_BASE ?? `https://api.telegram.org/bot${token}`;
}

/**
 * Send plain text to a chat (and optional forum topic). Best-effort: a failed
 * send is logged, never thrown — the poller's hot path must not unwind on a
 * transient Bot API hiccup. (Was poller `reply()`.)
 */
export async function sendText(
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

/**
 * Set a single reaction on a message. The wire shared by both ack stages —
 * the *policy* (whether to react, and the delivered vs. read glyph) lives in
 * the poller, which passes the chosen emoji here. Telegram limits a bot to one
 * reaction per message, so this replaces rather than stacks. ok:false (invalid
 * emoji on the free-bot whitelist) is swallowed: the operator picks the glyph
 * in Pager and a rejected one just no-ops.
 */
export async function setReaction(chat_id: number, message_id: number, emoji: string): Promise<void> {
  try {
    await fetch(`${getApiBase()}/setMessageReaction`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id,
        message_id,
        reaction: [{ type: "emoji", emoji }],
      }),
    });
  } catch (e) {
    process.stderr.write(`poller: setMessageReaction failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

/**
 * Fire a "typing…" chat action. Telegram auto-clears it after ~5s; the poller's
 * keepalive loop re-fires it. (Was the body of poller `sendTyping()`.)
 */
export async function sendChatAction(chat_id: number, thread_id?: number): Promise<void> {
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

/**
 * Edit a sent message's text in-place. Omitting reply_markup also drops any
 * inline keyboard on the original — one call covers "append the user's choice
 * + remove the buttons" for an answered button prompt. Best-effort: a failed
 * edit leaves a stale button, not a delivery loss.
 */
export async function editMessageText(
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

/**
 * Send a message carrying an inline keyboard. Returns the sent message's ref
 * so the caller can later edit it (e.g. to record the chosen button), or null
 * on failure.
 */
export async function sendInlineKeyboard(
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

/**
 * Acknowledge a callback query (button tap) so Telegram stops the client-side
 * spinner. Optional toast text / alert. Best-effort.
 */
export async function answerCallback(callback_query_id: string, text?: string, alert?: boolean): Promise<void> {
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
