/**
 * Tests for the file-access (Full Disk Access) self-probe. P6c made the agent
 * launchd-direct, so it doesn't inherit Pager.app's TCC grants — the poller
 * (which runs in the real launchd TCC context) probes whether it can read the
 * TCC-protected user folders and records the result for the Pager onboarding UI.
 *
 * macOS gates Documents / Desktop / Downloads separately, and a per-folder
 * grant covers only one — so probing all of them reflects what the user hits
 * (the agent's bun having just the Documents grant still gets prompted for the
 * others). protected_ok is true only when EVERY probed folder is readable.
 *
 * The classifier is pure over an injected reader: a reader that throws (EPERM)
 * marks that folder not-ok, without needing a real protected directory.
 */
import { describe, expect, test } from "bun:test";
import { probeFileAccess } from "./file-access-probe";

const eperm = (): never => {
  const e: NodeJS.ErrnoException = new Error("EPERM: operation not permitted");
  e.code = "EPERM";
  throw e;
};

describe("probeFileAccess", () => {
  test("all folders readable → protected_ok true", () => {
    const s = probeFileAccess(["/a/Documents", "/a/Desktop", "/a/Downloads"], () => {});
    expect(s.protected_ok).toBe(true);
    expect(s.probed.map((p) => p.ok)).toEqual([true, true, true]);
  });

  test("one folder blocked (EPERM) → protected_ok false, that folder not ok", () => {
    const s = probeFileAccess(["/a/Documents", "/a/Desktop"], (p) => {
      if (p.endsWith("Desktop")) eperm();
    });
    expect(s.protected_ok).toBe(false);
    expect(s.probed.find((p) => p.path === "/a/Documents")?.ok).toBe(true);
    expect(s.probed.find((p) => p.path === "/a/Desktop")?.ok).toBe(false);
  });

  test("checked_at is an ISO-8601 timestamp", () => {
    const s = probeFileAccess(["/p"], () => {});
    expect(Number.isNaN(Date.parse(s.checked_at))).toBe(false);
    expect(s.checked_at).toContain("T");
  });

  test("empty path list → protected_ok false (nothing proven)", () => {
    const s = probeFileAccess([], () => {});
    expect(s.protected_ok).toBe(false);
    expect(s.probed).toEqual([]);
  });
});
