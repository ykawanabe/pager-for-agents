#!/bin/bash
# Wrapper that delegates to `bun test` for services/poller/poller.test.ts.
# Lives here so run.sh picks it up alongside the other test_*.sh files.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR/services/poller"
bun test
