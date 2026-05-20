#!/bin/bash
# Wrapper that delegates to `bun test` for agent/channels/**/*.test.ts
# (the ChatTransport layer — types, the Telegram adapter + transport).
# Lives here so run.sh picks it up alongside the other test_*.sh files.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR/agent/channels"
bun test
