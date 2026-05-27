/**
 * Tests for the transport-factory DI seam (Phase 0). The factory is the one
 * place that maps CTA_CHANNEL → a concrete adapter. Phase 0 registers Telegram
 * only; any other channel must throw (no silent fallback / no half-wired Slack).
 */
import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { mkdirSync } from "node:fs";
import { tmpdir } from "node:os";

// TelegramTransport's ctor reads state/env paths — set them before constructing,
// the same seam the transport's own tests use.
const STATE = join(tmpdir(), `transport-factory-test-${process.pid}`);
mkdirSync(STATE, { recursive: true });
process.env.CTA_STATE_DIR = STATE;
process.env.ACCESS_JSON = join(STATE, "access.json");
process.env.TELEGRAM_BOT_TOKEN = "fake";

import { makeTransport } from "./transport-factory";
import { TelegramTransport } from "./telegram/transport";

describe("makeTransport", () => {
  test('"telegram" → TelegramTransport', () => {
    expect(makeTransport("telegram")).toBeInstanceOf(TelegramTransport);
  });

  test("default (no arg) → TelegramTransport", () => {
    expect(makeTransport()).toBeInstanceOf(TelegramTransport);
  });

  test("unknown channel throws (no silent fallback)", () => {
    // Slack/discord/line are valid Channel values but not yet registered.
    expect(() => makeTransport("slack" as never)).toThrow(/unsupported/);
    expect(() => makeTransport("bogus" as never)).toThrow(/unsupported/);
  });
});
