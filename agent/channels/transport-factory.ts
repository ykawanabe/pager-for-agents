/**
 * transport-factory — the DI seam that selects one ChatTransport per process.
 *
 * This is the ONLY module that imports a concrete platform adapter, which keeps
 * `types.ts` (the contract) platform-agnostic and means adding a platform is
 * "one more `case` + its adapter", with zero edits to the core. The poller calls
 * `makeTransport(CTA_CHANNEL ?? "telegram")` once at startup (replacing the old
 * hardcoded `new TelegramTransport()`).
 *
 * Phase 0 wires Telegram only — Telegram stays the hardcoded default until the
 * Slack adapter lands (Phase 3 uncomments the `case "slack"`).
 */
import type { ChatTransport, Channel } from "./types";
import { TelegramTransport } from "./telegram/transport";
// Phase 3: import { SlackTransport } from "./slack/transport";

export function makeTransport(channel: Channel = "telegram"): ChatTransport {
  switch (channel) {
    case "telegram":
      return new TelegramTransport();
    // case "slack": return new SlackTransport();   // Phase 3
    default:
      throw new Error(`CTA_CHANNEL unsupported: ${channel}`);
  }
}
