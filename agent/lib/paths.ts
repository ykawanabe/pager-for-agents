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

// ─── H2 daily digest heartbeat (Design A) ────────────────────────────────────
// Per-thread session UUIDs let the heartbeat-runner --resume yesterday's claude
// session so day N+1 sees day N's findings (avoids re-flagging the same item).
// Lives in its own subtree so a `cta digest reset` can wipe it without
// touching anything else.
export function heartbeatSessionsDir(): string { return join(stateDir(), "heartbeat-sessions"); }
export function heartbeatSessionFile(threadId: string | "dm"): string {
  return join(heartbeatSessionsDir(), `${threadId}`);
}
/** Per-fire append-only JSONL log of digest runs (cost, duration, result,
 *  per-check status). `cta digest log <thread>` tails this. */
export function heartbeatLogDir(): string { return join(stateDir(), "heartbeat-log"); }
export function heartbeatLogFile(threadId: string | "dm"): string {
  return join(heartbeatLogDir(), `${threadId}.jsonl`);
}
/** Scheduler state: `{ version: 1, firedToday: { "<thread>:<YYYY-MM-DD>": <epoch_ms>, ... } }`.
 *  Atomic-rename written; persisted BEFORE the runner spawns so a crash
 *  during fire() doesn't cause a same-day retry. */
export function heartbeatStateFile(): string { return join(stateDir(), "heartbeat-state.json"); }
export function caffeinatePidFile(): string { return join(stateDir(), "caffeinate.pid"); }

// ─── Scheduled tasks (proactive task scheduling) ─────────────────────────────
/** Task definitions: `{ version: 1, tasks: [{ name, time, days, checklist|prompt,
 *  topic, model?, effort?, enabled }] }`. Written by tasks-store (bun, locked,
 *  atomic); hot-reloaded by the poller on mtime change. */
export function tasksJson(): string { return join(stateDir(), "tasks.json"); }
/** Run-now flag dir: `cta task run <name>` touches `<name>` here; the poller's
 *  housekeep consumes (unlink-before-fire) on the next tick. */
export function taskRunDir(): string { return join(stateDir(), "task-run"); }
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
