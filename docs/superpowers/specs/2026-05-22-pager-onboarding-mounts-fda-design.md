# Pager Settings/Onboarding: Mounts clarity + File-Access (FDA) onboarding

Date: 2026-05-22
Status: approved direction; pending spec review
Scope: Pager macOS app (`pager/`). No agent runtime changes except a small poller
self-probe + a `cta status` additive field. Sits on top of the P6c launchd-direct
runtime (no tmux).

Two related Settings/onboarding improvements, bundled because both are about making
the first-run + Settings experience legible:

- **Part A — Mounts → "Projects" redesign.** The Mounts tab is jargon-heavy, the
  goal isn't legible, some topics can't be picked, and it feels unstable.
- **Part B — File-access (Full Disk Access) onboarding.** Proactively guide the
  user to grant the launchd-direct agent file access so claude can work in
  TCC-protected folders (Documents/Desktop/Downloads/iCloud), not just `~/ghq` etc.

---

## Part A — Mounts → "Projects"

### Problem (from user)
1. Jargon up front: "mount", "thread_id", `*`, `dm`.
2. No sense of *what you're configuring* or the end goal.
3. Some topics can't be selected in the picker.
4. Feels unstable.

### Mental model to surface
A "mount" is just: **"messages in this Telegram topic are worked on in this Mac
folder."** The whole tab should read as a list of **`Topic → Folder`** bindings.

### Design

**1. Rename + reframe.**
- Tab title "Mounts" → "Projects" (`folder.badge.gearshape` icon kept).
- One plain-language header sentence at the top of the tab:
  「Telegram の各トピックを、Mac のどのフォルダで作業させるか割り当てます。」
- Each current-mount row renders as `<topic label>  →  <folder>` with an explicit
  arrow glyph, so the binding is legible at a glance. The optional label chip and
  the remove (−) button stay.

**2. De-jargon the labels.** No raw `thread_id` / `*` / `dm` tokens as the primary
text. Mapping:
- `dm` → "General / DM" (matches the existing chat-type-aware naming).
- `*` → "新しいトピックの初期設定 (catch-all)" with a one-line subtitle explaining
  it auto-applies to any topic without its own binding.
- numeric → the topic name (from the poller's topics.json join); the bare id moves
  to a small grey subtitle, not the primary label.

**3. Fix "can't select some topics."** Root cause is partly a real Telegram limit:
the Bot API can't enumerate topics created before the bot joined, so they only
appear in the picker after the bot observes a message/service event there. Replace
the cryptic "Custom…" free-text fallback's framing with an explicit, friendly path:
- Keep a "別のトピックを手動で指定…" option, but pair it with empty-state guidance:
  「探しているトピックが出てこない場合 → そのトピックで一度メッセージを送ると、ここに
  表示されるようになります。」
- The manual entry stays for power users, but is no longer the only escape hatch
  presented without explanation.

**4. Investigate + fix the "unstable" feeling.** Hypothesis: the Settings reload
timer recomputes `threadOptions` (as the bot learns topics), and the picker's
`threadSelection` resets or jumps when the option list changes mid-edit. Design
intent: **selection is preserved across background reloads** — a reload must not
clear/replace what the user is mid-way through choosing. Implementation will
confirm the exact mechanism (selection binding reset vs list identity churn) and
make the add-form state survive reloads. If a different instability surfaces during
investigation, fix that instead; this is the one observable symptom to chase.

**5. Trim the footer wall-of-text.** Replace the two dense footer paragraphs with
one short line + a "?" help popover holding the details (the `*`/`dm`/topic-id
explanation and the "how to find a topic id" instructions).

### Components touched
- `pager/Sources/ClaudePager/SettingsView.swift` — `MountsTab` (rows, header,
  picker, footers), tab title in the parent `TabView`.
- Possibly extract the add-form state (`threadSelection`/`newThreadId`/`newPath`/
  `newLabel` + `threadOptions`) into a small testable model if needed to fix and
  test the selection-stability bug without driving SwiftUI.

### Testing
- Existing `SetupWizardModelTests` / Settings-related tests stay green.
- Add a unit test for the selection-stability fix: given a `threadSelection` the
  user picked, a `threadOptions` recompute (bot learned a new topic) must not reset
  it. Requires the small extracted model above; if extraction proves heavy, scope
  to asserting the pure `threadOptions`/`effectiveNewThreadId` behavior.
- Visual verification (manual): labels read in plain language, arrow rows, help
  popover, empty-state guidance.

### Out of scope
- No change to mounts.json schema or the `cta mount/umount/list` CLI contract
  (still `thread_id`-keyed under the hood — only the UI presentation changes).

---

## Part B — File-access (Full Disk Access) onboarding

### Problem
P6c made the agent launchd-direct: the file-accessing processes are `bun` (poller)
and `claude` (daemons) under `com.claude-agent`, **not** children of Pager.app. macOS
TCC is per-binary, so a Full Disk Access grant given to "Claude Pager.app" does not
reach them. Result: claude can read/write the user's normal dirs (`~/ghq`,
`~/projects`, `~/claude-home` — not TCC-protected) but silently hits EPERM in
**TCC-protected** dirs (Documents, Desktop, Downloads, iCloud Drive). A launchd
background process can't show a TCC prompt, so this fails silently. User wants
onboarding to grant this up front.

### Key design principle: empirical, never assumed
The status must reflect the **actual launchd agent's** access, not Pager's or cta's
(different TCC contexts). So:

- **The poller does the probe** (it runs in the `com.claude-agent` TCC context).
  On startup (and on a periodic refresh), it attempts a cheap read of a known
  TCC-protected location — e.g. `readdir(~/Documents)` (directory listing of
  `~/Documents` requires FDA-or-folder-grant since Catalina). It records the result
  to a small state file `~/.pager/file-access.json`:
  `{ "protected_ok": bool, "probed_path": "~/Documents", "checked_at": ISO8601 }`.
- **`cta status --json`** surfaces it as an additive field (no schema bump per the
  cta schema-versioning rule — additive fields stay at the current version):
  `"file_access": { "protected_ok": bool, "probed_path": "...", "checked_at": "..." }`,
  read straight from the state file (cheap; no probe in cta itself, which would be
  the wrong TCC context).
- **Pager** reads it via the existing `CTAClient.status()` / `StatusMonitor` path.

This guarantees the UI never claims access the agent doesn't have.

### Onboarding + Diagnostics surface
- **SetupWizard:** add a step "ファイルアクセス (任意)" after the existing 5. Status
  derived from `file_access.protected_ok` (✓ when the probe passes). Because it's
  optional (only matters for protected-folder projects), it does NOT block wizard
  completion — it's a ✓/— informational step with an action button. Copy explains:
  「Documents / デスクトップ / ダウンロード / iCloud 内のフォルダで作業させたい場合は、
  Bot にフルディスクアクセスを許可してください。~/ghq などの通常フォルダだけなら不要です。」
- **Diagnostics:** add a row "File access (protected folders)" reading the same
  field, so the existing diagnostic report reflects it.

### The grant action (the button)
- A button 「システム設定を開く」 opens the FDA pane directly:
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
  via `NSWorkspace.shared.open(URL)`.
- Guidance text tells the user which binary to add, plus a **"Finder で表示"**
  helper button that reveals that binary in Finder (`NSWorkspace.activateFileViewerSelecting`)
  so the user can drag it into the FDA list (the binary lives in a hidden path like
  `~/.bun/bin/bun`, which is otherwise hard to reach in the file picker).
- After granting, the user re-runs the probe (the poller re-checks on its refresh
  cadence, or a "再確認" button kicks `cta`/touches a refresh) and the ✓ flips.

### OPEN ITEM → implementation spike (before finalizing the grant copy)
Which binary does TCC actually attribute file access to in the
`launchd → start_agents.sh → bun → claude → (tool subprocesses)` tree, on the
user's macOS version? Candidates, in order to try:
1. `claude` (the binary doing most file ops) — narrowest blast radius if it works.
2. `bun` (`~/.bun/bin/bun`, the poller interpreter) — broad (all bun processes) but
   likely to cover both poller and claude if claude inherits.
3. The launchd job's responsible process.

**Spike procedure:** with the probe in place showing ✗ for a protected path, grant
FDA to candidate #1, re-probe; if still ✗, try #2; record which flips it to ✓. The
empirical probe makes this a tight loop. The final onboarding copy names the
confirmed binary + provides its "Finder で表示" path. Until confirmed, the step ships
with the probe + button but the binary instruction is finalized post-spike.

### Components touched
- `agent/poller/poller.ts` — startup + periodic FDA self-probe → `~/.pager/file-access.json`.
- `cli/cta` — `cmd_status` additive `file_access` field read from the state file.
- `pager/Sources/ClaudePager/CTAClient.swift` — decode the new field (optional, so
  older agents that don't write it decode as nil → treated as "unknown").
- `pager/Sources/ClaudePager/SetupWizardModel.swift` + `SetupWizardView.swift` — the
  optional step.
- `pager/Sources/ClaudePager/Diagnostics.swift` — the diagnostic row.
- A small `FullDiskAccess` helper (open pane URL + reveal-in-Finder).

### Testing
- Poller probe: unit-test the classification (readable → true; EPERM → false) with
  an injected reader, in `agent/`. The probe is a pure function over a "can I read
  this path" closure (same DI pattern as the existing daemon tests).
- `cta status` field: extend `tests/test_cta.sh` to assert the `file_access` field
  appears when `~/.pager/file-access.json` exists and is omitted/null when absent
  (back-compat: older agents).
- `CTAClient` decode: assert the optional field decodes (present + absent) in
  `CTAClientTests`.
- SetupWizard step + Diagnostics row: model-level tests (status derivation), like
  the existing step predicates.
- The grant button + reveal-in-Finder + the which-binary instruction: manual /
  spike (TCC interaction can't be unit-tested).

### Out of scope
- No automatic granting of FDA (macOS requires the user to do it in System Settings;
  there's no API to grant it programmatically). We only detect + guide.
- No revert of P6c launchd-direct (the inheritance trick is intentionally gone).

---

## Build order (for the plan)
1. Part A Mounts redesign (UI-only; lowest risk, immediate user value).
2. Part B probe + `cta status` field + `CTAClient` decode (data plumbing).
3. Part B SetupWizard step + Diagnostics row + grant button.
4. Part B which-binary spike → finalize grant copy.
