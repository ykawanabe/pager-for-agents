# Multi-Topic Stability Plan

> **For agentic workers:** REQUIRED SUB-SKILL — use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans`. Steps use `- [ ]` for tracking.
>
> **Verify before edit:** other claude sessions may have edited the same files since this plan was written (2026-05-18). Every step that cites a `file:line` MUST be re-confirmed with `grep`/`Read` before mutation. If line numbers drift, re-find the construct by name.
>
> **Hard rule:** every fix lands behind a regression test that fails before, passes after. No "manual smoke test" sign-off.

---

## Context

`claude-telegram-agent` ships a long-running Claude Code session per Telegram forum topic. After the DM-only → `MULTI_TOPIC=1` transition (commits b46c975, 1fe34d4, 9ec8357, 07d44d2, 0bf9981, eb82669, 621aadd, ba04830, 034b833), three symptoms appeared:

1. **State disappears on restart** — mounts that worked before a reboot or `cta start` are gone.
2. **Connections only from one session** — multiple topics paired, but only one gets messages, or messages land in the wrong topic.
3. **"Read" but no reply** — Telegram shows the 👀 ack reaction, but no reply arrives.

A 2026-05-16 audit (`feat(group): close gaps surfaced by group/forum-topic feature audit`, commit 0bf9981) closed six gaps but didn't address routing/timing/lifecycle integrity. This plan addresses the residual instability.

---

## Investigation summary

Four parallel exploration agents on 2026-05-18 produced cross-confirmed findings (see Appendix A for the full evidence). The instability is **not one bug** — it's roughly fifteen interacting issues, several of which mask each other.

The Iron Law (root cause before fix): each design issue (D1–D15) has been mapped to specific symptoms with `file:line` evidence in the catalog below.

## Design principles (the recurrence-prevention layer)

This plan's success metric is not "the three reported symptoms stop." It's "the **next** instability event we cannot yet name fails to materialize because the architecture refused to allow it." Every fix below is evaluated against these principles. Tactical patches that close a symptom without restoring a principle are flagged for follow-up strategic fixes.

**Principle 1 — Single source of truth per state file.** Each persistent state file (`mounts.json`, `paired.json`, `topics.json`, `access.json`, `.env`) has exactly ONE writer. All other code reads via the writer's published API. Direct `rm`, `unlink`, or hand-rolled JSON mutation by any other layer is a violation.

**Principle 2 — Liveness is observed, never inferred.** "X is alive" is established by a probe (heartbeat freshness, process existence, tmux session presence, FIFO readability) at the moment of use — not by remembering that a previous operation succeeded. Fixed sleeps and "should be ready by now" assumptions are violations.

**Principle 3 — The inbound channel is typed and per-topic.** Telegram → claude message delivery flows through a well-defined per-topic channel. tmux's `paste-buffer` (a server-wide TUI primitive) is structurally wrong: it leaks across topics and depends on claude's TUI state being ready to consume keystrokes.

**Principle 4 — Layer purity.** Roles are: **CLI (`cta`)** owns state mutation. **Poller** is read-only on state, write-only on events (Telegram API calls, tmux dispatch). **Pager** is read-only on everything; all mutation flows through cta. Any breach (Pager direct-writes JSON, poller `unlink`s a state file, install.sh edits state outside cta) is a violation.

**Principle 5 — Failures are loud and instrumented.** Silent drops are forbidden. Every "we couldn't deliver this" or "we lost this state" path emits a structured log line + (eventually) a metric. The current "if tmuxDispatch fails, return silently" pattern is a violation.

**Principle 6 — Semantics owned by us, never delegated to upstream UIs.** When we expose a Claude Code TUI command over Telegram, WE define what it means, atomically. Forwarding `/clear` via send-keys and hoping the TUI's behavior is stable is a violation: we depend on claude TUI's internal behavior, which we don't own and can't pin.

**Principle 7 — Lifecycle is centralized.** Spawn / kill / respawn / GC of any per-topic process flows through one supervisor. Today the responsibility is fragmented across `start_agents.sh`, `topic-wrapper.sh`'s restart loop, `watch_network.sh`'s `kick_*` functions, `poller.ts`'s `spawnHelper` / `gcOrphanedProvisionals`, and `cta`'s tmux spawn after `mount`. Five places, five inconsistencies (D4 → D8 → D11 → D12 → D15 are all symptoms of this fragmentation).

**Principle 8 — Recovery is tested, not just hoped for.** For every crash scenario (poller killed, topic claude killed, helper killed, host reboot, network blip, MCP server lost mid-session, lock file stale), there is an automated test that triggers the crash and verifies clean recovery. "Manual smoke test" is a violation when an automated form is feasible.

**Principle 9 — Encoding rules track upstream, not best-effort mirror.** When we need to compute a value the same way an upstream tool (claude code) does (e.g., project-dir encoding), we either (a) call the upstream tool and read its answer, or (b) test our mirror against a golden fixture generated from the upstream. Hand-rolled "I think it replaces these chars" is a violation (see D13).

**Principle 10 — Manifest-driven install.** install.sh resources (agent files, hooks, prompts, permission profiles) are declared in a manifest, not hand-listed in copy commands. A new file added under `agent/` that should ship must fail a manifest-completeness test, not silently ship-or-not-ship depending on whether someone remembered to edit install.sh.

Each design issue below cites the principle(s) it violates. Each phase fix cites which principle it restores. A fix that doesn't restore a principle is still useful for closing a symptom, but the principle stays violated and a P3 strategic item is queued.

## Status updates (2026-05-18 post-review)

A code review on 2026-05-18 (against the in-flight auto-mount + watchdog work) updated the D-catalog status. Three new design issues surfaced (D11–D13). See `## Design issues catalog` for full details and `## Phase status` for which fix tasks are done / in-progress / blocked.

| ID | Status | Violates | Notes |
|---|---|---|---|
| D1 | ❌ Open (critical) | P4, P8 | `cta mount` still doesn't call `replaceMount` on provisional; helper commit fails end-to-end |
| D2 | ❌ Open (critical) | P10, P8 | `install.sh` does not copy `helper-prompt.md` / `helper-permissions.json` |
| D3 | ❌ Open | P3 | `tmux load-buffer` still server-global at `poller.ts:360`. Wrong inbound primitive (server-wide TUI buffer) |
| D4 | ✅ Fixed | P7 (partial) | `kick_dead_topic_sessions` wired in `watch_network.sh:258-260`. Glue-fix; lifecycle still fragmented |
| D5 | ⚠️ Partial | P2 | Still 2000ms sleep; no readiness probe |
| D6 | ⚠️ Partial | P5, P6 | System-prompt-level mitigation only (`topic-wrapper.sh:165`); no PostCompact hook recovery |
| D7 | ❌ Open | P1, P4 | Multiple writers to access.json + .env; Pager bypasses cta for state mutation |
| D8 | ❌ Open | P7 | wildcard filter at `start_agents.sh:195` — separate lifecycle policy from watchdog |
| D9 | ✅ Fixed (was already) | P8 | `install.sh:128-130` appends MULTI_TOPIC=1; only caught by audit, not by a test |
| D10 | (operator) | — | Verify in P0.2 |
| **D11** | ❌ New (P1) | P7 | `kick_dead_topic_sessions` respawns **provisional** rows as topic mode — watchdog doesn't know helper policy |
| **D12** | ❌ New (P1) | P4, P7 | `kick_poller_session` only forwards 2 env vars to the new poller — new mutator path with its own conventions |
| **D13** | ❌ New (P2) | P9 | Dot-encoding fix is best-effort mirror of claude's encoding rule; future chars retrigger the bug class |
| **D14** | ❌ New (P2) | P6 | `/clear` over Telegram: forwarding to TUI delegates semantics to claude; must be owned poller-side |
| **D15** | ❌ New (P2) | P2 | `gcOrphanedProvisionals` infers "helper is gone" from "tmux is dead" — false on cold boot |

---

## Design issues catalog

Each issue is labeled (D1, D2, ...) and referenced by symptom mapping and fix phases.

### D1. Helper-mode commit path broken

- `cli/cta:730,732` — `cmd_mount` calls only `bun run "$store" add` (never `replace`).
- `agent/mount-store/mount-store.ts:296-298` — `addMount` throws `is already mounted` on duplicate, **including provisional rows**.
- `agent/mount-store/mount-store.ts:321-345` — `replaceMount` exists but is unreferenced from `cta`.
- `agent/helper-prompt.md:15` — instructs helper claude to run `cta mount …` to commit; this always fails when a provisional row exists.
- **Net effect:** helpers can never commit. Provisional rows accumulate, get garbage-collected by `gcOrphanedProvisionals` on next poller restart → user observation: "the mount I made disappeared."

### D2. Helper files not installed in production

- `install.sh` contains zero references to `helper-prompt.md` or `helper-permissions.json`.
- `agent/topic-wrapper.sh:255-260` — helper mode resolves these files via the script's `dirname`; in a production install (`$INSTALL_DIR/agent/`) the files don't exist → `exit 1` before claude launches.
- **Net effect:** in a clean install, any inbound to an unmounted topic dies before reply. Combined with D1, the helper path is doubly broken on production.

### D3. tmux load-buffer is server-global

- `agent/poller/poller.ts:360` — `spawnSync("tmux", ["load-buffer", "-"], …)` and `:363` `paste-buffer -d -t <session>` use the DEFAULT tmux buffer (server-wide, no `-b <name>`).
- **Net effect:** two near-simultaneous messages to different topics race. Topic B's `load-buffer` overwrites the buffer before Topic A's `paste-buffer` fires → A gets B's text, or A gets empty. Manifests as "only one topic gets messages" and "messages land in the wrong topic."

### D4. Dead-topic watchdog is dead code

- `agent/watch_network.sh:90` — `kick_dead_topic_sessions()` defined.
- `agent/watch_network.sh:176-287` — `main_loop` never calls it (confirmed by `grep`).
- **Net effect:** a per-topic `topic-<id>` tmux that crashes between messages stays dead until next inbound. `respawnTopicSession` (poller-side, single retry) is the only recovery — it races claude cold-start (see D5).

### D5. Cold-start race on auto-spawn

- `agent/poller/poller.ts:1280` (wildcard auto-spawn) — `tmuxDispatch` fires immediately after `tmux new-session`.
- `agent/poller/poller.ts:1322` (helper auto-spawn) — fixed 2000 ms sleep before dispatch.
- Comment at `agent/topic-wrapper.sh:684-685` admits claude cold-start is 5–15 s.
- **Net effect:** `paste-buffer + send-keys Enter` lands on the bare shell prompt before claude attaches → shell executes the message text as a (failing) command → message lost. 👀 ack already fired → "read, no reply."

### D6. send_telegram MCP can drop after compaction

- `agent/topic-wrapper.sh:163-183` — uncommitted system-prompt addition tells claude to call `ToolSearch` if `mcp__telegram__send_telegram` is unavailable. The fact this paragraph exists is direct evidence the tool sometimes disappears mid-session (claude composes a terminal-only reply with no Telegram output).
- `agent/mcp-telegram/server.ts:117-163` — `sendMessage` failures (403, deleted topic, malformed parse_mode) return `isError:true` to claude but never surface to the user.
- `agent/poller/typing-keepalive.ts:103` — typing keepalive's 10-minute cap masks silent drops.
- **Net effect:** ack fires, reply lives only in claude TUI, never in Telegram.

### D7. State has multiple writers without coordination

- `~/.claude/channels/telegram/access.json` written by `cli/cta:387-399` (python3 in-place mutate) AND `pager/SettingsView.swift:106-129` (read-modify-write, no lock). Last write wins.
- `~/.pager/mounts.json` deleted by `cli/cta:643` (`rm -f`) AND `agent/poller/poller.ts:1019` (`unlinkSync`) — both bypass `withLock` in mount-store.
- `~/.claude/channels/telegram/.env` written by `pager/SettingsView.swift:83`, also edited by install.sh and operators.
- `STATE_DIR` resolved in 4 places: `agent/lib/paths.ts:26`, `cli/cta:47`, `pager/CTAClient.swift:93`, plus hardcodes in Pager Diagnostics.
- `pager/MenuView.swift:90` — Restart bot shells `start_agents.sh` directly, bypassing `cta start`.
- **Net effect:** silent drift across renames, TOCTOU on access.json, "all mounts gone after unpair" surprise.

### D8. start_agents.sh excludes wildcard mounts

- `agent/start_agents.sh:194-195` — `jq` filter `select(.thread_id != "*")` when spawning topic sessions from `mounts.json`.
- **Net effect:** wildcard-only topics rely on the first inbound message after restart to trigger `autoSpawnFromWildcard`. Until that message lands, the topic looks "missing." Compounds with D5's cold-start race.

### D9. MULTI_TOPIC=1 not appended to existing .env files

- `install.sh:91-92` — if `.env` exists, it is left untouched. The 2026-05-16 audit fix (append `MULTI_TOPIC=1` to existing .env without the line) is incomplete or regressed: verify.
- **Net effect:** v0 upgraders silently keep single-topic mode; `mounts.json` is never consulted → user sees "state disappeared" though it's intact.

### D10. 409 conflict from competing pollers

- MEMORY: `project_409_conflict_debugging.md` — `claude-plugins-official/telegram` auto-loads in other claude sessions and runs `getUpdates` against the same token.
- **Net effect:** Telegram delivers each update to ONE consumer of `getUpdates`. The competing poller(s) silently swallow some fraction → "only one session gets messages" intermittently.

### D11. `kick_dead_topic_sessions` respawns provisional rows as topic mode (introduced 2026-05-18)

- `agent/watch_network.sh:80-83` — jq pipeline filters `select(.thread_id != "*")` but does NOT filter `.provisional == true`.
- When a `helper-<id>` tmux dies mid-conversation (user idled, claude crashed, OOM), the watchdog respawns `topic-wrapper.sh <thread_id> $HOME helper-<id>` with NO 4th arg → defaults to **topic mode** (not helper mode).
- **Net effect:** the helper conversation is replaced by a confused topic-mode claude running in `$HOME`. User experience: messages stop making sense after a tmux death.

### D12. `kick_poller_session` drops most env vars (introduced 2026-05-18)

- `agent/watch_network.sh:144-149` — `tmux new-session -e TELEGRAM_BOT_TOKEN=... -e MAIN_CHAT_ID=... ...`.
- Drops: `MULTI_TOPIC`, `PAGER_DISABLE_HELPER`, `MOUNT_STORE_PATH`, `CTA_STATE_DIR`, custom path overrides.
- **Net effect:** operator opt-outs silently re-enabled after a kick. Specifically, a user who set `PAGER_DISABLE_HELPER=1` to disable the auto-mount helper will find it re-enabled after the watchdog respawns the poller.

### D13. Dot-encoding fix is symptom-scoped (introduced 2026-05-18)

- `agent/restart_claude.sh:71`, `agent/topic-wrapper.sh:201` — `encoded="${encoded//./-}"` handles `.`.
- claude's actual encoding rule is broader (any non-`[a-zA-Z0-9_]` → `-`). Future paths with `@`, `+`, `,` etc. will re-trigger the same crash-loop bug class.
- **Net effect:** the immediate github.com case is fixed; the bug class remains.

### D14. `/clear` over Telegram is intercepted with unhelpful message

- `agent/poller/poller.ts:1054` — `/clear` is in `CLAUDE_BUILTIN_BLOCKLIST`. User sending `/clear` from Telegram gets "Claude Code local UI command and can't run over Telegram."
- The user's natural mental model: "/clear should reset this topic's conversation."
- **Important:** removing `/clear` from the blocklist alone is NOT sufficient. `/clear` is captured by claude TUI at the TUI layer (not by the model). If we forward `/clear` via tmux send-keys:
  1. TUI clears context
  2. Model never sees the command, never calls `send_telegram`
  3. typing-keepalive runs to its 10-min cap (`typing-keepalive.ts:62-71` only clears on `send_telegram`)
  4. User sees 👀 ack followed by 10 minutes of typing indicator, then silence
- **Net effect:** the simple "remove from blocklist" approach has a fatal UX bug. Must be handled poller-side with explicit session UUID rotation + tmux kill + Telegram ack.

### D15. `gcOrphanedProvisionals` runs unconditionally at startup

- `agent/poller/poller.ts:1411` — runs once per poller start, drops every provisional row whose tmux is dead.
- On a Mac reboot, ALL helper-`<id>` tmux are dead → all in-progress helper conversations are wiped from `mounts.json`.
- **Net effect:** rebooting the Mac mid-helper-conversation silently destroys state. The user observation "状態が消える" maps here.

---

## Symptom → design issue mapping

| Symptom | Primary causes | Secondary |
|---|---|---|
| State disappears on restart | **D1** (helper can't commit → GC wipes), **D15** (cold-boot wipes all provisional), **D11** (provisional respawned as topic mode), **D8** (wildcard not spawned at start) | D2, D7 (`cta unpair` rm) |
| Only one session connects | **D3** (server-global buffer race), **D10** (409 with other claude) | D5 (cold-start race in one topic), D12 (env-drop after watchdog kick) |
| Read but no reply | **D5** (paste before claude binds MCP), **D6** (send_telegram lost post-compaction), **D2** (helper exit 1), **D14** (`/clear` half-handled) | D4 (dead-topic not resurrected — now fixed), D13 (path-encoding edge cases) |

---

## P0: Diagnostics (read-only, run FIRST)

Goal: confirm which D-issues are firing in the current install before changing code.

- [ ] **P0.1 — Verify MULTI_TOPIC mode is active**
  ```bash
  grep -n '^MULTI_TOPIC=' ~/.pager/.env
  ```
  Expected: `MULTI_TOPIC=1`. If missing or `=0`, **D9 is live**.

- [ ] **P0.2 — Check for competing getUpdates consumers**
  ```bash
  # Look for any process polling api.telegram.org/bot.../getUpdates besides ours
  lsof -nP -i :443 2>/dev/null | grep -i telegram || true
  ps -A -o pid,command | grep -Ei 'telegram|getUpdates' | grep -v grep
  # Any claude session loading claude-plugins-official/telegram?
  ls -la ~/.claude/plugins/cache/claude-plugins-official/telegram 2>/dev/null
  ```
  If any other process is polling the same token, **D10 is live**. Resolution: uninstall the plugin from competing sessions, do NOT rotate the token.

- [ ] **P0.3 — Inventory current mounts state**
  ```bash
  cat ~/.pager/mounts.json | jq '.'
  cat ~/.pager/paired.json | jq '.'
  cat ~/.pager/topics.json | jq '.' 2>/dev/null || echo "(no topics.json)"
  ```
  Note any `provisional: true` rows (**D1 evidence**), wildcard rows (**D8 evidence**), and stale `tmux_session: helper-*` (helpers that never committed).

- [ ] **P0.4 — Look for stale claude session locks**
  ```bash
  ls -la ~/.claude/tasks/*/lock* 2>/dev/null || find ~/.claude -name '*.lock' -maxdepth 4 2>/dev/null
  ls -la ~/.pager/sessions/ 2>/dev/null
  ```
  Cross-reference with `mounts.json` `session_id`. Any UUID in `sessions/` whose lock file in `~/.claude/tasks/` exists may block topic-wrapper restart.

- [ ] **P0.5 — Verify helper files are installed**
  ```bash
  ls -la $(realpath "$(which cta)" | xargs dirname)/../agent/helper-prompt.md 2>/dev/null
  # OR look at where topic-wrapper.sh is installed:
  ls -la ~/.local/share/pager/agent/helper-prompt.md 2>/dev/null
  ```
  If absent, **D2 is live**.

- [ ] **P0.6 — Confirm tmux server alive and topic sessions present**
  ```bash
  tmux ls 2>/dev/null
  ```
  Expected (MULTI_TOPIC): `poller`, `watchdog`, and one `topic-<thread_id>` per non-wildcard mount. Missing topic sessions = D4 evidence (or D5 race).

- [ ] **P0.7 — Record evidence in this file**
  Append a `## P0 Diagnostic Results — YYYY-MM-DD` section to this plan with the output. Subsequent phases skip items whose D-issue isn't firing.

**Gate:** do not start P1 until P0.1–P0.6 are recorded. P0 takes <10 minutes.

---

## Phase status (updated 2026-05-18 post-review)

P1 items completed by the in-flight session as of 2026-05-18:
- ✅ P1.3 (D4) — `kick_dead_topic_sessions` wired
- ✅ P1.5 (D9) — `MULTI_TOPIC=1` appended to existing .env

New P1 items added from the review:
- P1.6 — D11 (provisional row filter in watchdog)
- P1.7 — D12 (env propagation in `kick_poller_session`)
- P1.8 — D14 (`/clear` over Telegram — explicit handler, NOT blocklist removal)

P1 items still open:
- P1.1 (D1), P1.2 (D2), P1.4 (D3), P1.6 (D11), P1.7 (D12), P1.8 (D14)

P2 items added:
- P2.6 — D13 (broaden path-encoding to match claude's full rule)

## P1: Critical bug fixes (high-value, low-risk)

Each item: failing test → fix → passing test → commit.

- [ ] **P1.1 — D1: route `cta mount` to `replaceMount` when provisional exists**

  Location: `cli/cta:707-758` (`cmd_mount`).

  Approach: before `bun run "$store" add`, query mount-store for existing row at same `(channel,thread_id)`. If present AND `.provisional == true`, call `bun run "$store" replace` (verify replace CLI op exists at `agent/mount-store/mount-store.ts:448` per investigation, otherwise add one).

  Test (`tests/test_cta_mounts.sh`):
  - Pre-add a provisional row via `bun run mount-store add --provisional <id> /tmp` (or whatever the existing op accepts).
  - Run `cta mount <id> /tmp/realpath`.
  - Assert exit 0, row no longer has `provisional`, path is `/tmp/realpath`.

  Risk: low. `replaceMount` semantics already documented; only `cta`-side dispatch changes.

- [ ] **P1.2 — D2: install helper files**

  Location: `install.sh:159-189` (agent file copy block — verify exact range).

  Approach: extend the agent-file copy list to include `helper-prompt.md` and `helper-permissions.json`. Same `chmod` as siblings.

  Test (`tests/test_cta.sh` or new `tests/test_install_helper.sh`):
  - After running install.sh in a temp `$INSTALL_DIR`, assert both files exist with non-zero size at `$INSTALL_DIR/agent/`.

  Risk: low.

- [ ] **P1.3 — D4: wire `kick_dead_topic_sessions` into watchdog**

  Location: `agent/watch_network.sh:90-114` (definition) and `main_loop:176-287` (call site).

  Approach: in the MULTI_TOPIC branch of `main_loop` (where `heartbeat-poller` is checked), after the poller-health block, call `kick_dead_topic_sessions` on the success path. Add a frequency throttle (e.g. once every 60s) so we don't hammer tmux/mount-store on every tick.

  Test (`tests/test_restart_claude.sh` — extend, or new `tests/test_watchdog_topic_kick.sh`):
  - Start poller + one topic-<id> tmux in a sandbox.
  - Kill the topic tmux session.
  - Send a fake heartbeat tick (or wait one cycle).
  - Assert the topic tmux gets re-created.

  Risk: medium. New behavior; verify no thundering-herd on cold boot when many topics are simultaneously absent.

- [ ] **P1.4 — D3: per-session tmux buffer name**

  Location: `agent/poller/poller.ts:351-370` (`tmuxDispatch`).

  Approach: use a unique buffer name per call. Either:
  - `tmux load-buffer -b "pager-<session>-<nanoid>" - …` then `tmux paste-buffer -b "pager-<session>-<nanoid>" -d -t <session>` then implicit `delete-buffer -b <name>` (or explicit cleanup).
  - OR pipe via `printf … | tmux send-keys -t <session> -l` (literal paste) followed by `tmux send-keys -t <session> Enter`. The `-l` flag preserves multiline + emoji + code, no buffer needed.

  Test (`tests/test_dispatch_concurrent.sh` — new):
  - Spin up two dummy tmux sessions echoing their stdin to logs.
  - Fire 50 concurrent `tmuxDispatch` calls alternating between the two sessions with distinct text.
  - Assert each session's log shows ONLY its own texts, no cross-contamination.

  Risk: medium. `send-keys -l` is a different paste primitive — verify behavior with newlines, backticks, dollar signs. If `-l` doesn't round-trip cleanly, fall back to named-buffer approach.

- [x] **P1.5 — D9: append MULTI_TOPIC=1 to existing .env** (already in place at `install.sh:128-130`; verified in review)

- [ ] **P1.6 — D11: skip provisional rows in `kick_dead_topic_sessions`**

  Location: `agent/watch_network.sh:80-83`.

  Approach: extend the jq filter:
  ```bash
  entries=$(jq -r '.mounts[] | select(.thread_id != "*") | select((.provisional // false) == false) | [...] | @tsv' ...)
  ```
  Rationale: provisional rows are owned by `gcOrphanedProvisionals` (lifecycle-coupled to helper tmux). If a helper tmux dies, the GC drops the row — the watchdog should NOT respawn it as a topic-mode session in `$HOME`.

  Test (`tests/test_watchdog_respawn_provisional.sh` — new):
  - Pre-populate `mounts.json` with a provisional row pointing at a fake `helper-1` session.
  - Confirm no `helper-1` tmux exists.
  - Run `kick_dead_topic_sessions` directly.
  - Assert no new tmux session was created.
  - Assert `mounts.json` row is unchanged (watchdog isn't responsible for GC).

  Risk: low. Tightening a filter; no behavior change for non-provisional rows.

- [ ] **P1.7 — D12: propagate full .env in `kick_poller_session`**

  Location: `agent/watch_network.sh:117-155`.

  Approach: instead of cherry-picking `TELEGRAM_BOT_TOKEN` and `MAIN_CHAT_ID`, wrap the poller command in a bash that sources `.env`:
  ```bash
  tmux new-session -d -s poller \
    "bash -c 'set -a; . \"$STATE_DIR/.env\"; set +a; exec bun \"$poller_path\"'"
  ```
  This mirrors how `start_agents.sh` boots the poller initially. Drop the explicit `-e` flags except where they need to override .env values.

  Test (`tests/test_watchdog_poller_env.sh` — new):
  - Pre-populate `.env` with `PAGER_DISABLE_HELPER=1`.
  - Trigger `kick_poller_session` (or call directly in test mode).
  - Assert the spawned poller's environment includes `PAGER_DISABLE_HELPER=1` (e.g., via `tmux send-keys` + capture-pane to `env | grep` inside).

  Risk: medium. Sourcing .env in a shell-exec context has shell-quoting gotchas; verify with a token containing special chars.

- [ ] **P1.8 — D14: `/clear` over Telegram with explicit handler**

  Locations: `agent/poller/poller.ts:1054` (blocklist), and a new `handleClear` function near `handleCancel`.

  **Decision (2026-05-18):** Option B (explicit handler, NOT just blocklist removal). Rationale: simple blocklist removal forwards `/clear` to claude TUI via tmux send-keys; TUI consumes it without invoking `send_telegram` → typing-keepalive runs to 10-min cap → user sees silent 👀 + endless typing. See D14 catalog entry.

  Approach:
  1. Remove `/clear` from `CLAUDE_BUILTIN_BLOCKLIST` AND add `case "/clear": await handleClear(msg); return true;` in `tryHandleCommand`.
  2. `handleClear`:
     - Reject if topic is unmounted or in helper mode (provisional). Direct user to `/cancel` for helper-mode topics.
     - Rotate `$STATE_DIR/sessions/<thread_id>` to a new UUID (atomic write).
     - `tmux kill-session -t <mount.tmux_session>`.
     - Reply via send_telegram (poller-side, not claude's MCP): "Cleared. New session starting…"
  3. `kick_dead_topic_sessions` will respawn the topic with the new UUID → fresh claude session.

  Test (`tests/test_poller_clear.sh` — new shell + bun integration):
  - Pre-create a topic mount with session UUID U1, and a `helper-N` provisional mount.
  - Send `/clear` to the topic via a poller mock; assert:
    - `$STATE_DIR/sessions/<thread_id>` now holds a new UUID U2 (U1 → U2).
    - `tmux kill-session` was called on the topic's tmux_session.
    - Telegram reply was queued with "Cleared…" text.
  - Send `/clear` to the provisional mount; assert handler refuses + suggests `/cancel`.
  - Send `/clear` to an unmounted topic; assert handler is a no-op (or returns "Nothing to clear").

  Risk: low. New code path, doesn't affect existing flows. Edge case: race with helper commit (small window — accept).

**Gate:** all P1 tests green + manual smoke (send message to a new topic, observe helper → mount → reply round-trip; send `/clear` to a real mount, observe ack + new session) before P2.

---

## P2: Timing and state-integrity fixes

- [ ] **P2.1 — D5: claude readiness probe before dispatch**

  Locations:
  - `agent/poller/poller.ts:1190-1228` (`autoSpawnFromWildcard`)
  - `agent/poller/poller.ts:676-732` (`spawnHelper`)
  - `agent/poller/poller.ts:1340-1342` (`respawnTopicSession`)

  Approach: introduce `waitForClaudeReady(tmuxSession, deadlineMs)`. Strategy options (pick the most reliable available):
  1. Probe `~/.claude/tasks/<session_uuid>/` for existence (claude creates this directory after MCP init).
  2. `tmux capture-pane -t <session> -p | head` polling for claude's TUI prompt characters (`>` or similar).
  3. Send a no-op `tmux send-keys` first and wait until pane content changes.

  Replace the fixed 2000 ms sleep in `spawnHelper`. Add the same wait to wildcard auto-spawn (currently zero wait) and to `respawnTopicSession`.

  Test (`tests/test_dispatch_after_spawn.sh` — new):
  - Mock claude binary that takes N seconds to print its prompt.
  - Auto-spawn topic, immediately dispatch.
  - Assert message lands in claude after readiness, not into the shell pre-claude.

  Risk: medium. Wrong readiness signal causes either drops (false-positive ready) or hangs (false-negative). Have a hard deadline + fallback to current behavior on timeout.

- [ ] **P2.2 — D8: spawn wildcard at start_agents.sh**

  Location: `agent/start_agents.sh:180-208`.

  Approach: drop the `select(.thread_id != "*")` filter OR add an explicit wildcard-spawn step that creates a placeholder `topic-wildcard` tmux session running idle (no claude — only used to mark "wildcard is live"). Decide: does wildcard need a pre-spawned topic, or is the issue purely cosmetic ("first message takes longer")?

  If we keep lazy spawn, document the first-message latency expectation in README. Otherwise:

  Test (`tests/test_start_agents_wildcard.sh` — new):
  - Pre-populate `mounts.json` with one wildcard row.
  - Run `start_agents.sh main_multi_topic` against a sandbox.
  - Assert appropriate tmux state.

  Risk: low if we keep lazy and just document; medium if we change spawn semantics.

- [ ] **P2.3 — D1+gc: defer gcOrphanedProvisionals on cold boot**

  Location: `agent/poller/poller.ts:1414` (calls `gcOrphanedProvisionals`).

  Approach: avoid wiping provisional rows immediately on poller start. Either:
  1. Add a grace window — only GC provisional rows older than N minutes since `created_at`.
  2. Check if `start_agents.sh` was the parent (cold boot) vs. poller-only restart; skip GC on cold boot, run after a delay.

  Test (`tests/test_gc_provisional_grace.sh` — new):
  - Pre-populate a provisional row created 10s ago.
  - Boot poller.
  - Assert row still exists after one tick.
  - Wait until grace elapses; assert GC runs.

  Risk: low; defensive.

- [ ] **P2.4 — D6: send_telegram resurrection on compaction**

  Locations:
  - `agent/bot-hooks.json` (PreCompact/PostCompact hooks)
  - `agent/topic-wrapper.sh` (claude args, hook script invocation)

  Approach: PostCompact hook calls a check script that verifies `mcp__telegram__send_telegram` is reachable (e.g., dry-run a Bot API `getMe`). If not, signal the topic-wrapper to restart claude (touch a sentinel file the wrapper's main_loop checks before the next iteration).

  This is non-trivial — depends on claude's internal compaction lifecycle. Coordinate with `034b833` (helper system prompt addition).

  Test: hard to automate reliably. Manual test: send 100+ messages to trigger compaction, send the 101st, verify reply arrives. Document the test procedure if no automated form is feasible.

  Risk: high; touches claude internals' assumptions. Consider deferring to P3 unless D6 is verified live in P0.

- [ ] **P2.5 — D7: stop `cta unpair` from rm-ing mounts.json**

  Locations:
  - `cli/cta:639-649` (rm path)
  - `agent/poller/poller.ts:1018-1019` (parallel rm path)

  Approach: replace `rm -f` with a mount-store CLI op (`clear`) that acquires the lock and writes an empty `{ "mounts": [], "version": 2 }`. Preserve atomicity.

  Test (`tests/test_cta_unpair.sh` — new or extend):
  - Pre-populate mounts.
  - Run `cta unpair` (without `--keep-mounts`).
  - Assert `mounts.json` exists and is `{"mounts":[]}`.
  - Run concurrent `cta mount` during unpair (loop a few times) — no torn writes.

  Risk: low; consolidates an existing path.

**Gate:** all P2 tests green + manual E2E (helper → mount → 50 messages → compaction → continued reply).

---

## P3: Design integrity (recurrence prevention)

These are larger refactors. Land each as its own PR.

- [ ] **P3.1 — D7-d: single STATE_DIR resolver**

  Locations: `agent/lib/paths.ts:26`, `cli/cta:47`, `pager/CTAClient.swift:93`, plus Pager Diagnostics hardcodes.

  Approach: declare `agent/lib/paths.ts` canonical for the TS/bun side. Add a `cta state-dir` command (prints `$STATE_DIR`) and have Pager call it once at launch and cache. Eliminate the Swift duplicate. CLI bash already sources via `paths.ts`'s env — verify.

  Test:
  - Set `CTA_STATE_DIR=/tmp/xxx`; run `cta state-dir`; assert prints `/tmp/xxx`.
  - Launch Pager (unit test or runtime probe); assert it sees `/tmp/xxx`.

  Risk: medium. Swift app surface change; ensure backwards-compat if cached value missing.

- [ ] **P3.2 — D7-a/b: Pager routes through cta for all state writes**

  Locations:
  - `pager/SettingsView.swift:83` (.env write)
  - `pager/SettingsView.swift:106-129` (access.json write)
  - `pager/MenuView.swift:90` (start_agents.sh shell-out)

  Approach:
  - .env writes → `cta config token`, `cta config <key>` (add ops as needed).
  - access.json writes → `cta config ack` (exists) and equivalents for `allowFrom` etc.
  - Restart bot → `cta start` (idempotent — already used elsewhere).

  Pager stops touching `~/.pager/*` and `~/.claude/channels/telegram/*` directly except for read-via-`cta-*-json` commands.

  Test:
  - Each cta config op gets a shell test.
  - Pager unit test: call each Settings save action, mock cta, assert correct cta invocation.

  Risk: medium. Pager has to wait on cta exit, async UX.

- [ ] **P3.3 — D7: Pager reads state via cta JSON ops**

  Locations: `pager/CTAClient.swift:283-329` (direct file reads of paired/topics).

  Approach: extend `cta list --json` (already exists) to also expose paired + topics. Or add `cta status --json` with the full state shape. Pager reads exclusively through these.

  Test: `cta status --json` shell test asserting schema. Pager unit test mocking the JSON.

  Risk: medium. Pager UI refresh polling cost increases (forking cta vs. raw read). Cache aggressively.

- [ ] **P3.4 — D6/D7: push-not-poll for state changes**

  Locations: `agent/poller/poller.ts:1149-1157` (mtime watch in `refreshMountsIfChanged`), all callers of mount writes.

  Approach: when `cta` mutates state, signal the poller via:
  - `kill -SIGUSR1 $(pgrep -f 'bun.*poller')` — poller registers a handler that triggers immediate cache refresh.
  - OR a write-side bump to a sentinel file the poller `inotify`-equivalents (macOS `kqueue`).

  Eliminate mtime polling (still keep as a fallback heartbeat).

  Test: `cta mount` followed by sub-second message dispatch — assert poller routes correctly. Without the signal, this should fail; with it, pass.

  Risk: medium. Signal handler must be reentrant-safe; lock around cache refresh.

- [ ] **P3.5 — D7: prevent dual access.json writers**

  Locations: `cli/cta:387-399` (python3 mutate), `pager/SettingsView.swift:106-129`.

  Approach: cta becomes the only writer (per P3.2). Add a file lock in `cta config ack` similar to mount-store's `withLock`. Remove the Pager direct write.

  Test: concurrent `cta config ack on/off` invocations — last-wins semantics preserved, no torn JSON.

  Risk: low after P3.2 lands.

- [ ] **P3.6 — clean separation: `mount.session_id` vs `~/.pager/sessions/<thread_id>`**

  Locations: `agent/mount-store/mount-store.ts:304,337` (`session_id` field generation), `agent/topic-wrapper.sh:107-114` (per-thread UUID file).

  These are two separate "what session_id should claude resume" sources. The mount field looks load-bearing but `topic-wrapper.sh` reads the file, not the mount. Decide:
  - Drop `Mount.session_id` entirely (it's dead code per investigation), OR
  - Make `Mount.session_id` canonical and stop writing the `sessions/<thread_id>` file.

  Test: a `cta umount <id>; cta mount <id> <new_path>` round-trip — assert fresh claude session UUID and no resume of prior transcript.

  Risk: medium. Touches transcript continuity; verify `--resume` behavior post-change.

- [ ] **P3.7 — sessions/<thread_id> cleanup on umount/unpair**

  Locations: `cli/cta:760-790` (`cmd_umount`), `cli/cta:617-649` (`cmd_unpair`).

  Approach: `cta umount` and `cta unpair` delete the per-thread session UUID file (plus the lock under `~/.claude/tasks/<uuid>/` if safe).

  Test: pre-create the UUID file; run `cta umount`; assert file deleted.

  Risk: low.

### Strategic refactors (the recurrence-prevention layer proper)

The items above mostly address Principle 1 (single source of truth) and Principle 4 (layer purity). The items below address the principles that, if left unaddressed, will produce the *next* class of instability.

- [ ] **P3.8 — Centralized lifecycle supervisor** (Principle 7)

  Today, spawn/kill/respawn of per-topic processes is scattered across:
  - `agent/start_agents.sh` (initial spawn from mounts.json)
  - `agent/topic-wrapper.sh` (in-tmux restart loop on claude crash)
  - `agent/watch_network.sh` `kick_dead_topic_sessions` (tmux-level respawn)
  - `agent/watch_network.sh` `kick_poller_session` (poller respawn)
  - `agent/poller/poller.ts` `spawnHelper` (helper spawn)
  - `agent/poller/poller.ts` `autoSpawnFromWildcard` (wildcard-mount spawn)
  - `agent/poller/poller.ts` `gcOrphanedProvisionals` (helper row GC)
  - `cli/cta` (post-mount tmux spawn at `cli/cta:747-754`)

  D4, D8, D11, D12, D15 are all consequences of this fragmentation. Each new spawn site reimplements its own env handling, its own provisional-row policy, its own wildcard filter.

  Approach: introduce `agent/lifecycle/supervisor.ts` (bun module) exposing:
  ```ts
  type TopicSpec = { thread_id: ThreadId; project_path: string; tmux_session: string; mode: "topic" | "helper" | "wildcard"; env: Record<string,string> };
  
  async function ensureTopicAlive(spec: TopicSpec): Promise<void>;
  async function killTopic(thread_id: ThreadId, reason: string): Promise<void>;
  async function listLiveTopics(): Promise<TopicSpec[]>;
  async function gcProvisionalTopics(opts: { graceSecondsSinceBoot: number }): Promise<number>;
  ```
  All current spawn/kill callers replaced with calls into the supervisor. The supervisor owns env merging (one canonical "what env does a topic get" function — fixes D12), provisional policy (one canonical "should we respawn this row" check — fixes D11), and wildcard handling (one canonical "what does wildcard spawn mean" — fixes D8).

  Test (`tests/test_lifecycle_supervisor.sh` — new, comprehensive):
  - Spawn a topic; assert tmux alive + env correct.
  - Spawn a helper; assert tmux alive + helper mode + provisional row.
  - Helper crashes; supervisor respawns (helper mode preserved if pre-grace, GC'd if post-grace).
  - Topic crashes; supervisor respawns with full env.
  - Provisional row + helper tmux dead + within cold-boot grace → kept; outside grace → dropped.
  - Concurrent calls don't double-spawn (idempotency + locking).

  Risk: high. This is the largest refactor in the plan. Land behind a feature flag (`PAGER_LIFECYCLE_SUPERVISOR=1`) that routes spawn/kill through the new path; legacy paths stay as fallback until the flag is the default. After two weeks of stability under the flag, remove legacy.

  Restores: P7 entirely. Enables P3.11 (manifest-driven, since supervisor reads from manifest), P3.14 (recovery tests target the supervisor).

- [ ] **P3.9 — Per-topic inbound FIFO (replace tmux paste-buffer)** (Principle 3)

  `tmux load-buffer` + `paste-buffer` is the wrong primitive: it's a server-wide TUI display buffer, not a structured inbound channel. Today it races across topics (D3), races against claude cold-start (D5), and depends on claude's TUI being ready to consume keystrokes (which is itself an inferred liveness — P2 violation).

  Approach: each topic's `topic-wrapper.sh` creates `$STATE_DIR/inbound/<thread_id>.fifo` and spawns claude with stdin redirected from the FIFO:
  ```bash
  mkfifo "$STATE_DIR/inbound/$THREAD_ID.fifo" 2>/dev/null
  claude "${args[@]}" < "$STATE_DIR/inbound/$THREAD_ID.fifo"
  ```
  The poller writes to the FIFO instead of calling `tmuxDispatch`:
  ```ts
  const fifo = openSync(fifoPath, O_WRONLY | O_NONBLOCK);
  writeSync(fifo, text + "\n");
  closeSync(fifo);
  ```
  Properties:
  - Per-topic isolation (each FIFO is independent — D3 disappears structurally).
  - Backpressure (write blocks if claude isn't reading — turns D5's silent message loss into observable wait, fixable with O_NONBLOCK + retry).
  - Survives compaction (FIFO is filesystem-level, not bound to claude's TUI lifecycle).
  - Standard POSIX primitive — no tmux-version-specific behavior.

  Trade-offs / open questions:
  - Does claude accept FIFO stdin cleanly for interactive use? Test on a small toy first.
  - tmux still owns the visible pane (so `cta attach`, "watch live" still work). dispatch and display are decoupled.
  - Multi-line / paste-mode handling: FIFO write preserves bytes exactly; no escaping needed. Better than tmux paste-buffer.

  Test (`tests/test_fifo_dispatch.sh` — new):
  - Spawn a mock claude reading from FIFO, echoing input to a log.
  - Write 50 concurrent messages alternating between two FIFOs.
  - Assert each FIFO's log shows ONLY its own messages, in order.
  - Test with multi-line / unicode / emoji / code-blocks.

  Risk: medium-high. claude must accept FIFO stdin; if not, fallback to a different per-topic primitive (per-topic tmux session pipe with `pipe-pane -I`).

  Restores: P3, P2 (FIFO backpressure observed, not inferred).

- [ ] **P3.10 — TUI-command translation framework** (Principle 6)

  `/clear` (D14) is the first instance of a class: Claude Code TUI commands that have meaningful Telegram equivalents but cannot be forwarded verbatim. Today these are hand-listed in `CLAUDE_BUILTIN_BLOCKLIST` and rejected wholesale. We forfeit a whole UX surface.

  Approach: build a registry of TUI commands with three dispositions:
  - **Translated** — has a poller-side handler that implements the semantic over Telegram (e.g., `/clear` → rotate UUID + kill + ack).
  - **Hidden** — TUI-only, no Telegram equivalent (e.g., `/output-style`, `/agents`). Reply with a clear "this is a TUI-only command" message.
  - **Forwarded** — safe to send to claude TUI via inbound channel (e.g., user skill commands like `/qa`).

  Registry shape (in `agent/poller/tui-commands.ts`):
  ```ts
  type Disposition = "translated" | "hidden" | "forwarded";
  type CommandSpec = {
    pattern: string | RegExp;
    disposition: Disposition;
    handler?: (msg: TgMessage) => Promise<void>;
    hiddenReason?: string;
  };
  ```
  Adding a new command is one entry. Future Claude Code releases that add commands need a one-line registry update (vs. today's hand-grown blocklist that silently fails to keep up).

  Test (`tests/test_tui_commands.sh` — new):
  - For each registry entry, assert disposition is one of the three.
  - For each `translated`, assert handler is callable.
  - For unknown `/foo`, assert default `forwarded` path.
  - Smoke: send `/clear`, assert handler ran (UUID rotated, tmux killed, ack sent).

  Risk: low; pure refactor of the existing intercept logic.

  Restores: P6 (we own semantics), P5 (the "drop on unknown command" path is explicit, not silent).

- [ ] **P3.11 — Install manifest with completeness test** (Principle 10)

  D2 (helper files not shipped) was caught by a code review. D9 (MULTI_TOPIC default) was caught by an audit. Both should be caught by a test before reaching review.

  Approach: declare `agent/MANIFEST.txt` (or `install-manifest.toml`) listing every file under `agent/` that must ship plus its expected install destination and permissions. `install.sh` reads this manifest instead of hand-listing files. CI runs a completeness check:
  ```
  for f in $(find agent/ -type f); do
    grep -q "^$f " MANIFEST.txt || echo "MISSING from manifest: $f"
  done
  ```
  Any file under `agent/` not in the manifest fails CI. Conversely, any manifest entry pointing at a missing file fails CI.

  Same pattern for env defaults: a `agent/env-defaults.txt` lists every `KEY=DEFAULT` that install.sh must ensure exists in `.env`. install.sh iterates the file. A test verifies the file matches what install.sh writes.

  Test (`tests/test_install_manifest.sh` — new):
  - Every file under `agent/` is in MANIFEST.
  - Every manifest entry resolves to a real file.
  - install.sh dry-run output matches the manifest.

  Risk: low; CI gate, doesn't touch runtime.

  Restores: P10. Also makes future renames safe (rename a file → update manifest in same commit, CI catches drift).

- [ ] **P3.12 — Path-encoding from upstream** (Principle 9)

  D13: our `restart_claude.sh` and `topic-wrapper.sh` mirror claude's project-dir encoding by hand (`.` → `-`, `/` → `-`). claude's actual rule is broader. The bug class repeats every time a new path character appears.

  Approach: don't mirror. Either:
  - **(a)** Call claude itself with `--print-session-path <cwd>` (if such flag exists; verify) and parse the answer.
  - **(b)** Generate a golden fixture in CI by invoking claude on representative paths and recording the encoded forms, then test our `session_arg_flag` against the fixture.
  - **(c)** Read claude's source-of-truth function (if available via the published API) and mirror it with a versioned fixture.

  Test:
  - Golden fixture covers paths with `.`, `/`, `@`, `+`, `,`, `:`, space, unicode.
  - `session_arg_flag` matches fixture for every entry.
  - On claude version bump, fixture regen step in CI flags any encoding rule change.

  Risk: medium. Depends on claude exposing a way to compute the encoded path; if not, fall back to fixture + manual regen.

  Restores: P9.

- [ ] **P3.13 — MCP health probe + recovery** (Principle 5, partial Principle 6)

  D6 (send_telegram disappears after compaction) is today mitigated by a system-prompt paragraph telling claude to call `ToolSearch`. This delegates the recovery to claude's behavior — fragile.

  Approach: the topic-wrapper's PostCompact hook (`bot-hooks.json`) calls a probe script that does one of:
  - Calls Bot API `getMe` directly to verify mcp-telegram is reachable.
  - Or: checks that `mcp-telegram` MCP server process is still alive (PID check).

  If unhealthy, the hook touches a sentinel file (`$STATE_DIR/topic-<id>/.restart-requested`). The wrapper's `main_loop` checks this file each iteration; if present, exits claude cleanly (SIGTERM, drain) → restart loop respawns with fresh MCP.

  Test:
  - Kill mcp-telegram while claude is running; touch the PostCompact sentinel (or wait for hook trigger); assert wrapper restarts claude within 30s.
  - After restart, send a message; assert reply arrives via Telegram.

  Risk: high. Touches claude/MCP internals. Land behind `PAGER_MCP_HEALTH_PROBE=1` flag.

  Restores: P5 (probe is real), P6 partially (we recover instead of asking claude to recover itself).

  Note: this supersedes P2.4 (which is the prompt-level workaround). When P3.13 lands, the system prompt paragraph at `topic-wrapper.sh:165-170` becomes redundant — remove it then.

- [ ] **P3.14 — Recovery test harness** (Principle 8)

  Manual smoke tests are a violation of P8. Build an automated harness:
  - `tests/recovery/poller-killed.sh` — kills poller, asserts respawn within N seconds, asserts inbound messages flow.
  - `tests/recovery/topic-killed.sh` — kills topic-<id>, asserts respawn, asserts next message routed correctly.
  - `tests/recovery/helper-killed-pre-commit.sh` — kills helper mid-conversation, asserts row stays within grace, drops after grace.
  - `tests/recovery/host-reboot.sh` — simulates reboot by SIGTERMing every pager process + clearing tmux, asserts startup recovers all real (non-provisional) mounts.
  - `tests/recovery/network-blip.sh` — drops network 30s, asserts watchdog re-establishes, no message loss.
  - `tests/recovery/mcp-killed.sh` — kills mcp-telegram bun process, asserts P3.13 recovery.
  - `tests/recovery/compaction-bump.sh` — forces compaction (synthetic), asserts send_telegram still works.
  - `tests/recovery/stale-lock.sh` — pre-creates `~/.claude/tasks/<uuid>/.lock` with no holder, asserts `clear_stale_lock` removes it.
  - `tests/recovery/dual-claude-token.sh` — spawns a competing `getUpdates` consumer; asserts our poller logs the 409 and continues (not just silently drops).

  Each test must run in <60s, in a sandbox state-dir, leave the host clean.

  CI runs the full suite on every PR.

  Risk: medium. Setup complexity is real. Mitigation: most tests reuse the lifecycle supervisor's test harness (P3.8 dependency).

  Restores: P8 entirely. Provides the safety net that lets future refactors be undertaken without fear.

**Gate:** P3 strategic items (P3.8–P3.14) are independent of each other but each carries real complexity. Land them in this order: P3.8 (supervisor) → P3.11 (manifest) → P3.10 (TUI commands) → P3.14 (recovery tests) → P3.9 (FIFO) → P3.12 (encoding) → P3.13 (MCP probe). Reasoning: supervisor is foundation; manifest catches drift early; TUI commands closes the /clear gap quickly; recovery tests guard the bigger changes; FIFO and MCP probe are the riskiest and benefit most from the test harness.

---

## P4: Validation

- [ ] **P4.1 — Multi-topic E2E smoke**

  Scenario:
  1. Pair fresh group with bot.
  2. Create 3 forum topics, send `hi` to each within 1 s of each other.
  3. Helper mode (D1+D2) commits each to a distinct project dir.
  4. Each topic gets a reply within 30 s.
  5. Send 5 more messages, 1 per topic, simultaneously.
  6. Each reply lands in the correct topic.
  7. Kill the poller tmux session manually; watchdog kicks within 2 min.
  8. After respawn, send another message to each topic; replies still land correctly.
  9. Reboot the Mac. After login, every topic recovers without manual intervention.

  Document in `docs/test-plan.md` as `multi-topic-stability-e2e` test sequence.

- [ ] **P4.2 — Compaction stress test**

  Send 200 messages to one topic, observe behavior across N compaction cycles. Assert send_telegram remains live throughout. Document threshold and recovery time if it does drop.

- [ ] **P4.3 — Update CHANGELOG**

  Single entry covering D1–D10 fixes. Reference this plan file.

- [ ] **P4.4 — Update README "known issues"**

  Either remove resolved items or list explicitly what was fixed and in what release.

---

## Open items / out-of-scope

- **F5 (cross-host)** and **F4 (multi-channel)** from roadmap are untouched. This plan is single-channel (Telegram) integrity only.
- **Pager Mounts tab UX** improvements (per-mount Watch live link) deferred.
- **`cta groups list` discovery / `cta prune` for orphans** deferred.
- **Helper idle timeout** deferred to v0.2 (per auto-mount.md).
- **Removing install-time wildcard mount** is a separate decision (changes onboarding default).

---

## Self-review

- **Principles coverage:** every principle (P1–P10) has at least one P3 strategic item that restores it. P1: P3.1/.5; P2: P3.9, P3.13; P3 (channel): P3.9; P4: P3.1/.2/.3/.5; P5: P3.13, P3.10; P6: P3.10, P3.13; P7: P3.8; P8: P3.14; P9: P3.12; P10: P3.11.
- **D-issue coverage:** each D-issue has at minimum a tactical fix (P1 or P2) AND, where the underlying principle violation persists after the tactical fix, a strategic counterpart (P3). D1 → P1.1; D2 → P1.2 + P3.11; D3 → P1.4 + P3.9; D4 → ✅ (already wired); D5 → P2.1 + P3.9; D6 → P2.4 → superseded by P3.13; D7 → P2.5 + P3.1/.2/.3/.5; D8 → P2.2 + P3.8; D9 → ✅ + P3.11 (so the next D9-class drift fails a test); D11 → P1.6 + P3.8; D12 → P1.7 + P3.8; D13 → P3.12; D14 → P1.8 + P3.10; D15 → P2.3 + P3.8.
- **Tactical vs strategic separation:** tactical fixes (P1/P2) close visible symptoms without claiming the principle is restored. Strategic items (P3) are framed against principles, not symptoms. The plan does not declare "stability" until P3 is landed.
- **Order rationale:** P0 verifies which issues are firing (avoid fixing dead bugs). P1 unblocks the auto-mount feature (D1+D2 are ship-blockers). P2 hardens timing/state integrity at the existing-design level. P3 is the recurrence-prevention layer — without it, the next instability of a different shape will find a different fragmentation point.
- **Robustness against future changes:** P3.10 (TUI commands), P3.11 (install manifest), P3.12 (encoding from upstream), P3.14 (recovery tests) each define a *system* that absorbs future change. Adding a new TUI command is one registry entry. Adding a new agent file is one manifest line. A claude version bump that changes encoding fails CI loudly. A new crash scenario gets a recovery test that the rest of CI enforces.
- **What this plan deliberately does NOT do:** introduce LINE (F4) or cross-host (F3); restructure the channel adapter abstraction; rewrite mcp-telegram. These are intentionally out of scope — the goal is stabilize-then-extend.
- **File-line drift caveat:** other claude sessions may be editing. Every step says "verify location before edit."
- **Test-first compliance:** every tactical fix has a failing-test step. Strategic fixes additionally have a feature-flag rollout so legacy paths stay as fallback during stabilization.

## Appendix A — Investigation evidence

(Compiled 2026-05-18 from four parallel exploration agents — routing, state, helper-mode, CLI/Pager boundary.)

Key cited locations (re-verify before edit):

- `agent/poller/poller.ts`: `tmuxDispatch:351-370`, `spawnHelper:676-732`, `gcOrphanedProvisionals:734-744`, `autoSpawnFromWildcard:1190-1228`, `routeMessage:1256-1283`, `dispatchUpdate:1285-1356`, mtime watch `:1149-1157`.
- `agent/mount-store/mount-store.ts`: `addMount:271-312`, `replaceMount:321-345`, `gcProvisional:353-367`, `withLock:170-191`, atomic write `:256-267`.
- `agent/topic-wrapper.sh`: per-thread UUID `:107-114`, MCP config `:139-158`, system prompt `:163-183`, helper mode `:240-282`, main loop `:284-318`.
- `agent/watch_network.sh`: `kick_dead_topic_sessions:90-114` (UNREFERENCED), `kick_poller_session:116-155`, `main_loop:176-287`.
- `agent/start_agents.sh`: `main_multi_topic:80-208` (wildcard filter at `:194-195`).
- `agent/mcp-telegram/server.ts`: env pin `:32-48`, `sendMessage:117-163`.
- `agent/lib/paths.ts`: STATE_DIR resolver `:26-62`.
- `cli/cta`: `cmd_mount:707-758` (no replace path), `cmd_unpair:617-649` (rm -f), `cmd_umount:760-790`, ack mutation `:387-399`.
- `pager/SettingsView.swift`: env write `:83`, access write `:106-129`.
- `pager/MenuView.swift`: shell start_agents `:90`.
- `pager/CTAClient.swift`: STATE_DIR dup `:93`, paired read `:283`, topics read `:314`.
- `agent/helper-prompt.md`: cta mount commit `:15`.
- `install.sh`: `.env` left-alone `:91-92`, agent copy block `:159-189`, no helper-* copy.

Each step in this plan that mutates code MUST re-verify these locations with grep before editing — line numbers will drift.
