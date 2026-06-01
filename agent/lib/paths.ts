/**
 * paths.ts — single resolver for state + install directories.
 *
 * Two scopes:
 *   STATE_DIR   — user data: paired.json, mounts.json, .env, sessions/,
 *                 typing/, heartbeat-poller, topics.json.
 *                 Default: $HOME/.pager
 *                 Legacy default: $HOME/.claude-telegram-agent (pre-rename)
 *
 *   INSTALL_DIR — runtime modules deployed by install.sh: agent/, hooks/,
 *                 bot-hooks.json.
 *                 Default: $HOME/.local/share/pager
 *                 Legacy default: $HOME/.local/share/claude-telegram-agent
 *
 * Both honor env overrides for tests and operator customization:
 *   CTA_STATE_DIR
 *   CTA_INSTALL_DIR
 *
 * This module is path-resolution only — it does NOT touch the filesystem.
 * Migration logic (move/copy/symlink) lives in `cta migrate-state`.
 */
import { homedir } from "node:os";
import { join } from "node:path";

/** State directory: user-mutable runtime data. */
export function stateDir(): string {
  return process.env.CTA_STATE_DIR ?? join(homedir(), ".pager");
}

/**
 * Legacy state directory used by v0.1 installs (pre-rename). The migration
 * command reads from here; new code should never reference this directly.
 */
export function legacyStateDir(): string {
  return join(homedir(), ".claude-telegram-agent");
}

/** Install directory: runtime modules deployed by install.sh. */
export function installDir(): string {
  return process.env.CTA_INSTALL_DIR ?? join(homedir(), ".local/share/pager");
}

/** Legacy install directory used by v0.1 installs (pre-rename). */
export function legacyInstallDir(): string {
  return join(homedir(), ".local/share/claude-telegram-agent");
}

// ─── State files ──────────────────────────────────────────────────────────────

export function envFile(): string { return join(stateDir(), ".env"); }
export function pairedStateFile(): string { return join(stateDir(), "paired.json"); }
export function pairingCodeFile(): string { return join(stateDir(), "pairing-code"); }
export function mountsJson(): string { return join(stateDir(), "mounts.json"); }
export function topicsJson(): string { return join(stateDir(), "topics.json"); }
export function pollerOffsetFile(): string { return join(stateDir(), "poller-offset"); }
export function heartbeatFile(): string { return join(stateDir(), "heartbeat-poller"); }
/** Wake-event flag. Pager (NSWorkspace.didWakeNotification) touches this on
 *  macOS system wake; the poller's housekeep observes it and aborts the
 *  current getUpdates so a stale-after-sleep socket can't burn the full
 *  long-poll budget before the next fetch refreshes. */
export function wakeFlagFile(): string { return join(stateDir(), "wake.flag"); }
export function caffeinatePidFile(): string { return join(stateDir(), "caffeinate.pid"); }
export function sessionsDir(): string { return join(stateDir(), "sessions"); }
export function typingDir(): string { return join(stateDir(), "typing"); }
export function agentLog(): string { return join(stateDir(), "agent.log"); }
export function agentErrLog(): string { return join(stateDir(), "agent.err.log"); }
export function fileAccessJson(): string { return join(stateDir(), "file-access.json"); }
export function sharedContextMd(): string { return join(stateDir(), "shared-context.md"); }
export function settingsJson(): string { return join(stateDir(), "settings.json"); }

// ─── Install paths ────────────────────────────────────────────────────────────

export function installAgentDir(): string { return join(installDir(), "agent"); }
export function installHooksDir(): string { return join(installDir(), "hooks"); }
export function botHooksJson(): string { return join(installDir(), "bot-hooks.json"); }

export function installPollerTs(): string { return join(installAgentDir(), "poller/poller.ts"); }
export function installMcpServerTs(): string { return join(installAgentDir(), "mcp-telegram/server.ts"); }
export function installTopicWrapperSh(): string { return join(installAgentDir(), "topic-wrapper.sh"); }
export function installMountStoreTs(): string { return join(installAgentDir(), "mount-store/mount-store.ts"); }
