/**
 * Bot-side slash command handlers.
 *
 * Phase 1 of the stream-json migration: instead of screen-scraping claude
 * TUI output for commands like /cost and /usage (which produce a different
 * pane-text format every claude release), we intercept these at the bot
 * layer and compute the answer directly from claude's on-disk state. Pattern
 * is taken from teleclaw / RichardAtCT — every other Telegram-Claude bot
 * does it this way; our prior Format A/B regex parser was the outlier.
 *
 * Pure functions only — they take dependencies (paths, fetch fn) as args
 * so unit tests can run without network or keychain access. The poller
 * wires them up to TgMessage handlers.
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

/**
 * Bun's `os.homedir()` reads from the OS user database, NOT process.env.HOME
 * — which means tests that redirect HOME to a tmpdir still get the real user's
 * home back. Use this helper everywhere we resolve "the user's claude dir",
 * so HOME-redirected tests work and operators with overridden HOME (rare but
 * supported in fixed-mount installs) get the override they asked for.
 */
function effectiveHome(): string {
  return process.env.HOME ?? homedir();
}

// ─── /cost ───────────────────────────────────────────────────────────────────

export interface ModelTokens {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
}

export interface CostSummary {
  byModel: Record<string, ModelTokens>;
  totalCostUsd: number;
}

interface ModelRate {
  input: number;        // USD per 1M tokens
  output: number;
  cacheRead: number;
  cacheWrite: number;
}

// Anthropic pricing as of late 2025. Subscription users may not be billed at
// these rates, but this is what claude code's own /cost reports — keep parity
// with the TUI so the number is "the number the user expects to see".
// Cache write = 1.25× input, cache read = 0.10× input (Anthropic standard 5m
// cache pricing). 1h cache has different rates but assistant.usage doesn't
// distinguish them in a single field, so we approximate with 5m rates.
const MODEL_RATES: Record<string, ModelRate> = {
  "claude-opus-4-7":     { input: 15.00, output: 75.00, cacheRead: 1.50,  cacheWrite: 18.75 },
  "claude-opus-4-6":     { input: 15.00, output: 75.00, cacheRead: 1.50,  cacheWrite: 18.75 },
  "claude-opus-4-5":     { input: 15.00, output: 75.00, cacheRead: 1.50,  cacheWrite: 18.75 },
  "claude-sonnet-4-6":   { input:  3.00, output: 15.00, cacheRead: 0.30,  cacheWrite:  3.75 },
  "claude-sonnet-4-5":   { input:  3.00, output: 15.00, cacheRead: 0.30,  cacheWrite:  3.75 },
  "claude-haiku-4-5":    { input:  1.00, output:  5.00, cacheRead: 0.10,  cacheWrite:  1.25 },
};

/**
 * Pick a rate row given a model id. Falls back to a prefix match
 * ("claude-opus-4-7-20260105" → "claude-opus-4-7") so monthly point releases
 * don't silently zero out cost when this table goes stale.
 */
function rateFor(model: string): ModelRate | null {
  if (MODEL_RATES[model]) return MODEL_RATES[model];
  for (const key of Object.keys(MODEL_RATES)) {
    if (model.startsWith(key)) return MODEL_RATES[key];
  }
  return null;
}

/**
 * Sum token usage across all `assistant` entries in the per-session JSONL
 * transcript. claude code writes one assistant entry per turn with a
 * `message.usage` object — that's the source of truth for billing.
 */
export function aggregateCostFromJsonl(jsonlPath: string): CostSummary {
  if (!existsSync(jsonlPath)) return { byModel: {}, totalCostUsd: 0 };
  let content: string;
  try {
    content = readFileSync(jsonlPath, "utf8");
  } catch {
    return { byModel: {}, totalCostUsd: 0 };
  }
  const byModel: Record<string, ModelTokens> = {};
  for (const line of content.split("\n")) {
    if (!line.trim()) continue;
    let entry: { type?: string; message?: { model?: string; usage?: Record<string, number> } };
    try {
      entry = JSON.parse(line);
    } catch {
      continue; // skip malformed line — JSONL is append-only, an in-progress
                // last line written by claude is occasionally truncated
    }
    if (entry.type !== "assistant") continue;
    const model = entry.message?.model;
    const u = entry.message?.usage;
    if (!model || !u) continue;
    if (!byModel[model]) byModel[model] = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
    byModel[model].input      += u.input_tokens                ?? 0;
    byModel[model].output     += u.output_tokens               ?? 0;
    byModel[model].cacheRead  += u.cache_read_input_tokens     ?? 0;
    byModel[model].cacheWrite += u.cache_creation_input_tokens ?? 0;
  }
  let totalCostUsd = 0;
  for (const [model, t] of Object.entries(byModel)) {
    const r = rateFor(model);
    if (!r) continue;
    totalCostUsd += (t.input * r.input + t.output * r.output + t.cacheRead * r.cacheRead + t.cacheWrite * r.cacheWrite) / 1_000_000;
  }
  return { byModel, totalCostUsd };
}

export function formatCostMessage(summary: CostSummary): string {
  if (Object.keys(summary.byModel).length === 0) {
    return "No usage recorded in this session yet.";
  }
  const lines: string[] = [
    `Session cost: $${summary.totalCostUsd.toFixed(2)}`,
    "",
  ];
  for (const [model, t] of Object.entries(summary.byModel)) {
    const total = t.input + t.output + t.cacheRead + t.cacheWrite;
    lines.push(`${model}`);
    lines.push(`  total: ${total.toLocaleString()} tokens`);
    lines.push(`    input: ${t.input.toLocaleString()}`);
    lines.push(`    output: ${t.output.toLocaleString()}`);
    if (t.cacheRead > 0) lines.push(`    cache read: ${t.cacheRead.toLocaleString()}`);
    if (t.cacheWrite > 0) lines.push(`    cache write: ${t.cacheWrite.toLocaleString()}`);
  }
  return lines.join("\n");
}

// ─── /usage ──────────────────────────────────────────────────────────────────
// Anthropic OAuth Usage API for subscription users. teleclaw's pattern.
// Credentials live in one of two places depending on claude code version:
//   1. ~/.claude/.credentials.json  — older versions, Linux, opt-out keychain
//   2. macOS Keychain entry "Claude Code-credentials" — current default on Mac

const ANTHROPIC_USAGE_API = "https://api.anthropic.com/api/oauth/usage";

export interface ResolveOpts {
  credentialsJsonPath?: string;
  /** Returns the keychain item's contents (a JSON string), or null if unavailable. */
  runKeychain?: () => Promise<string | null>;
}

function defaultKeychainRunner(): Promise<string | null> {
  return new Promise((resolve) => {
    if (process.platform !== "darwin") { resolve(null); return; }
    const r = spawnSync("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], { encoding: "utf8" });
    if (r.status !== 0) { resolve(null); return; }
    resolve(r.stdout.trim());
  });
}

/**
 * Try to find claude code's OAuth access token. Returns null if neither
 * credentials.json nor keychain is available — caller should reply with a
 * "couldn't authenticate" message rather than throwing.
 */
export async function resolveCredentialToken(opts: ResolveOpts = {}): Promise<string | null> {
  const credPath = opts.credentialsJsonPath ?? join(effectiveHome(), ".claude/.credentials.json");
  if (existsSync(credPath)) {
    try {
      const raw = readFileSync(credPath, "utf8");
      const parsed = JSON.parse(raw) as { claudeAiOauth?: { accessToken?: string } };
      const tok = parsed.claudeAiOauth?.accessToken;
      if (tok) return tok;
    } catch {
      /* fall through to keychain */
    }
  }
  const runner = opts.runKeychain ?? defaultKeychainRunner;
  const keychainContent = await runner();
  if (!keychainContent) return null;
  try {
    const parsed = JSON.parse(keychainContent) as { claudeAiOauth?: { accessToken?: string } };
    return parsed.claudeAiOauth?.accessToken ?? null;
  } catch {
    return null;
  }
}

export interface UsageStats {
  fiveHourPct: number | null;
  sevenDayPct: number | null;
  error: string | null;
}

/**
 * Fetch usage utilization from Anthropic's OAuth Usage endpoint. Subscription
 * users get a 5-hour and 7-day rolling utilization window — what teleclaw's
 * /usage shows. fetchFn is injectable so tests can run without network.
 */
export async function fetchUsageStats(token: string, fetchFn: typeof fetch = fetch): Promise<UsageStats> {
  try {
    // POST with no body — matches teleclaw's working pattern. The endpoint
    // is undocumented (an internal claude-code-subscription API), so this
    // contract is empirical, not spec'd. If Anthropic changes the method
    // we surface a graceful "Couldn't fetch" via the non-OK path below.
    const resp = await fetchFn(ANTHROPIC_USAGE_API, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "anthropic-beta": "oauth-2025-04-20",
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    if (!resp.ok) {
      return { fiveHourPct: null, sevenDayPct: null, error: `${resp.status}: ${resp.statusText || "request failed"}` };
    }
    const json = (await resp.json()) as {
      five_hour?: { utilization?: number };
      seven_day?: { utilization?: number };
    };
    return {
      fiveHourPct: typeof json.five_hour?.utilization === "number" ? json.five_hour.utilization * 100 : null,
      sevenDayPct: typeof json.seven_day?.utilization === "number" ? json.seven_day.utilization * 100 : null,
      error: null,
    };
  } catch (e) {
    return { fiveHourPct: null, sevenDayPct: null, error: e instanceof Error ? e.message : String(e) };
  }
}

export function formatUsageMessage(stats: UsageStats): string {
  if (stats.error || stats.fiveHourPct === null) {
    return [
      "Couldn't fetch usage stats.",
      stats.error ? `(${stats.error})` : "",
      "",
      "This works only on Anthropic-subscription claude code installs — make sure you're signed in via `claude /login` on the host.",
    ].filter(Boolean).join("\n");
  }
  return [
    `Anthropic usage`,
    `  5h window:  ${stats.fiveHourPct.toFixed(1)}%`,
    `  7d window:  ${stats.sevenDayPct?.toFixed(1) ?? "?"}%`,
  ].join("\n");
}

// ─── shared: locate the JSONL for a topic ─────────────────────────────────────
// Mirror of agent/topic-wrapper.sh's claude_project_dir_encode + session UUID
// resolution. Used by handleCost.

/** Mirror of the bash encoder — see tests/test_path_encoding.sh. */
export function claudeProjectDirEncode(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9-]/g, "-");
}

/** Resolve the on-disk JSONL transcript path for a (projectPath, sessionUuid). */
export function jsonlPathForSession(projectPath: string, sessionUuid: string, claudeHome?: string): string {
  const base = claudeHome ?? join(effectiveHome(), ".claude");
  return join(base, "projects", claudeProjectDirEncode(projectPath), `${sessionUuid}.jsonl`);
}
