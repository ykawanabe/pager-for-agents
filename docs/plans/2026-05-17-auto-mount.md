<!-- Task 0 verified 2026-05-17: skip-perms+deny enforced (canary "PUBLIC_OK_BLOB" read OK, "DENIED_PRIVATE_BLOB" blocked); deny syntax confirmed: Read(**/glob) gitignore-style; addMount throws on duplicate confirmed (mount-store.ts:280). -->

# Auto-mount (mount-helper) Implementation Plan — v2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Telegram topic receives a message and has no mount yet, replace the current silent-drop behavior with a short-lived "mount-helper" claude session that talks to the user via Telegram and runs `cta mount` once a directory is chosen.

**Architecture:** Helper mode is added to `topic-wrapper.sh` (4th positional arg `mode=helper`). When the poller's `routeMessage` returns null with no wildcard fallback AND `PAGER_DISABLE_HELPER` is not set, the poller (a) sends an immediate ack message via Bot API, (b) writes a provisional mount entry to `mounts.json` (additive `provisional: true` field), and (c) spawns a tmux session `helper-<thread_id>` running claude in `$HOME` with the bot's normal MCP config plus an extra `--settings helper-permissions.json` and a dedicated system prompt. Helper keeps `--dangerously-skip-permissions` (so headless tmux never hangs on permission prompts) but the settings file's `deny` list provides hard limits on Edit/Write/network/destructive Bash + sensitive paths. Denies enforce regardless of skip-permissions. On user choice, the helper runs `cta mount <thread_id> <abs_path> <label>`; cta detects the existing provisional, kills the helper tmux, and spawns the real `topic-<thread_id>` session via the standard path. Garbage collection on poller startup drops any orphaned provisional rows whose helper tmux is dead.

**Tech Stack:** Bun/TypeScript (poller, mount-store), bash (cta, topic-wrapper, install.sh), tmux, claude code CLI permission profile (`--settings`).

**Decisions locked (round 2, post eng+DX review):**
- Bootstrap cwd is `$HOME`. No user-supplied search-paths config in v1.
- Helper keeps `--dangerously-skip-permissions` to avoid headless prompt hangs; deny list is the real defense (denies are enforced regardless of skip).
- Provisional state lives in `mounts.json` as an optional `provisional: true` field (schema additive, no version bump).
- Wildcard mount, if present, still wins. `install.sh` auto-creates a wildcard at install time today, so helper is invisible on fresh installs — documented loudly in docs/troubleshooting.md and on the website. Removing the install-time wildcard is OUT OF SCOPE for v1 (separate decision).
- `addMount` keeps its throw-on-duplicate contract. cta uses `removeMount` + `addMount` to overwrite a provisional entry.
- `routeMessage` cannot rely on topic_name being known. Helper system prompt is written to handle the unknown-name case gracefully.
- Helper drops "create new at <path>" from v1. Mount only points at existing directories. Saves bootstrap complexity (git init, README, perms). v0.2 can add it.
- `/cancel` slash command, `PAGER_DISABLE_HELPER` env var, helper-side immediate ack, restart-time GC, and Pager UI filter are all IN v1.
- Helper idle timeout (kill helper after N min no activity): deferred to v0.2 — orphan cleanup is handled by restart GC and `/cancel`.

---

## File Structure

**Create:**
- `agent/helper-prompt.md` — mount-helper system prompt
- `agent/helper-permissions.json` — claude `--settings` profile (deny-list defense)
- `tests/test_helper_permissions.sh` — boots claude with the settings profile against canary files; asserts denies actually work
- `tests/test_auto_mount.sh` — end-to-end integration through the poller using mock claude
- `tests/fixtures/mock-claude-mount-helper.sh` — mock claude binary that simulates a helper session

**Modify:**
- `agent/mount-store/mount-store.ts` — add optional `provisional?: boolean` field on `Mount`; add `replaceMount()` function (atomic remove+add); CLI exposes `--provisional` on `add` and a new `gc-provisional` subcommand for restart-time cleanup.
- `agent/poller/poller.ts` — `routeMessage` returns null when neither specific nor wildcard exists AND `PAGER_DISABLE_HELPER` is unset, after which `dispatchUpdate` calls a new `spawnHelper()` that sends an immediate ack via Bot API, then writes provisional + starts the helper tmux session. Adds `/cancel` slash command handler. Adds startup GC pass for orphaned provisional rows. Plumbs cached `topic_name` (from `topics.json`) into helper env when available.
- `agent/topic-wrapper.sh` — accept 4th positional arg `mode` (default `topic`, alternative `helper`); in helper mode pass `--settings agent/helper-permissions.json` IN ADDITION TO existing bot-hooks settings, use `helper-prompt.md` instead of `DEFAULT_BOT_APPEND_SYSTEM_PROMPT`, KEEP `--dangerously-skip-permissions`, disable restart loop.
- `cli/cta` — `cmd_mount` calls `removeMount` first when an existing provisional is detected, then `addMount`, then kills `helper-<thread_id>` tmux. `cmd_list` filters or labels provisional rows.
- `install.sh` — add `cp` lines for `helper-prompt.md` and `helper-permissions.json` into `$AGENT_DIR/`.
- `pager/Sources/ClaudePager/CTAClient.swift` and the Add-a-mount picker — filter `provisional: true` entries OR show them as "helper running" with the Mount button disabled.
- `docs/troubleshooting.md` — helper-mode debug section + escape hatches.

---

## Task 0: Pre-implementation verifications

These are tiny, must run first, and protect every later task from rebuilding on bad assumptions.

- [ ] **Step 1: Verify `--dangerously-skip-permissions` does NOT bypass the settings.json deny list**

Run this canary against the current claude binary:

```bash
TMP=$(mktemp -d)
cat > "$TMP/canary-settings.json" <<'EOF'
{ "permissions": { "deny": ["Read(**/canary.txt)"] } }
EOF
echo "secret" > "$TMP/canary.txt"
cd "$TMP"
claude --dangerously-skip-permissions --settings ./canary-settings.json \
  --append-system-prompt "Read the file canary.txt and print its contents in one word." \
  -p "go" 2>&1 | tee out.txt
grep -q "secret" out.txt && echo "FAIL: deny bypassed" || echo "OK: deny enforced"
```

Expected: `OK: deny enforced`. If FAIL → escalate; the architectural premise (skip-perms + deny list) is broken, and we either (a) drop skip-perms and accept that the allow list must be exhaustive, or (b) gate helper through a wrapper binary instead.

- [ ] **Step 2: Verify the deny pattern syntax claude actually parses**

Repeat Step 1 with each candidate pattern; only patterns that produce `OK: deny enforced` are valid. Run these three forms against `~/.ssh/known_hosts` (a guaranteed-existing readable file on most macs) — DO NOT use `id_*` files:

```bash
for pat in 'Read(**/.ssh/**)' 'Read(~/.ssh/**)' 'Read(/Users/*/.ssh/**)'; do
  cat > "$TMP/canary-settings.json" <<EOF
{ "permissions": { "deny": ["$pat"] } }
EOF
  echo "--- testing pattern: $pat ---"
  claude --dangerously-skip-permissions --settings "$TMP/canary-settings.json" \
    --append-system-prompt "Run: cat ~/.ssh/known_hosts | head -1. Print exactly what cat printed." \
    -p "go" 2>&1 | tail -5
done
```

Record which patterns work; use those forms in Task 3. If NONE work, deny patterns rely on something this plan doesn't know; escalate.

- [ ] **Step 3: Verify `addMount` semantics**

Already known from code read: `agent/mount-store/mount-store.ts:280` throws `"${channel}:${thread_id} is already mounted"`. No code change here — Task 1 will add `replaceMount()` rather than mutate `addMount`. This step just confirms by running:

```bash
cd "$(git rev-parse --show-toplevel)"
STATE=$(mktemp -d) CTA_STATE_DIR=$STATE bun run agent/mount-store/mount-store.ts add 1 /tmp a >/dev/null
STATE_OUT=$(CTA_STATE_DIR=$STATE bun run agent/mount-store/mount-store.ts add 1 /tmp a 2>&1 || true)
echo "$STATE_OUT" | grep -q "already mounted" && echo "OK: throws on duplicate"
```

Expected: `OK: throws on duplicate`. Confirms the assumption Task 1 builds on.

- [ ] **Step 4: Commit the verification results to the plan as a NOTE**

Add a one-line comment near the top of this plan file:

```markdown
<!-- Task 0 verified on YYYY-MM-DD: skip-perms+deny=enforced; deny pattern syntax: <pattern1>, <pattern2>; addMount throws confirmed. -->
```

Do NOT commit code yet — verifications produce no source changes. Just record what's true so subsequent tasks reference the right syntax.

---

## Task 1: Mount-store provisional + replaceMount + GC

**Files:**
- Modify: `agent/mount-store/mount-store.ts`
- Test: `tests/test_mount_store.sh`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_mount_store.sh`:

```bash
test_provisional_field_roundtrip() {
  local state; state=$(mktemp -d)
  CTA_STATE_DIR="$state" bun run "$STORE" add 99 /tmp helper-test --provisional >/dev/null
  local got; got=$(CTA_STATE_DIR="$state" bun run "$STORE" get 99 | jq -r '.provisional')
  [[ "$got" == "true" ]] || { ng "provisional roundtrip: got $got"; return; }
  ok "provisional flag persists"
}

test_replace_mount() {
  local state; state=$(mktemp -d)
  CTA_STATE_DIR="$state" bun run "$STORE" add 88 /tmp first --provisional >/dev/null
  CTA_STATE_DIR="$state" bun run "$STORE" replace 88 /home/me/real real-label >/dev/null
  local prov path label
  prov=$(CTA_STATE_DIR="$state" bun run "$STORE" get 88 | jq -r '.provisional // "absent"')
  path=$(CTA_STATE_DIR="$state" bun run "$STORE" get 88 | jq -r '.path')
  label=$(CTA_STATE_DIR="$state" bun run "$STORE" get 88 | jq -r '.label')
  [[ "$prov" == "absent" ]] && [[ "$path" == "/home/me/real" ]] && [[ "$label" == "real-label" ]] \
    && ok "replace clears provisional + updates fields" \
    || ng "replace failed: prov=$prov path=$path label=$label"
}

test_gc_provisional_drops_dead_helper() {
  local state; state=$(mktemp -d)
  CTA_STATE_DIR="$state" bun run "$STORE" add 77 "$HOME" h --provisional --tmux-session helper-77 >/dev/null
  # helper-77 does NOT exist in tmux
  CTA_STATE_DIR="$state" bun run "$STORE" gc-provisional >/dev/null
  local got; got=$(CTA_STATE_DIR="$state" bun run "$STORE" get 77 2>/dev/null || echo "null")
  [[ "$got" == "null" ]] && ok "gc drops orphan provisional" || ng "gc missed: $got"
}

test_provisional_field_roundtrip
test_replace_mount
test_gc_provisional_drops_dead_helper
```

- [ ] **Step 2: Run, confirm failure**

Run: `bash tests/test_mount_store.sh`
Expected: FAIL — all three new tests.

- [ ] **Step 3: Add `provisional` to the Mount interface**

In `agent/mount-store/mount-store.ts`, locate the `Mount` interface near the top:

```ts
export interface Mount {
  channel: Channel;
  thread_id: ThreadId;
  path: string;
  label?: string;
  session_id?: string;
  tmux_session?: string;
  created_at: string;
  provisional?: boolean;  // ADD THIS
}
```

- [ ] **Step 4: Add `replaceMount` function**

In the same file, after `removeMount`:

```ts
export async function replaceMount(args: {
  channel?: Channel;
  thread_id: ThreadId;
  path: string;
  label?: string;
  tmux_session?: string;
}): Promise<Mount> {
  const channel = args.channel ?? DEFAULT_CHANNEL;
  return withLock(() => {
    const data = readMounts();
    const filtered = data.mounts.filter((m) => !sameTarget(m, channel, args.thread_id));
    const mount: Mount = {
      channel,
      thread_id: args.thread_id,
      path: args.path,
      label: args.label,
      session_id: randomUUID(),
      tmux_session: args.tmux_session ?? `topic-${args.thread_id}`,
      created_at: new Date().toISOString(),
    };
    filtered.push(mount);
    writeMountsAtomic({ ...data, mounts: filtered });
    return mount;
  });
}
```

- [ ] **Step 5: Add `gcProvisional` function**

```ts
export async function gcProvisional(isAlive: (tmuxSession: string) => boolean): Promise<number> {
  return withLock(() => {
    const data = readMounts();
    const before = data.mounts.length;
    const kept = data.mounts.filter((m) => {
      if (!m.provisional) return true;
      if (!m.tmux_session) return false; // provisional w/o tmux is corrupt — drop
      return isAlive(m.tmux_session);
    });
    if (kept.length !== before) writeMountsAtomic({ ...data, mounts: kept });
    return before - kept.length;
  });
}
```

- [ ] **Step 6: Add CLI surface (`add --provisional`, `replace`, `gc-provisional`)**

Search for the `add` CLI dispatch in `mount-store.ts`. Extend it to parse `--provisional` and `--tmux-session <name>`. Add new subcommands:

```ts
if (subcmd === "add") {
  const args = process.argv.slice(3);
  const provisional = args.includes("--provisional");
  const tmuxIdx = args.indexOf("--tmux-session");
  const tmuxSession = tmuxIdx >= 0 ? args[tmuxIdx + 1] : undefined;
  const positional = args.filter((a, i) => !a.startsWith("--") && args[i - 1] !== "--tmux-session");
  const [tid, path, label] = positional;
  const m = await addMount({ thread_id: parseThreadId(tid), path, label, tmux_session: tmuxSession });
  if (provisional) {
    // re-write with provisional set (addMount itself doesn't take the flag; do a second pass under lock-free path is fine since we just added)
    const data = readMounts();
    const idx = data.mounts.findIndex((x) => sameTarget(x, DEFAULT_CHANNEL, m.thread_id));
    data.mounts[idx].provisional = true;
    writeMountsAtomic(data);
    m.provisional = true;
  }
  console.log(JSON.stringify(m));
  return;
}

if (subcmd === "replace") {
  const [tid, path, label] = process.argv.slice(3);
  const m = await replaceMount({ thread_id: parseThreadId(tid), path, label });
  console.log(JSON.stringify(m));
  return;
}

if (subcmd === "gc-provisional") {
  const n = await gcProvisional((s) => {
    try {
      const r = Bun.spawnSync(["tmux", "has-session", "-t", s]);
      return r.exitCode === 0;
    } catch { return false; }
  });
  console.log(JSON.stringify({ dropped: n }));
  return;
}
```

Note: the `add --provisional` re-write-under-lock is a small race window. Acceptable for v1 since only the helper-spawn path uses it and it's idempotent. If linting complains, factor `addMount` to accept `provisional` natively in a follow-up.

- [ ] **Step 7: Run tests, confirm pass**

Run: `bash tests/test_mount_store.sh`
Expected: PASS on all three new tests + all existing tests.

- [ ] **Step 8: Commit**

```bash
git add agent/mount-store/mount-store.ts tests/test_mount_store.sh
git commit -m "feat(mount-store): provisional flag, replaceMount, gc-provisional"
```

---

## Task 2: Helper system prompt

**Files:**
- Create: `agent/helper-prompt.md`

- [ ] **Step 1: Write the prompt file**

Create `agent/helper-prompt.md` exactly:

```
You are running in MOUNT-HELPER mode. You are NOT in a project directory yet (cwd is $HOME). Your one job: figure out which local project directory the user wants for this Telegram topic, then commit it with `cta mount`.

Context provided via env:
  TELEGRAM_THREAD_ID — numeric thread id, or the literal string "dm"
  PAGER_TOPIC_NAME    — human-readable topic name. May be empty/unknown.

Workflow:
  1. Greet briefly via send_telegram. If PAGER_TOPIC_NAME is known: "Looking for projects matching '<name>'…". If empty: "What project do you want to bind this topic to?". One short message.
  2. Read ~/.pager/mounts.json (Read tool). Learn the user's directory convention: what roots their existing mounts live under. If 50%+ of mounts share a root (e.g. ~/ghq/src/github.com/<user>/), prefer that root for suggestions.
  3. Search for candidates. Tools available: ls, find (read-only), fd, tree, ghq list, mdfind, locate, zoxide/z, git -C <dir> config --get remote.origin.url, cat on project markers (package.json, go.mod, Cargo.toml, README, .git/config). DO NOT walk into ~/Library or ~/Documents (the deny list will block reads anyway; just don't waste turns trying).
  4. Match strategy: case-insensitive substring of PAGER_TOPIC_NAME in basename or git remote name; ignore punctuation. If no name, ask user for hints before searching.
  5. Send candidates as buttons via send_telegram with `buttons=[...]`. Button labels: keep ≤50 chars. Use unique-suffix style: `ykawanabe/cta` for `~/ghq/src/github.com/ykawanabe/cta`. If two candidates share a basename, include parent dir to disambiguate. Cap at 3 path buttons + 1 "Other (type a path)". If you have zero candidates, just say "I couldn't find a match — type the absolute path to the project."
  6. When the user picks or types a path:
     a. Verify it EXISTS as a directory. If not, send "That path doesn't exist. Try again, or create it manually and re-type." Do NOT create directories yourself in v1.
     b. Run: `cta mount "$TELEGRAM_THREAD_ID" <abs_path> "${PAGER_TOPIC_NAME:-helper-mount}"`
     c. If exit 0: send "Mounted <abs_path>. Note: I'm a temporary helper — your next message starts a fresh claude session in that project with no memory of this conversation." Then stop. Your tmux session will be killed by cta mount.
     d. If non-zero: paste the cta error verbatim to the user via send_telegram and ask them to try again or `/cancel`.

Language detection: prefer the user's first-message language over the topic name. PAGER_TOPIC_NAME is a fallback signal only. If user wrote in Japanese, reply in Japanese; etc. Keep messages short — users are on phones.

Hard rules:
  - You MUST NOT use Edit, Write, or NotebookEdit. They are denied.
  - You MUST NOT install packages, push git changes, or make network requests.
  - You MUST NOT propose paths outside $HOME without the user typing them explicitly.
  - You MUST NOT create directories in v1.
  - If the user wants to abort, tell them to send `/cancel` (the poller handles it; you don't).
  - If the user goes off-topic during the helper conversation, say once: "I'm in mount-helper mode. Let's finish picking a directory first; once mounted, the project session will handle the rest." Then re-offer candidates.
  - You have access to the same `send_telegram` MCP tool as a normal topic session. Telegram renders plain text — no markdown.
```

- [ ] **Step 2: Commit**

```bash
git add agent/helper-prompt.md
git commit -m "feat(agent): mount-helper system prompt"
```

---

## Task 3: Helper permissions profile

**Files:**
- Create: `agent/helper-permissions.json`

- [ ] **Step 1: Write the settings file**

Use the deny-pattern syntax that Task 0 step 2 verified. As a starting candidate (replace patterns with verified forms before committing):

```json
{
  "permissions": {
    "deny": [
      "Edit",
      "Write",
      "NotebookEdit",
      "WebFetch",
      "WebSearch",
      "Read(**/.ssh/**)",
      "Read(**/.aws/**)",
      "Read(**/.gnupg/**)",
      "Read(**/.config/gh/**)",
      "Read(**/Library/**)",
      "Read(**/Library/Keychains/**)",
      "Read(**/.Trash/**)",
      "Read(**/Documents/**)",
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(**/*.pem)",
      "Read(**/*.key)",
      "Read(**/id_rsa*)",
      "Read(**/id_ed25519*)",
      "Glob(**/.ssh/**)",
      "Glob(**/Library/**)",
      "Glob(**/Documents/**)",
      "Bash(rm:*)",
      "Bash(mv:*)",
      "Bash(cp:*)",
      "Bash(chmod:*)",
      "Bash(chown:*)",
      "Bash(curl:*)",
      "Bash(wget:*)",
      "Bash(ssh:*)",
      "Bash(scp:*)",
      "Bash(nc:*)",
      "Bash(npm:*)",
      "Bash(pip:*)",
      "Bash(pip3:*)",
      "Bash(cargo:*)",
      "Bash(brew:*)",
      "Bash(make:*)",
      "Bash(git push:*)",
      "Bash(git commit:*)",
      "Bash(git reset:*)",
      "Bash(git checkout:*)",
      "Bash(git rebase:*)",
      "Bash(git pull:*)",
      "Bash(mkdir:*)",
      "Bash(touch:*)"
    ]
  }
}
```

Allow list intentionally omitted — `--dangerously-skip-permissions` (set in Task 4) makes everything else go through without prompting. Denies are the only line of defense.

NOTE: `Read(**/Documents/**)` is broad — it blocks reading anything under any Documents folder, including legitimate project files at `~/Documents/code/`. This is intentional in v1 (iCloud Drive avalanche risk dominates). If users complain, allow `Read(/Users/*/Documents/code/**)` etc. as exceptions in v0.2.

- [ ] **Step 2: Commit**

```bash
git add agent/helper-permissions.json
git commit -m "feat(agent): helper-mode permission profile (deny-list defense)"
```

---

## Task 4: Topic-wrapper helper mode

**Files:**
- Modify: `agent/topic-wrapper.sh`

- [ ] **Step 1: Add helper mode arg + branch on it**

In `agent/topic-wrapper.sh` near the top, find the positional arg parsing and add a 4th:

```bash
THREAD_ID="${1:?thread_id required}"
PROJECT_PATH="${2:?project_path required}"
TMUX_SESSION="${3:?tmux_session required}"
MODE="${4:-topic}"
```

Locate the `args=(...)` block in `main_loop`. Replace with:

```bash
local args=(--mcp-config "$MCP_CFG" --strict-mcp-config --dangerously-skip-permissions)
[[ -f "$BOT_HOOKS_PATH" ]] && args+=(--settings "$BOT_HOOKS_PATH")
if [[ "$MODE" == "helper" ]]; then
  args+=(--settings "$AGENT_DIR/helper-permissions.json")
  append_prompt=$(cat "$AGENT_DIR/helper-prompt.md")
else
  append_prompt=$(resolve_append_prompt "${BOT_APPEND_SYSTEM_PROMPT:-}" "$DEFAULT_BOT_APPEND_SYSTEM_PROMPT")
fi
[[ -n "$append_prompt" ]] && args+=(--append-system-prompt "$append_prompt")
```

NOTE: claude code accepts multiple `--settings` flags; later ones layer on top of earlier. Verify in Task 0 step 2 if uncertain. If only one is supported, MERGE the bot-hooks settings + helper-permissions into a single temp file at startup.

Confirm `$AGENT_DIR` is already defined near the top of topic-wrapper.sh. If not:

```bash
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

- [ ] **Step 2: Disable restart loop in helper mode**

Wrap the `while true` block in main_loop. Before the loop:

```bash
if [[ "$MODE" == "helper" ]]; then
  export PAGER_TOPIC_NAME="${PAGER_TOPIC_NAME:-}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] helper for topic $THREAD_ID: claude starting in $PROJECT_PATH"
  claude "${args[@]}" || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] helper for topic $THREAD_ID: exited"
  return 0
fi
# original restart loop unchanged
```

- [ ] **Step 3: Run full existing test suite**

Run: `bash tests/run.sh`
Expected: All current tests pass (no helper-specific test yet — comes in Task 8).

- [ ] **Step 4: Commit**

```bash
git add agent/topic-wrapper.sh
git commit -m "feat(topic-wrapper): helper mode (separate prompt + denylist, no restart loop)"
```

---

## Task 5: Poller — spawnHelper, immediate ack, /cancel, GC, kill-switch

**Files:**
- Modify: `agent/poller/poller.ts`

- [ ] **Step 1: Add `PAGER_DISABLE_HELPER` kill-switch + GC at startup**

Find the poller startup sequence (where `mountsCache` is first hydrated). Add after the wildcard ensure call:

```ts
const HELPER_DISABLED = process.env.PAGER_DISABLE_HELPER === "1";

async function gcOrphanedProvisionals(): Promise<void> {
  const dropped = await gcProvisional((s) => {
    try {
      const r = Bun.spawnSync(["tmux", "has-session", "-t", s]);
      return r.exitCode === 0;
    } catch { return false; }
  });
  if (dropped > 0) {
    process.stdout.write(`[${new Date().toISOString()}] poller: gc dropped ${dropped} orphaned provisional mount(s)\n`);
  }
}

// call once at startup, after mountsCache is loaded
await gcOrphanedProvisionals();
```

- [ ] **Step 2: Add `sendImmediateAck` helper using Bot API directly**

The poller already has Bot API access for getUpdates. Add:

```ts
async function sendImmediateAck(thread_id: number | "dm", topic_name: string | null): Promise<void> {
  const chat_id = effectiveChatId();
  if (chat_id == null) return;
  const text = topic_name
    ? `Looking for projects matching "${topic_name}"…`
    : "Setting up this topic — what project should it point to?";
  const body: Record<string, unknown> = { chat_id, text };
  if (typeof thread_id === "number") body.message_thread_id = thread_id;
  try {
    await fetch(`https://api.telegram.org/bot${process.env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (e) {
    process.stderr.write(`poller: sendImmediateAck failed: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}
```

- [ ] **Step 3: Add `spawnHelper`**

```ts
async function spawnHelper(thread_id: number | "dm"): Promise<string | null> {
  if (HELPER_DISABLED) return null;
  const tmuxSession = `helper-${thread_id}`;

  // Idempotent: existing helper tmux session means a helper is already running.
  if (tmuxHasSession(tmuxSession)) {
    return tmuxSession;
  }

  const topicName = readTopicNameFromCache(thread_id); // see Step 4
  await sendImmediateAck(thread_id, topicName);

  await addMount({
    thread_id,
    path: process.env.HOME ?? "/tmp",
    label: topicName ?? `helper-${thread_id}`,
    tmux_session: tmuxSession,
  });
  // mark provisional via re-write under lock (acceptable race window — see mount-store note)
  await markProvisional(thread_id);

  const wrapper = join(AGENT_DIR, "topic-wrapper.sh");
  const env = { ...process.env, PAGER_TOPIC_NAME: topicName ?? "" };
  spawnTmuxSessionWithEnv(tmuxSession, [wrapper, String(thread_id), env.HOME!, tmuxSession, "helper"], env);
  return tmuxSession;
}
```

Where `markProvisional` is a small helper that reads + rewrites mount with the flag set. Implement inline or in mount-store.

- [ ] **Step 4: Add `readTopicNameFromCache`**

```ts
function readTopicNameFromCache(thread_id: number | "dm"): string | null {
  if (thread_id === "dm") return null;
  try {
    const cache = readTopics(); // existing function
    const key = `${effectiveChatId()}/${thread_id}`;
    return cache.topics?.[key]?.name ?? null;
  } catch { return null; }
}
```

- [ ] **Step 5: Plumb spawnHelper into routeMessage / dispatchUpdate**

`routeMessage` stays sync (returns the existing tmux_session or null). The async helper-spawn happens in `dispatchUpdate` after `routeMessage` returns null:

```ts
const target = routeMessage(msg);
if (target) {
  tmuxDispatch(target, formatMessageForClaude(msg));
  return;
}
// No mount and no wildcard. Try helper.
if (msg.message_thread_id != null || msg.text) {
  const key: number | "dm" = msg.message_thread_id ?? "dm";
  const helperSession = await spawnHelper(key);
  if (helperSession) {
    // Brief delay for tmux+claude to come up, then dispatch the message.
    await sleep(2000);
    tmuxDispatch(helperSession, formatMessageForClaude(msg));
    return;
  }
}
// Helper disabled or unavailable. Original silent-drop path.
process.stderr.write(`poller: drop msg ... reason=no-mount-no-helper\n`);
```

- [ ] **Step 6: Add `/cancel` slash command**

In the message-handler block (where other slash commands like `/mount`, `/unpair` are processed), add:

```ts
if (msg.text?.trim() === "/cancel") {
  const key: number | "dm" = msg.message_thread_id ?? "dm";
  const mount = findMount("telegram", key);
  if (!mount?.provisional) {
    await sendImmediateAck(key, null); // reply: nothing to cancel
    return;
  }
  const helperSession = mount.tmux_session ?? `helper-${key}`;
  try { Bun.spawnSync(["tmux", "kill-session", "-t", helperSession]); } catch {}
  await removeMount(key);
  await sendCancelConfirmation(key); // small helper using fetch like sendImmediateAck
  return;
}
```

- [ ] **Step 7: Smoke test**

Add to `tests/test_poller_commands.sh`:

```bash
test_disable_helper_env_skips_spawn() {
  # With PAGER_DISABLE_HELPER=1 set, an unmounted message should NOT
  # produce a provisional entry.
  PAGER_DISABLE_HELPER=1 send_mock_update_to_poller '{"message":{"message_thread_id":555,"text":"hi","chat":{"id":-100123,"is_forum":true}}}'
  sleep 1
  local got; got=$(jq -r '.mounts | map(select(.thread_id==555)) | length' "$CTA_STATE_DIR/mounts.json")
  [[ "$got" == "0" ]] && ok "kill-switch suppresses helper" || ng "helper still fired"
}
test_disable_helper_env_skips_spawn
```

(The full end-to-end test is in Task 8.)

- [ ] **Step 8: Run, fix, commit**

Run: `bash tests/test_poller_commands.sh`
Expected: PASS.

```bash
git add agent/poller/poller.ts tests/test_poller_commands.sh
git commit -m "feat(poller): spawn helper for unmounted topics + immediate ack + /cancel + GC + kill-switch"
```

---

## Task 6: cta — replace-on-provisional, helper teardown, list filter

**Files:**
- Modify: `cli/cta`
- Test: `tests/test_cta_mounts.sh`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_cta_mounts.sh`:

```bash
test_mount_replaces_provisional_and_kills_helper() {
  bun run "$STORE" add 42 "$HOME" h --provisional --tmux-session helper-42 >/dev/null
  TMUX_TMPDIR="$STATE/tmuxtmp" tmux -L "$PRIVATE_SOCKET" new-session -d -s "helper-42" "sleep 30"
  "$CTA" mount 42 "$TMP_PROJECT" my-project >/dev/null
  local prov; prov=$(bun run "$STORE" get 42 | jq -r '.provisional // "absent"')
  [[ "$prov" == "absent" ]] && ok "provisional cleared by cta mount" || ng "still provisional: $prov"
  TMUX_TMPDIR="$STATE/tmuxtmp" tmux -L "$PRIVATE_SOCKET" has-session -t "helper-42" 2>/dev/null \
    && ng "helper-42 still alive" || ok "helper tmux torn down"
}

test_list_filters_provisional() {
  bun run "$STORE" add 88 "$HOME" h --provisional --tmux-session helper-88 >/dev/null
  bun run "$STORE" add 89 "$TMP_PROJECT" real >/dev/null
  local out; out=$("$CTA" list 2>/dev/null)
  echo "$out" | grep -q "helper-88\|thread 88" && ng "list showed provisional 88" || ok "list hides provisional"
  echo "$out" | grep -q "89\|real" && ok "list shows real mount" || ng "list missed real mount"
}

test_mount_replaces_provisional_and_kills_helper
test_list_filters_provisional
```

- [ ] **Step 2: Modify `cmd_mount`**

In `cli/cta`, locate `cmd_mount()` (around line 707). After the abs_path resolution and BEFORE `bun run "$store" add`:

```bash
# If this thread has a provisional helper mount, tear it down and use replace.
local existing
existing=$(bun run "$store" get "$thread_id" 2>/dev/null || echo "")
local is_provisional=false
if [[ -n "$existing" ]] && echo "$existing" | jq -e '.provisional == true' >/dev/null 2>&1; then
  is_provisional=true
  local helper_session="helper-${thread_id}"
  if tmux has-session -t "$helper_session" 2>/dev/null; then
    tmux kill-session -t "$helper_session" || true
  fi
fi

if [[ "$is_provisional" == "true" ]]; then
  mount_json=$(bun run "$store" replace "$thread_id" "$abs_path" "$label")
else
  mount_json=$(bun run "$store" add "$thread_id" "$abs_path" "$label")
fi
```

(Replace the existing `mount_json=$(bun run "$store" add ...)` line with the branch above.)

- [ ] **Step 3: Filter provisional from `cmd_list`**

Locate `cmd_list()`. Add a pipe filter (or equivalent in TS-side via mount-store CLI):

Easiest path: in the jq pipeline that formats the list, add `select(.provisional != true)` to the human-readable output. JSON output (`--json`) can KEEP provisional rows so Pager + tooling see them and filter themselves.

```bash
# In the existing list-rendering block:
echo "$mounts_json" | jq -r '.mounts | map(select(.provisional != true)) | .[] | ...'
```

- [ ] **Step 4: Run tests**

Run: `bash tests/test_cta_mounts.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cli/cta tests/test_cta_mounts.sh
git commit -m "feat(cta): replace+teardown on provisional mount commit; hide provisional from list"
```

---

## Task 7: install.sh — copy helper files

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: Add the cp lines**

Locate the `cp "$REPO_DIR/agent/topic-wrapper.sh" "$AGENT_DIR/topic-wrapper.sh"` line. Add directly after it:

```bash
cp "$REPO_DIR/agent/helper-prompt.md" "$AGENT_DIR/helper-prompt.md"
cp "$REPO_DIR/agent/helper-permissions.json" "$AGENT_DIR/helper-permissions.json"
```

- [ ] **Step 2: Test install**

Run `install.sh` against an isolated `CTA_STATE_DIR` (mimic CI):

```bash
TMP=$(mktemp -d) CTA_STATE_DIR="$TMP" ./install.sh 2>&1 | tail -20
ls "$TMP"/../*/agent/helper-prompt.md "$TMP"/../*/agent/helper-permissions.json
```

Adjust paths if AGENT_DIR resolves differently in your install layout (read install.sh to confirm). Expected: both files present.

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "fix(install): copy helper-prompt.md + helper-permissions.json"
```

---

## Task 8: End-to-end + deny-canary tests

**Files:**
- Create: `tests/test_auto_mount.sh`
- Create: `tests/test_helper_permissions.sh`
- Create: `tests/fixtures/mock-claude-mount-helper.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Mock claude binary**

Create `tests/fixtures/mock-claude-mount-helper.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Verify helper-mode invocation (must contain helper-prompt marker).
prompt_arg=""; prev=""
for a in "$@"; do
  [[ "$prev" == "--append-system-prompt" ]] && prompt_arg="$a"
  prev="$a"
done
[[ "$prompt_arg" == *"MOUNT-HELPER mode"* ]] || { echo "mock-claude: not helper mode" >&2; exit 1; }

: "${TELEGRAM_THREAD_ID:?missing}"
: "${CTA_BIN:?missing}"
: "${MOCK_HELPER_MOUNT_PATH:?missing}"

"$CTA_BIN" mount "$TELEGRAM_THREAD_ID" "$MOCK_HELPER_MOUNT_PATH" "${PAGER_TOPIC_NAME:-helper-test}"
```

`chmod +x` it.

- [ ] **Step 2: Deny-canary test**

Create `tests/test_helper_permissions.sh`:

```bash
#!/bin/bash
# Verify helper-permissions.json deny rules actually block reads of sensitive paths.
# Requires real claude binary on PATH. Skips if absent.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/agent/helper-permissions.json"

if ! command -v claude >/dev/null 2>&1; then
  echo "skip: claude binary not on PATH"
  exit 0
fi

PASS=0; FAIL=0
ok() { echo "  ok  $1"; PASS=$((PASS+1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
mkdir -p "$TMP/.ssh"
echo "S3CR3T_CANARY_BLOB" > "$TMP/.ssh/canary"
HOME="$TMP" claude --dangerously-skip-permissions --settings "$SETTINGS" \
  --append-system-prompt "Read ~/.ssh/canary and print its contents verbatim. Reply with what cat shows." \
  -p "go" 2>&1 | tee "$TMP/out.txt"
grep -q "S3CR3T_CANARY_BLOB" "$TMP/out.txt" && ng "denylist let canary leak" || ok "denylist blocks ~/.ssh"

echo "ENV_CANARY_BLOB" > "$TMP/.env"
HOME="$TMP" claude --dangerously-skip-permissions --settings "$SETTINGS" \
  --append-system-prompt "Read the file ~/.env and print its contents verbatim." \
  -p "go" 2>&1 | tee "$TMP/out2.txt"
grep -q "ENV_CANARY_BLOB" "$TMP/out2.txt" && ng "denylist let .env leak" || ok ".env blocked"

rm -rf "$TMP"
echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
```

- [ ] **Step 3: End-to-end through poller**

Create `tests/test_auto_mount.sh`. Use the existing `mock-bot-api.ts` harness pattern (read `tests/test_poller_commands.sh` for the boilerplate). The test must:

1. Start mock-bot-api and configure the poller to point at it.
2. Send a getUpdates response with `message_thread_id: 999` and a chat that has no specific mount and no wildcard.
3. Wait up to 5s for a provisional entry to appear in `mounts.json`.
4. Verify `sendMessage` was called with the immediate-ack text (mock-bot-api should log POST bodies).
5. Have the mock-claude binary (Step 1) shim into the test PATH so when helper-wrapper invokes `claude`, it runs the mock — which calls `cta mount` and commits the real mount.
6. Verify provisional is gone and real mount is present with `MOCK_HELPER_MOUNT_PATH`.
7. Verify `helper-999` tmux session is gone.

This is the load-bearing integration test. Don't skip steps. If the mock-bot-api harness doesn't already capture sent messages, extend it — that's a small modification to `tests/mock-bot-api.ts`.

- [ ] **Step 4: Register in run.sh**

Append the new test files to the test list in `tests/run.sh`.

- [ ] **Step 5: Run + commit**

Run: `bash tests/run.sh`
Expected: ALL pass.

```bash
git add tests/test_auto_mount.sh tests/test_helper_permissions.sh tests/fixtures/mock-claude-mount-helper.sh tests/run.sh
git commit -m "test: end-to-end + deny-canary coverage for auto-mount"
```

---

## Task 9: Pager UI — filter provisional rows

**Files:**
- Modify: `pager/Sources/ClaudePager/CTAClient.swift` (Mount decode + list filter)
- Modify: whatever Swift file renders the menubar's mount list and the Add-a-mount picker (find via grep for `fetchMounts` or `Mount` consumers).

- [ ] **Step 1: Add `provisional` to the Swift `Mount` struct**

Locate the `Mount` struct in `CTAClient.swift`. Add:

```swift
struct Mount: Codable {
    // ... existing fields
    let provisional: Bool?
}
```

- [ ] **Step 2: Filter from the menubar list display**

In whichever view renders the mount list, filter or label:

```swift
let displayed = mounts.filter { $0.provisional != true }
// OR show them with a "helper running" label and a disabled Mount button:
// ForEach(mounts) { m in
//   if m.provisional == true {
//     Text("\(m.label ?? "topic \(m.thread_id)") · helper running").foregroundColor(.secondary)
//   } else { /* normal row */ }
// }
```

For v1, pick filtering — simpler, no new UI strings. Use the labeled variant in v0.2.

- [ ] **Step 3: Filter from the Add-a-mount topic picker**

Find the recent topic-picker code (commit 621aadd). When deciding which thread_ids are "already mounted", treat provisional ones as unmounted (since user is in the middle of fixing them via helper).

- [ ] **Step 4: Manual smoke test**

Build Pager dev (`cd pager && swift build`), launch, ensure: (a) a provisional mount doesn't appear in the menubar list; (b) the topic picker shows the provisional's thread_id as available for mounting; (c) Pager-side manual mount on a provisional thread successfully replaces (relies on Task 6's cta mount path).

- [ ] **Step 5: Commit**

```bash
git add pager/Sources/ClaudePager/
git commit -m "feat(pager): filter provisional mounts from UI"
```

---

## Task 10: Docs

**Files:**
- Modify: `docs/troubleshooting.md`
- Modify: `docs/index.html` (landing page) — short mention of new behavior

- [ ] **Step 1: Add troubleshooting section**

Append to `docs/troubleshooting.md`:

```markdown
## Mount-helper mode (auto-mount)

When you send the first message to an unmounted Telegram forum topic, the poller spawns a short-lived "mount-helper" claude session that searches your filesystem and asks which directory to mount. The helper runs in `$HOME` with a permission profile (`agent/helper-permissions.json`) that denies Edit/Write/network and reads against `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/Library`, `~/Documents`, and `.env` files.

If the helper doesn't fire:
- A wildcard mount (`thread_id: "*"`) takes priority. The default install creates one pointing at `$CLAUDE_CWD`. Run `cta umount '*'` to opt into helper-based onboarding.
- Set `PAGER_DISABLE_HELPER=1` in `~/.pager/.env` to disable the helper entirely.
- Check `~/.pager/poller.log` — every unmounted-message-with-no-helper logs the reason.

If the helper hangs or refuses to mount:
- Tmux session is `helper-<thread_id>`. `tmux attach -t helper-<thread_id>` to inspect.
- Send `/cancel` in the Telegram topic to abort. The poller kills the helper tmux and clears the provisional mount.
- Or: `cta mount <thread_id> /abs/path label` from your Mac manually overrides any in-progress helper.

If the helper leaves orphaned state:
- The poller GCs orphaned provisional mounts on startup (when helper tmux is dead). Restart with `cta restart`.
- Manual cleanup: `cta umount <thread_id>` then `tmux kill-session -t helper-<thread_id>` if still around.

Known UX trade-offs (v1):
- The helper conversation does NOT carry into the project session. Once mounted, your next message starts a fresh claude session in that directory with no memory of the helper convo.
- Helper cannot create new directories. `mkdir -p ~/code/new-project` yourself before pointing the helper at it.
- First reply takes ~5-15s on cold start; helper sends an immediate "Looking for projects…" ack to reduce perceived silence.
```

- [ ] **Step 2: Brief mention on landing page**

In `docs/index.html`, find the feature list. Add a short bullet under existing items:

```html
<li>Send a message to a new Telegram topic → bot proposes matching project directories from your Mac, you tap to mount.</li>
```

- [ ] **Step 3: Commit**

```bash
git add docs/
git commit -m "docs: auto-mount user-facing docs + troubleshooting"
```

---

## Open items deferred to v0.2

- Helper idle timeout (currently relies on user `/cancel` or restart GC).
- Helper-driven "create new directory" with `git init` + README scaffolding.
- Pager UI shows provisional rows with a "helper running" label (v1 just hides them).
- Removing the install-time wildcard mount (debate: changes onboarding default).
- Allow narrow exceptions in deny patterns for `~/Documents/code/**` and similar.
- Search-roots config: `~/.pager/config.json` `mount_search_paths` to constrain helper search.

## Self-review

- Spec coverage: pre-verify ✓ (Task 0), mount-store ✓ (Task 1), prompt ✓ (Task 2), perms ✓ (Task 3), wrapper ✓ (Task 4), poller incl. ack+cancel+GC+killswitch ✓ (Task 5), cta replace+filter ✓ (Task 6), install ✓ (Task 7), tests incl. deny-canary ✓ (Task 8), Pager ✓ (Task 9), docs ✓ (Task 10).
- Placeholder scan: Task 8 step 3 directs implementer to read existing harness — that's a real instruction, not a placeholder. Task 9 step 3 says "find via grep" — same.
- Type consistency: `Mount.provisional` is `optional boolean` in TS and Swift; cta passes via JSON; mount-store CLI exposes via `--provisional` flag.
- Critical risks gated: Task 0 verifies skip-perms+deny enforcement and deny pattern syntax BEFORE any helper code is written. If Task 0 fails, the plan halts and gets revised.
