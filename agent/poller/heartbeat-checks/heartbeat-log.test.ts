import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { appendFireLog, type FireLogRecord } from "./heartbeat-log";

let dir: string;
let logPath: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "hb-log-test-"));
  logPath = join(dir, "log", "42.jsonl");
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function record(overrides: Partial<FireLogRecord> = {}): FireLogRecord {
  return {
    thread_id: "42",
    started_at: "2026-06-01T09:00:00.000Z",
    trigger: "daily",
    duration_ms: 1234,
    checks_ran: ["open-prs"],
    checks_errored: [],
    result: "sent",
    total_cost_usd: 0.01,
    skip_reason: null,
    ...overrides,
  };
}

describe("appendFireLog", () => {
  test("creates the log file and writes a single JSONL line", () => {
    appendFireLog(record(), logPath);
    expect(existsSync(logPath)).toBe(true);
    const content = readFileSync(logPath, "utf8");
    expect(content.endsWith("\n")).toBe(true);
    const lines = content.trim().split("\n");
    expect(lines).toHaveLength(1);
    const parsed = JSON.parse(lines[0]);
    expect(parsed.thread_id).toBe("42");
    expect(parsed.result).toBe("sent");
    expect(parsed.total_cost_usd).toBe(0.01);
  });

  test("multiple appends are append-only (existing lines preserved)", () => {
    appendFireLog(record({ started_at: "2026-06-01T09:00:00.000Z", total_cost_usd: 0.01 }), logPath);
    appendFireLog(record({ started_at: "2026-06-02T09:00:00.000Z", total_cost_usd: 0.02 }), logPath);
    appendFireLog(record({ started_at: "2026-06-03T09:00:00.000Z", total_cost_usd: 0.03 }), logPath);
    const lines = readFileSync(logPath, "utf8").trim().split("\n");
    expect(lines).toHaveLength(3);
    const costs = lines.map(l => JSON.parse(l).total_cost_usd);
    expect(costs).toEqual([0.01, 0.02, 0.03]);
  });

  test("creates parent dir if missing (heartbeat-log/<thread>.jsonl)", () => {
    const deeper = join(dir, "fresh", "subdir", "5.jsonl");
    appendFireLog(record({ thread_id: "5" }), deeper);
    expect(existsSync(deeper)).toBe(true);
  });

  test("captures skip_reason and error_message when present", () => {
    appendFireLog(record({
      result: "no-heartbeat-md",
      skip_reason: "no-heartbeat-md",
      error_message: "HEARTBEAT.md not found at /tmp/x/HEARTBEAT.md",
    }), logPath);
    const parsed = JSON.parse(readFileSync(logPath, "utf8").trim());
    expect(parsed.skip_reason).toBe("no-heartbeat-md");
    expect(parsed.error_message).toContain("not found");
  });

  test("captures checks_ran + checks_errored arrays verbatim", () => {
    appendFireLog(record({
      checks_ran: ["open-prs", "ci-red", "urgent-todos"],
      checks_errored: ["ci-red"],
    }), logPath);
    const parsed = JSON.parse(readFileSync(logPath, "utf8").trim());
    expect(parsed.checks_ran).toEqual(["open-prs", "ci-red", "urgent-todos"]);
    expect(parsed.checks_errored).toEqual(["ci-red"]);
  });

  test("each line is independently JSON-parseable (newline-delimited contract)", () => {
    for (let i = 0; i < 5; i++) {
      appendFireLog(record({ duration_ms: i * 1000 }), logPath);
    }
    const lines = readFileSync(logPath, "utf8").trim().split("\n");
    expect(lines).toHaveLength(5);
    for (const line of lines) {
      expect(() => JSON.parse(line)).not.toThrow();
    }
  });
});
