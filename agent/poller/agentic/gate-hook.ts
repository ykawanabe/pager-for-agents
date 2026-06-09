#!/usr/bin/env bun
/**
 * Agentic gate — the PreToolUse hook that runs inside the agentic executor's
 * `claude` child. It is the ONLY thing standing between the model and a side
 * effect, so it FAILS CLOSED: any error, missing config, or unclassifiable call
 * results in DENY, never allow.
 *
 * Per tool call:
 *   SILENT → allow + log         (reversible / in-mount / read-only)
 *   DENY   → deny + log          (blast-radius cap: sudo, rm -rf ~, fork bomb, …)
 *   ASK    → write a request record, BLOCK polling for the human's decision file,
 *            then allow / allow-with-edited-args / deny — or deny on expiry.
 *
 * Config arrives via env vars the runner sets when spawning claude (the hook is a
 * child of claude and inherits them). Confirmed by the 2026-06-09 spike that this
 * PreToolUse hook fires, blocks, and hard-denies in `claude -p --input-format
 * stream-json` even under --dangerously-skip-permissions.
 *
 * Why a blocking hook (not LangGraph-style serialize/resume): the call is held
 * in-process for the whole human round-trip, so there is NO re-execution and the
 * side effect runs exactly once after `allow` — strictly simpler and safer.
 */

import { appendFileSync, readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { classify } from "./autonomy-policy";
import {
  writeRequest, readDecision, decisionExists, cleanup, hashArgs,
  type ApprovalRequest,
} from "./approval-store";

export interface HookInput {
  readonly tool_name?: string;
  readonly tool_input?: Record<string, unknown>;
  readonly cwd?: string;
  readonly tool_use_id?: string;
  readonly session_id?: string;
}

export interface HookOutput {
  hookSpecificOutput: {
    hookEventName: "PreToolUse";
    permissionDecision: "allow" | "deny";
    permissionDecisionReason: string;
    /** For an Edit decision: the corrected tool input to run instead. */
    updatedInput?: Record<string, unknown>;
  };
}

export interface HookConfig {
  readonly approvalsDir: string;
  readonly mount: string;
  readonly threadId: string;
  readonly chatId: number;
  readonly expiryMs: number;
  readonly pollMs: number;
  readonly logFile?: string;
  // Seams for tests:
  readonly nowMs: () => number;
  readonly sleep: (ms: number) => void;
  readonly genId: () => string;
}

const out = (decision: "allow" | "deny", reason: string, updatedInput?: Record<string, unknown>): HookOutput => ({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: decision,
    permissionDecisionReason: reason,
    ...(updatedInput ? { updatedInput } : {}),
  },
});

function logLine(cfg: HookConfig, rec: Record<string, unknown>): void {
  if (!cfg.logFile) return;
  try { appendFileSync(cfg.logFile, JSON.stringify({ at: new Date(cfg.nowMs()).toISOString(), ...rec }) + "\n"); }
  catch { /* best effort */ }
}

/**
 * Decide the permission for one tool call. Pure aside from the approval-store IO
 * (real temp dir in tests) and the injected now/sleep/genId seams.
 */
export function decide(input: HookInput, cfg: HookConfig): HookOutput {
  const toolName = input.tool_name ?? "";
  const toolInput = (input.tool_input ?? {}) as Record<string, unknown>;
  const cwd = input.cwd || cfg.mount;

  let cls;
  try {
    cls = classify({ toolName, toolInput, cwd });
  } catch (e) {
    logLine(cfg, { tool: toolName, tier: "deny", decision: "deny", reason: "classify-error", err: String(e) });
    return out("deny", "Agentic gate: could not classify this action, refusing for safety.");
  }

  if (cls.tier === "silent") {
    logLine(cfg, { tool: toolName, tier: "silent", decision: "allow", reason: cls.reason });
    return out("allow", `Agentic gate (silent): ${cls.reason}`);
  }

  if (cls.tier === "deny") {
    logLine(cfg, { tool: toolName, tier: "deny", decision: "deny", reason: cls.reason });
    return out("deny", `Agentic gate refused: ${cls.reason}`);
  }

  // tier === "ask": write a request and block for the human decision.
  const id = cfg.genId();
  const summary = summarize(toolName, toolInput);
  const req: ApprovalRequest = {
    id,
    threadId: cfg.threadId,
    chatId: cfg.chatId,
    tool: toolName,
    summary,
    args: toolInput,
    argsHash: hashArgs(toolInput),
    reason: cls.reason,
    reversibility: cls.reversibility,
    blastRadius: cls.blastRadius,
    createdAt: new Date(cfg.nowMs()).toISOString(),
    expiresAt: cfg.nowMs() + cfg.expiryMs,
    status: "pending",
  };
  try {
    writeRequest(cfg.approvalsDir, req);
  } catch (e) {
    logLine(cfg, { tool: toolName, tier: "ask", decision: "deny", reason: "request-write-failed", err: String(e) });
    return out("deny", "Agentic gate: couldn't reach the approval channel, refusing for safety.");
  }

  const startedMs = cfg.nowMs();
  while (cfg.nowMs() < req.expiresAt) {
    if (decisionExists(cfg.approvalsDir, id)) {
      const d = readDecision(cfg.approvalsDir, id);
      const waited = cfg.nowMs() - startedMs;
      if (!d) { cfg.sleep(cfg.pollMs); continue; } // half-written; re-poll
      cleanup(cfg.approvalsDir, id);
      if (d.decision === "allow") {
        logLine(cfg, { id, tool: toolName, tier: "ask", decision: "allow", waited_ms: waited });
        return out("allow", `Approved: ${cls.reason}`);
      }
      if (d.decision === "edit" && d.updatedArgs) {
        logLine(cfg, { id, tool: toolName, tier: "ask", decision: "edit", waited_ms: waited });
        return out("allow", "Approved with edited parameters.", d.updatedArgs as Record<string, unknown>);
      }
      // deny (or edit with no args → treat as deny)
      logLine(cfg, { id, tool: toolName, tier: "ask", decision: "deny", waited_ms: waited, reason: d.reason });
      return out("deny", d.reason ? `Rejected: ${d.reason}` : "Rejected by user.");
    }
    cfg.sleep(cfg.pollMs);
  }

  // Expired with no decision.
  cleanup(cfg.approvalsDir, id);
  logLine(cfg, { id, tool: toolName, tier: "ask", decision: "deny", reason: "expired" });
  return out("deny", "Approval request timed out — no response. Re-ask if you still want this.");
}

/** A short, phone-readable one-liner describing the action for the card. */
export function summarize(toolName: string, input: Record<string, unknown>): string {
  if (toolName === "Bash" && typeof input.command === "string") return input.command.slice(0, 200);
  for (const k of ["file_path", "notebook_path", "path", "url"]) {
    if (typeof input[k] === "string") return `${toolName}: ${(input[k] as string).slice(0, 160)}`;
  }
  if (toolName.startsWith("mcp__")) {
    const compact = JSON.stringify(input);
    return `${toolName} ${compact.length > 160 ? compact.slice(0, 160) + "…" : compact}`;
  }
  return toolName;
}

// ── main: wire real env + stdin, fail closed on anything unexpected ───────────
function readStdin(): string {
  try { return readFileSync(0, "utf8"); } catch { return ""; }
}

function configFromEnv(): HookConfig {
  const e = process.env;
  return {
    approvalsDir: e.AGENTIC_APPROVALS_DIR ?? "",
    mount: e.AGENTIC_MOUNT ?? process.cwd(),
    threadId: e.AGENTIC_THREAD_ID ?? "dm",
    chatId: Number(e.AGENTIC_CHAT_ID ?? "0"),
    expiryMs: Number(e.AGENTIC_EXPIRY_MS ?? "240000"),
    pollMs: Number(e.AGENTIC_POLL_MS ?? "1000"),
    logFile: e.AGENTIC_LOG_FILE || undefined,
    nowMs: () => Date.now(),
    sleep: (ms: number) => { Bun.sleepSync(ms); },
    genId: () => randomUUID().slice(0, 8),
  };
}

function isMain(): boolean {
  // Bun sets import.meta.main when run as the entrypoint.
  return typeof (import.meta as unknown as { main?: boolean }).main === "boolean"
    ? (import.meta as unknown as { main: boolean }).main
    : false;
}

if (isMain()) {
  let result: HookOutput;
  try {
    const cfg = configFromEnv();
    if (!cfg.approvalsDir || !Number.isFinite(cfg.chatId) || cfg.chatId === 0) {
      result = out("deny", "Agentic gate misconfigured (no approval channel) — refusing for safety.");
    } else {
      const raw = readStdin();
      let input: HookInput = {};
      try { input = JSON.parse(raw) as HookInput; } catch { /* empty → fail closed below */ }
      result = input.tool_name
        ? decide(input, cfg)
        : out("deny", "Agentic gate: unreadable tool call — refusing for safety.");
    }
  } catch (e) {
    result = out("deny", `Agentic gate internal error — refusing for safety. (${e instanceof Error ? e.message : String(e)})`);
  }
  process.stdout.write(JSON.stringify(result));
  process.exit(0);
}
