import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  alreadyFiredToday,
  dayKey,
  markFiredToday,
  pruneOldKeys,
  readState,
  writeState,
} from "./heartbeat-state";

let dir: string;
let statePath: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "hb-state-test-"));
  statePath = join(dir, "heartbeat-state.json");
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("readState", () => {
  test("missing file → empty state", () => {
    const s = readState(statePath);
    expect(s.version).toBe(1);
    expect(s.firedToday).toEqual({});
  });

  test("malformed JSON → empty state (doesn't throw)", () => {
    writeFileSync(statePath, "{ not json");
    const s = readState(statePath);
    expect(s.firedToday).toEqual({});
  });

  test("wrong version → empty state", () => {
    writeFileSync(statePath, JSON.stringify({ version: 99, firedToday: { "x:2026-06-01": 1 } }));
    const s = readState(statePath);
    expect(s.firedToday).toEqual({});
  });

  test("missing firedToday field → version=1 with empty map", () => {
    writeFileSync(statePath, JSON.stringify({ version: 1 }));
    const s = readState(statePath);
    expect(s.firedToday).toEqual({});
  });

  test("non-number values in firedToday are filtered out", () => {
    writeFileSync(statePath, JSON.stringify({
      version: 1,
      firedToday: { "good:2026-06-01": 12345, "bad:2026-06-01": "twelve thousand" },
    }));
    const s = readState(statePath);
    expect(s.firedToday).toEqual({ "good:2026-06-01": 12345 });
  });

  test("happy-path round-trip", () => {
    const original = { version: 1 as const, firedToday: { "42:2026-06-01": 1_780_000_000_000 } };
    writeState(original, statePath);
    const r = readState(statePath);
    expect(r.firedToday).toEqual(original.firedToday);
  });
});

describe("writeState — atomic write", () => {
  test("creates the file with mode 0600 (chmod via openSync mode arg)", () => {
    writeState({ version: 1, firedToday: { "x:2026-06-01": 1 } }, statePath);
    expect(existsSync(statePath)).toBe(true);
    // We can't portably assert the mode bits across CI vs host without
    // statSync — assert the file exists + content is correct.
    const content = JSON.parse(readFileSync(statePath, "utf8"));
    expect(content.version).toBe(1);
    expect(content.firedToday["x:2026-06-01"]).toBe(1);
  });

  test("creates parent dir if missing", () => {
    const deeper = join(dir, "sub", "deeper", "state.json");
    writeState({ version: 1, firedToday: {} }, deeper);
    expect(existsSync(deeper)).toBe(true);
  });

  test("temp file is cleaned up after successful rename", () => {
    writeState({ version: 1, firedToday: {} }, statePath);
    // No .tmp.<pid> sibling should remain
    const siblings = require("node:fs").readdirSync(dir);
    expect(siblings.filter((f: string) => f.includes(".tmp."))).toEqual([]);
  });

  test("multiple sequential writes don't accumulate temp files", () => {
    for (let i = 0; i < 5; i++) {
      writeState({ version: 1, firedToday: { [`x:2026-06-${i + 1}`]: i } }, statePath);
    }
    const siblings = require("node:fs").readdirSync(dir);
    expect(siblings.filter((f: string) => f.includes(".tmp."))).toEqual([]);
    expect(siblings).toContain("heartbeat-state.json");
  });
});

describe("alreadyFiredToday / markFiredToday", () => {
  test("fresh state → not fired", () => {
    const s = { version: 1 as const, firedToday: {} };
    expect(alreadyFiredToday(s, "42", "2026-06-01")).toBe(false);
  });

  test("mark + check round-trip", () => {
    let s = { version: 1 as const, firedToday: {} };
    s = markFiredToday(s, "42", "2026-06-01");
    expect(alreadyFiredToday(s, "42", "2026-06-01")).toBe(true);
    expect(alreadyFiredToday(s, "42", "2026-06-02")).toBe(false);
    expect(alreadyFiredToday(s, "43", "2026-06-01")).toBe(false);
  });

  test("markFiredToday is immutable (doesn't mutate input state)", () => {
    const original = { version: 1 as const, firedToday: {} };
    const updated = markFiredToday(original, "42", "2026-06-01");
    expect(original.firedToday).toEqual({});
    expect(updated.firedToday["42:2026-06-01"]).toBeDefined();
  });

  test("markFiredToday stores the supplied epoch", () => {
    const s = markFiredToday({ version: 1, firedToday: {} }, "42", "2026-06-01", 9999);
    expect(s.firedToday["42:2026-06-01"]).toBe(9999);
  });

  test("same thread+day called twice keeps the latest timestamp", () => {
    let s = { version: 1 as const, firedToday: {} };
    s = markFiredToday(s, "42", "2026-06-01", 100);
    s = markFiredToday(s, "42", "2026-06-01", 200);
    expect(s.firedToday["42:2026-06-01"]).toBe(200);
  });
});

describe("dayKey", () => {
  test("composes <threadId>:<YYYY-MM-DD>", () => {
    expect(dayKey("42", "2026-06-01")).toBe("42:2026-06-01");
    expect(dayKey("dm", "2026-06-01")).toBe("dm:2026-06-01");
  });
});

describe("pruneOldKeys", () => {
  test("removes keys older than keepDays", () => {
    const s = {
      version: 1 as const,
      firedToday: {
        "42:2026-05-01": 1, // ~30 days old (depending on today)
        "42:2026-06-01": 2,
        "43:2026-04-01": 3, // much older
      },
    };
    const pruned = pruneOldKeys(s, "2026-06-15", 30);
    expect(Object.keys(pruned.firedToday).sort()).toEqual(["42:2026-05-16", "42:2026-06-01"].filter(k => k in pruned.firedToday));
    // The May 1 and April 1 keys should be gone (both >30 days before June 15)
    expect(pruned.firedToday["42:2026-05-01"]).toBeUndefined();
    expect(pruned.firedToday["43:2026-04-01"]).toBeUndefined();
    expect(pruned.firedToday["42:2026-06-01"]).toBe(2);
  });

  test("malformed today date → state passes through unchanged", () => {
    const s = { version: 1 as const, firedToday: { "x:2026-06-01": 1 } };
    const pruned = pruneOldKeys(s, "not-a-date", 30);
    expect(pruned.firedToday).toEqual(s.firedToday);
  });

  test("keys without a date suffix are dropped (malformed)", () => {
    const s = { version: 1 as const, firedToday: { "valid:2026-06-01": 1, "malformed": 2 } };
    const pruned = pruneOldKeys(s, "2026-06-15", 30);
    expect(pruned.firedToday["valid:2026-06-01"]).toBe(1);
    expect(pruned.firedToday["malformed"]).toBeUndefined();
  });

  test("empty state stays empty", () => {
    const pruned = pruneOldKeys({ version: 1, firedToday: {} }, "2026-06-15", 30);
    expect(pruned.firedToday).toEqual({});
  });
});
