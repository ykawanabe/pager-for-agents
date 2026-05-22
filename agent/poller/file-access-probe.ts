/**
 * File-access (Full Disk Access) self-probe.
 *
 * P6c made the agent launchd-direct (no tmux). Its file-accessing processes
 * (`bun` poller, `claude` daemons) run under `com.claude-agent`, NOT as children
 * of Pager.app, so they don't inherit Pager's TCC grants. They can read the
 * user's normal dirs (~/ghq, ~/projects) but silently hit EPERM in TCC-protected
 * dirs (Documents/Desktop/Downloads/iCloud) — and a launchd background process
 * can't show a TCC prompt.
 *
 * Because this runs INSIDE the poller (the real launchd TCC context), it's the
 * only place that can truthfully answer "can the agent read protected folders?"
 * The result is written to $STATE_DIR/file-access.json for `cta status` / Pager
 * to surface. Never throws — a probe failure must not take the poller down.
 */
import { openSync, closeSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

export interface FileAccessState {
  /** True iff ALL probed protected folders are readable. False if any is
   *  blocked — that's the prompt-prone state where macOS keeps asking. */
  protected_ok: boolean;
  /** Per-folder result so the UI can name what's still blocked. */
  probed: { path: string; ok: boolean }[];
  checked_at: string;
}

/** Full-Disk-Access canary: the user TCC database. Opening it for read requires
 *  Full Disk Access specifically — a per-folder grant (Documents/Desktop/…) does
 *  NOT satisfy it. That's the right signal here: per-folder grants left the
 *  agent's `bun` still getting prompted (it hits protected spots beyond those
 *  folders, and prompt-grants for a bare CLI binary don't reliably persist), so
 *  "can the agent read an FDA-only resource?" == "does it have Full Disk Access?"
 *  == "will it stop prompting?" The fix for ✗ is one FDA grant to bun. */
export function fdaCanaryPath(): string {
  return join(homedir(), "Library", "Application Support", "com.apple.TCC", "TCC.db");
}

/** Pure classifier: probe each path via an injected reader. A reader that
 *  throws (EPERM etc.) marks that path not-ok; protected_ok is true only when
 *  every path is readable. */
export function probeFileAccess(paths: string[], reader: (p: string) => void): FileAccessState {
  const probed = paths.map((path) => {
    let ok = false;
    try { reader(path); ok = true; } catch { ok = false; }
    return { path, ok };
  });
  return {
    protected_ok: probed.length > 0 && probed.every((p) => p.ok),
    probed,
    checked_at: new Date().toISOString(),
  };
}

/** Run the real probe (open the FDA-only canary for read) and write the result
 *  to $stateDir/file-access.json at 0600. Best-effort: swallows all errors and
 *  still returns the probed state. */
export function runFileAccessProbe(stateDir: string, paths: string[] = [fdaCanaryPath()]): FileAccessState {
  const state = probeFileAccess(paths, (p) => {
    // Open for read: EPERM without Full Disk Access, succeeds with it.
    const fd = openSync(p, "r");
    closeSync(fd);
  });
  try {
    mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    writeFileSync(join(stateDir, "file-access.json"), JSON.stringify(state, null, 2) + "\n", { mode: 0o600 });
  } catch {
    // Writing the status file is non-critical; leave the prior file in place.
  }
  return state;
}
