/**
 * Tests for the poller's in-chat command flow.
 *
 * Strategy:
 *   - Override CTA_STATE_DIR to a tmpdir so each test owns its state files.
 *   - Override TELEGRAM_BOT_TOKEN + TELEGRAM_API_BASE so reply() POSTs go to
 *     a local fake server. The fake server records every request so tests
 *     can assert outbound message bodies.
 *   - Import the command handlers directly from poller.ts (they're exported
 *     under `import.meta.main` so importing won't start the loop).
 */
import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// Spin up a fake Telegram Bot API server. Records sendMessage calls so each
// test can introspect what the poller tried to send.
type SentMessage = {
  chat_id: number | string;
  message_thread_id?: number;
  text: string;
  reply_markup?: { inline_keyboard: unknown };
};
type CallbackAck = { callback_query_id: string; text?: string; show_alert?: boolean };
const sent: SentMessage[] = [];
const callbackAcks: CallbackAck[] = [];

const server = Bun.serve({
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname.endsWith("/sendMessage")) {
      const body = (await req.json()) as SentMessage;
      sent.push(body);
      return new Response(JSON.stringify({ ok: true, result: { message_id: sent.length } }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    if (url.pathname.endsWith("/answerCallbackQuery")) {
      const body = (await req.json()) as CallbackAck;
      callbackAcks.push(body);
      return new Response(JSON.stringify({ ok: true, result: true }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    return new Response(JSON.stringify({ ok: false, description: "not mocked" }), { status: 404 });
  },
});
const FAKE_API = `http://localhost:${server.port}/bot-fake`;
afterAll(() => server.stop());

// Per-test tmpdir for state.
const STATE = join(tmpdir(), `poller-test-${process.pid}-${Date.now()}`);
process.env.CTA_STATE_DIR = STATE;
process.env.TELEGRAM_BOT_TOKEN = "fake";
process.env.TELEGRAM_API_BASE = FAKE_API;
delete process.env.MAIN_CHAT_ID; // make sure pre-pair tests start unpaired

// Import after env is set so the module-level constants pick up our overrides.
const poller = await import("./poller");

const PAIRING_CODE_FILE = join(STATE, "pairing-code");
const PAIRED_STATE_FILE = join(STATE, "paired.json");
const MOUNTS_JSON = join(STATE, "mounts.json");

function resetState(): void {
  sent.length = 0;
  callbackAcks.length = 0;
  rmSync(STATE, { recursive: true, force: true });
  mkdirSync(STATE, { recursive: true, mode: 0o700 });
  poller.refreshPairedIfChanged();
  poller.refreshMountsIfChanged();
  poller._setBotUserIdForTest(99999); // pretend bot id; tests use distinct user ids
}

beforeEach(() => resetState());

function msg(args: {
  text: string;
  chat_id?: number;
  thread_id?: number;
  from_id?: number;
}): poller.TgMessage {
  return {
    message_id: 1,
    chat: { id: args.chat_id ?? -1001234 },
    from: args.from_id != null ? { id: args.from_id } : undefined,
    message_thread_id: args.thread_id,
    text: args.text,
  };
}

describe("pre-pair state", () => {
  test("/pair with correct code claims chat + writes paired.json + consumes code", async () => {
    writeFileSync(PAIRING_CODE_FILE, "ABCD-EFGH\n");
    poller.refreshPairedIfChanged();

    const handled = await poller.tryHandleCommand(
      msg({ text: "/pair ABCD-EFGH", chat_id: -1001, from_id: 99 }),
    );

    expect(handled).toBe(true);
    expect(existsSync(PAIRED_STATE_FILE)).toBe(true);
    const paired = JSON.parse(readFileSync(PAIRED_STATE_FILE, "utf8")) as poller.PairedState;
    expect(paired.chat_id).toBe(-1001);
    expect(paired.user_id).toBe(99);
    expect(existsSync(PAIRING_CODE_FILE)).toBe(false); // consumed
    expect(sent.length).toBeGreaterThanOrEqual(1);
    expect(sent[0].text).toContain("Paired");
  });

  test("/pair with wrong code does NOT claim chat", async () => {
    writeFileSync(PAIRING_CODE_FILE, "ABCD-EFGH\n");
    poller.refreshPairedIfChanged();

    const handled = await poller.tryHandleCommand(
      msg({ text: "/pair WRONG-CODE", chat_id: -1001, from_id: 99 }),
    );

    expect(handled).toBe(true); // command was consumed (don't fall through)
    expect(existsSync(PAIRED_STATE_FILE)).toBe(false);
    expect(existsSync(PAIRING_CODE_FILE)).toBe(true); // NOT consumed
    expect(sent.some((m) => m.text.includes("did not match"))).toBe(true);
  });

  test("/pair when no pairing-code file is present stays silent", async () => {
    // No pairing-code on disk → either never installed or already consumed.
    // Per security model, stay silent so attackers can't probe.
    poller.refreshPairedIfChanged();

    const handled = await poller.tryHandleCommand(
      msg({ text: "/pair AB7K-9XQR", chat_id: -1001, from_id: 99 }),
    );

    expect(handled).toBe(true);
    expect(sent.length).toBe(0);
    expect(existsSync(PAIRED_STATE_FILE)).toBe(false);
  });

  test("/start (Telegram's first-touch convention) tells the user how to pair", async () => {
    // No paired.json, no pairing-code file — a totally fresh bot getting its
    // first Telegram message ever. Telegram clients auto-send /start.
    poller.refreshPairedIfChanged();
    const handled = await poller.tryHandleCommand(
      msg({ text: "/start", chat_id: -1001, from_id: 99 }),
    );
    expect(handled).toBe(true);
    expect(sent.some((m) => m.text.includes("waiting to be paired"))).toBe(true);
    expect(sent.some((m) => m.text.includes("/pair"))).toBe(true);
  });

  test("non-/pair commands fall through pre-pair", async () => {
    // /mount, /list etc. pre-pair → return false (not handled), so the caller
    // can drop them silently (no MAIN_CHAT_ID set yet → routeMessage returns
    // null anyway).
    const handled = await poller.tryHandleCommand(
      msg({ text: "/mount /tmp", chat_id: -1001, from_id: 99 }),
    );

    expect(handled).toBe(false);
    expect(sent.length).toBe(0);
  });
});

describe("post-pair state", () => {
  function pair(opts?: { chat_id?: number; user_id?: number }): void {
    const state: poller.PairedState = {
      version: 1,
      chat_id: opts?.chat_id ?? -1001,
      user_id: opts?.user_id ?? 99,
      paired_at: new Date().toISOString(),
    };
    writeFileSync(PAIRED_STATE_FILE, JSON.stringify(state, null, 2));
    poller.refreshPairedIfChanged();
  }

  test("effectiveChatId prefers paired.json over env", () => {
    process.env.MAIN_CHAT_ID = "-999"; // env override
    pair({ chat_id: -1001 });
    try {
      expect(poller.effectiveChatId()).toBe("-1001"); // paired wins
      expect(poller.effectiveUserId()).toBe(99);
    } finally {
      delete process.env.MAIN_CHAT_ID;
    }
  });

  test("/list with no mounts replies friendly message", async () => {
    pair();
    const handled = await poller.tryHandleCommand(
      msg({ text: "/list", chat_id: -1001, from_id: 99 }),
    );
    expect(handled).toBe(true);
    expect(sent.some((m) => m.text.includes("No mounts"))).toBe(true);
  });

  test("/mount with bad path rejects without writing mounts.json", async () => {
    pair();
    const handled = await poller.tryHandleCommand(
      msg({ text: "/mount /definitely/not/a/dir", chat_id: -1001, thread_id: 42, from_id: 99 }),
    );
    expect(handled).toBe(true);
    expect(sent.some((m) => m.text.includes("not a directory"))).toBe(true);
    expect(existsSync(MOUNTS_JSON)).toBe(false);
  });

  test("/mount outside of a topic rejects with hint", async () => {
    pair();
    // thread_id absent → user sent /mount in the chat root, not a topic
    const handled = await poller.tryHandleCommand(
      msg({ text: "/mount /tmp", chat_id: -1001, from_id: 99 }),
    );
    expect(handled).toBe(true);
    expect(sent.some((m) => m.text.includes("inside a forum topic"))).toBe(true);
  });

  test("commands from non-paired user_id are silently dropped (handled, no reply)", async () => {
    pair({ user_id: 99 });
    sent.length = 0;
    const handled = await poller.tryHandleCommand(
      msg({ text: "/list", chat_id: -1001, from_id: 12345 }),
    );
    expect(handled).toBe(true); // consumed so claude doesn't see it
    expect(sent.length).toBe(0); // but no reply leaked
  });

  test("/pair after paired returns 'already paired' message", async () => {
    pair();
    const handled = await poller.tryHandleCommand(
      msg({ text: "/pair ANY-CODE", chat_id: -1001, from_id: 99 }),
    );
    expect(handled).toBe(true);
    expect(sent.some((m) => m.text.includes("Already paired"))).toBe(true);
  });
});

describe("bot-added intro (/pair <code> flow)", () => {
  // The inline-keyboard auto-pair flow was removed (2026-05-13) because it
  // depended on callback_query delivery, which depends on bot membership
  // state being settled — a chicken/egg in forum groups with admin/privacy
  // caching. The bot now sends a plain text intro pointing the user to
  // `/pair <code>`, which is a Telegram `/command` and is delivered to even
  // non-admin privacy-enabled bots reliably.
  const BOT_ID = 99999;
  const INVITER_ID = 7;
  const CHAT_ID = -1001;

  function botAddedEvent(opts?: { chat_id?: number; inviter_id?: number; status?: string }) {
    return {
      chat: { id: opts?.chat_id ?? CHAT_ID },
      from: { id: opts?.inviter_id ?? INVITER_ID, first_name: "Alice" },
      new_chat_member: { user: { id: BOT_ID, is_bot: true }, status: opts?.status ?? "administrator" },
      old_chat_member: { user: { id: BOT_ID, is_bot: true }, status: "left" },
    };
  }

  test("my_chat_member (bot added) sends plain text intro — no inline keyboard, no pending pair", async () => {
    await poller.handleMyChatMember(botAddedEvent());
    expect(sent.length).toBe(1);
    expect(sent[0].reply_markup).toBeUndefined();
    expect(sent[0].text).toContain("/pair");
    expect(sent[0].text).toContain("cta pair-code");
    // No state mutation — the user has to send /pair <code> to actually pair.
    expect(existsSync(PAIRED_STATE_FILE)).toBe(false);
  });

  test("stale callback pair-confirm declines (no pending pair set anymore)", async () => {
    // Even if a user somehow taps a button from a historical message, the
    // poller no longer stages pendingPair, so the callback returns the
    // "expired" alert and refuses to pair.
    await poller.handleMyChatMember(botAddedEvent());
    await poller.handleCallbackQuery({
      id: "cb1",
      from: { id: INVITER_ID },
      message: { chat: { id: CHAT_ID }, message_id: 1 },
      data: "pair-confirm",
    });
    expect(existsSync(PAIRED_STATE_FILE)).toBe(false);
    expect(callbackAcks.some((a) => a.show_alert === true && a.text?.includes("expired"))).toBe(true);
  });

  test("bot added when already paired declines (still plain text, no inline)", async () => {
    // Pre-stage paired state.
    writeFileSync(PAIRED_STATE_FILE, JSON.stringify({
      version: 1, chat_id: -7777, user_id: 1, paired_at: new Date().toISOString(),
    }));
    poller.refreshPairedIfChanged();
    sent.length = 0;

    await poller.handleMyChatMember(botAddedEvent({ chat_id: CHAT_ID }));

    // Should reply with "already paired" — single plain reply, no inline keyboard.
    expect(sent.length).toBe(1);
    expect(sent[0].text).toContain("already paired");
    expect(sent[0].reply_markup).toBeUndefined();
  });

  test("my_chat_member for a non-bot user is ignored", async () => {
    const evt = botAddedEvent();
    evt.new_chat_member.user.id = 12345; // not the bot
    await poller.handleMyChatMember(evt);
    expect(sent.length).toBe(0);
  });
});

describe("plain text (non-command) handling", () => {
  test("plain text returns false (let routeMessage handle it)", async () => {
    const handled = await poller.tryHandleCommand(
      msg({ text: "hello there", chat_id: -1001, from_id: 99 }),
    );
    expect(handled).toBe(false);
  });

  test("unknown /command from paired user falls through (claude can see it)", async () => {
    writeFileSync(PAIRED_STATE_FILE, JSON.stringify({
      version: 1, chat_id: -1001, user_id: 99, paired_at: new Date().toISOString(),
    }));
    poller.refreshPairedIfChanged();

    const handled = await poller.tryHandleCommand(
      msg({ text: "/something-not-ours arg", chat_id: -1001, from_id: 99 }),
    );
    expect(handled).toBe(false); // pass through to claude
  });
});
