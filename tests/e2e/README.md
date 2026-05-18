# E2E Scenarios

Agent-runnable end-to-end scenarios that exercise the real poller process
through a mocked Telegram Bot API. See `docs/plans/e2e-test-harness.md` for
the broader design.

## Running

```bash
# All scenarios
bash tests/e2e/run.sh

# A single scenario (with or without .sh)
bash tests/e2e/run.sh clear_real_mount
```

Each scenario:
- Sandboxes its own `$STATE_DIR` and `$INSTALL_DIR` under `/tmp`.
- Spawns the mock Bot API on a free port.
- Spawns the real `agent/poller/poller.ts` pointed at the mock.
- Uses a private tmux socket so the user's real tmux server is untouched.
- Tears down everything on exit (signal-safe).

## Anatomy of a scenario

```bash
#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/harness.sh"

h_setup_sandbox "scenario-name"   # tmp dirs, .env files
h_spawn_mock                       # mock-bot-api on a random port
h_seed_paired                      # paired.json
h_seed_mount 42 /tmp/proj "label"  # mounts.json row
h_spawn_poller                     # the real poller

h_inject_text 42 "/clear" 99       # POST to /__test__/inject

h_wait_for_capture sendMessage \
  '[.[] | select(.body.text|test("Cleared"))] | length >= 1' 10 \
  && h_ok "ack received" || h_ng "no ack"

echo "scenario: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
```

Auto-teardown is wired via `trap` in `lib/harness.sh`.

## Library API (lib/harness.sh)

| Function | Purpose |
|---|---|
| `h_setup_sandbox <name>` | Create `$SCENARIO_DIR`, set `$CTA_STATE_DIR`, `$CTA_INSTALL_DIR`, copy agent sources, write fake .envs |
| `h_spawn_mock` | Start `mock-bot-api.ts`, wait until `getMe` responds, set `$TELEGRAM_API_BASE` |
| `h_seed_paired [chat_id] [user_id]` | Write `paired.json` directly |
| `h_seed_mount <thread_id> <path> [label] [provisional]` | Add a row via mount-store CLI |
| `h_seed_session_uuid <thread_id> <uuid>` | Write `$STATE_DIR/sessions/<thread_id>` |
| `h_spawn_poller` | Start the real poller in a tmux session on the private socket |
| `h_inject_text <thread_id> <text> [from_id] [chat_id]` | POST a TG Update to `/__test__/inject` |
| `h_wait_for_capture <method> <jq-pred> [timeout]` | Poll `/__test__/captured?method=…` until match or timeout |
| `h_assert_jq <file> <jq-pred> <desc>` | Assert a JSON state file matches a predicate |
| `h_assert_file_grep <file> <regex> <desc>` | Assert a non-JSON file matches a regex |
| `h_dump_captures` | Print captures + poller pane + mount state (for failure diagnosis) |
| `h_teardown` | Auto-runs on EXIT; manual call only for explicit cleanup |

## Mock test endpoints

The mock at `http://localhost:$MOCK_PORT` exposes:

- `POST /__test__/inject` — body is a TG Update JSON. Queued for the next `getUpdates` request.
- `POST /__test__/reset` — clear queue + capture file.
- `GET /__test__/captured?method=sendMessage` — JSON `{ok, count, items}` with all matching recorded calls.

## Adding a scenario

1. Copy an existing scenario file (`clear_real_mount.sh` is the minimal template).
2. Replace seeds and injections with your scenario's setup + inputs.
3. Replace assertions with what you want to verify.
4. Run `bash tests/e2e/run.sh <your_name>`.

If you find a missing primitive in `lib/harness.sh`, add it there with a one-line comment explaining when to use it.

## Prerequisites

`bun`, `tmux`, `curl`, `jq`. The runner errors out if any are missing.

Some scenarios require real `claude` headless and are marked `# REQUIRES_CLAUDE` near the top — they're skipped automatically when `claude` isn't on PATH.

## Known limitations (v1)

- Helper-mode scenarios (anything that spawns real `claude` in helper mode) take 5–15s for cold start. Mark them slow; consider stubbing claude for breadth.
- `tmux pipe-pane` to a per-topic log isn't wired in v1 — `h_dump_captures` reads `tmux capture-pane` instead. Once `pager-watch-live.md` ships Phase B, scenarios can subscribe to the streamed log.
- One scenario at a time per host: scenarios share the user's free-port pool, but the harness picks a random port to reduce conflicts.
