# Chat Transport Interface — Design Plan (v3)

**Status:** plan, 2026-05-20 (v3 — folds in the decisions locked over chat: I1=A, Q1–Q5, tmux removal, deps, onboarding-at-edge, distribution). Successor to `chat-platform-research.md`. Precedes `line-support.md` (which gets re-scoped after this lands).

> v3 changelog (see §12 for detail): **I1 = Option A** — unify outbound egress, retire the outbound MCP server. Buttons become a structured marker in Claude's text stream, parsed by the poller. Cascade: zero chat tools for Claude (fully platform-agnostic), typing keepalive becomes fully in-process (no disk marker), one ordered egress. Also: Q4 = core declares an ordering *contract*, adapters satisfy it (no queue in core); tmux dropped (poller/watchdog → launchd-direct, mount-helper → daemon+buttons, watch-live → JSONL tail); onboarding = per-adapter `Onboardable` connect-descriptor (core-agnostic); required deps = claude + bun; distribution = notarized non-sandbox.

> v2 changelog: v1 was written from grep counts and described a **tmux-era** architecture. The running code is **Phase 4 daemon mode** (locked 2026-05-19). v2 corrected five load-bearing wrong assumptions (outbound path, ack fan-in, inbound debounce, daemon-registry keying, MountKey collisions) and adopted the bridgev2 "small core + optional interfaces + graded capabilities" pattern. See §11 for the full v1→v2 correction list.

This doc designs a `ChatTransport` abstraction that decouples the poller's chat-platform calls from any single platform's API, so Slack / Discord (and later LINE) can be added without editing core poller logic. It must survive the locked F1+F2 invariant ("1 forum topic = 1 project") and the local-first North Star (no hosted ingress).

---

## 0. Ground-truth architecture (Phase 4, what we're actually abstracting)

Before the interface, the real control flow — because v1 got this wrong:

```
Telegram getUpdates (long-poll, single consumer)
  → poller.dispatchUpdate()              # routeMessage: allowlist + thread→mount
  → ClaudeDaemonRegistry.enqueue(threadId, text)
       ├─ debounce 2s (PAGER_DAEMON_DEBOUNCE_MS); rapid msgs coalesce
       └─ flush(): combined = queue.join("\n") → daemon.send(combined)
  → claude -p --input-format stream-json (ONE long-lived daemon PER threadId)
  → stream-json "assistant" text events
       → poller.postTelegramTextFromDaemon() → poller.reply()   # ← outbound here
  → claude calls send_telegram ONLY for inline-keyboard buttons   # ← MCP, secondary
```

Key facts the interface must respect (file:line refs from the audit):

- **One daemon per `threadId` string**, lazy-spawned, kept warm across turns. Registry keyed by **bare `thread_id`** ("dm" | numeric), *not* by `"telegram:<id>"`. (`claude-daemon-registry.ts:55`, `poller.ts:1989`)
- **Outbound plain text bypasses MCP.** The poller intercepts stream-json `assistant` text and sends via its own `reply()` (`poller.ts:582-588`, `:228`). The append-system-prompt tells claude *not* to call `send_telegram` for prose (`:460-473`). MCP `send_telegram` is used **only** for buttons (`mcp-telegram/server.ts:139-146`) and lives in a separate process.
- **Inbound debounce is load-bearing.** N rapid user messages → 2s debounce → `join("\n")` → one daemon turn (`claude-daemon-registry.ts:207-241`). This is the "send a few thoughts in a row" UX; it must not be flattened to one-event-per-message dispatch.
- **The 2-stage ack has N:1 fan-in.** 👀 fires at dispatch per message (`poller.ts:637`); 👌 fires from the registry's `onFlush` hook, which drains a per-thread `pendingReadAcks` queue — so **one flush can flip several messages' reactions at once** (`poller.ts:340-357`, `registry:240`). The 👀 glyph is **operator-configured** via Pager's `access.json` (`poller.ts:280-297`); only 👌 is hardcoded. If `ackReaction` is empty, both stages are skipped.
- **The bot only SENDS reactions, never receives them.** `allowed_updates` is `["message","edited_message","my_chat_member","callback_query"]` (`poller.ts:2001`) — no `message_reaction`. (v1's inbound `reaction-added`/`reaction-removed` events were fiction.)
- **Offset is persisted before dispatch** (`poller.ts:2093-2096`): crash-mid-dispatch drops the batch rather than re-delivering. A durability contract the transport loop must keep.
- **`/clear` rotates the session UUID and resets the daemon** (`poller.ts:1150-1205`, `registry.resetTopic`), so the next enqueue cold-spawns without `--resume`.
- **β "Open in Terminal" handoff** uses a disk-flag IPC keyed by bare `thread_id` (`poller.ts:664-754`, `registry.releaseForTerminal`). Any change to the daemon key space ripples here.

---

## 1. Architectural shape: DI + small-core / optional-interfaces (bridgev2 pattern)

**Picked:**
1. **DI** — one `ChatTransport` constructed at `cta start` time, selected by `CTA_CHANNEL` env (default `telegram`). One platform per poller process is a hard constraint (single `getUpdates`/Socket-Mode/Gateway consumer), so plugins (multi-tenant tooling) buy nothing. Bun static imports = 0 startup cost; `tsc` enforces conformance; `grep` still works.
2. **Small required core + optional capability interfaces** — adopted directly from **mautrix bridgev2**, which converged on this after a 2024 rewrite away from a fat interface. The mandatory surface is tiny (connect, stream inbound, send text). Edits, reactions, typing, files, threads, slash-commands, proactive-send are **separate optional interfaces** an adapter implements only if the platform supports them. The poller feature-detects (`if (isReactable(t)) …`).

Why the split matters here specifically: LINE has no reactions, no edits, no slash commands, no group typing. Under a fat interface those become no-op landmines (silent failures). Under optional interfaces, LINE's adapter simply doesn't implement `Reactable`/`Editable`/`SlashCommandable`, and the poller's feature-detection skips the whole code path — the same way the real code already short-circuits when `access.json` has no `ackReaction`.

Rejected alternatives:
- **Plugin via dynamic `import()`** — solves multi-tenancy we don't have.
- **One fat `ChatTransport` with every method required** (v1's shape) — this is the matterbridge/Hubot approach; both projects' issue trackers document the resulting "silently drop unsupported features" and "stringly-typed `Extra` bag" pain. bridgev2 explicitly moved away from it.
- **Functional record of closures** — the daemon registry, typing keepalive, and topic-name cache need a stable instance handle for teardown; a class is cheaper than threading state.

Versioning: each adapter declares `readonly transportVersion`. New optional interfaces are additive (no existing adapter changes). A breaking core change bumps the version and the poller refuses to start a stale adapter with a clear error.

Tests: `MockTransport implements ChatTransport` (+ whichever optional interfaces a test needs) in `tests/mocks/`. Existing E2E that pipes through `TELEGRAM_API_BASE` keeps working because the Telegram adapter still hits Bot API; new transport-level tests need no HTTP.

---

## 2. The interface

```ts
// agent/channels/types.ts

export type Channel = "telegram" | "slack" | "discord" | "line";

/**
 * Platform-native address. Discriminated by `channel`; the poller passes it
 * opaquely. Each variant carries only the IDs that platform needs.
 *
 * Considered (rejected): a single opaque string. mount-store and the bash
 * mount CLI both reason about thread_id directly (mount-store.ts:361-524),
 * so an opaque key would force the adapter to be loaded on every mount read.
 */
export type ChatAddress =
  | { channel: "telegram"; chatId: number; threadId?: number }            // threadId omitted = General topic / DM
  | { channel: "slack"; teamId: string; channelId: string; threadTs?: string }
  | { channel: "discord"; guildId: string | null; channelId: string }
  | { channel: "line"; targetKind: "user" | "group" | "room"; targetId: string };

/**
 * Opaque, transport-scoped message handle. Returned by every send and
 * required by edit/react/delete. Tagged union, not a bare string, so
 * multi-id platforms (Slack: channel+ts) don't encode/decode per call.
 *
 * Lesson from Hubot's v2→v3 regression: losing the sent-message return
 * value broke all downstream edit/react. Every send MUST return this.
 */
export type MessageRef =
  | { channel: "telegram"; chatId: number; messageId: number }
  | { channel: "slack"; channelId: string; ts: string }
  | { channel: "discord"; channelId: string; messageId: string }
  | { channel: "line" };  // LINE: no edit/delete/react — ref is informational only

/** Normalized sender. Allowlist auth runs against `id` (stable per scope). */
export interface SenderId {
  channel: Channel;
  id: string;            // stringified (Telegram numeric, others not)
  displayName?: string;  // mutable; UX only, NEVER auth
  isBot?: boolean;
}

/**
 * RoutingKey — the daemon-registry / mount key. THIS IS THE BARE thread-id
 * string in the current code ("dm" | "<thread_id>"), NOT "<channel>:<id>".
 * The interface keeps it that way so the daemon registry, the β release-flag
 * filenames, and /clear's resetTopic all keep working unchanged.
 *
 * The "<channel>:<id>" form ("telegram:42") is the mount-STORE cache key,
 * derived by the adapter via `mountCacheKey()`. Two distinct keys, on
 * purpose: registry is per-process-per-platform (bare id is enough);
 * mount-store is potentially multi-channel on disk (needs the prefix).
 */
export type RoutingKey = string & { readonly __brand: "RoutingKey" };
```

### 2.1 Capabilities — graded, not boolean (bridgev2 `RoomFeatures` shape)

```ts
/** Support level for a feature. Booleans can't say "edits allowed 15 min". */
export type Support = "rejected" | "dropped" | "unsupported" | "partial" | "full";

export interface Capabilities {
  inboundTransport: "long-poll" | "websocket" | "webhook-push";
  threadModel: "forum-topic" | "thread-ts" | "thread-channel" | "none";

  /** Two-stage ack delivery. "none" → poller skips the whole ack pipeline. */
  ackMechanism: "reaction-swap" | "reaction-stack" | "status-line" | "inline-text" | "none";

  text: { maxChars: number };                    // adapter chunks above this (NET-NEW; see §8.1)
  edit: { support: Support; maxAgeSec?: number }; // Slack admin policy may restrict; LINE unsupported
  reaction: {
    support: Support;
    maxPerBotPerMessage: number;                 // Telegram = 1 (drives swap-not-stack)
    allowedEmoji?: string[];                     // Telegram free-bot whitelist (👌 ok, ✅ rejected)
    canStack: boolean;                           // Slack/Discord true; Telegram false
  };
  typing: { scope: "chat-thread" | "channel" | "dm-only" | "none"; keepaliveSec?: number };
  files: { in: Support; out: "multipart-bytes" | "three-step-upload" | "public-url-required" | "unsupported" };
  slashCommands: "registered" | "manifest" | "none"; // TG=registered, Slack=manifest, LINE=none

  /** Can the bot message a target it didn't just receive from? Critical for
   *  the secretary/heartbeat roadmap. Errbot+Hubot both document this as a
   *  real per-platform constraint, NOT a safe assumption. */
  proactiveSend: Support;
}
```

### 2.2 Inbound events — typed, no stringly bag

```ts
/**
 * Normalized inbound event. Small universal core; platform extras go in the
 * TYPED `raw` field (matterbridge's untyped map[string]interface{} bag is the
 * anti-pattern we avoid).
 *
 * NOTE: no reaction-added/removed — the bot does not subscribe to inbound
 * reactions (allowed_updates omits message_reaction). v1 invented those.
 */
export type InboundEvent =
  | { kind: "message"; routingKey: RoutingKey; address: ChatAddress; from: SenderId;
      text: string; messageRef: MessageRef; files?: PlatformFileHandle[]; raw: TgRaw | SlackRaw | DiscordRaw | LineRaw }
  | { kind: "button-press"; routingKey: RoutingKey; address: ChatAddress; from: SenderId;
      label: string; messageRef: MessageRef }
  | { kind: "topic-created"; routingKey: RoutingKey; name: string }
  | { kind: "topic-renamed"; routingKey: RoutingKey; name: string }
  | { kind: "joined"; address: ChatAddress; invitedBy?: SenderId; chatTitle?: string; needsAdminForText?: boolean }
  | { kind: "removed"; address: ChatAddress }
  | { kind: "transport-degraded"; reason: string };  // reconnecting; informational. Fatal errors → adapter throws from start()/run loop → process.exit → launchd respawn.
```

### 2.3 Core interface (required) + optional capability interfaces

```ts
/** REQUIRED. Every adapter implements exactly this. */
export interface ChatTransport {
  readonly channel: Channel;
  readonly transportVersion: number;
  readonly capabilities: Capabilities;

  /** Open inbound (long-poll / WS / webhook server). publicUrl required iff
   *  capabilities.inboundTransport === "webhook-push" (LINE). Resolves when
   *  ready; throws fatally on bad credentials (poller exits, launchd respawns). */
  start(opts: { publicUrl?: string }): Promise<void>;
  stop(): Promise<void>;  // graceful, <5s (SIGTERM budget)

  /** Subscribe to normalized inbound events. Adapter owns reconnect; emits
   *  `transport-degraded` while retrying. The adapter MUST persist its read
   *  cursor BEFORE invoking the handler (Telegram offset-before-dispatch
   *  durability contract, poller.ts:2093-2096) so a crash drops rather than
   *  double-delivers. */
  onEvent(handler: (e: InboundEvent) => Promise<void>): void;

  whoami(): Promise<{ id: string; username?: string; displayName?: string }>;

  /** Send plain text. Returns ref for later edit/react. Chunks above
   *  capabilities.text.maxChars and returns the LAST chunk's ref. This is the
   *  poller's primary outbound path (maps to reply(), NOT MCP). */
  sendText(args: { to: ChatAddress; text: string }): Promise<MessageRef>;

  /** Encode/decode the mount-STORE cache key ("telegram:42"). The RoutingKey
   *  (bare "42") is computed by the poller from the address; this is the
   *  prefixed disk-lookup key only. */
  mountCacheKey(address: ChatAddress): string;
  routingKey(address: ChatAddress): RoutingKey;
}

/** OPTIONAL. Implemented only where the platform supports it. */
export interface Editable { editText(ref: MessageRef, text: string): Promise<void>; }

export interface Reactable {
  /** Register the "delivered" ack on an inbound message. The poller calls
   *  this at dispatch. Returns a handle to later flip, or null if the adapter
   *  declines (e.g. operator disabled the glyph). The glyph is chosen by the
   *  adapter from capabilities/operator-config — see §4. */
  setDeliveredAck(target: MessageRef): Promise<AckHandle | null>;
  /** Flip delivered→read. May be called with MANY handles at once (N:1 flush
   *  fan-in — see §4). On swap platforms this replaces the glyph; on stack
   *  platforms it adds. */
  setReadAcks(handles: AckHandle[]): Promise<void>;
}

export interface TypingIndicating {
  startTyping(to: ChatAddress): Promise<TypingToken>;
  stopTyping(token: TypingToken): Promise<void>;
  /** Cross-process clear: mcp-telegram calls this after a successful buttons
   *  send. Implemented via the on-disk typing marker (still genuinely needed
   *  because it's a different process — see §4.3). */
  clearTypingExternal(address: ChatAddress): Promise<void>;
}

export interface FileCapable {
  downloadFile(handle: PlatformFileHandle): Promise<{ bytes: Uint8Array; mime: string; filename?: string }>;
  sendFile(args: { to: ChatAddress; bytes: Uint8Array; mime: string; filename?: string; caption?: string }): Promise<MessageRef>;
}

export interface SlashCommandable {
  registerCommands(cmds: Array<{ name: string; description: string }>): Promise<void>;
}

export interface ButtonCapable {
  /** Inline-keyboard choice buttons. On Telegram this is the MCP send_telegram
   *  path (separate process); on Slack/Discord native components; on LINE a
   *  Quick Reply. Each tap returns a `button-press` InboundEvent. */
  sendButtons(args: { to: ChatAddress; text: string; buttons: string[] }): Promise<MessageRef>;
}

export interface ProactiveCapable {
  /** Message a target without a triggering inbound message (heartbeat /
   *  secretary notifications). Separate interface because Errbot/Hubot both
   *  document platforms where you simply can't do this. */
  sendProactive(args: { to: ChatAddress; text: string }): Promise<MessageRef>;
}

// type guards
export const isEditable = (t: ChatTransport): t is ChatTransport & Editable => "editText" in t;
export const isReactable = (t: ChatTransport): t is ChatTransport & Reactable => "setDeliveredAck" in t;
// …isTyping, isFileCapable, isSlashCommandable, isButtonCapable, isProactive

export type TypingToken = unknown;
export type AckHandle = unknown;
export type PlatformFileHandle = unknown;
```

---

## 3. Method walkthrough (corrected stubs)

### 3.1 sendText — the primary outbound (poller `reply()`, not MCP)

```ts
// Telegram (note: chunking is NET-NEW; today nothing chunks — §8.1):
async sendText({ to, text }) {
  if (to.channel !== "telegram") throw new Error("wrong adapter");
  let lastRef!: MessageRef;
  for (const chunk of chunkText(text, this.capabilities.text.maxChars)) {
    const body: any = { chat_id: to.chatId, text: chunk };  // plain text; no parse_mode (§8.2)
    if (to.threadId != null) body.message_thread_id = to.threadId;
    const r = await this.api("sendMessage", body);
    lastRef = { channel: "telegram", chatId: to.chatId, messageId: r.message_id };
  }
  return lastRef;
}

// Slack:
async sendText({ to, text }) {
  const r = await this.web.chat.postMessage({ channel: to.channelId, thread_ts: to.threadTs, text });
  return { channel: "slack", channelId: to.channelId, ts: r.ts! };
}

// Discord:
async sendText({ to, text }) {
  const r = await this.rest.post(`/channels/${to.channelId}/messages`, { content: text });
  return { channel: "discord", channelId: to.channelId, messageId: r.id };
}
```

### 3.2 Ack (Reactable) — corrected for N:1 flush fan-in + operator glyph

```ts
// Telegram (reaction-swap; 1 reaction/msg; glyph from access.json):
async setDeliveredAck(target) {
  if (target.channel !== "telegram") return null;
  const glyph = this.ackConfig.deliveredEmoji;          // from access.json, mtime-watched
  if (!glyph) return null;                               // operator disabled → skip pipeline
  await this.api("setMessageReaction", { chat_id: target.chatId, message_id: target.messageId,
    reaction: [{ type: "emoji", emoji: glyph }] });
  return { channel: "telegram", target, glyph } as AckHandle;
}
async setReadAcks(handles) {
  // N:1: one flush drains many queued refs. Telegram = swap (replace, not stack).
  await Promise.all(handles.map((h: any) =>
    this.api("setMessageReaction", { chat_id: h.target.chatId, message_id: h.target.messageId,
      reaction: [{ type: "emoji", emoji: "👌" }] })));   // 👌 hardcoded; whitelist-safe
}

// Slack (reaction-stack): setDeliveredAck → reactions.add eyes;
//   setReadAcks → for each: reactions.remove eyes + reactions.add ok_hand.
// Discord (reaction-stack): PUT 👀 then per-handle DELETE 👀 + PUT 👌.
// LINE: does NOT implement Reactable at all → poller's isReactable() is false → no ack pipeline.
```

The poller side (replacing the real `pendingReadAcks` + `onDaemonFlush`):

```ts
// at dispatch, per message:
if (isReactable(transport)) {
  const h = await transport.setDeliveredAck(ev.messageRef);
  if (h) pendingReadAcks.get(routingKey).push(h);   // per-routingKey queue, unchanged shape
}
// in the registry onFlush hook (fires when debounce closes + batch written to stdin):
onFlush: async (routingKey) => {
  const handles = pendingReadAcks.drain(routingKey);  // N handles
  if (handles.length && isReactable(transport)) await transport.setReadAcks(handles);
}
```

### 3.3 Typing (TypingIndicating) — keepalive owned by adapter, disk marker kept for MCP

```ts
// Telegram (chat-thread scope, 4s keepalive — matches typing-keepalive.ts):
async startTyping(to) {
  const token = { id: randomUUID(), to };
  this.markTypingActive(to, token.id);                 // writes $STATE_DIR/typing/<chat>__<thread>.token
  void this.keepaliveLoop(to, 4000, token.id);         // sendChatAction every 4s until token clears
  return token;
}
async stopTyping(token) { this.markTypingDone((token as any).to); }
async clearTypingExternal(address) { this.markTypingDone(address); }  // called BY mcp-telegram process

// Slack: assistant.threads.setStatus (auto-clears 2min; no loop). dm-only-style no-op if no thread.
// Discord: POST /typing every 8s.
// LINE: dm-only — startTyping no-ops for group addresses.
```

### 3.4 Files (FileCapable), 3.5 Slash commands (SlashCommandable), 3.6 Buttons (ButtonCapable)

(Same shapes as v1 §3.6–3.8 — `downloadFile`/`sendFile` dispatch on `capabilities.files.out`; `registerCommands` no-ops on `slashCommands !== "registered"` — but now these are **optional interfaces**, so LINE simply omits `FileCapable.sendFile` raw-bytes path and `SlashCommandable` entirely rather than implementing no-op stubs.) Buttons is its own `ButtonCapable` interface because on Telegram it is physically a **different process** (mcp-telegram), so the Telegram `ButtonCapable.sendButtons` implementation actually writes through the MCP server's code path / shared encoding (`callback_data = ans:<thread>:<label>`, 64-byte cap → 50-char labels — §8.3), not the poller's `reply()`.

---

## 4. The ack & outbound corrections in detail

**§4.1 — Outbound is two paths in two processes.** `ChatTransport.sendText` (poller `reply()`) carries *all prose*; `ButtonCapable.sendButtons` (mcp-telegram, separate process) carries *only button prompts*. The abstraction must cover both, and the Telegram adapter's `sendButtons` is special: it doesn't run in the poller process. Practically, Phase 4 keeps `mcp-telegram` as-is and the Telegram `ButtonCapable` impl delegates to the existing MCP encoding; Slack/Discord implement `sendButtons` in-process with native components. **Do not** model buttons as a `sendText({buttons})` param (v1's mistake) — it hides the cross-process reality.

**§4.2 — Ack is register-then-flush, N:1, operator-glyphed.** 👀 set per-message at dispatch; refs queued per `routingKey`; the registry's flush hook drains the queue and flips all of them to 👌 at once. The glyph for 👀 comes from `access.json` (Pager-written, mtime-watched); empty → skip. `setReadAcks` (plural) replaces v1's per-message `setReadAck`.

**§4.3 — Typing keepalive: in-process loop, but the disk marker stays.** The keepalive loop moves into the Telegram adapter (in-process Map of tokens). BUT the on-disk marker file (`$STATE_DIR/typing/<chat>__<thread>.token`) is still genuinely required because **mcp-telegram is a different process** and clears typing after a buttons send via `clearTypingExternal`. So: in-process for the common case (poller self-clears at `turn-end`), disk marker for the MCP cross-process clear. v1 implied the disk marker was nearly vestigial; it isn't.

---

## 5. Mount-store generalization (reconciled with real invariants)

### Current (v2 schema)
`thread_id: number | "dm" | "*"`; mount-store cache key `"<channel>:<thread_id>"`; daemon registry key = bare `thread_id`.

Two real invariants v1 broke:
1. **General topic IS the `"dm"` sentinel.** Telegram omits `message_thread_id` for the General topic, so `routeMessage` sets `key = "dm"` (`poller.ts:1905`). In a group, `"dm"` doubles as both the literal DM mount and the General-topic mount; `/list` only relabels it cosmetically (`:1577-1585`). A migration must NOT split these into separate keys or routing changes.
2. **`mount-store` is read by non-TS consumers.** The bash mount CLI and `topic-wrapper.sh` parse `thread_id` directly (`mount-store.ts:432-524`); `gcProvisional` reasons about `provisional` + tmux-liveness without any adapter (`:361-381`). So the on-disk key MUST stay decodable without loading an adapter — i.e. keep the `thread_id` column, do **not** replace it with an opaque blob.

### Proposed (v3 schema) — additive, not a rewrite
Keep `thread_id`. Add an explicit `channel` (already present) and nothing else structural. The "MountKey" concept from v1 is **dropped** — it conflated the registry key (bare thread_id) with the store key (channel-prefixed) and would have broken both bash consumers and the β release-flag filenames.

```jsonc
{ "version": 3, "mounts": [
  { "channel": "telegram", "thread_id": 42,   "path": "~/p/iron-flow", "provisional": false, ... },
  { "channel": "telegram", "thread_id": "dm", "path": "~/claude-home", ... },   // = General topic too
  { "channel": "telegram", "thread_id": "*",  "path": "...", ... },             // wildcard
  { "channel": "slack",    "thread_id": "C09XYZW", "path": "...", ... }          // Slack: channel id as thread_id
]}
```

For Slack (per research: **channel** is the mount unit, not thread), `thread_id` holds the channel id string. For Discord, the thread/forum-channel id. For LINE, the group/user id. The bash CLI keeps working because `thread_id` is still a flat scalar.

v2→v3 migration: bump version, default `channel:"telegram"` on rows missing it, no key rewrite. Trivial and idempotent (no chat_id archaeology needed, because we keep thread_id-as-key).

---

## 6. Pairing flow generalization

`presentPairCode(to, code, hostInstructions)` renders per-platform; the poller's existing `handlePair` text-match path is unchanged.

| Adapter | Surface | User types | Inbound |
|---|---|---|---|
| Telegram | text: "Send `/pair CODE` here" | `/pair <code>` | `message` |
| Slack | ephemeral msg + `/pair` slash | `/pair <code>` | `message` |
| Discord | text + `/pair` slash surfaced | `/pair <code>` | `message` (needs MESSAGE_CONTENT) or interaction |
| LINE | plain DM: "Send: pair CODE" | `pair <code>` | `message` |

Auto-pair fires from the `joined` event (`my_chat_member` / `GUILD_CREATE` / `team_join`-style / LINE `follow`). The `joined` event carries `needsAdminForText` so the Telegram adapter can surface the "promote me to admin or I only see /commands" copy (privacy-mode coupling, `poller.ts:881-893`) — a real platform gotcha v1 ignored.

---

## 7. Capability degradation rules (poller branches on capability, never on `channel`)

| Capability | Value | Poller behavior |
|---|---|---|
| `isReactable` | false (LINE) | Skip ack pipeline entirely (no setDeliveredAck/setReadAcks) |
| `ackMechanism` | reaction-swap | setReadAcks replaces glyph (Telegram 1-reaction limit) |
| `ackMechanism` | reaction-stack | setReadAcks remove+add (Slack/Discord) |
| `ackMechanism` | status-line | delivered=set "thinking", read=clear |
| `reaction.allowedEmoji` | present | adapter must pick a whitelisted glyph (TG: 👌 ok, ✅ rejected) |
| `isEditable` | false (LINE) | after button press, send new "↳ choice" msg instead of editing |
| `typing.scope` | dm-only / none | startTyping no-ops for groups / entirely |
| `threadModel` | thread-ts (Slack) | mount unit = channel, not thread (threads route to same mount) |
| `threadModel` | none (LINE) | one mount per group/user |
| `inboundTransport` | webhook-push | start({publicUrl}) required; wizard runs tunnel first |
| `slashCommands` | none (LINE) | document commands in pair text |
| `proactiveSend` | unsupported | heartbeat/secretary features disabled for that platform with a clear log |

---

## 8. Hidden Telegram couplings (from the audit — net-new or easily missed)

- **§8.1 No outbound chunking exists today.** `text.maxChars` + adapter chunking is net-new behavior, not a refactor. Build it in the Telegram adapter; nothing to extract.
- **§8.2 `parse_mode` lives only in mcp-telegram**, defaulting to plain text; the product depends on plain-text rendering (append-system-prompt forbids Markdown). The interface intentionally has no markdown concept.
- **§8.3 `callback_data = ans:<thread>:<label>`** is written by mcp-telegram and parsed by the poller across two processes, 64-byte cap → 50-char labels. `ButtonCapable` must preserve this encoding for Telegram.
- **§8.4 Single-reaction-per-bot + free-bot emoji whitelist** drive swap-not-stack and the 👌 choice. Captured in `reaction.{maxPerBotPerMessage, allowedEmoji, canStack}`.
- **§8.5 `allowed_updates` must be re-sent every poll** or `my_chat_member`/`callback_query` stop arriving. The Telegram adapter's run loop owns this.
- **§8.6 Privacy-mode coupling** (`needsAdminForText` on `joined`).
- **§8.7 Crash recovery is at the daemon layer, not transport.** Daemon backoff (`registry:291-316`), β release-flags, heartbeat file, launchd respawn. `transport-degraded` is informational only; it does not own claude-process recovery.
- **§8.8 MCP authority model.** The daemon merges the per-topic telegram MCP with the user's own `~/.claude.json` MCPs (no `--strict-mcp-config`). The security boundary is `routeMessage`'s user-id allowlist, not MCP scoping. Unchanged by this design, but adapters must keep the per-topic env-pinning (`TELEGRAM_CHAT_ID`/`THREAD_ID`/`CTA_STATE_DIR`).

---

## 9. Migration plan (updated for daemon mode)

**Phase 1 — Extract `agent/channels/telegram/adapter.ts` (pure refactor).** Move Bot API call sites — `reply`, `setMessageReaction`(both stages), `sendChatAction`+keepalive, `editMessageText`, `getUpdates` loop+offset, `getFile`, `my_chat_member`/`callback_query` handling — into the adapter as plain functions. Leave the daemon registry, `pendingReadAcks`, debounce, β release-flags **in the poller**. No interface yet. Bar: every existing test passes unchanged; `tests/mock-bot-api.ts` still intercepts. Risk: import cycles — adapter takes state-dir paths as ctor args, no module globals.

**Phase 2 — Define `types.ts`, wrap as `class TelegramTransport implements ChatTransport, Editable, Reactable, TypingIndicating, FileCapable, SlashCommandable, ButtonCapable, ProactiveCapable`.** Populate `capabilities` and review every value against `chat-platform-research.md`. Poller still calls the adapter directly. `MockTransport` lands. Bar: Phase 1 tests pass + a conformance test asserting the capability struct.

**Phase 3 — Cut poller over to the interface + type guards.** Replace direct calls with `transport.sendText`, `if (isReactable) …`, etc. `ChatAddress`/`MessageRef` flow through `dispatchUpdate`. Crucially: keep the registry keyed by bare `thread_id`; keep `pendingReadAcks` + the flush hook (now calling `setReadAcks`). mount-store → v3 (additive). Bar: all tests pass; new transport-level tests via `MockTransport`; E2E confirms TG round-trip, ack fan-in, debounce, β handoff all intact.

**Phase 4 — Slack adapter** (`agent/channels/slack/adapter.ts` + `mcp-slack` mirroring mcp-telegram for buttons). `threadModel: "thread-ts"` but **mount unit = channel**. Implements all optional interfaces except where Slack differs (status-line ack as an option). Bar: mock Slack WS E2E; assert ack uses stack-remove+add and typing uses setStatus.

**Phase 5 — Discord adapter.** MESSAGE_CONTENT intent; thread-channel = mount 1:1. Guild commands (instant) over global (1h propagation).

**Phase 6 — LINE adapter, re-scoped.** Now clean: omit `Reactable`/`Editable`/`SlashCommandable` (poller feature-detects and skips), `inboundTransport: "webhook-push"` + `start({publicUrl})`, `files.out: "public-url-required"`, `proactiveSend` via push API (quota-limited). The old `line-support.md` "fork-and-paste from Telegram" approach is obsolete — update that doc to point here.

---

## 10. Open questions

1. ~~**`mcp-slack`/`mcp-discord`/`mcp-line` for buttons.**~~ **RESOLVED by I1=A (§12): no outbound MCP at all.**
2. ~~**Multi-message outbound ordering.**~~ **RESOLVED by Q4 (§12): core declares a per-`routingKey` ordering contract; each adapter satisfies it internally (no queue in core).**
3. **Proactive-send + heartbeat.** `ProactiveCapable` is the hook, but the heartbeat plan (`project_secretary_heartbeat_plan`) is H2-piggyback (no periodic tick), so proactive send may not be needed soon. Keep the capability, defer the wiring.
4. **LINE file-out TTL + path-traversal** for the tunnel pubdir. Phase 6.
5. **Inbound file quarantine** (`~/.pager/inbound-files/`) — today files are dropped (text/caption only). Not blocking Phase 1–3.
6. **Operator-configurable ack glyph** belongs in `access.json`, read by the adapter — confirm the adapter (not the poller) owns reading `access.json`'s `ackReaction` after the cut-over.
7. **Slack workspace pairing scope** — pair in #foo, accept from #bar? Default "whole workspace"; document in `slack.md`.
8. **Rate-limit policy** — no central backoff today; could be a `rateLimitPolicy` hook per adapter. Defer.

---

## 11. v1 → v2 corrections (audit findings)

1. **Phase 4 daemon mode, not tmux.** The whole mental model was wrong; rewrote §0 + migration around poller → `ClaudeDaemonRegistry` → stream-json.
2. **Outbound plain text bypasses MCP** — it's the poller's `reply()`. `sendText` maps there; buttons (MCP, separate process) are a distinct `ButtonCapable` interface. (v1 said all outbound-from-claude goes through MCP.)
3. **Ack is N:1 register-then-flush with operator glyph** — `setReadAcks(handles[])` + `pendingReadAcks` queue + `access.json` glyph. (v1's 1:1 `setReadAck` couldn't model the flush fan-in.)
4. **Inbound debounce is load-bearing** — documented as a preserved invariant; the registry sits below `onEvent`. Dropped the fictional inbound `reaction-added/removed` events.
5. **MountKey dropped.** Registry stays keyed by bare `thread_id`; mount-store stays `thread_id`-decodable (bash CLI + gcProvisional depend on it); General-topic == `"dm"` collision preserved. (v1's opaque channel-prefixed MountKey broke all three.)
6. **Adopted bridgev2 patterns** — small core + optional interfaces, graded `Support` capabilities with quantitative limits, typed `raw` (no stringly bag), `proactiveSend` as an explicit capability, every send returns a `MessageRef` (Hubot lesson).

---

## 12. v2 → v3 decisions (locked 2026-05-20)

**I1 = Option A — unify outbound egress, retire the outbound MCP server.**
- Buttons become a structured marker Claude emits in its normal text stream. The poller parses it from the stream-json `assistant` output and calls `transport.sendButtons`. Plain text and buttons share one ordered egress (the poller).
- The outbound MCP server (`mcp-telegram`, buttons-only in Phase 4) is retired entirely. Claude has **zero chat tools**.
- **Typing keepalive becomes fully in-process.** The on-disk typing marker existed only so the separate MCP process could clear typing after a buttons send. No separate process → no disk marker. (Reverses the §4.3 / Audit-Q6 cross-process requirement — it no longer applies.)
- **Claude is fully platform-agnostic** (Q1). System prompt: reply in plain text; to offer choices, emit a buttons marker. No `send_telegram`/`send_slack`/etc. The append-system-prompt becomes platform-neutral.
- `ButtonCapable` remains an optional transport interface; the poller calls it after parsing the marker. An adapter without buttons just omits it → poller renders choices inline as text.
- Net: the core gets **smaller** — one fewer process, one fewer cross-process hack.

**Q2** — mount-unit asymmetry accepted: TG=topic, Slack=channel, Discord=forum-channel/thread, LINE=whole chat. Encoded via `capabilities.threadModel`; mount-store keeps `thread_id` as a flat scalar per platform.

**Q3** — v1 ships plain text on all platforms (platform stays hidden from Claude). Rich formatting revisited only if users complain.

**Q4** — outbound ordering: the **core declares a contract** ("sends to the same `routingKey` are delivered in order"); each adapter satisfies it internally (Slack/Discord hold an internal per-key queue). **No queue is added to the core** — keeps the core thin.

**Q5** — allowlist is `{channel, id}` tuples, per-platform; no cross-platform identity unification (impossible for LINE). User id is **auto-captured at pair time** from the first message → the "enter your user ID" step is removed on every platform.

**tmux removed (decision: drop).** poller + watchdog → launchd-direct (agent.log via plist `StandardOutPath`, no `pipe-pane`); mount-helper → daemon + buttons flow (see I2 below); watch-live → stream-json/JSONL tail; Pager's bundled-tmux logic deleted (its dylib-bundling bug disappears with it). Required deps shrink to **claude + bun** (jq also dropped — JSON handling moves to bun/TS). Its own phase (medium effort).

**Onboarding lives at the edge.** Each adapter declares a connect-descriptor via an optional `Onboardable` interface (required tokens, pre-generated artifacts, deep links). The Pager wizard is a generic renderer driven by that descriptor; neither the poller core nor the `ChatTransport` core knows about onboarding. Install = two layers: (1) common local-env setup (fully automated) + (2) per-platform connect wizard (manifest / invite-URL / token paste / pair). Pre-generated artifacts: Slack app manifest + create-from-manifest deep link; Discord OAuth invite URL with scopes baked in; Telegram BotFather deep link + token field.

**Distribution.** Notarized, non-sandboxed, direct-distribution app (no App Store) — so it can write LaunchAgents / `~/.local/bin`, run `launchctl`, and install deps. Deps installed (not bundled):
- **claude** — detect-only, guide if missing (user-licensed, updates independently; the "use the user's tool" peer pattern, cf. git clients shelling to the user's git).
- **bun** — for the **app flow**, download a *pinned* bun into `~/Library/Application Support/Pager/bin` and call it by absolute path (version-locked to the app, no brew, no `~/.bun`/PATH pollution — the VS-Code-style "download a controlled helper into Application Support" pattern). For the **CLI-only/headless flow**, fall back to the official `curl bun.sh` installer. (Rejected: brew — requires brew + version drift; full bundle-in-`.app` — bun's fine to bundle but the pinned-download keeps the app small and the update path simple.)
- The install step resolves absolute binary paths and bakes them into the plist (fixes the "LaunchAgent: claude not found" PATH bug).

### Still open (lower-stakes, deferred)
- **I2** — mount-helper chicken-and-egg after tmux removal: a daemon needs a cwd (a mount), but the helper exists precisely because there's no mount yet. Options: a helper daemon in a neutral cwd (`~/.pager/helper-cwd`) that confirms the mount then hands off to the real daemon, OR move mount entirely to Pager/cta and drop the in-chat helper. Decide in the tmux-removal phase.
- **I3** — tmux removal reworks the recent watch-live SwiftTerm/pipe-pane implementation (last ~2 weeks of work) into a JSONL-tail viewer. Sunk cost to absorb in the tmux-removal phase.
- Items 3–8 from §10 (proactive wiring, LINE file TTL, inbound file quarantine, ack-glyph ownership, Slack pairing scope, rate-limit policy) remain deferred.
