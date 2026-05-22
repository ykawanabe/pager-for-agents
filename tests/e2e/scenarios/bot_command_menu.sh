#!/bin/bash
# E2E scenario: the poller publishes the "/" command menu on boot.
#
# Validates that registerBotCommands() calls setMyCommands once at startup with
# a non-empty command list including the key operational commands (/stop, /help,
# /clear). This is what makes Telegram show the autocomplete menu when you type /.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: bot_command_menu"
h_setup_sandbox "bot-command-menu"
h_spawn_mock
h_seed_paired -1001234 99
h_spawn_poller

# The poller calls setMyCommands once during boot (after the getMe preflight).
if h_wait_for_capture setMyCommands \
   '[.[] | select(.body.commands | length > 0)] | length >= 1' 10; then
  h_ok "setMyCommands called on boot with a non-empty command list"
else
  h_ng "did NOT capture a setMyCommands call within 10s"
  h_dump_captures
fi

# The menu must include the headline commands.
for cmd in stop help clear; do
  if h_wait_for_capture setMyCommands \
     "[.[] | select(.body.commands[]?.command == \"$cmd\")] | length >= 1" 5; then
    h_ok "command menu includes /$cmd"
  else
    h_ng "command menu missing /$cmd"
  fi
done

echo
echo "scenario bot_command_menu: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
