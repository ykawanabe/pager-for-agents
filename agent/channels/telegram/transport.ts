/**
 * TelegramTransport — the Telegram implementation of ChatTransport, wrapping the
 * P1 wire adapter (./adapter). Phase 2 of the ChatTransport migration.
 *
 * STATUS: P2 (2/n) — implemented but NOT yet wired. The poller still drives its
 * own getUpdates loop and calls the adapter directly; P3 cuts the poller over to
 * construct + drive this transport. So `start`/`onEvent`/normalization here are
 * correct-in-isolation and mock-tested, but the production runtime path is
 * exercised end-to-end only after P3.
 *
 * Interfaces implemented = those that wrap wire the adapter ALREADY has, so this
 * is a faithful refactor, not speculative new wire:
 *   ChatTransport (core) + Editable + Reactable + ButtonCapable + ProactiveCapable.
 *
 * Deliberately DEFERRED (per the doc's "don't ship no-op stubs" rule — these
 * need net-new wire / a rehome, built in their own phase; the poller
 * feature-detects via the type guards and skips the path until then):
 *   - TypingIndicating: needs typing-keepalive.ts rehomed out of agent/poller/
 *     (importing it here would make channels/ depend on poller/ and risk a P3
 *     import cycle). Wired in P3 alongside the cutover.
 *   - FileCapable: no send/download wire exists yet (inbound files are dropped
 *     today); also blocked on the deferred quarantine/TTL design.
 *   - SlashCommandable: no setMyCommands wire exists yet.
 * `capabilities` below still reports the PLATFORM's true abilities (files,
 * slashCommands, typing) — capability = what Telegram can do; interface presence
 * = what this adapter version has wired. The two axes are intentionally distinct.
 */

import { openSync, closeSync, writeFileSync, fsyncSync, renameSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  getUpdates,
  getMe,
  sendText as wireSendText,
  setReaction,
  editMessageText as wireEditMessageText,
  sendInlineKeyboard,
  type TgUpdate,
  type TgMessage,
} from "./adapter";
import { pollerOffsetFile } from "../../lib/paths";
import type {
  ChatTransport,
  Editable,
  Reactable,
  ButtonCapable,
  ProactiveCapable,
  Capabilities,
  ChatAddress,
  MessageRef,
  RoutingKey,
  SenderId,
  InboundEvent,
  AckHandle,
} from "../types";

/** Telegram's documented free-bot reaction whitelist (non-premium bots may only
 *  react with these standard emoji; custom emoji needs Premium / chat-admin).
 *  Source: https://core.telegram.org/api/reactions. The product's glyphs — 👀
 *  (operator-default, configurable) and 👌 (hardcoded read) — are both here. */
const TG_REACTION_WHITELIST = [
  "👍", "👎", "❤", "🔥", "🥰", "👏", "😁", "🤔", "🤯", "😱", "🤬", "😢", "🎉", "🤩",
  "🤮", "💩", "🙏", "👌", "🕊", "🤡", "🥱", "🥴", "😍", "🐳", "❤‍🔥", "🌚", "🌭", "💯",
  "🤣", "⚡", "🍌", "🏆", "💔", "🤨", "😐", "🍓", "🍾", "💋", "🖕", "😈", "😴", "😭",
  "🤓", "👻", "👨‍💻", "👀", "🎃", "🙈", "😇", "😨", "🤝", "✍", "🤗", "🫡", "🎅", "🎄",
  "☃", "💅", "🤪", "🗿", "🆒", "💘", "🙉", "🦄", "😘", "💊", "🙊", "😎", "👾",
];

/** The hardcoded "read" glyph. 👌 is whitelist-safe and reads as "got it". */
const READ_REACTION_EMOJI = "👌";

/** Telegram plain-text message hard limit. sendText chunks above this. */
const TG_TEXT_MAX_CHARS = 4096;

/** A Telegram ack handle: enough to flip the reaction later (N:1 flush). */
interface TgAckHandle {
  channel: "telegram";
  chatId: number;
  messageId: number;
}

/** Split text into <=maxChars chunks on line boundaries where possible. No-op
 *  for the overwhelming common case (messages well under the limit). */
function chunkText(text: string, maxChars: number): string[] {
  if (text.length <= maxChars) return [text];
  const chunks: string[] = [];
  let rest = text;
  while (rest.length > maxChars) {
    let cut = rest.lastIndexOf("\n", maxChars);
    if (cut <= 0) cut = maxChars; // no newline to break on — hard split
    chunks.push(rest.slice(0, cut));
    rest = rest.slice(cut).replace(/^\n/, "");
  }
  if (rest.length > 0) chunks.push(rest);
  return chunks;
}

export class TelegramTransport
  implements ChatTransport, Editable, Reactable, ButtonCapable, ProactiveCapable
{
  readonly channel = "telegram" as const;
  readonly transportVersion = 1;
  readonly capabilities: Capabilities = {
    inboundTransport: "long-poll",
    threadModel: "forum-topic",
    ackMechanism: "reaction-swap",
    text: { maxChars: TG_TEXT_MAX_CHARS },
    edit: { support: "full" }, // bots can edit their own messages indefinitely
    reaction: {
      support: "full",
      maxPerBotPerMessage: 1, // one reaction per bot per message → swap, not stack
      allowedEmoji: TG_REACTION_WHITELIST,
      canStack: false,
    },
    typing: { scope: "chat-thread", keepaliveSec: 4 },
    files: { in: "full", out: "multipart-bytes" },
    slashCommands: "registered",
    proactiveSend: "full",
  };

  // ACCESS_JSON holds the operator-configured ack glyph (Pager writes it). The
  // transport owns reading it post-cutover (doc open-Q6); read on demand for now.
  private readonly accessJsonPath =
    process.env.ACCESS_JSON ?? join(homedir(), ".claude/channels/telegram/access.json");
  private readonly offsetFile = pollerOffsetFile();
  private readonly pollTimeoutSec = Number(process.env.POLL_TIMEOUT_SEC ?? "25");

  private handler: ((e: InboundEvent) => Promise<void>) | null = null;
  private running = false;

  // ─── required core ─────────────────────────────────────────────────────────

  onEvent(handler: (e: InboundEvent) => Promise<void>): void {
    this.handler = handler;
  }

  /** Drive the long-poll loop: getUpdates → persist offset BEFORE dispatch
   *  (drop-not-double-deliver durability contract) → normalize → handler. */
  async start(_opts: { publicUrl?: string }): Promise<void> {
    this.running = true;
    let offset = this.readOffset();
    while (this.running) {
      let updates: TgUpdate[];
      try {
        updates = await getUpdates(offset, this.pollTimeoutSec);
      } catch (e) {
        process.stderr.write(`telegram: getUpdates failed: ${e instanceof Error ? e.message : String(e)}\n`);
        await new Promise((r) => setTimeout(r, 5_000));
        continue;
      }
      if (updates.length === 0) continue;
      const maxId = updates[updates.length - 1].update_id;
      this.writeOffset(maxId + 1);
      offset = maxId + 1;
      for (const u of updates) {
        const ev = normalizeUpdate(u);
        if (ev && this.handler) await this.handler(ev);
      }
    }
  }

  async stop(): Promise<void> {
    this.running = false;
  }

  async whoami(): Promise<{ id: string; username?: string; displayName?: string }> {
    const json = await getMe();
    return { id: String(json.result?.id ?? ""), username: json.result?.username };
  }

  async sendText({ to, text }: { to: ChatAddress; text: string }): Promise<MessageRef> {
    if (to.channel !== "telegram") throw new Error("TelegramTransport.sendText: wrong channel");
    let lastRef: MessageRef = { channel: "telegram", chatId: to.chatId, messageId: 0 };
    for (const chunk of chunkText(text, this.capabilities.text.maxChars)) {
      await wireSendText({ chat_id: to.chatId, thread_id: to.threadId }, chunk);
      // The plain sendMessage wire is best-effort (no id returned); the ref
      // carries the chat coordinates, sufficient for the poller's current use.
      lastRef = { channel: "telegram", chatId: to.chatId, messageId: 0 };
    }
    return lastRef;
  }

  mountCacheKey(address: ChatAddress): string {
    if (address.channel !== "telegram") throw new Error("TelegramTransport.mountCacheKey: wrong channel");
    // Matches mount-store mountKey("telegram", thread_id): "telegram:<id|dm>".
    return `telegram:${address.threadId ?? "dm"}`;
  }

  routingKey(address: ChatAddress): RoutingKey {
    if (address.channel !== "telegram") throw new Error("TelegramTransport.routingKey: wrong channel");
    // Bare thread-id string ("dm" | "<id>") — the daemon-registry / mount key.
    return String(address.threadId ?? "dm") as RoutingKey;
  }

  // ─── Editable ────────────────────────────────────────────────────────────────

  async editText(ref: MessageRef, text: string): Promise<void> {
    if (ref.channel !== "telegram") throw new Error("TelegramTransport.editText: wrong channel");
    await wireEditMessageText(ref.chatId, ref.messageId, text);
  }

  // ─── Reactable (reaction-swap, operator glyph, N:1 flush) ────────────────────

  async setDeliveredAck(target: MessageRef): Promise<AckHandle | null> {
    if (target.channel !== "telegram") return null;
    const glyph = this.readDeliveredGlyph();
    if (!glyph) return null; // operator disabled → skip the whole ack pipeline
    await setReaction(target.chatId, target.messageId, glyph);
    const handle: TgAckHandle = { channel: "telegram", chatId: target.chatId, messageId: target.messageId };
    return handle as AckHandle;
  }

  async setReadAcks(handles: AckHandle[]): Promise<void> {
    // N:1: one daemon flush drains many queued refs. Telegram = swap (replace).
    await Promise.all(
      handles.map((h) => {
        const a = h as TgAckHandle;
        return setReaction(a.chatId, a.messageId, READ_REACTION_EMOJI);
      }),
    );
  }

  /** Operator-configured delivered glyph from access.json (empty/absent = off).
   *  Read on demand; P3 may add mtime caching (the poller has it today). */
  private readDeliveredGlyph(): string | null {
    try {
      const parsed = JSON.parse(readFileSync(this.accessJsonPath, "utf8")) as { ackReaction?: unknown };
      const v = typeof parsed.ackReaction === "string" ? parsed.ackReaction.trim() : "";
      return v.length > 0 ? v : null;
    } catch {
      return null; // missing / malformed → ack off
    }
  }

  // ─── ButtonCapable ───────────────────────────────────────────────────────────

  async sendButtons({
    to,
    text,
    buttons,
  }: {
    to: ChatAddress;
    text: string;
    buttons: string[];
  }): Promise<MessageRef> {
    if (to.channel !== "telegram") throw new Error("TelegramTransport.sendButtons: wrong channel");
    // One button per row; callback_data carries the label (P4 refines the
    // cross-process buttons protocol — for now this mirrors the inline-keyboard
    // wire the poller already uses for mount prompts).
    const rows = buttons.map((label) => [{ text: label, callback_data: label.slice(0, 64) }]);
    const res = await sendInlineKeyboard(to.chatId, text, rows);
    return { channel: "telegram", chatId: to.chatId, messageId: res?.message_id ?? 0 };
  }

  // ─── ProactiveCapable ────────────────────────────────────────────────────────

  async sendProactive({ to, text }: { to: ChatAddress; text: string }): Promise<MessageRef> {
    // Telegram bots may message any chat they're in without a triggering inbound
    // message — identical wire to sendText.
    return this.sendText({ to, text });
  }

  // ─── offset persistence (atomic; tempfile + fsync + rename) ──────────────────

  private readOffset(): number {
    try {
      const n = Number(readFileSync(this.offsetFile, "utf8").trim());
      return Number.isFinite(n) && n >= 0 ? n : 0;
    } catch {
      return 0;
    }
  }

  private writeOffset(value: number): void {
    const tmp = `${this.offsetFile}.tmp.${process.pid}`;
    const fd = openSync(tmp, "w", 0o600);
    try {
      writeFileSync(fd, `${value}\n`);
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, this.offsetFile);
  }
}

// ─── inbound normalization (pure) ──────────────────────────────────────────────

/**
 * Map one raw TgUpdate to a normalized InboundEvent (or null to ignore). The
 * `raw` field carries the original update so the poller's existing handlers can
 * still reach Telegram-specific fields during the P3 transition; P3 migrates
 * them onto the normalized fields incrementally.
 *
 * Exported for direct unit testing.
 */
export function normalizeUpdate(u: TgUpdate): InboundEvent<TgUpdate> | null {
  const msg = u.message ?? u.edited_message;
  if (msg) {
    if (msg.forum_topic_created) {
      return { kind: "topic-created", routingKey: threadRoutingKey(msg), name: msg.forum_topic_created.name };
    }
    if (msg.forum_topic_edited?.name) {
      return { kind: "topic-renamed", routingKey: threadRoutingKey(msg), name: msg.forum_topic_edited.name };
    }
    return {
      kind: "message",
      routingKey: threadRoutingKey(msg),
      address: addressOf(msg),
      from: senderOf(msg),
      text: msg.text ?? msg.caption ?? "",
      messageRef: { channel: "telegram", chatId: msg.chat.id, messageId: msg.message_id },
      raw: u,
    };
  }

  if (u.callback_query) {
    const cb = u.callback_query;
    const m = cb.message;
    const address: ChatAddress = m
      ? { channel: "telegram", chatId: m.chat.id, threadId: m.message_thread_id }
      : { channel: "telegram", chatId: 0 };
    return {
      kind: "button-press",
      routingKey: (m?.message_thread_id != null ? String(m.message_thread_id) : "dm") as RoutingKey,
      address,
      from: { channel: "telegram", id: String(cb.from.id), displayName: cb.from.first_name },
      label: cb.data ?? "",
      messageRef: m
        ? { channel: "telegram", chatId: m.chat.id, messageId: m.message_id }
        : { channel: "telegram", chatId: 0, messageId: 0 },
    };
  }

  if (u.my_chat_member) {
    const mcm = u.my_chat_member;
    const newS = mcm.new_chat_member.status;
    const address: ChatAddress = { channel: "telegram", chatId: mcm.chat.id };
    if (newS === "left" || newS === "kicked") {
      return { kind: "removed", address };
    }
    return {
      kind: "joined",
      address,
      invitedBy: { channel: "telegram", id: String(mcm.from.id), displayName: mcm.from.first_name },
      chatTitle: mcm.chat.title,
    };
  }

  return null; // update kind we don't surface
}

function threadRoutingKey(msg: TgMessage): RoutingKey {
  return (msg.message_thread_id != null ? String(msg.message_thread_id) : "dm") as RoutingKey;
}

function addressOf(msg: TgMessage): ChatAddress {
  return { channel: "telegram", chatId: msg.chat.id, threadId: msg.message_thread_id };
}

function senderOf(msg: TgMessage): SenderId {
  return { channel: "telegram", id: msg.from ? String(msg.from.id) : "" };
}
