/**
 * Tests for the file-access (Full Disk Access) self-probe. P6c made the agent
 * launchd-direct, so it doesn't inherit Pager.app's TCC grants — the poller
 * (which runs in the real launchd TCC context) probes whether it can read a
 * protected folder and records the result for the Pager onboarding UI to read.
 *
 * The classifier is pure over an injected reader: a reader that throws (EPERM)
 * means no access; one that succeeds means access. That keeps it testable
 * without a real TCC-protected directory.
 */
import { describe, expect, test } from "bun:test";
import { probeFileAccess } from "./file-access-probe";

describe("probeFileAccess", () => {
  test("reader succeeds → protected_ok true", () => {
    const s = probeFileAccess("/Users/x/Documents", () => { /* readable */ });
    expect(s.protected_ok).toBe(true);
    expect(s.probed_path).toBe("/Users/x/Documents");
  });

  test("reader throws (EPERM) → protected_ok false", () => {
    const s = probeFileAccess("/Users/x/Documents", () => {
      const e: NodeJS.ErrnoException = new Error("EPERM: operation not permitted");
      e.code = "EPERM";
      throw e;
    });
    expect(s.protected_ok).toBe(false);
    expect(s.probed_path).toBe("/Users/x/Documents");
  });

  test("checked_at is an ISO-8601 timestamp", () => {
    const s = probeFileAccess("/p", () => {});
    // Round-trips through Date without becoming Invalid Date.
    expect(Number.isNaN(Date.parse(s.checked_at))).toBe(false);
    expect(s.checked_at).toContain("T");
  });
});
