#!/bin/bash
# Build Claude Pager (release config), wrap into an .app bundle with a stable
# bundle identifier, ad-hoc sign it, and register a LaunchAgent that runs the
# bundle at login.
#
# Why the .app bundle + ad-hoc signing: macOS attaches "permission grants"
# (network, Apple Events, automation, etc.) to the (bundle id, signed identity)
# pair. A raw binary recompiled from scratch each time gets a fresh identity,
# so the OS re-prompts on every rebuild. A bundle ID with an ad-hoc signature
# is stable across rebuilds, so prompts survive.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$HOME/Applications"
APP_BUNDLE="$APPS_DIR/Claude Pager.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.claude-pager"
PLIST_PATH="$LAUNCH_AGENTS_DIR/${PLIST_LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/claude-pager"
BUNDLE_ID="com.claude-pager"

say() { printf "→ %s\n" "$*"; }

command -v swift >/dev/null || { echo "swift not found"; exit 1; }

say "Building Claude Pager (release)"
cd "$REPO_DIR"
swift build -c release

# ---- Wrap binary into a .app bundle -----------------------------------------
say "Assembling app bundle at $APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

# Copy the app icon. AppIcon.icns lives at pager/Resources/ in the repo;
# Info.plist's CFBundleIconFile (set below) references it by base name.
# Without this, Finder/Spotlight/About use the generic placeholder icon.
if [[ -f "$REPO_DIR/Resources/AppIcon.icns" ]]; then
    cp "$REPO_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    say "Copied AppIcon.icns into bundle"
else
    say "AppIcon.icns missing — bundle will use the macOS default icon"
fi

# Replace the binary while the old one may still be running.
#
# Why no `launchctl unload` here: the previous version of this script called
# unload right before doing the cp. That forced the `launchctl print` check
# below to always fall into the `load` branch (because we'd just unloaded),
# which triggers macOS's "is now running in the background" notification on
# every install — exactly the "毎回 load 走ってる" problem we're solving.
#
# Why this rm+cp is safe even with the old binary running: macOS keeps the
# mmapped binary alive via its old inode as long as the process is running.
# `rm` only removes the directory entry, not the inode. `cp` then writes a
# fresh file at the path. The running process keeps executing from the old
# inode until kickstart -k kills it; the respawn picks up the new inode.
rm -f "$APP_BUNDLE/Contents/MacOS/ClaudePager"
cp ".build/release/ClaudePager" "$APP_BUNDLE/Contents/MacOS/ClaudePager"
chmod +x "$APP_BUNDLE/Contents/MacOS/ClaudePager"

# P6d: tmux is no longer bundled. The agent runtime no longer uses tmux
# (poller/watchdog go launchd-direct in P6c; watch-live reads JSONL +
# agent.log), so there's nothing for the FDA-inheritance trick to cover.
# Remove any stale bundled copy left by a prior install.
rm -f "$APP_BUNDLE/Contents/MacOS/tmux" 2>/dev/null || true

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudePager</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Claude Pager</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Pager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
EOF

# Ad-hoc sign with a stable identity. `-` = ad-hoc; --force replaces previous
# signature; the bundle id in Info.plist provides the stable identity macOS
# uses to remember permission grants.
say "Ad-hoc signing $APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"

# ---- LaunchAgent ------------------------------------------------------------
mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${APP_BUNDLE}/Contents/MacOS/ClaudePager</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <!-- Respawn only on unsuccessful exit (crash). A clean Quit from the
         menu (NSApp.terminate → exit 0) is treated as intentional and the
         agent stays dead until the next login. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/pager.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/pager.err.log</string>
</dict>
</plist>
EOF

# Re-register only on first install — every subsequent reinstall just
# restarts the same service in-place via `kickstart`. Otherwise macOS shows
# its "[app] is now running in the background" notification on every reload,
# because `launchctl unload && load` looks like a fresh service registration
# for an LSUIElement app and the notification fires once per registration.
#
# Use `launchctl print` rather than the deprecated `launchctl list | grep`:
# `print` exits 0 only if the service is loaded in this domain.
LAUNCHCTL_TARGET="gui/$(id -u)/${PLIST_LABEL}"
if launchctl print "$LAUNCHCTL_TARGET" >/dev/null 2>&1; then
    # `-k` kills the running instance; launchd then respawns it (KeepAlive
    # is conditional on SuccessfulExit=false, but kickstart re-launches
    # regardless). Picks up the new binary inside the .app bundle.
    launchctl kickstart -k "$LAUNCHCTL_TARGET" >/dev/null 2>&1 || true
    say "Restarted LaunchAgent $PLIST_LABEL in-place (no re-registration)"
else
    launchctl load "$PLIST_PATH"
    say "Loaded LaunchAgent $PLIST_LABEL"
fi

# Reap orphan instances: any ClaudePager process that's NOT the one
# launchctl just spawned. Older versions of this script used
# `launchctl unload` to stop the running process before overwrite — that
# detached the running instance from launchctl's bookkeeping, so a
# subsequent `kickstart` only restarted the new bookkeeping while the old
# orphan kept running. Result: two Pager menu bar icons. The fix below
# catches anyone still surviving from that legacy path. After the
# install.sh migration is complete on this machine, this block becomes a
# no-op (nothing left to reap).
sleep 1  # give launchctl a moment to settle its respawn
TRACKED_PID=$(launchctl print "$LAUNCHCTL_TARGET" 2>/dev/null | awk '/^\s*pid =/ {print $3; exit}')
if [[ -n "$TRACKED_PID" ]]; then
    pgrep -f "Claude Pager.app/Contents/MacOS/ClaudePager" 2>/dev/null | while read -r pid; do
        # Skip the agent-launcher: start_agents.sh runs THIS binary as
        # `ClaudePager --agent-launcher <poller>` to supervise the bot under
        # com.claude-agent (the FDA-inheritance trick). It shares the bundle
        # binary path but is a different service — reaping it SIGTERMs the
        # poller, which exits 0 cleanly, and com.claude-agent's
        # KeepAlive(SuccessfulExit=false) then would NOT respawn it: the bot
        # would silently stay down until the next login or `cta start`.
        if ps -o args= -p "$pid" 2>/dev/null | grep -q -- '--agent-launcher'; then
            continue
        fi
        if [[ "$pid" != "$TRACKED_PID" ]]; then
            kill "$pid" 2>/dev/null && say "Reaped orphan Pager pid=$pid (launchctl-tracked is $TRACKED_PID)"
        fi
    done
fi

# ---- Migrate legacy install (raw binary at ~/.local/bin/claude-pager) -------
if [[ -f "$HOME/.local/bin/claude-pager" ]]; then
    rm -f "$HOME/.local/bin/claude-pager"
    say "Removed legacy raw-binary install at ~/.local/bin/claude-pager"
fi

cat <<EOF

✓ Installed at $APP_BUNDLE.

Logs:  $LOG_DIR/pager.log
Plist: $PLIST_PATH

To stop:     launchctl unload $PLIST_PATH
To restart:  launchctl unload $PLIST_PATH && launchctl load $PLIST_PATH
To upgrade:  re-run ./install.sh (rebuilds, re-signs, reloads agent)
EOF
