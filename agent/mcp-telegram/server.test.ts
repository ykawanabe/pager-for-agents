/**
 * Integration test for mcp-telegram: spawns the real server.ts over stdio,
 * sends a `send_telegram` tools/call through the MCP SDK client, and
 * verifies (a) the outbound HTTP call hit a mocked Telegram API, and
 * (b) the typing-keepalive marker file the poller wrote was cleared.
 *
 * Why an integration test: the cross-process contract is the load-bearing
 * piece — poller and mcp-telegram run in separate processes and must agree
 * on the marker file's path and lifecycle. A unit test of either side alone
 * can't catch a path-format drift. Here we wire them up for real.
 */
import { afterAll, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const STATE = mkdtempSync(join(tmpdir(), "mcp-telegram-test-"));
const TYPING_DIR = join(STATE, "typing");
mkdirSync(TYPING_DIR, { recursive: true });

// Minimal Telegram Bot API mock — accepts sendMessage and records the body.
const sent: Array<Record<string, unknown>> = [];
const mock = Bun.serve({
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname.endsWith("/sendMessage")) {
      sent.push((await req.json()) as Record<string, unknown>);
      return Response.json({ ok: true, result: { message_id: sent.length } });
    }
    return Response.json({ ok: false, description: "not mocked" }, { status: 404 });
  },
});
const API_BASE = `http://localhost:${mock.port}/botFAKE`;

afterAll(() => {
  mock.stop();
  rmSync(STATE, { recursive: true, force: true });
});

async function callSendTelegram(opts: {
  chatId: string;
  threadId: string; // "dm" or numeric string
  text: string;
}): Promise<{ markerBefore: string; markerExistedBefore: boolean }> {
  const markerName = `${opts.chatId}__${opts.threadId === "dm" || Number.isNaN(Number(opts.threadId)) ? "dm" : opts.threadId}.token`;
  const markerPath = join(TYPING_DIR, markerName);
  writeFileSync(markerPath, "dispatch-token-xyz", { mode: 0o600 });
  const markerExistedBefore = existsSync(markerPath);

  const transport = new StdioClientTransport({
    command: "bun",
    args: [join(import.meta.dir, "server.ts")],
    env: {
      ...process.env,
      TELEGRAM_BOT_TOKEN: "FAKE",
      TELEGRAM_CHAT_ID: opts.chatId,
      TELEGRAM_THREAD_ID: opts.threadId,
      TELEGRAM_API_BASE: API_BASE,
      CTA_STATE_DIR: STATE,
    },
  });
  const client = new Client({ name: "test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  try {
    const res = await client.callTool({
      name: "send_telegram",
      arguments: { text: opts.text },
    });
    // Tool should not return an error.
    expect(res.isError).toBeFalsy();
  } finally {
    await client.close();
  }

  return { markerBefore: markerPath, markerExistedBefore };
}

test("send_telegram clears the dm typing marker after a successful send", async () => {
  sent.length = 0;
  const { markerBefore, markerExistedBefore } = await callSendTelegram({
    chatId: "12345",
    threadId: "dm",
    text: "hello",
  });
  expect(markerExistedBefore).toBe(true);
  expect(sent.length).toBe(1);
  expect(sent[0].text).toBe("hello");
  expect(sent[0].chat_id).toBe("12345");
  // The marker the poller wrote must be gone now.
  expect(existsSync(markerBefore)).toBe(false);
});

test("send_telegram clears the per-thread typing marker", async () => {
  sent.length = 0;
  const { markerBefore, markerExistedBefore } = await callSendTelegram({
    chatId: "-1009999",
    threadId: "42",
    text: "thread reply",
  });
  expect(markerExistedBefore).toBe(true);
  expect(sent.length).toBe(1);
  expect(sent[0].message_thread_id).toBe(42);
  expect(existsSync(markerBefore)).toBe(false);
});

test("send_telegram tolerates a missing marker (idempotent clear)", async () => {
  sent.length = 0;
  // Don't pre-write a marker — simulate mcp-telegram running outside the
  // poller's dispatch path (e.g. claude calling send_telegram unsolicited).
  const transport = new StdioClientTransport({
    command: "bun",
    args: [join(import.meta.dir, "server.ts")],
    env: {
      ...process.env,
      TELEGRAM_BOT_TOKEN: "FAKE",
      TELEGRAM_CHAT_ID: "55555",
      TELEGRAM_THREAD_ID: "dm",
      TELEGRAM_API_BASE: API_BASE,
      CTA_STATE_DIR: STATE,
    },
  });
  const client = new Client({ name: "test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  try {
    const res = await client.callTool({ name: "send_telegram", arguments: { text: "orphan" } });
    expect(res.isError).toBeFalsy();
  } finally {
    await client.close();
  }
  expect(sent.length).toBe(1);
});
