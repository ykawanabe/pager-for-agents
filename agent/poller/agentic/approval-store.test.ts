import { test, expect, describe, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  hashArgs, stableStringify, writeRequest, readRequest, writeDecision, readDecision,
  decisionExists, listRequests, markSent, cleanup, requestPath, type ApprovalRequest,
} from "./approval-store";

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "apv-")); });
afterEach(() => { try { rmSync(dir, { recursive: true, force: true }); } catch {} });

const req = (id: string, over: Partial<ApprovalRequest> = {}): ApprovalRequest => ({
  id, threadId: "260", chatId: 123, tool: "Bash", summary: "git push origin main",
  args: { command: "git push origin main" }, argsHash: hashArgs({ command: "git push origin main" }),
  reason: "outward", reversibility: "outward", blastRadius: "remote", createdAt: "t",
  expiresAt: 9_999_999_999_999, status: "pending", ...over,
});

describe("hashArgs / stableStringify", () => {
  test("key order independent", () => {
    expect(hashArgs({ a: 1, b: 2 })).toBe(hashArgs({ b: 2, a: 1 }));
    expect(stableStringify({ b: 2, a: 1 })).toBe('{"a":1,"b":2}');
  });
  test("different args differ", () => {
    expect(hashArgs({ command: "git push" })).not.toBe(hashArgs({ command: "git push --force" }));
  });
  test("nested key order independent", () => {
    expect(hashArgs({ x: { p: 1, q: 2 } })).toBe(hashArgs({ x: { q: 2, p: 1 } }));
  });
});

describe("request round-trip", () => {
  test("write then read", () => {
    writeRequest(dir, req("a1"));
    const r = readRequest(dir, "a1");
    expect(r?.summary).toBe("git push origin main");
    expect(r?.status).toBe("pending");
  });
  test("read missing → null", () => expect(readRequest(dir, "nope")).toBeNull());
  test("atomic write leaves no tmp", () => {
    writeRequest(dir, req("a2"));
    expect(existsSync(requestPath(dir, "a2"))).toBe(true);
    expect(listRequests(dir).every(() => true)).toBe(true);
  });
});

describe("decision round-trip", () => {
  test("allow", () => {
    writeDecision(dir, "a1", { decision: "allow", at: "t" });
    expect(decisionExists(dir, "a1")).toBe(true);
    expect(readDecision(dir, "a1")?.decision).toBe("allow");
  });
  test("edit carries updatedArgs", () => {
    writeDecision(dir, "a1", { decision: "edit", at: "t", updatedArgs: { command: "git push --dry-run" } });
    expect(readDecision(dir, "a1")?.updatedArgs).toEqual({ command: "git push --dry-run" });
  });
  test("deny carries reason", () => {
    writeDecision(dir, "a1", { decision: "deny", at: "t", reason: "not now" });
    expect(readDecision(dir, "a1")?.reason).toBe("not now");
  });
  test("missing decision → null / false", () => {
    expect(readDecision(dir, "x")).toBeNull();
    expect(decisionExists(dir, "x")).toBe(false);
  });
});

describe("listRequests / markSent / cleanup", () => {
  test("lists only request files", () => {
    writeRequest(dir, req("a1"));
    writeRequest(dir, req("a2"));
    writeDecision(dir, "a1", { decision: "allow", at: "t" });
    const ids = listRequests(dir).map((r) => r.id).sort();
    expect(ids).toEqual(["a1", "a2"]);
  });
  test("markSent flips status idempotently", () => {
    writeRequest(dir, req("a1"));
    markSent(dir, "a1");
    expect(readRequest(dir, "a1")?.status).toBe("sent");
    markSent(dir, "a1"); // no throw
    expect(readRequest(dir, "a1")?.status).toBe("sent");
  });
  test("cleanup removes both files", () => {
    writeRequest(dir, req("a1"));
    writeDecision(dir, "a1", { decision: "allow", at: "t" });
    cleanup(dir, "a1");
    expect(readRequest(dir, "a1")).toBeNull();
    expect(decisionExists(dir, "a1")).toBe(false);
  });
  test("listRequests on missing dir → []", () => {
    expect(listRequests(join(dir, "nope"))).toEqual([]);
  });
});
