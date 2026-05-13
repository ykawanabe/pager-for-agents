#!/usr/bin/env bun
/**
 * mcp-telegram — minimal outbound MCP server for the Telegram bot.
 *
 * One tool, `send_telegram`. Bot's claude calls it to send a reply. The
 * server reads its target chat (and optional thread/topic id) from env vars
 * set by the wrapper, so claude itself never needs to know which topic it
 * is operating in — that's pinned at spawn time.
 *
 * Why a custom server instead of the official plugin:
 *   - Plugin sends parse_mode unset and silently drops Markdown rendering
 *     decisions (server.ts:529). We need explicit control.
 *   - Plugin is ~1000 LOC and changes upstream; this is ~80 LOC and ours.
 *   - F1+F2 needs one server per topic, each with its own thread_id pinned
 *     to the wrapper's env. A single global plugin can't do that.
 *
 * Loaded into claude via:
 *   claude --mcp-config '{"mcpServers":{"telegram":{"command":"bun",
 *     "args":["…/server.ts"],"env":{"TELEGRAM_BOT_TOKEN":…,
 *     "TELEGRAM_CHAT_ID":…,"TELEGRAM_THREAD_ID":…}}}}' --strict-mcp-config
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const CHAT_ID = process.env.TELEGRAM_CHAT_ID;
const THREAD_ID = process.env.TELEGRAM_THREAD_ID; // optional

if (!TOKEN || !CHAT_ID) {
  // Don't `throw` at top level — the MCP transport hasn't initialized yet,
  // so claude would see an opaque "server failed to start" with no detail.
  // Print to stderr (claude surfaces it in the session) and exit non-zero.
  process.stderr.write(
    "mcp-telegram: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set in env\n"
  );
  process.exit(1);
}

// TELEGRAM_API_BASE override lets E2E tests redirect outbound calls at a
// local mock server (tests/mock-bot-api.ts). Without it, every test would
// either hit real Telegram or silently no-op when the mock isn't reached.
const API_BASE = process.env.TELEGRAM_API_BASE ?? `https://api.telegram.org/bot${TOKEN}`;

type ParseMode = "MarkdownV2" | "HTML";

const server = new Server(
  { name: "mcp-telegram", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "send_telegram",
      description:
        "Send a text message to the user via Telegram. The target chat and " +
        "optional thread (forum topic) are pinned by the server's env at " +
        "spawn time — callers cannot redirect output. Markdown is rendered " +
        "literally by default (Telegram's plain-text mode); pass " +
        "parse_mode='MarkdownV2' or 'HTML' only when you know the input is " +
        "correctly escaped for that mode.",
      inputSchema: {
        type: "object",
        properties: {
          text: { type: "string", description: "Message body (≤4096 chars)." },
          parse_mode: {
            type: "string",
            enum: ["MarkdownV2", "HTML"],
            description: "Optional. Omit for plain text (recommended).",
          },
        },
        required: ["text"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (req.params.name !== "send_telegram") {
    return { content: [{ type: "text", text: `unknown tool: ${req.params.name}` }], isError: true };
  }
  const args = (req.params.arguments ?? {}) as { text?: string; parse_mode?: ParseMode };
  if (typeof args.text !== "string" || args.text.length === 0) {
    return { content: [{ type: "text", text: "text is required and must be non-empty" }], isError: true };
  }

  const body: Record<string, unknown> = { chat_id: CHAT_ID, text: args.text };
  // "dm" is a sentinel matching the poller's DM smoke-test mode (Phase 1).
  // Anything that isn't a non-empty numeric string is treated as DM (no
  // message_thread_id in the outbound body).
  if (THREAD_ID && THREAD_ID !== "dm" && !Number.isNaN(Number(THREAD_ID))) {
    body.message_thread_id = Number(THREAD_ID);
  }
  if (args.parse_mode) body.parse_mode = args.parse_mode;

  try {
    const resp = await fetch(`${API_BASE}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const json = (await resp.json()) as { ok: boolean; result?: { message_id: number }; description?: string };
    if (!json.ok) {
      return { content: [{ type: "text", text: `Telegram API error: ${json.description ?? "(no description)"}` }], isError: true };
    }
    return { content: [{ type: "text", text: `sent: message_id=${json.result?.message_id}` }] };
  } catch (e) {
    return { content: [{ type: "text", text: `send_telegram failed: ${e instanceof Error ? e.message : String(e)}` }], isError: true };
  }
});

await server.connect(new StdioServerTransport());
