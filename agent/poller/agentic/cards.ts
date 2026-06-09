/**
 * Pure helpers for the approval card UX: the recommendation-packet text, the
 * inline-button rows + callback_data, callback parsing, and the Edit-apply.
 * No IO — unit-testable. The poller wires these to sendInlineKeyboard / onButtonPress.
 */

import type { ApprovalRequest } from "./approval-store";

export type ApprovalVerb = "allow" | "deny" | "edit";

/** Phone-readable recommendation packet (plain text — Telegram renders no markdown). */
export function renderApprovalCard(req: ApprovalRequest): string {
  return [
    "🤖 Approval needed",
    "",
    req.summary,
    "",
    `Why: ${req.reason}`,
    `Risk: ${req.reversibility} · ${req.blastRadius}`,
  ].join("\n");
}

/** callback_data for an approval button. Bot API caps callback_data at 64 bytes;
 *  the id is ~8 chars so `apv:<id>:edit` is well within budget. */
export function approvalCallbackData(id: string, verb: ApprovalVerb): string {
  return `apv:${id}:${verb}`.slice(0, 64);
}

export function approvalButtonRows(id: string): Array<Array<{ text: string; callback_data: string }>> {
  return [
    [{ text: "✅ Approve", callback_data: approvalCallbackData(id, "allow") }],
    [{ text: "✏️ Edit", callback_data: approvalCallbackData(id, "edit") }],
    [{ text: "🚫 Reject", callback_data: approvalCallbackData(id, "deny") }],
  ];
}

export function parseApprovalCallback(data: string): { id: string; verb: ApprovalVerb } | null {
  if (!data.startsWith("apv:")) return null;
  const rest = data.slice(4);
  const ci = rest.indexOf(":");
  if (ci < 0) return null;
  const id = rest.slice(0, ci);
  const verb = rest.slice(ci + 1);
  if (verb !== "allow" && verb !== "deny" && verb !== "edit") return null;
  if (!id) return null;
  return { id, verb };
}

/** Build the edited tool input from the user's corrected free-text. Replaces the
 *  tool's primary parameter (the command for Bash; otherwise the first known
 *  string field), leaving the rest of the args intact. */
export function applyEdit(tool: string, args: Readonly<Record<string, unknown>>, correctedText: string): Record<string, unknown> {
  if (tool === "Bash") return { ...args, command: correctedText };
  for (const k of ["file_path", "notebook_path", "path", "url", "text", "content", "query"]) {
    if (k in args) return { ...args, [k]: correctedText };
  }
  return { ...args, command: correctedText };
}
