import { test, expect, describe } from "bun:test";
import { renderApprovalCard, approvalCallbackData, approvalButtonRows, parseApprovalCallback, applyEdit } from "./cards";
import { type ApprovalRequest } from "./approval-store";

const req: ApprovalRequest = {
  id: "38effd45", threadId: "260", chatId: 1, tool: "Bash", summary: "git push origin main",
  args: { command: "git push origin main" }, argsHash: "sha256:x", reason: "git push — publishes shared history.",
  reversibility: "outward", blastRadius: "remote / shared branch", createdAt: "t", expiresAt: 1, status: "pending",
};

describe("renderApprovalCard", () => {
  const card = renderApprovalCard(req);
  test("shows summary, why, risk", () => {
    expect(card).toContain("git push origin main");
    expect(card).toContain("Why: git push");
    expect(card).toContain("Risk: outward · remote / shared branch");
  });
});

describe("callback data / parse round-trip", () => {
  test("encode/decode each verb", () => {
    for (const v of ["allow", "deny", "edit"] as const) {
      const data = approvalCallbackData(req.id, v);
      expect(data.length).toBeLessThanOrEqual(64);
      expect(parseApprovalCallback(data)).toEqual({ id: req.id, verb: v });
    }
  });
  test("rows have all three actions", () => {
    const rows = approvalButtonRows(req.id);
    const datas = rows.flat().map((b) => b.callback_data);
    expect(datas).toEqual(["apv:38effd45:allow", "apv:38effd45:edit", "apv:38effd45:deny"]);
  });
  test("rejects foreign / malformed callback data", () => {
    expect(parseApprovalCallback("ans:260:Yes")).toBeNull();
    expect(parseApprovalCallback("apv:")).toBeNull();
    expect(parseApprovalCallback("apv:abc")).toBeNull();
    expect(parseApprovalCallback("apv:abc:frobnicate")).toBeNull();
  });
});

describe("applyEdit", () => {
  test("Bash → replaces command", () =>
    expect(applyEdit("Bash", { command: "git push", description: "d" }, "git push --dry-run"))
      .toEqual({ command: "git push --dry-run", description: "d" }));
  test("Edit tool → replaces file_path-ish primary param, keeps rest", () =>
    expect(applyEdit("Write", { file_path: "/a", content: "x" }, "/b"))
      .toEqual({ file_path: "/b", content: "x" }));
  test("mcp send → replaces text", () =>
    expect(applyEdit("mcp__tg__send_message", { chat: 1, text: "old" }, "new"))
      .toEqual({ chat: 1, text: "new" }));
  test("unknown shape → falls back to command", () =>
    expect(applyEdit("Weird", { a: 1 }, "x")).toEqual({ a: 1, command: "x" }));
});
