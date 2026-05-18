# Pager: Native Watch-Live View

> **For agentic workers:** REQUIRED SUB-SKILL — use `superpowers:subagent-driven-development`. Steps use `- [ ]` for tracking.
>
> **Hard rule:** Pager must not directly invoke `tmux`. All access to per-topic state goes through `cta`. This is Principle 4 of `multi-topic-stability-plan.md` ("Layer purity"). Any temptation to shell `tmux capture-pane` from Swift is wrong — surface it via a `cta` op first.

## Context

Today, "Watch live" in Pager's menu bar opens Terminal.app and runs `tmux attach -t topic-<id>`. The user is then inside a real terminal with claude's TUI. This works but:
- Requires Terminal.app installed and accessible (some users disable it / use only Pager).
- The "attach" gives WRITE access to claude's TUI — a typo can issue `/clear`, `/exit`, etc.
- Visual style is whatever Terminal.app is configured for; no Pager branding.
- No way to multi-watch (separate Terminal windows clutter quickly).
- Mobile-style observability (just see what's happening) requires full terminal literacy.

Goal: **a single native Pager window that shows the live state of ALL active topics at a glance**, with optional message input to the focused topic.

### Layout decision (2026-05-18)

Sidebar + main pane (Slack/Discord pattern), NOT one-window-per-topic. Reasoning:
- Watching N topics in detail simultaneously is impractical at typical screen real estate.
- Users want both **overview** (which topics have activity right now?) and **detail** (what is IronFlow doing?). A sidebar with unread indicator + 1-line preview gives overview; the main pane gives detail.
- Single-window scales to many topics. Per-topic windows clutter the dock and require the user to manage window state.
- Familiar UX from Slack, Discord, Element — no learning curve.

```
┌──────────────┬─────────────────────────────────┐
│ # IronFlow   │ ⏺ Bash(git status --short)      │
│   ⏺ git st…  │   M IronFlow.xcodeproj/...      │
│              │   M IronFlow/DesignSystem/...   │
│ # Plans  ●   │ ❯ コミットしてmainにマージ        │
│   ❯ コミッ.. │                                  │
│              │ ⏺ Handoff prompt をTelegramに   │
│ # claude-tg  │   送信しました。新セッションで    │
│   ✓ Brewed.. │   そのまま使える形式で...         │
│              │                                  │
│ # General    │ ─────────────────────────────── │
│   (idle 2h)  │ ❯ [    Reply to #Plans       ]  │
└──────────────┴─────────────────────────────────┘

Legend:
 ● = unread / active recently
 ✓ = idle, last activity was claude completing
 (idle Nh) = stale, no activity in N hours
```

Rejected alternatives: grid/mosaic (text too small with 4+ topics; expensive to render N tmux captures simultaneously), tabs (hides activity in inactive tabs — directly contradicts the "see everything" goal).

## Non-goals

- Full terminal emulator. SwiftTerm / xterm.js / iTerm-embed are out of scope. We do NOT need Ctrl-C, Tab completion, mouse interaction with claude's TUI, or multi-pane.
- Replacing `cta attach`. The Terminal path stays for power users and debugging.
- Web-based watch (Pager is macOS-native; cross-host watch is roadmap F3).

## Layered architecture (binds to `multi-topic-stability-plan.md` principles)

```
                ┌────────────────────────────────────┐
       user →   │ Pager unified WatchLive window     │  SwiftUI, read-mostly
                │  sidebar (all topics) + main pane  │
                │  + optional input to focused topic │
                └─────────────────┬──────────────────┘
                                  │
                                  ↓ shells out
                ┌────────────────────────────────────┐
                │ cta watch <thread> [--follow]      │  display source
                │ cta send  <thread> <text>          │  input sink (focused)
                │ cta status --json                  │  liveness + mount list
                └────────────────────┬───────────────┘
                             │
                             ↓ owns
              ┌────────────────────────────────┐
              │ $STATE_DIR/topics/<id>.log     │  Phase B: streamed via pipe-pane
              │ tmux capture-pane              │  Phase A: polled directly
              │ inbound FIFO / send-keys       │  Phase C: input path
              └────────────────────────────────┘
                             ↑
                             │ writes
                ┌────────────────────────────┐
                │ topic-wrapper.sh           │  per-topic supervised claude
                └────────────────────────────┘
```

**Cross-plan dependency:** Phase C's input path depends on `multi-topic-stability-plan.md` P3.9 (per-topic inbound FIFO). If that ships first, input is just "write to FIFO." If not, input falls back to the existing tmux paste-buffer dispatch (with the D3 buffer-race risk). We can ship Phase A + B without Phase C if needed.

## Phases

### Phase A — Polled read-only display (MVP)

The smallest version that demonstrates value. Polls tmux capture-pane on a timer; SwiftUI text view; strip ANSI.

- [ ] **A.1 — Add `cta watch <thread>` command**

  Location: `cli/cta` (new `cmd_watch` function).

  Surface:
  ```
  cta watch <thread_id|dm> [--lines N] [--ansi]
  ```
  Output: tmux capture-pane snapshot of the topic's pane. Default `--lines 200`. Default strips ANSI (`tmux capture-pane -p`); `--ansi` preserves escapes (`-e`).

  Implementation:
  ```bash
  cmd_watch() {
    local thread_id="${1:-}" lines=200 keep_ansi=0
    # arg parse: --lines N, --ansi
    local mount_json tmux_session
    mount_json=$(bun run "$(_mount_store_path)" get "$thread_id") || exit 1
    [[ "$mount_json" == "null" ]] && { echo "no mount" >&2; exit 1; }
    tmux_session=$(echo "$mount_json" | jq -r '.tmux_session')
    tmux has-session -t "$tmux_session" 2>/dev/null || { echo "tmux session not alive" >&2; exit 2; }
    local capture_args=(-p -S "-$lines" -t "$tmux_session")
    [[ "$keep_ansi" == "1" ]] && capture_args=(-e "${capture_args[@]}")
    tmux capture-pane "${capture_args[@]}"
  }
  ```

  Exit codes: 0 = ok, 1 = no mount, 2 = tmux session dead.

  Test (`tests/test_cta_watch.sh` — new):
  - Pre-populate a mock topic with a fake tmux session emitting known text.
  - `cta watch <id>` returns expected text.
  - Missing mount → exit 1 + stderr.
  - Dead tmux → exit 2 + stderr.
  - `--lines 50` returns ≤50 lines.

- [ ] **A.2 — Pager unified WatchLive window**

  Location: `pager/WatchLiveWindowController.swift` (new file).

  Single window across all topics — sidebar lists every mount, main pane renders the selected topic.

  Window:
  - Title: `Pager — Watch live`, size 1000×600 (resizable, min 700×400).
  - Singleton: opening "Watch live" from the menu bar focuses the existing window if open, otherwise creates it.
  - Closes only when user explicitly closes it. Empty mounts list ≠ close (sidebar just shows a "no topics yet" placeholder).

  Sidebar (left, ~240pt):
  - One row per mount from `cta status --json` (P3.3 — see Cross-plan integration; for v1 read `mounts.json` directly).
  - Row content (top→bottom):
    - Topic label (`#IronFlow`, `#General`, `DM` for dm key).
    - Activity indicator: `●` (active, latest log line in last 60s), `✓` (idle but green), `(idle Nh)` (stale).
    - 1-line preview: last non-empty line from the topic log, truncated to fit (`⏺ git status..`).
  - Selection: clicking a row makes it the focused topic. Selection persists in memory until Pager quits; not persisted across restarts (E.3).
  - Default selection on open: most recently active topic.

  Main pane (right, flex):
  - Renders the selected topic's stream. Polled `cta watch <thread> --lines 500` every 500ms in Phase A; switches to streamed in Phase B.
  - SwiftUI `ScrollView` with `Text` in `SF Mono 12`.
  - Auto-scrolls to bottom unless the user has manually scrolled up (detect via `ScrollViewReader`).
  - Strips ANSI codes (basic regex `\x1B\[[0-9;]*[a-zA-Z]` — Phase D adds color rendering).
  - Header shows the focused topic name + status pill (A.3).
  - On focus change: cancel the previous topic's poll/stream, start the new one.

  Polling cost: sidebar previews need 1-line tail from each mount every ~2s. Cheap as long as Phase B (per-topic log files) is in place — then it's `tail -n 1` of a static file, not a `tmux capture-pane` per row. In Phase A the sidebar previews are derived from the same `cta watch <id> --lines 1` call piggy-backing on whatever polling is happening; refresh rate degraded to ~5s for sidebar to keep cost down.

  Wiring:
  - Existing menu bar "Watch live" submenu collapses to a single "Open Watch live window…" item (replaces the per-topic Terminal-launching items). Power users keep Terminal access via `cta attach <id>` from the shell.

  Test (Pager unit test):
  - Mock `cta watch` to return a fixed buffer; assert main pane renders.
  - Mock sidebar data (3 mounts); assert 3 rows + preview lines + correct activity indicators.
  - Click a sidebar row; assert main pane switches to that topic.
  - Mock `cta watch` error for selected topic; assert main pane shows "topic not running" state, not crash.
  - Mock mount removal: assert row disappears from sidebar; if it was selected, focus shifts to next active row.

- [ ] **A.3 — Status pill in main-pane header**

  Location: `WatchLiveWindowController.swift` main pane header (above the stream).

  Behavior:
  - Show a small status pill for the **selected** topic: `● Live` (green) when `cta status --json` reports the topic's tmux session alive, `● Dead` (red) when not, `● Restarting…` (yellow) when alive but `--lines 1` capture is empty (cold start).
  - Sidebar activity indicators (●/✓/idle) are a coarser real-time view; the pill is the authoritative liveness signal for the focused topic.

  Test:
  - Mock each status; assert pill renders correctly when each topic is focused.

**Gate A:** can open the unified window from Pager menu, sidebar lists all mounts with previews + activity dots, clicking a row swaps the main pane to that topic's stream, status pill reflects liveness. Manual sign-off acceptable for Phase A only.

### Phase B — Streamed display via per-topic log file

Polling tmux capture-pane every 500ms is wasteful (forks tmux, reads pane state, returns big buffer). Better: each topic-wrapper streams its pane to a per-topic file; Pager tails the file.

Side benefit: enables `cta logs <thread>` to return the topic's specific log (today `cta logs` shows the shared `agent.log` only).

- [ ] **B.1 — `topic-wrapper.sh`: pipe-pane to per-topic log**

  Location: `agent/topic-wrapper.sh` near the end of the spawn phase (after claude starts).

  Approach: in topic mode AND helper mode, after the tmux session is established, set up pipe-pane:
  ```bash
  local topic_log="$STATE_DIR/topics/$THREAD_ID.log"
  mkdir -p "$(dirname "$topic_log")"
  # Truncate on each spawn to bound size; rotate aged logs separately.
  : > "$topic_log"
  tmux pipe-pane -t "$tmux_session" -o "cat >> $topic_log" 2>/dev/null || true
  ```

  Open question: pipe-pane is normally invoked from outside the tmux session by the spawner. Verify topic-wrapper can do it for its own pane (likely yes — it controls the same tmux server).

  Log rotation: each respawn truncates. Long-running topics should not grow unbounded — add a simple size-based rotation later if needed (P3 for the watch-live plan, not P3 in stability plan).

  Test (`tests/test_topic_log_pipe.sh` — new):
  - Spawn a topic with a mock claude printing known text.
  - Assert `$STATE_DIR/topics/<id>.log` exists and contains the text.

- [ ] **B.2 — `cta watch --follow` mode**

  Location: `cli/cta` `cmd_watch`.

  Add `--follow` flag (or `-f` like tail). When set, after printing the snapshot, `tail -f` the per-topic log file:
  ```bash
  if [[ "$follow" == "1" ]]; then
    tail -n "$lines" -f "$topic_log"
    return
  fi
  ```
  Without `--follow`, behavior is the same as A.1 (one-shot capture). With `--follow`, output streams indefinitely; client closes the pipe to stop.

  Test:
  - `cta watch --follow <id>` in a sub-shell; write to log file; assert client receives the appended text within 200ms.

- [ ] **B.3 — Pager switches to streaming**

  Location: `WatchLiveWindowController.swift`.

  Change A.2's polled `cta watch` for the **focused** topic to a long-lived `cta watch --follow <id>` subprocess. Read stdout line-by-line, append to that topic's in-memory buffer. Cancel the subprocess when the user switches to a different topic (focus change → cancel old subprocess + start new) or when the window closes.

  Sidebar previews ALSO switch off polling: each row reads the last line of `$STATE_DIR/topics/<id>.log` directly (cheap `tail -n 1` via FileHandle, no subprocess). Refresh on log file mtime change via FSEvents.

  Bound the in-memory buffer per topic to last N=500 lines (drop oldest on push). Non-focused topics' buffers are NOT kept in memory — only the last preview line, fetched on-demand from the file. (Keeping all N topics' full buffers in memory would balloon Pager's RSS for high-traffic topics.)

  Test:
  - Mock `cta watch --follow` to emit lines on a timer; assert main pane appends in order.
  - Switch focus to another topic; assert the first subprocess receives SIGTERM and the new one starts.
  - Close window; assert all subprocesses exit.
  - Touch a non-focused topic's log file; assert that sidebar row's preview updates within 1s.

**Gate B:** Pager no longer polls. Stream is near-real-time. Topic log files are available via `cta watch --follow` from CLI too.

### Phase C — Optional message input

Read-only display is the bulk of the value. Input is a stretch goal — useful when the user wants to send a quick message without picking up their phone.

- [ ] **C.1 — `cta send <thread> <text>` command**

  Location: `cli/cta` (new `cmd_send`).

  Surface:
  ```
  cta send <thread_id|dm> <text...>
  ```
  Implementation:
  - If `multi-topic-stability-plan.md` P3.9 (FIFO inbound) has landed: write `text` + newline to `$STATE_DIR/inbound/<thread>.fifo`.
  - If not: shell out to the same tmux dispatch primitive the poller uses (`tmux load-buffer` + `paste-buffer`).

  Test (`tests/test_cta_send.sh` — new):
  - Pre-spawn a mock tmux session echoing stdin.
  - `cta send <id> hello`.
  - Assert mock received `hello\n`.

- [ ] **C.2 — Pager input field**

  Location: `WatchLiveWindowController.swift` bottom bar.

  Behavior:
  - TextField at the bottom of the window.
  - Cmd+Return submits → calls `cta send <thread> <text>` → clears the field.
  - Plain Return inserts a newline (multi-line input).
  - Status pill flashes green on successful send.

  Open question: should Pager show "(sent: <text>)" in the watch stream to confirm? Probably not — the stream already shows claude's response in due course. But for clarity, mirror sent text dimmed in the display.

  Test:
  - Type text + Cmd+Return; mock cta send; assert called with correct args.
  - On cta failure: show error toast.

**Gate C:** user can both watch and send from Pager without opening Telegram or Terminal.

### Phase D — ANSI color rendering (polish)

Today A.2 strips ANSI. claude's TUI uses colors for syntax highlighting, errors, etc. — losing them hurts readability.

- [ ] **D.1 — ANSI parser in Swift**

  Location: `pager/ANSIRenderer.swift` (new).

  Implement a minimal SGR (Select Graphic Rendition) parser. Map ANSI color codes to NSAttributedString attributes:
  - `\x1B[31m` → foreground red
  - `\x1B[1m` → bold
  - `\x1B[0m` → reset

  Coverage target: enough to render claude's TUI cleanly (8 colors, bold/italic, reset). 256-color and 24-bit color: optional Phase E.

  Reuse: there are MIT-licensed Swift packages for ANSI parsing (e.g., `ANSITerminal`). Evaluate before writing custom.

  Test:
  - Unit test: feed known ANSI strings; assert attributed string colors match.

- [ ] **D.2 — Wire into WatchLive display**

  Location: `WatchLiveWindowController.swift`.

  Use `cta watch --follow --ansi` (B.2 + A.1 flag) to preserve escapes; pipe through `ANSIRenderer`; render `NSAttributedString` in `TextView`.

  Test:
  - Render a known-color line from claude's TUI; assert colors visible.

**Gate D:** watch-live renders with claude TUI's colors faithfully.

### Phase E — Lifecycle integration

Make the window robust to topic respawn / unmount.

- [ ] **E.1 — Window survives topic respawn**

  Scenario: user has WatchLive open for topic 42. Operator runs `cta start` (kills + respawns all topics).

  Behavior expected:
  - Window detects tmux session disappeared (status pill → Red).
  - Window detects new tmux session for same thread_id (status pill → Yellow → Green).
  - Stream resumes from the new tmux session.

  Implementation: `cta watch --follow` on the wrapper side reads `$STATE_DIR/topics/<id>.log` which is per-thread, not per-tmux-session. The wrapper's pipe-pane is re-established on respawn, and `: > "$topic_log"` truncates. Tail-f reopens cleanly on truncate (use `tail -F`).

  Test:
  - Open watch window for topic 42.
  - Kill topic-42 tmux + respawn.
  - Assert window shows respawn boundary (e.g., a separator), then resumes.

- [ ] **E.2 — Sidebar row disappears on mount removal**

  Pager observes `cta status --json` (every 2s). When a mount is gone (umount, unpair):
  - That topic's row disappears from the sidebar.
  - If the removed topic was the focused one, the main pane briefly shows "Mount removed — switched to <next-active>", focus shifts to the most recently active remaining mount, stream restarts.
  - If no mounts remain, sidebar shows the empty-state placeholder; main pane shows "No topics paired yet — pair the bot from Telegram to begin."
  - The window itself does NOT auto-close. Closing is always explicit by the user.

  Test:
  - Open window with 3 mounts; focus #2.
  - `cta umount #2` → assert row disappears, focus shifts to a remaining row, no crash.
  - `cta umount` the other two → assert empty-state placeholder, window still open.

- [ ] **E.3 — Window persistence across Pager restarts**

  Open question: should re-opening Pager restore the watch window state?

  Two sub-questions now that the window is unified:
  1. Was the watch window open when Pager last quit? Reopen if yes.
  2. Which topic was selected? Restore selection if yes.

  Recommendation v1: **NO to (1), YES to (2)**. Don't auto-open the window — watch-live is an attention-focused activity. But if the user does open it, default-select their last-selected topic (falling back to most-recently-active if that mount is gone). Store as a single key in `~/.pager/pager-state.json` (Pager-only). This avoids "where am I?" friction without the boldness of auto-popping a window at login.

  If user demand for full restore surfaces later, add a `watch_window_open: bool` flag in the same state file.

## Test strategy

- A-phase: shell tests for `cta watch` + Pager unit tests with mocked cta.
- B-phase: shell tests for pipe-pane + `cta watch --follow`; Pager integration test with subprocess.
- C-phase: shell test for `cta send`; Pager unit test for input submission.
- D-phase: ANSI parser unit tests.
- E-phase: scenario tests (kill+respawn, umount).

All Pager tests run on the macOS CI runner (Pager's existing CI lane). Shell tests run alongside `tests/test_cta*.sh`.

## Risks and open questions

- **tmux `pipe-pane` from inside the wrapper:** does it work from a process running inside the same pane it's piping? Most likely yes (tmux pipe-pane is a tmux server call, not a pane-internal action), but verify in Task B.1 with a smoke test before relying on it.
- **`tail -F` behavior on truncation:** `tail -F` (capital F) follows by name and survives truncation / recreation. Verify on macOS specifically — `tail -f` (lowercase) does not.
- **ANSI parser scope creep:** claude TUI may use cursor positioning, screen clearing, alternative screen buffer. Phase D's parser must handle these gracefully (drop them, or render as-is) — don't try to emulate cursor positioning, that's terminal-emulator territory.
- **Helper mode visibility:** should helper-mode (provisional) mounts appear in the sidebar? Probably yes — the user benefits from seeing helper conversation progress while it's still mid-pairing. Treat provisional rows the same as regular rows for sidebar inclusion.
- **Provisional row display:** how does the sidebar distinguish a provisional row from a regular one? Suggest: prepend `(helper)` to the label, and use the yellow `● Helper (mid-conversation)` pill in the main pane when focused, to make the helper lifecycle observable.
- **Sidebar with many topics:** at 10+ active mounts the sidebar gets long. Out of scope for v1 (works fine with vertical scroll), but a future iteration may add grouping (`#chat-group / #IronFlow`) or pinning.

## Cross-plan integration

- **Depends on:** `multi-topic-stability-plan.md` P3.3 (`cta status --json` extension) for E.2 status polling. Without P3.3, fall back to direct file read of `mounts.json` for v1 of this plan (Principle 4 violation, accept temporarily, fix when P3.3 lands).
- **Benefits from:** `multi-topic-stability-plan.md` P3.9 (FIFO inbound) for C.1 — clean primitive for `cta send`. Without P3.9, C.1 uses the existing tmux dispatch (carries the D3 buffer-race risk for concurrent watch+poller writes; acceptable for low-volume manual sends).
- **Enables:** richer Pager surfaces (history panel, search across topic logs, etc.) — out of scope here but the per-topic log infrastructure (B.1) is the foundation.

## Self-review

- **Scope discipline:** each phase has a clear gate; can ship A alone, A+B alone, etc.
- **Layer purity:** Pager only ever shells `cta` commands — never `tmux` directly. Every tmux interaction is owned by cta/agent layer.
- **Test coverage:** every step has a test or explicit "manual sign-off acceptable" note (only Gate A allows manual).
- **Future robustness:** ANSI parsing isolated; per-topic logs are reusable beyond Pager (CLI, future web UI); single-window model scales to many topics without dock clutter; lifecycle integration ensures sidebar tracks real state.
- **Layout choice rationale:** sidebar + main pane was picked over per-topic windows / mosaic grid / tabs — see "Layout decision" in Context. Trade-off: only one topic in detail at a time, but sidebar previews give the at-a-glance overview that motivated the unified-window request.
- **What this plan does NOT do:** terminal emulation, cross-host streaming (F3), embedded web UI, auto-opening the window at Pager launch, multiple simultaneous detail panes. Each is a deliberate non-goal. (E.3 *does* persist the last-selected topic — a narrow exception explained there.)
