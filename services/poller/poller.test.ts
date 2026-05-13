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
type SentMessage = { chat_id: number | string; message_thread_id?: number; text: string };
const sent: SentMessage[] = [];

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
  rmSync(STATE, { recursive: true, force: true });
  mkdirSync(STATE, { recursive: true, mode: 0o700 });
  poller.refreshPairedIfChanged();
  poller.refreshMountsIfChanged();
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
