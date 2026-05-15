# LINE channel support — plan

Status: **backlog**. Decided 2026-05-15. Not yet started.

## Why now

Japanese market dominance. Telegram has very small share in Japan; LINE is the consumer messaging app. Without LINE, pager-for-agents has effectively zero reach into the Japanese consumer / prosumer market that the project was conceived for.

## Why this is harder than Telegram

LINE Messaging API is **webhook-only** — no long-polling, no Gateway WebSocket, no Socket Mode equivalent. The bot host must expose a public HTTPS endpoint that LINE can POST into.

For a "runs on your Mac" project, that means inserting a public-endpoint layer between LINE and the Mac. Three implementation paths exist, none of which preserve the absolute zero-cloud claim, but all of which keep message content from being persistently stored off-host.

### What OpenClaw does (for reference)

OpenClaw supports LINE via a downloadable plugin and tells the user: set webhook URL to `https://gateway-host/line/webhook`. They don't host any ingress; users bring their own VPS, Tailscale, or Cloudflare tunnel. We can match this bar without inventing anything new.

## Architecture

### Channel adapter abstraction

```
agent/channels/
  ├── telegram/
  │    └── adapter.ts          # existing poller logic moved here
  └── line/
       ├── adapter.ts          # LINE Messaging API ↔ Pager dispatch
       └── endpoints/          # pluggable public-URL provider
            ├── interface.ts   # PublicEndpoint { url, start(), stop() }
            ├── tailscale.ts
            ├── cloudflared.ts
            ├── custom.ts      # user-supplied URL (no-op)
            └── ngrok.ts
```

The LINE adapter is endpoint-agnostic — it just needs a working public URL. Endpoint provider lifecycle (install, auth, start daemon, persist config) is owned by each provider module.

### Setup wizard UX

`cta channels add line` walks the user through:

```
LINE は webhook 用に公開 HTTPS が必要です。提供方法を選んで:

  1. Tailscale Funnel        無料・ドメイン不要・推奨
  2. Cloudflare Tunnel       無料・独自ドメイン (Cloudflare 管理) 必要
  3. 自前の URL を入力       VPS / 他社 DNS / 既存環境がある人向け
  4. ngrok 有料プラン        $8/mo
```

Each path detects prerequisites, installs missing tools via brew (with consent), guides through one-time auth, persists config, registers as a LaunchAgent so the endpoint survives reboot. Final step: copy webhook URL to clipboard + open LINE Developer Console.

### MCP outbound

A new `send_line` MCP tool mirroring `send_telegram`. Different message-type repertoire (LINE has Quick Reply for choice buttons, Flex Message for rich layout, etc.). For our scope:
- Text reply: `send_line(text)` — basic
- Choice buttons: `send_line(text, quickReply=[...])` — uses LINE Quick Reply for the chip-style buttons that appear above the chat input

`topic-wrapper.sh` reads channel kind from mount config and wires the matching MCP tool only (so claude in a LINE-paired topic never sees `send_telegram`).

### Pairing flow

Same UX as Telegram: invite bot to LINE group → bot announces → owner sends `/pair YOUR-CODE` to claim. Group ID is the chat target; LINE has no forum-topic equivalent so each group = one mount = one project.

### State layout

Rename `~/.claude-telegram-agent/` → `~/.pager/`. Per-channel subdir:

```
~/.pager/
  ├── telegram/
  │    ├── .env (token)
  │    ├── access.json
  │    └── paired.json
  └── line/
       ├── .env (channel-access-token + channel-secret)
       ├── access.json
       └── paired.json
```

`install.sh` provides a one-time symlink shim from the old path for back-compat with v0.1 users.

## Recommended approach

**Default = Tailscale Funnel.** Free, no domain, stable URL, modest trust boundary (Tailscale's edge sees the TLS-terminated payload, same as Cloudflare). Auto-detect via `tailscale status`; offer to `brew install tailscale` if missing.

**Power-user paths** stay reachable via the wizard's remaining options. Documented in `docs/channels/line.md`.

**Not building** a managed-by-us hosted relay. The cost-vs-OSS-sustainability math doesn't pencil; we'd rather match OpenClaw's bring-your-own-tunnel bar than commit to running ingress for the world.

## Honest UX bound

Even with Tailscale Funnel as default, the LINE setup will be ~10 minutes (vs Telegram's ~3 minutes). The wizard can compress, but it can't eliminate:
- Tailscale account signup (if user is new)
- LINE Developer Console: create channel, copy tokens, paste webhook URL

This means LINE channel is **structurally power-user territory**, not zero-config. Anyone wanting "consumer-grade LINE bot UX" is solving a different problem (SaaS like Manychat). We are not that.

## Implementation phases (revised after autoplan review 2026-05-15)

| Phase | Scope | Estimate |
|---|---|---|
| A | State-dir rename + mounts schema v2 (channel identity) — **separate PR** | 1.5d |
| B | Extract shared dispatch primitives into `agent/lib/` (no speculative full refactor) | 1d |
| C | LINE adapter as parallel `agent/channels/line/` (fork-and-paste from Telegram, don't refactor speculatively) | 2d |
| D | LINE webhook server with hardened security: HMAC verify before JSON parse, replay protection via webhookEventId dedupe LRU, 64KB body cap, fail-closed signature, rate limit | 1.5d |
| E | Tailscale Funnel adapter (only — no other providers in MVP) with failure-mode handling (NoState detection, ACL toggle, quota, tailnet rename) | 1d |
| F | `send_line` MCP + Quick Reply choice buttons | 0.5d |
| G | `cta channels add line` wizard — resumable (persisted partial state), with all error states covered + `cta channels doctor line` health check | 1.5d |
| H | `docs/channels/line.md` — full footgun coverage (Provider vs Channel, auto-reply disable in Official Account Manager, token vs secret, bilingual JP/EN) | 1d |
| I | Pager.app multi-channel UI updates | 1d (separate codebase, may slip) |
| **Realistic total** | | **~10-11d** |

Custom URL + Cloudflare Tunnel + ngrok providers: **deferred** until Tailscale-only ships and someone asks. Documented as escape hatch in `line.md`.

## Required (locked by review)

These are no longer "open questions" — review consensus settled them:

1. **No symlink shim.** `cta migrate-state` command does atomic move with backup manifest, refuses to run if poller is alive (`pgrep -f poller.ts`). Old path is read-only fallback during transition; symlinks rot.
2. **mounts.json v2 schema.** Identity becomes `{channel, target_id}` not bare `thread_id`. Cache keys become `channel:target`. v1 reader stays tested.
3. **LINE pairing v1 = group-scoped only.** No per-user allowlist within group (LINE doesn't surface stable user identity reliably). Host-side approval required for first pair. Per-user admin semantics deferred until validated against real LINE events.
4. **State-dir rename is its own PR.** Ship `~/.claude-telegram-agent/` → `~/.pager/` + mounts v2 migration as a standalone PR (Phase A above) before any LINE work lands. Two recoverable merges instead of one 10-day blast radius.

## Webhook security checklist (Phase D scope)

- [ ] Raw-body HMAC-SHA256 verify with channel secret, timing-safe compare, BEFORE JSON.parse
- [ ] Fail-closed: any verify error → 401, no further processing
- [ ] `webhookEventId` dedupe via bounded LRU (≥1000 entries, ≥1h TTL)
- [ ] Body size cap 64KB (LINE max is 25KB)
- [ ] Rate limit: 100 req/min per source IP, token-bucket
- [ ] Fast 2xx after enqueue (LINE has a 10s SLA, don't block on tmux dispatch)
- [ ] Structured audit logs (timestamp, source IP, verify result, event ID)
- [ ] Public Funnel exposure documented in `line.md` with threat model

## Required tests (gap-filled from review)

- mounts.json v2 read with `channel` absent (v1 back-compat)
- mounts.json v2 write rejects same `target_id` in same channel, allows same `target_id` across channels
- Re-pair to new chat_id leaves old mounts orphaned: poller warn-and-skips, doesn't crash
- LINE webhook replay (same `webhookEventId` twice → second dropped)
- LINE webhook signature verify with malformed/missing `x-line-signature` header (fail-closed)
- LINE webhook body > 64KB → 413
- `cta migrate-state` refuses with poller running
- `tailscale funnel status` returns NoState → wizard surfaces explicit consent URL
- `topic-wrapper.sh` selects `send_line` vs `send_telegram` based on mount's channel kind

## Realistic TTHW

| User type | Setup time |
|---|---|
| No Tailscale, no LINE Dev account | **20-30 min** (Tailscale signup + browser auth + Funnel ACL toggle + LINE phone OTP verify + Provider/Channel creation + auto-reply disable in Official Account Manager + token/secret paste + webhook Verify + /pair) |
| Has Tailscale, no LINE account | ~15 min |
| Has both | ~8 min |

10 min was optimistic. Wizard must show progress bar (N/8 steps) and persist partial state for resume.

## Decisions resolved at autoplan gate (2026-05-15)

1. **Channel priority — LINE-first stays** (user override of CEO recommendation). Discord Socket Mode was flagged by CEO subagent as the lighter-architecture alternative, but Yusuke's call: market-specificity (LINE/Japan) over certainty-of-reach (Discord). Discord deferred — may come later as a separate channel addition once the abstraction is paid for.

2. **Refactor strategy — parallel-then-extract** (consensus + user confirmed). Don't speculative-refactor poller.ts. Ship LINE as `agent/channels/line/` parallel implementation, fork-and-paste from Telegram where useful. Extract shared primitives into `agent/lib/` AFTER LINE works, when the real abstraction reveals itself.

3. **State-dir rename PR scope — split into two** (consensus + user confirmed). Phase A (`~/.claude-telegram-agent/` → `~/.pager/` rename + mounts.json v2) ships as standalone migration PR FIRST. LINE work (Phases B–H) layers on top of confirmed-stable foundation.

## Trigger to start work

Unchanged: wait for demand (3+ external requests OR personal need shift). When triggered, **Phase A migration ships standalone first**; LINE work follows on top.

**Kill date**: if <3 external requests by 2026-09-01, archive this plan.

---

## GSTACK REVIEW REPORT

| Phase | Reviewer | Status | Key findings |
|---|---|---|---|
| CEO | Claude subagent | Strategic concerns | Discord Socket Mode unexplored (high), "Japanese market" premise weak (critical), OpenClaw parity isn't differentiation (high) |
| Eng | Claude subagent | Implementation hazards | 1.5d adapter is fantasy → 3-4d (critical), symlink shim corrupts running poller (high), webhook security 1-line spec (high), mounts schema collision (medium) |
| Eng | Codex (adversarial) | Confirms Claude eng | Webhook ingress underspecified (critical), state rename fragile (high), mounts not additive-safe (high), 8-12d realistic |
| DX | Claude subagent | TTHW + footguns | 10min → 20-30min realistic (critical), wizard happy-path only no error states (critical), token/secret confusion #1 noob mistake (high), `line.md` unscoped (high) |

**Verdict**: backlog with consensus-mandated revisions applied above. Trigger and kill date in place. Three taste decisions surfaced for user (channel priority, refactor strategy, rename PR scope).

