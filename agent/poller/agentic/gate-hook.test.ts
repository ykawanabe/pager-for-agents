import { test, expect, describe, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { decide, summarize, type HookConfig, type HookInput } from "./gate-hook";
import { writeDecision, readRequest, decisionExists } from "./approval-store";

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "gate-")); });
afterEach(() => { try { rmSync(dir, { recursive: true, force: true }); } catch {} });

const MOUNT = "/work/proj";
const cfg = (over: Partial<HookConfig> = {}): HookConfig => ({
  approvalsDir: dir, mount: MOUNT, threadId: "260", chatId: 123,
  expiryMs: 100_000, pollMs: 0, logFile: undefined,
  nowMs: () => 1000, sleep: () => {}, genId: () => "fixed1", ...over,
});
const input = (tool_name: string, tool_input: Record<string, unknown> = {}, cwd = MOUNT): HookInput =>
  ({ tool_name, tool_input, cwd });

const dec = (o: ReturnType<typeof decide>) => o.hookSpecificOutput.permissionDecision;

describe("silent / deny short-circuit (no request written)", () => {
  test("Read → allow", () => {
    expect(dec(decide(input("Read", { file_path: "a.ts" }), cfg()))).toBe("allow");
    expect(decisionExists(dir, "fixed1")).toBe(false);
    expect(readRequest(dir, "fixed1")).toBeNull();
  });
  test("git status → allow", () => expect(dec(decide(input("Bash", { command: "git status" }), cfg()))).toBe("allow"));
  test("sudo → deny, no request", () => {
    expect(dec(decide(input("Bash", { command: "sudo rm -rf /" }), cfg()))).toBe("deny");
    expect(readRequest(dir, "fixed1")).toBeNull();
  });
});

describe("ask → blocks then resolves on the decision file", () => {
  test("pre-approved → allow + request written then cleaned up", () => {
    writeDecision(dir, "fixed1", { decision: "allow", at: "t" });
    const o = decide(input("Bash", { command: "git push origin main" }), cfg());
    expect(dec(o)).toBe("allow");
    // request + decision cleaned up after consuming
    expect(readRequest(dir, "fixed1")).toBeNull();
    expect(decisionExists(dir, "fixed1")).toBe(false);
  });

  test("rejected → deny with reason", () => {
    writeDecision(dir, "fixed1", { decision: "deny", at: "t", reason: "not now" });
    const o = decide(input("Bash", { command: "gh pr merge 42" }), cfg());
    expect(dec(o)).toBe("deny");
    expect(o.hookSpecificOutput.permissionDecisionReason).toContain("not now");
  });

  test("edited → allow + updatedInput carries corrected args", () => {
    writeDecision(dir, "fixed1", { decision: "edit", at: "t", updatedArgs: { command: "git push --dry-run origin main" } });
    const o = decide(input("Bash", { command: "git push origin main" }), cfg());
    expect(dec(o)).toBe("allow");
    expect(o.hookSpecificOutput.updatedInput).toEqual({ command: "git push --dry-run origin main" });
  });

  test("edit with no updatedArgs → treated as deny", () => {
    writeDecision(dir, "fixed1", { decision: "edit", at: "t" });
    expect(dec(decide(input("Bash", { command: "git push" }), cfg()))).toBe("deny");
  });

  test("expiry (no decision) → deny + request cleaned up", () => {
    // expiryMs 0 ⇒ expiresAt == now ⇒ loop condition false immediately ⇒ expire
    const o = decide(input("mcp__telegram-user__send_message", { text: "hi" }), cfg({ expiryMs: 0 }));
    expect(dec(o)).toBe("deny");
    expect(o.hookSpecificOutput.permissionDecisionReason).toContain("timed out");
    expect(readRequest(dir, "fixed1")).toBeNull();
  });

  test("request record captures the recommendation packet fields", () => {
    // long expiry, no decision yet — inspect the written request before it would expire.
    // Use a nowMs that stays below expiresAt and a sleep that throws to break the loop
    // after the first poll so we can read the on-disk request.
    let polled = false;
    const c = cfg({
      expiryMs: 100_000,
      sleep: () => { if (polled) throw new Error("stop"); polled = true; },
    });
    expect(() => decide(input("Bash", { command: "git push origin main" }), c)).toThrow("stop");
    const r = readRequest(dir, "fixed1");
    expect(r?.tool).toBe("Bash");
    expect(r?.summary).toBe("git push origin main");
    expect(r?.reversibility).toBe("outward");
    expect(r?.argsHash).toMatch(/^sha256:/);
    expect(r?.threadId).toBe("260");
    expect(r?.chatId).toBe(123);
  });
});

describe("fail-closed", () => {
  test("missing tool_name (handled by main, but decide on empty) classifies unknown → ask path", () => {
    // decide with empty tool_name → classify("") → unknown → ask → writes a request,
    // then expires (no decision) → deny. Proves it never silently allows an unknown.
    const o = decide({ tool_name: "", tool_input: {} }, cfg({ expiryMs: 0 }));
    expect(dec(o)).toBe("deny");
  });
});

describe("summarize", () => {
  test("bash command", () => expect(summarize("Bash", { command: "git push" })).toBe("git push"));
  test("edit path", () => expect(summarize("Edit", { file_path: "/a/b.ts" })).toContain("/a/b.ts"));
  test("mcp compact", () => expect(summarize("mcp__x__send", { text: "hi" })).toContain("mcp__x__send"));
});
