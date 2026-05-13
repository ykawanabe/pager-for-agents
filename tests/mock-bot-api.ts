#!/usr/bin/env bun
/**
 * mock-bot-api.ts — minimal Telegram Bot API stand-in for E2E tests.
 *
 * Intercepts `/bot<TOKEN>/sendMessage` (and any other Bot API method we end
 * up using) and records the call to a JSONL file. Tests poll the file to
 * assert that the bot actually sent a message — closing the loop without
 * involving real Telegram servers.
 *
 * Why a separate process instead of inlining the mock in the test script:
 * the topic-wrapper.sh → claude → mcp-telegram chain spans multiple
 * processes, all of which respect TELEGRAM_API_BASE. A shared HTTP endpoint
 * lets every layer record into one log file.
 *
 * Usage:
 *   bun run tests/mock-bot-api.ts <port> <record_file>
 *
 * Endpoints exposed:
 *   GET  /bot<token>/getMe          → {"ok":true,"result":{...minimal bot...}}
 *   POST /bot<token>/sendMessage    → records JSON body, returns {"ok":true,...}
 *   GET  /bot<token>/getUpdates     → returns {"ok":true,"result":[]}
 *   (any other path)                → 404, recorded as "unknown" for debugging
 */
import { appendFileSync, writeFileSync } from "node:fs";

const port = Number(process.argv[2] ?? "0");
const recordFile = process.argv[3] ?? "/tmp/mock-bot-api.jsonl";
if (!port) {
  console.error("usage: bun run mock-bot-api.ts <port> <record_file>");
  process.exit(1);
}
// Truncate the record file at startup so tests start from a clean slate.
writeFileSync(recordFile, "");

function record(entry: Record<string, unknown>): void {
  appendFileSync(recordFile, JSON.stringify({ ts: new Date().toISOString(), ...entry }) + "\n");
}

Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url);
    // Path looks like /bot<TOKEN>/method — drop the bot<token>/ prefix.
    const m = url.pathname.match(/^\/bot[^/]+\/(.+)$/);
    const method = m?.[1] ?? "(no-method)";
    let body: unknown = null;
    if (req.method === "POST") {
      const ct = req.headers.get("content-type") ?? "";
      try {
        if (ct.includes("application/json")) {
          body = await req.json();
        } else if (ct.includes("application/x-www-form-urlencoded")) {
          const text = await req.text();
          body = Object.fromEntries(new URLSearchParams(text));
        } else if (ct.includes("multipart/form-data")) {
          const form = await req.formData();
          body = Object.fromEntries(form);
        } else {
          body = await req.text();
        }
      } catch (e) {
        body = `<unparseable: ${e instanceof Error ? e.message : String(e)}>`;
      }
    } else {
      body = Object.fromEntries(url.searchParams);
    }
    record({ method, body });

    switch (method) {
      case "getMe":
        return Response.json({
          ok: true,
          result: { id: 1, is_bot: true, first_name: "MockBot", username: "mockbot", can_read_all_group_messages: true },
        });
      case "sendMessage":
        return Response.json({
          ok: true,
          result: { message_id: Math.floor(Math.random() * 1e6), chat: { id: -1 }, date: Math.floor(Date.now() / 1000), text: (body as { text?: string })?.text ?? "" },
        });
      case "getUpdates":
        return Response.json({ ok: true, result: [] });
      default:
        return Response.json({ ok: false, description: `mock: unhandled method ${method}` }, { status: 404 });
    }
  },
});

console.log(`mock-bot-api listening on :${port}, recording to ${recordFile}`);
