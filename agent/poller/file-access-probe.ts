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
import { readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

export interface FileAccessState {
  protected_ok: boolean;
  probed_path: string;
  checked_at: string;
}

/** Default TCC-protected canary. Listing ~/Documents requires Full Disk Access
 *  (or a Documents-folder grant) since macOS Catalina; a launchd process with
 *  neither gets EPERM. */
export function defaultProbedPath(): string {
  return join(homedir(), "Documents");
}

/** Pure classifier: run the probe via an injected reader and shape the result.
 *  Reader throws (EPERM etc.) → protected_ok:false; succeeds → true. */
export function probeFileAccess(probedPath: string, reader: (p: string) => void): FileAccessState {
  let ok = false;
  try {
    reader(probedPath);
    ok = true;
  } catch {
    ok = false;
  }
  return { protected_ok: ok, probed_path: probedPath, checked_at: new Date().toISOString() };
}

/** Run the real probe (readdir the protected canary) and write the result to
 *  $stateDir/file-access.json at 0600. Best-effort: swallows all errors and
 *  still returns the probed state. */
export function runFileAccessProbe(stateDir: string, probedPath: string = defaultProbedPath()): FileAccessState {
  const state = probeFileAccess(probedPath, (p) => { readdirSync(p); });
  try {
    mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    writeFileSync(join(stateDir, "file-access.json"), JSON.stringify(state, null, 2) + "\n", { mode: 0o600 });
  } catch {
    // Writing the status file is non-critical; leave the prior file in place.
  }
  return state;
}
