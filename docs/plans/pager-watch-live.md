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

Goal: a native Pager window that shows the live state of a topic's claude session, with optional message input.

## Non-goals

- Full terminal emulator. SwiftTerm / xterm.js / iTerm-embed are out of scope. We do NOT need Ctrl-C, Tab completion, mouse interaction with claude's TUI, or multi-pane.
- Replacing `cta attach`. The Terminal path stays for power users and debugging.
- Web-based watch (Pager is macOS-native; cross-host watch is roadmap F3).

## Layered architecture (binds to `multi-topic-stability-plan.md` principles)

```
                ┌───────────────────────────┐
       user →   │ Pager WatchLive Window    │  SwiftUI, read-mostly
                │ (display + optional input)│
                └────────────┬──────────────┘
                             │
                             ↓ shells out
                ┌───────────────────────────┐
                │ cta watch <thread>        │  display source
                │ cta send  <thread> <text> │  input sink
                │ cta status --json         │  liveness
                └────────────┬──────────────┘
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

- [ ] **A.2 — Pager WatchLive window controller (one window per topic)**

  Location: `pager/WatchLiveWindowController.swift` (new file).

  Behavior:
  - Opens a window titled `Watch: <topic_name>` sized 800×500 (resizable).
  - Polls `cta watch <thread> --lines 500` every 500 ms.
  - Renders in a SwiftUI `ScrollView` with `Text` in monospaced font (e.g., `SF Mono 12`).
  - Auto-scrolls to bottom unless the user has manually scrolled up (detect via `ScrollViewReader`).
  - Strips ANSI codes (basic regex `\x1B\[[0-9;]*[a-zA-Z]` — Phase D adds color rendering).

  Lifecycle:
  - One window per `thread_id`. If user clicks "Watch live" for a topic already open, focus the existing window.
  - Window closes when user closes it OR when the topic's mount is removed (observe via `cta status --json` polled every 2s).

  Wiring:
  - Add a "Watch live in Pager" menu item under each mount in the existing menu bar `WatchLiveSubmenu`, alongside the existing "Open in Terminal" item.

  Test (Pager unit test):
  - Mock `cta watch` to return a fixed buffer; assert window renders.
  - Mock `cta watch` to error; assert window shows "topic not running" state, not crash.
  - Mock status change (mount removed); assert window auto-closes.

- [ ] **A.3 — Status indicator in window header**

  Location: `WatchLiveWindowController.swift` header bar.

  Behavior:
  - Show a small status pill: `● Live` (green) when `cta status --json` reports the topic's tmux session alive, `● Dead` (red) when not, `● Restarting…` (yellow) when alive but `--lines 1` capture is empty (cold start).

  Test:
  - Mock each status; assert pill renders correctly.

**Gate A:** can open a window from Pager menu, see claude's TUI output update every 500ms, status pill reflects liveness. Manual sign-off acceptable for Phase A only.

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

  Change A.2's polled `cta watch` call to a long-lived `cta watch --follow <id>` subprocess. Read stdout line-by-line, append to the text buffer. Cancel the subprocess when the window closes.

  Bound the in-memory buffer to last N=500 lines (drop oldest on push).

  Test:
  - Mock `cta watch --follow` to emit lines on a timer; assert window appends in order.
  - Close window; assert subprocess receives SIGTERM and exits.

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

- [ ] **E.2 — Window auto-closes on mount removal**

  Already in A.2 but verify the path: Pager observes `cta status --json` (every 2s). When the watched mount is gone (umount, unpair), window shows a brief "Mount removed" message and auto-closes after 5s.

  Test:
  - Open watch window.
  - Run `cta umount <id>`.
  - Assert window closes within 7s.

- [ ] **E.3 — Window persistence across Pager restarts**

  Open question: should re-opening Pager restore previously-open watch windows?

  Recommendation: NO for v1. Each Pager launch starts with no watch windows. Reasoning: watch is an attention-focused activity ("what's happening NOW") — automatic re-open after restart implies persistence the user may not intend.

  If user demand surfaces, add a `~/.pager/pager-state.json` Pager-only state file with last-open-window thread_ids. Out of scope for v1.

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
- **Helper mode visibility:** should helper-mode topics appear in the watch menu? Probably yes — the user benefits from seeing helper conversation progress. Treat helper mounts the same as topic mounts for watch purposes.
- **Provisional row display:** the status pill for a provisional row says what? Suggest: `● Helper (mid-conversation)` distinct color, to make the helper lifecycle observable.

## Cross-plan integration

- **Depends on:** `multi-topic-stability-plan.md` P3.3 (`cta status --json` extension) for E.2 status polling. Without P3.3, fall back to direct file read of `mounts.json` for v1 of this plan (Principle 4 violation, accept temporarily, fix when P3.3 lands).
- **Benefits from:** `multi-topic-stability-plan.md` P3.9 (FIFO inbound) for C.1 — clean primitive for `cta send`. Without P3.9, C.1 uses the existing tmux dispatch (carries the D3 buffer-race risk for concurrent watch+poller writes; acceptable for low-volume manual sends).
- **Enables:** richer Pager surfaces (history panel, search across topic logs, etc.) — out of scope here but the per-topic log infrastructure (B.1) is the foundation.

## Self-review

- **Scope discipline:** each phase has a clear gate; can ship A alone, A+B alone, etc.
- **Layer purity:** Pager only ever shells `cta` commands — never `tmux` directly. Every tmux interaction is owned by cta/agent layer.
- **Test coverage:** every step has a test or explicit "manual sign-off acceptable" note (only Gate A allows manual).
- **Future robustness:** ANSI parsing isolated; per-topic logs are reusable beyond Pager (CLI, future web UI); lifecycle integration ensures windows track real state.
- **What this plan does NOT do:** terminal emulation, cross-host streaming (F3), embedded web UI, persistent window state. Each is a deliberate non-goal.
