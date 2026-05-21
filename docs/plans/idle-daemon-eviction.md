# Idle daemon eviction (opt-in RAM reclaim)

## Goal
Each per-topic claude daemon is a long-lived child process of the poller holding its
own context window in RAM. On a RAM-tight host, idle topics waste memory. Add an
**opt-in** policy: evict a daemon idle ≥ N minutes to reclaim its RAM. Default OFF,
operated from Pager, and toggling needs **no poller restart**.

## Key decisions
- **Eviction = automatic `/restart`.** Reuse `ClaudeDaemonRegistry.resetTopic()`
  (SIGTERM, 5s→SIGKILL, drop handle — `claude-daemon-registry.ts:214-229`,
  `claude-daemon.ts:166-199`). It does NOT rotate the session UUID (that is
  `/clear`'s job in `handleClear`), so the next inbound message lazy-respawns and
  `--resume`s the same conversation — cold-start (~5–15s), **no context loss**.
- **Sweep, not per-daemon self-exit.** A poller-loop-global sweep owns the policy;
  daemons don't evict themselves. Runs each poll iteration (≤ `POLL_TIMEOUT_SEC`=25s
  cadence) at `poller.ts:1934`, beside `refreshPairedIfChanged()`.
- **Storage = `~/.pager/settings.json`** (new, live-reloaded). snake_case to match the
  other STATE_DIR JSONs: `{ "version": 1, "idle_evict_minutes": 30 }`. `0`/absent = OFF.
- **App writes via `cta config idle-evict <min>`**, NOT a direct file write — STATE_DIR
  is `cta`-owned; Pager mutates it through `cta` (same as mounts/caffeinate). Pager
  *reads* `settings.json` directly for display (same idiom as `paired.json`).
- **Live-reload, no restart.** Poller mtime-gates `settings.json` exactly like
  `refreshPairedIfChanged()` (`poller.ts:188-206`); a Pager toggle is honored on the
  next sweep.
- **Safety.** Only `state==="idle"`, empty queue, alive daemon, past threshold are
  evicted. `inFlight`/`pending`/`released`/`crashed` are never touched → no race with a
  live turn or a β-handoff. Graceful SIGTERM → clean session-lock release.

## Changes
1. **`agent/lib/paths.ts`** — add `settingsJson()` (after `sharedContextMd()`, L62).
2. **`agent/poller/claude-daemon-registry.ts`**
   - `DaemonHandle`: add `lastActivityAt: number` (L70).
   - Stamp it on handle-init + every `enqueue` (L120-135) and on turn-end→idle (L376).
   - New `sweepIdle(idleMs): Promise<string[]>` (after `shutdown()`, L249): collect
     idle/quiescent handles past threshold, `resetTopic()` each, return evicted ids.
     No-op when `idleMs <= 0`.
3. **`agent/poller/poller.ts`**
   - `SETTINGS_FILE` const + module caches `idleEvictMinutes` / `settingsMtimeMs` (~L185).
   - `refreshSettingsIfChanged()` mirroring `refreshPairedIfChanged()` (after L206).
   - Call at startup (L1923) + each loop (L1934); when `idleEvictMinutes>0`,
     `await daemonRegistry.sweepIdle(idleEvictMinutes*60_000)` + log evictions.
4. **`cli/cta`** — `SETTINGS_FILE` const (L57-62); `idle-evict` case in `cmd_config`
   (L398) + usage strings; `_config_idle_evict <min|"">` (no arg prints current;
   validates non-neg int; python3-writes settings.json + chmod 600; "no restart"
   message). Mirrors `_config_ack` (L413).
5. **`pager/Sources/ClaudePager/CTAClient.swift`** — `setIdleEvict(minutes:)` (mirror
   `setCaffeinate`, L184) + `idleEvictMinutes() -> Int` reading settings.json directly
   (mirror `pairedState`, L355) + a `SettingsJSON` Codable.
6. **`pager/Sources/ClaudePager/SettingsView.swift`** — new "Memory" section in
   **PagerTab** (Mac-app tab, next to Sleep prevention): toggle + minutes picker →
   `CTAClient.setIdleEvict` off-main; load current onAppear; footer explains RAM
   reclaim + cold-start-on-return + auto-resume (no context loss).

## Tests
- `claude-daemon-registry.test.ts`: evict-after-threshold; no-evict-before-threshold;
  disabled when `idleMs<=0`; respawn-after-evict (`spawnedCount`++). (fake-claude
  fixture + `waitFor`.)
- `tests/test_cta.sh` (or focused): `cta config idle-evict 30 / 0 / <none> / abc`
  → settings.json content / current print / reject.
- `swift build` compile-check for Pager.

## Out of scope (YAGNI)
System-RAM-pressure eviction, LRU count caps, per-topic thresholds.
