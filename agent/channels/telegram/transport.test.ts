/**
 * Tests for TelegramTransport (P2). Two layers:
 *   - pure: capabilities struct + normalizeUpdate (no network);
 *   - wire: methods routed at a local fake Bot API (TELEGRAM_API_BASE), the
 *     same seam the poller's own tests + the E2E harness use.
 * Plus a conformance check that the class satisfies ChatTransport + the optional
 * interfaces it advertises (compile-time assignment + runtime type guards).
 */
import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ─── env must be set before constructing the transport (ctor reads paths/env) ─
const STATE = join(tmpdir(), `tg-transport-test-${process.pid}`);
mkdirSync(STATE, { recursive: true });
const ACCESS_JSON = join(STATE, "access.json");
process.env.CTA_STATE_DIR = STATE;
process.env.ACCESS_JSON = ACCESS_JSON;
process.env.TELEGRAM_BOT_TOKEN = "fake";
process.env.POLL_TIMEOUT_SEC = "1";

// ─── fake Bot API ─────────────────────────────────────────────────────────────
type Sent = { chat_id: number | string; message_thread_id?: number; text: string; reply_markup?: unknown };
type Reaction = { chat_id: number; message_id: number; reaction: Array<{ type: string; emoji: string }> };
const sent: Sent[] = [];
const reactions: Reaction[] = [];
const edits: Array<{ chat_id: number; message_id: number; text: string }> = [];
let updateQueue: unknown[] = [];

const server = Bun.serve({
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    const p = url.pathname;
    if (p.endsWith("/getMe")) {
      return Response.json({ ok: true, result: { id: 4242, username: "pager_bot" } });
    }
    if (p.endsWith("/getUpdates")) {
      const out = updateQueue;
      updateQueue = [];
      if (out.length === 0) await new Promise((r) => setTimeout(r, 30)); // avoid hot spin
      return Response.json({ ok: true, result: out });
    }
    if (p.endsWith("/sendMessage")) {
      const body = (await req.json()) as Sent;
      sent.push(body);
      return Response.json({ ok: true, result: { message_id: sent.length } });
    }
    if (p.endsWith("/setMessageReaction")) {
      reactions.push((await req.json()) as Reaction);
      return Response.json({ ok: true, result: true });
    }
    if (p.endsWith("/editMessageText")) {
      edits.push((await req.json()) as { chat_id: number; message_id: number; text: string });
      return Response.json({ ok: true, result: true });
    }
    return Response.json({ ok: true, result: true });
  },
});
process.env.TELEGRAM_API_BASE = `http://localhost:${server.port}/botfake`;

afterAll(() => {
  server.stop(true);
  rmSync(STATE, { recursive: true, force: true });
});

// Import AFTER env is set so the adapter's lazy getApiBase() resolves the mock.
const { TelegramTransport, normalizeUpdate } = await import("./transport");
const guards = await import("../types");

beforeEach(() => {
  sent.length = 0;
  reactions.length = 0;
  edits.length = 0;
  updateQueue = [];
  writeFileSync(ACCESS_JSON, JSON.stringify({ ackReaction: "👀" }));
});

describe("capabilities", () => {
  const t = new TelegramTransport();
  test("reports Telegram platform truth", () => {
    expect(t.channel).toBe("telegram");
    expect(t.transportVersion).toBe(1);
    expect(t.capabilities.inboundTransport).toBe("long-poll");
    expect(t.capabilities.threadModel).toBe("forum-topic");
    expect(t.capabilities.ackMechanism).toBe("reaction-swap");
    expect(t.capabilities.text.maxChars).toBe(4096);
    expect(t.capabilities.reaction.maxPerBotPerMessage).toBe(1);
    expect(t.capabilities.reaction.canStack).toBe(false);
  });
  test("ack whitelist contains the product's glyphs (👀 default, 👌 read)", () => {
    expect(t.capabilities.reaction.allowedEmoji).toContain("👀");
    expect(t.capabilities.reaction.allowedEmoji).toContain("👌");
  });
});

describe("conformance (type guards reflect implemented interfaces)", () => {
  const t = new TelegramTransport();
  test("implements editable / reactable / buttons / proactive", () => {
    expect(guards.isEditable(t)).toBe(true);
    expect(guards.isReactable(t)).toBe(true);
    expect(guards.isButtonCapable(t)).toBe(true);
    expect(guards.isProactive(t)).toBe(true);
  });
  test("does NOT advertise the deferred interfaces (typing/files/slash)", () => {
    expect(guards.isTyping(t)).toBe(false);
    expect(guards.isFileCapable(t)).toBe(false);
    expect(guards.isSlashCommandable(t)).toBe(false);
  });
});

describe("wire methods route at the Bot API", () => {
  const t = new TelegramTransport();

  test("sendText posts to a chat + thread", async () => {
    await t.sendText({ to: { channel: "telegram", chatId: -100, threadId: 42 }, text: "hello" });
    expect(sent).toHaveLength(1);
    expect(sent[0].text).toBe("hello");
    expect(sent[0].message_thread_id).toBe(42);
  });

  test("sendText chunks text above maxChars", async () => {
    const big = "x".repeat(5000);
    await t.sendText({ to: { channel: "telegram", chatId: 1 }, text: big });
    expect(sent.length).toBeGreaterThan(1);
    expect(sent.every((s) => s.text.length <= 4096)).toBe(true);
  });

  test("setDeliveredAck uses the operator glyph; null when disabled", async () => {
    const ref = { channel: "telegram" as const, chatId: 7, messageId: 9 };
    const h = await t.setDeliveredAck(ref);
    expect(h).not.toBeNull();
    expect(reactions[0].reaction[0].emoji).toBe("👀");

    writeFileSync(ACCESS_JSON, JSON.stringify({ ackReaction: "" })); // operator disabled
    reactions.length = 0;
    const h2 = await t.setDeliveredAck(ref);
    expect(h2).toBeNull();
    expect(reactions).toHaveLength(0);
  });

  test("setReadAcks flips many handles to 👌 (N:1 flush)", async () => {
    const handles = await Promise.all([
      t.setDeliveredAck({ channel: "telegram", chatId: 1, messageId: 1 }),
      t.setDeliveredAck({ channel: "telegram", chatId: 1, messageId: 2 }),
    ]);
    reactions.length = 0;
    await t.setReadAcks(handles.filter((h): h is NonNullable<typeof h> => h != null));
    expect(reactions).toHaveLength(2);
    expect(reactions.every((r) => r.reaction[0].emoji === "👌")).toBe(true);
  });

  test("editText edits in place", async () => {
    await t.editText({ channel: "telegram", chatId: 3, messageId: 5 }, "edited");
    expect(edits[0]).toEqual({ chat_id: 3, message_id: 5, text: "edited" });
  });

  test("sendButtons sends an inline keyboard", async () => {
    const ref = await t.sendButtons({ to: { channel: "telegram", chatId: 8 }, text: "pick", buttons: ["A", "B"] });
    expect(ref.channel).toBe("telegram");
    expect(sent[0].reply_markup).toBeDefined();
  });

  test("whoami returns the bot identity", async () => {
    const me = await t.whoami();
    expect(me.id).toBe("4242");
    expect(me.username).toBe("pager_bot");
  });
});

describe("key derivation", () => {
  const t = new TelegramTransport();
  test("mountCacheKey + routingKey match the store / registry formats", () => {
    expect(t.mountCacheKey({ channel: "telegram", chatId: -100, threadId: 42 })).toBe("telegram:42");
    expect(t.mountCacheKey({ channel: "telegram", chatId: -100 })).toBe("telegram:dm");
    expect(t.routingKey({ channel: "telegram", chatId: -100, threadId: 42 })).toBe("42");
    expect(t.routingKey({ channel: "telegram", chatId: -100 })).toBe("dm");
  });
});

describe("normalizeUpdate (pure)", () => {
  test("message → message event with normalized fields + raw", () => {
    const ev = normalizeUpdate({
      update_id: 1,
      message: { message_id: 11, from: { id: 99 }, chat: { id: -100 }, message_thread_id: 42, text: "hi" },
    });
    expect(ev?.kind).toBe("message");
    if (ev?.kind === "message") {
      expect(ev.text).toBe("hi");
      expect(ev.routingKey).toBe("42");
      expect(ev.from.id).toBe("99");
      expect(ev.messageRef).toEqual({ channel: "telegram", chatId: -100, messageId: 11 });
      expect(ev.raw.update_id).toBe(1);
    }
  });

  test("DM/General (no thread) routes to 'dm'", () => {
    const ev = normalizeUpdate({ update_id: 2, message: { message_id: 1, chat: { id: 5 }, text: "yo" } });
    expect(ev?.kind === "message" && ev.routingKey).toBe("dm");
  });

  test("forum_topic_created → topic-created", () => {
    const ev = normalizeUpdate({
      update_id: 3,
      message: { message_id: 1, chat: { id: -100 }, message_thread_id: 7, forum_topic_created: { name: "Plans" } },
    });
    expect(ev).toEqual({ kind: "topic-created", routingKey: "7", name: "Plans" });
  });

  test("callback_query → button-press", () => {
    const ev = normalizeUpdate({
      update_id: 4,
      callback_query: { id: "cb1", from: { id: 99 }, message: { chat: { id: -100 }, message_id: 50, message_thread_id: 42 }, data: "A" },
    });
    expect(ev?.kind).toBe("button-press");
    if (ev?.kind === "button-press") {
      expect(ev.label).toBe("A");
      expect(ev.routingKey).toBe("42");
    }
  });

  test("my_chat_member join → joined, leave → removed", () => {
    const base = {
      chat: { id: -100, title: "Proj" },
      from: { id: 7, first_name: "Y" },
    };
    const joined = normalizeUpdate({
      update_id: 5,
      my_chat_member: { ...base, old_chat_member: { user: { id: 4242, is_bot: true }, status: "left" }, new_chat_member: { user: { id: 4242, is_bot: true }, status: "member" } },
    });
    expect(joined?.kind).toBe("joined");
    const removed = normalizeUpdate({
      update_id: 6,
      my_chat_member: { ...base, old_chat_member: { user: { id: 4242, is_bot: true }, status: "member" }, new_chat_member: { user: { id: 4242, is_bot: true }, status: "kicked" } },
    });
    expect(removed?.kind).toBe("removed");
  });

  test("unhandled update kind → null", () => {
    expect(normalizeUpdate({ update_id: 7 })).toBeNull();
  });
});

describe("start/onEvent long-poll loop", () => {
  test("delivers a normalized event from getUpdates, then stops", async () => {
    const t = new TelegramTransport();
    const got: string[] = [];
    let resolveFirst: () => void;
    const first = new Promise<void>((r) => (resolveFirst = r));
    t.onEvent(async (e) => {
      if (e.kind === "message") {
        got.push(e.text);
        resolveFirst();
      }
    });
    const loop = t.start({});
    updateQueue = [{ update_id: 100, message: { message_id: 1, from: { id: 99 }, chat: { id: -100 }, message_thread_id: 42, text: "from-loop" } }];
    await Promise.race([first, new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), 4000))]);
    await t.stop();
    await loop;
    expect(got).toContain("from-loop");
  });
});
