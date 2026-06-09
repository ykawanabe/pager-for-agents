/**
 * Approval store — the durable file-IPC contract between the gate hook (inside the
 * agentic executor's claude child) and the poller.
 *
 *   hook  → writeRequest(<id>.request.json)  then polls for <id>.decision.json
 *   poller→ listPending() → sends Telegram card → on button tap writeDecision(<id>.decision.json)
 *   hook  → readDecision() resolves → returns allow/deny (+ updatedInput) to claude
 *
 * All writes are atomic (temp + rename) so a crash mid-write never yields a half file.
 * Args are hashed with a stable (sorted-key) serialization so the poller-side approval
 * can be bound to the exact params; if the model re-plans and the args drift, the hook
 * re-asks instead of running a stale-approved action.
 *
 * No global state, no env reads — callers pass the approvals directory explicitly, so
 * this module is trivially unit-testable.
 */

import { createHash } from "node:crypto";
import {
  mkdirSync, writeFileSync, renameSync, readFileSync, readdirSync, existsSync, unlinkSync,
} from "node:fs";
import { join } from "node:path";

export type Tier = "silent" | "ask" | "deny";
export type Decision = "allow" | "deny" | "edit";

export interface ApprovalRequest {
  readonly id: string;
  /** Topic to deliver the card to: "dm" or a numeric thread id as string. */
  readonly threadId: string;
  readonly chatId: number;
  readonly tool: string;
  /** Short one-line action summary for the card (e.g. "git push origin main"). */
  readonly summary: string;
  readonly args: Readonly<Record<string, unknown>>;
  readonly argsHash: string;
  readonly reason: string;
  readonly reversibility: string;
  readonly blastRadius: string;
  readonly createdAt: string;
  /** Epoch ms after which the hook gives up and denies. */
  readonly expiresAt: number;
  /** "pending" until the poller renders the card, then "sent" (so it's not re-sent). */
  status: "pending" | "sent";
}

export interface ApprovalDecision {
  readonly decision: Decision;
  readonly at: string;
  /** For "edit": the corrected tool input to run instead. */
  readonly updatedArgs?: Readonly<Record<string, unknown>>;
  /** For "deny": a reason fed back to the model so it can adapt. */
  readonly reason?: string;
}

/** Deterministic JSON: object keys sorted recursively. Stable across runs. */
export function stableStringify(value: unknown): string {
  return JSON.stringify(sortDeep(value));
}
function sortDeep(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortDeep);
  if (v && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(v as Record<string, unknown>).sort()) {
      out[k] = sortDeep((v as Record<string, unknown>)[k]);
    }
    return out;
  }
  return v;
}

/** sha256 hex of the stable serialization of the tool args. */
export function hashArgs(args: unknown): string {
  return "sha256:" + createHash("sha256").update(stableStringify(args)).digest("hex").slice(0, 24);
}

export const requestPath = (dir: string, id: string): string => join(dir, `${id}.request.json`);
export const decisionPath = (dir: string, id: string): string => join(dir, `${id}.decision.json`);

function atomicWrite(path: string, data: string): void {
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, data, { mode: 0o600 });
  renameSync(tmp, path);
}

export function ensureDir(dir: string): void {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
}

export function writeRequest(dir: string, req: ApprovalRequest): void {
  ensureDir(dir);
  atomicWrite(requestPath(dir, req.id), JSON.stringify(req, null, 2));
}

export function readRequest(dir: string, id: string): ApprovalRequest | null {
  try { return JSON.parse(readFileSync(requestPath(dir, id), "utf8")) as ApprovalRequest; }
  catch { return null; }
}

export function writeDecision(dir: string, id: string, decision: ApprovalDecision): void {
  ensureDir(dir);
  atomicWrite(decisionPath(dir, id), JSON.stringify(decision, null, 2));
}

export function readDecision(dir: string, id: string): ApprovalDecision | null {
  try { return JSON.parse(readFileSync(decisionPath(dir, id), "utf8")) as ApprovalDecision; }
  catch { return null; }
}

export function decisionExists(dir: string, id: string): boolean {
  return existsSync(decisionPath(dir, id));
}

/** All request records on disk (pending or sent). Caller filters by status. */
export function listRequests(dir: string): ApprovalRequest[] {
  let names: string[];
  try { names = readdirSync(dir); } catch { return []; }
  const out: ApprovalRequest[] = [];
  for (const n of names) {
    if (!n.endsWith(".request.json")) continue;
    const id = n.slice(0, -".request.json".length);
    const r = readRequest(dir, id);
    if (r) out.push(r);
  }
  return out;
}

/** Mark a request "sent" (poller, after rendering the card) — idempotent rewrite. */
export function markSent(dir: string, id: string): void {
  const r = readRequest(dir, id);
  if (!r) return;
  if (r.status === "sent") return;
  writeRequest(dir, { ...r, status: "sent" });
}

/** Remove a resolved request + its decision (poller cleanup after the hook consumed it). */
export function cleanup(dir: string, id: string): void {
  for (const p of [requestPath(dir, id), decisionPath(dir, id)]) {
    try { unlinkSync(p); } catch { /* best effort */ }
  }
}
