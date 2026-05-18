# E2E Test Harness (Agent-Runnable)

> **For agentic workers:** REQUIRED SUB-SKILL — use `superpowers:subagent-driven-development`. This plan grounds `multi-topic-stability-plan.md` Principle 8 ("Recovery is tested, not just hoped for") with executable scenarios.

## Why this exists

The user (Yusuke) runs multiple parallel claude code sessions on this project and wants a way to (a) run scenario-level tests after a change without manually walking through Telegram, (b) have an AI agent re-verify the system after every meaningful diff. The 14+ commits in the 2026-05-18 wave demonstrated the cost of manual regression detection: bugs (D1, D2, D11, D12, D14, D15) sat undetected because no automated test exercised the full inbound→claude→outbound loop with multiple topics, restarts, and slash-command translations.

Existing infrastructure that gets us partway:
- `tests/mock-bot-api.ts` — bun HTTP server that records `sendMessage` calls. Used today by `test_send_telegram_e2e.sh` to verify claude+mcp-telegram do call the tool. Lacks INBOUND simulation (no `getUpdates` injection).
- `test_cta_mounts.sh` — sandboxed cta CLI tests using a private tmux socket. Solid template for state-dir isolation.
- `poller.test.ts` — bun unit tests for poller command handlers with fake Bot API. Fast and isolated, but unit-level: doesn't spawn topic-wrapper, doesn't run real claude.

Cross-ecosystem prior art (researched 2026-05-18):
- **jehy/telegram-test-api** (Node.js) — full mock Bot API with client-side helpers. Pattern: bot points at mock URL; test code injects updates via a sidecar client API; test reads captured outbound calls.
- **vb64/telemulator3** (Python, for pyTelegramBotAPI) — partial emulator focused on unit tests, not multi-process E2E.
- **dcdunkan/grammy_tests** (Deno) — handles outgoing API + generates dynamic responses. Same shape.
- **teremock** — persistent mock server, 15-30× faster than test-per-spawn approaches.

Common pattern across all: separate **Bot API impersonation** (HTTP) from **test-side helpers** (inject/drain). We follow the same shape.

## Goals and non-goals

**Goals:**
- Run a scenario end-to-end with one command: `bash tests/e2e/run.sh <scenario>`
- Each scenario: spawn mock, spawn poller (+ topic-wrappers as needed), inject inbound, assert outbound + state, tear down.
- Fast enough for an agent to re-run after every change: <60s per scenario, parallelizable.
- Self-contained sandboxes: every scenario gets a fresh `$STATE_DIR` under `/tmp` and a private tmux socket.
- Deterministic: no flaky timing waits where condition polling is feasible.
- Catches the bug classes we already paid for: D1, D2, D3, D5, D11, D12, D14, D15.

**Non-goals (v1):**
- Real Telegram API contact (kept for staging smoke only, separate flow).
- Mobile-app simulation, Telegram Web UI replay.
- Multi-machine / cross-host scenarios (F3 territory).
- Performance benchmarking (separate suite).
- Pager (Swift) integration — those tests live in the Pager repo path.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Scenario runner (bash)                                       │
│  tests/e2e/scenarios/<name>.sh                                │
│    ├── source tests/e2e/lib/harness.sh                        │
│    ├── h_setup_sandbox                                        │
│    ├── h_spawn_mock                                           │
│    ├── h_spawn_poller (with private tmux socket)              │
│    ├── h_inject <update.json>                                 │
│    ├── h_wait_for_capture <predicate>                         │
│    ├── h_assert_state <jq expression>                         │
│    └── h_teardown                                             │
└────┬──────────────────────────────────────────────────┬───────┘
     │ inject via POST /__test__/inject                 │ asserts via GET /__test__/captured
     ↓                                                  ↑
┌──────────────────────────────────────────────────────────────┐
│  Mock Bot API (extends tests/mock-bot-api.ts)                 │
│    GET  /bot<TOKEN>/getMe          static identity            │
│    POST /bot<TOKEN>/getUpdates     drains injected queue      │
│    POST /bot<TOKEN>/sendMessage    captures into JSONL        │
│    POST /bot<TOKEN>/sendChatAction captures                   │
│    POST /bot<TOKEN>/setMessageReaction captures               │
│    POST /bot<TOKEN>/answerCallbackQuery captures              │
│    GET  /bot<TOKEN>/getChatMember  static creator             │
│    POST /__test__/inject           accepts update JSON         │
│    GET  /__test__/captured?method= filtered capture readout    │
│    POST /__test__/reset            clear queue + capture       │
└──────────────────────────────────────────────────────────────┘
     ↑                                                  ↓
     │                                       outbound from poller +
     │                                       claude TUI + mcp-telegram
     │                                                  ↑
┌──────────────────────────────────────────────────────────────┐
│  Sandboxed system under test                                  │
│    bun poller.ts            (real, $TELEGRAM_API_BASE → mock) │
│    topic-wrapper.sh         (real, spawned per topic)         │
│    claude TUI               (real, headless if available)     │
│    mcp-telegram             (real)                            │
│    $STATE_DIR=/tmp/sandbox-<id>                               │
│    tmux -L /tmp/socket-<id> (private)                         │
└──────────────────────────────────────────────────────────────┘
```

## Phase A — Foundation (this commit)

Minimum viable harness. Delivers:

- [x] **A.1 — Extend `tests/mock-bot-api.ts` with inject + drain endpoints**

  New endpoints:
  - `POST /__test__/inject` — body: `{update_id, message, edited_message, ...}`. Appends to an in-memory queue.
  - `POST /__test__/reset` — clears queue + capture file. Called by harness on each scenario start.
  - `GET /__test__/captured?method=<name>` — returns JSONL of captured calls, filtered. `getUpdates` is excluded (those are normal long-poll requests, not assertions).

  Modify `getUpdates` handler: when queue non-empty, return the items (FIFO) and clear; advance an internal `update_id` counter. When empty, return `[]` (existing behavior).

  All other Bot API methods (getMe, sendMessage, sendChatAction, setMessageReaction, answerCallbackQuery, getChatMember) get explicit handlers that return realistic responses + record. Unknown methods continue to return 404 + record-as-unknown.

  Test: extend `test_send_telegram_e2e.sh` or add a new bun test asserting inject→getUpdates roundtrip works without a real bot.

- [x] **A.2 — Harness library `tests/e2e/lib/harness.sh`**

  Sourced by each scenario. Functions:
  - `h_setup_sandbox` — `STATE_DIR`, `INSTALL_DIR`, fake plugin .env, .pager/.env, etc. Exports env vars.
  - `h_spawn_mock` — bun runs mock-bot-api on a random port, polls `/getMe` until live.
  - `h_spawn_poller` — exec bun on the real poller, env set, private tmux socket.
  - `h_inject_text <thread_id> <text> [from_id]` — convenience wrapper: builds a TG update JSON, POSTs to /__test__/inject.
  - `h_wait_for_capture <method> <jq_predicate> [timeout_s]` — polls /__test__/captured until predicate matches or timeout.
  - `h_assert_file_exists <path>`, `h_assert_jq <file> <expr>` — state-side assertions.
  - `h_teardown` — kill mock, kill tmux socket, rm -rf state dir.

- [x] **A.3 — Test runner `tests/e2e/run.sh [scenario_name]`**

  No args: runs every `tests/e2e/scenarios/*.sh`. With name: runs only that scenario. Reports PASS/FAIL counts, surfaces logs on failure. Exit code = number of failed scenarios.

- [x] **A.4 — First scenario: `scenario_clear_real_mount.sh`**

  Validates D14 (the most recent fix). Steps:
  1. Setup sandbox + spawn mock.
  2. Pre-pair: write paired.json directly (skip pairing flow).
  3. Pre-mount: write a non-provisional mount at thread 42 + write session UUID file `U1`.
  4. Spawn poller.
  5. Inject `/clear` in thread 42 from paired user.
  6. Wait for capture: sendMessage to thread 42 containing "Cleared".
  7. Assert: $STATE_DIR/sessions/42 now holds a UUID != `U1`.
  8. Assert: tmux session for topic-42 was killed (has-session returns nonzero).
  9. Teardown.

- [x] **A.5 — README / discovery**

  Tiny README in `tests/e2e/README.md` explaining how to run, add scenarios, and what each library function does. Single source agents can read.

## Phase B — Coverage breadth (incremental)

Add scenarios covering each D-issue. Suggested order (smallest blast radius first):

- [ ] **B.1 — `scenario_mount_provisional_replace.sh`** (D1)
  - Inject `/mount /tmp/x` is not the right shape; we want the helper flow.
  - Easier: pre-write provisional row + helper tmux marker, run `cta mount` directly, assert row becomes non-provisional.
  - (This is essentially `test_cta_mount_provisional.sh` already; consider whether to duplicate at E2E layer or just reference.)

- [ ] **B.2 — `scenario_helper_unmounted_topic.sh`** (D2)
  - Inject "hi" to a brand-new thread on a paired bot.
  - Assert: helper-<id> tmux session appears.
  - Assert: helper sends greeting via sendMessage.
  - Manual: requires real claude headless. May be slow (5-15s cold start). Marker as `slow`.

- [ ] **B.3 — `scenario_concurrent_topics.sh`** (D3)
  - Pre-mount 2 topics with stub tmux sessions running `cat`.
  - Inject 50 messages alternating, all roughly the same instant.
  - Assert: each tmux pane's captured output contains ONLY its own messages.

- [ ] **B.4 — `scenario_provisional_gc_on_cold_boot.sh`** (D15)
  - Pre-write provisional row + dead helper-<id> tmux (i.e., never started).
  - Spawn poller.
  - Assert: provisional row was dropped within 5s of poller startup.
  - (Tests current behavior; after P2.3 fix this scenario asserts grace-period preservation instead.)

- [ ] **B.5 — `scenario_watchdog_respawn.sh`** (D4 + D11)
  - Pre-mount one topic + one provisional.
  - Spawn watchdog (`watch_network.sh main_loop`).
  - Kill the topic tmux session.
  - Wait for respawn.
  - Assert: topic tmux back; provisional row's helper-<id> still absent (D11 fix verified).

- [ ] **B.6 — `scenario_poller_kick_env.sh`** (D12)
  - Write `.env` with `PAGER_DISABLE_HELPER=1`.
  - Spawn watchdog. Kill poller.
  - Wait for kick_poller_session respawn.
  - Inject a message to an unmounted topic.
  - Assert: NO helper-<id> tmux was spawned (helper is disabled). Validates D12 env propagation.

- [ ] **B.7 — `scenario_pair_unpair_repair.sh`** (D7 + general lifecycle)
  - Inject /pair flow → paired.
  - Inject /unpair → cleanup.
  - Inject /pair again.
  - Assert state transitions complete + idempotent.

## Phase C — Agent-driven verification loop (this is the "監視できる機構")

Once scenarios are stable, expose them to a higher-level driver an agent can run:

- [ ] **C.1 — `tests/e2e/run.sh --json`**
  - Outputs structured results (per-scenario PASS/FAIL, duration, captured failure logs).
  - Agent reads JSON, diagnoses regressions, optionally re-runs.

- [ ] **C.2 — `tests/e2e/diff-run.sh <ref>`**
  - Runs the suite, compares against a baseline (last known-good run).
  - Reports `IDENTICAL` / `IMPROVED` / `REGRESSED` per scenario.
  - Agent calls this after each PR-shaped change.

- [ ] **C.3 — Per-scenario timeline log**
  - Each scenario writes a timeline JSONL: `{ts, event, data}` for setup, inject, capture, assert, teardown.
  - Failure surfaces the timeline so the agent can diagnose at the moment.

- [ ] **C.4 — Pre-commit hook (opt-in)**
  - When configured, runs the `fast` subset (no real claude headless) on every commit.
  - Slow scenarios run on push or in CI.

- [ ] **C.5 — Codebase-aware test selection**
  - Map files-changed → scenarios-to-run via simple manifest.
  - Editing `agent/poller/poller.ts` → run all poller scenarios.
  - Editing `cli/cta` → run cta + mount scenarios.

## Phase D — Real-Telegram smoke (optional, separate)

For releases. Hits real api.telegram.org with a dedicated test bot token + test chat. Validates the mock didn't lie. Triggered manually, not in CI.

- [ ] **D.1** — `tests/smoke/real-telegram.sh` with explicit TOKEN/CHAT env knobs, runs a tiny subset (pair + 1 message + 1 mount + /clear) against the real API.

## Risk and open questions

- **Claude headless cold-start cost.** Scenarios that need real claude take 5–15s on first message. Mitigations: (a) share a single claude process across scenarios in a suite (risk: state bleed between scenarios), (b) use a stub claude that replies via a script (risk: doesn't catch model-level regressions like the compaction-induced send_telegram drop in D6). Recommended default: real claude for the marked `slow` subset; stub claude for the bulk.

- **tmux + private socket reliability.** `test_cta_mounts.sh` already showed the gotcha (outer-tmux env leakage). Harness must strip `TMUX` / `TMUX_PANE`. Use `tmux -L /tmp/socket-<id>` consistently.

- **mcp-telegram process needs the mock URL.** Our mock-bot-api.ts already respects `TELEGRAM_API_BASE` (verified in test_send_telegram_e2e.sh). The harness sets it on the poller environment and on every spawned topic-wrapper (which passes env into the per-topic mcp-telegram config).

- **Race between inject and getUpdates poll.** The poller's getUpdates uses long-poll (POLL_TIMEOUT_SEC=25 by default). After inject, the poller's next poll returns the queued update — that next poll might be up to 25s away. Mitigation: harness sets `POLL_TIMEOUT_SEC=2` in scenario env so polls are fast.

- **Helper-mode scenarios need real claude.** The auto-mount feature's value is the helper conversation. Stub claude can't simulate that. Either (a) accept slow E2E for helper scenarios, (b) test helper invocation surface (does spawnHelper get called, does it pass the right args) at the unit level — which we already do.

- **CI cost.** Real claude in CI is expensive. Default CI: fast subset only. Slow subset runs on a nightly cron or PR label.

## Self-review

- **Layer purity (Principle 4):** the harness shells `bash`, `bun`, `tmux`, `curl` — same primitives the production system uses. No special hooks into poller internals; everything goes through the same Bot API path the real Telegram would use.
- **Liveness observed (Principle 2):** `h_wait_for_capture` polls until the predicate matches or timeout. No fixed sleeps.
- **Single source of truth (Principle 1):** all assertions go through the mock's captured store or the state files; no in-process introspection.
- **Failure loud (Principle 5):** every scenario writes its own log; failures dump the captured store, mount state, and tmux state to the runner output.
- **Recovery tested (Principle 8):** Phase B covers exactly the crash scenarios called out in stability plan P3.14.

## Cross-plan integration

- **Stability plan:** Phase A delivers `multi-topic-stability-plan.md` P3.14 (recovery test harness) at the foundation level. Phase B fills in each D-issue with an executable scenario.
- **Watch-live plan:** when Pager's watch-live ships, scenarios can spawn a `cta watch --follow` subscriber as a third party and assert the streamed content includes expected text.
- **TUI-command translation framework (P3.10):** once the command registry exists, scenarios for /clear, /compact, /fork, etc. all follow the same shape.
