import { describe, expect, test } from "bun:test";
import { detectMissedFire, shouldFire, type ShouldFireInput } from "./scheduler";
import { markFiredToday, type HeartbeatState } from "./heartbeat-state";

const TZ = "Asia/Tokyo";
const EMPTY: HeartbeatState = { version: 1, firedToday: {} };

function utc(y: number, mo: number, d: number, h: number, mi: number): Date {
  return new Date(Date.UTC(y, mo - 1, d, h, mi));
}

function input(overrides: Partial<ShouldFireInput> = {}): ShouldFireInput {
  return {
    state: EMPTY,
    threadId: "42",
    digestTime: "09:00",
    quietHours: null,
    timezone: TZ,
    isInFlight: () => false,
    isMidTurn: () => false,
    // 09:30 JST 2026-06-01 = 00:30 UTC 2026-06-01
    now: utc(2026, 6, 1, 0, 30),
    ...overrides,
  };
}

describe("detectMissedFire — silently-skipped day alert", () => {
  // 09:30 JST 2026-06-03; yesterday in JST = 2026-06-02
  const NOW = utc(2026, 6, 3, 0, 30);
  const miss = (state: HeartbeatState) =>
    detectMissedFire({ state, threadId: "dm", timezone: TZ, now: NOW });

  test("yesterday missed + older fire exists → returns yesterday's ymd", () => {
    const state = markFiredToday(EMPTY, "dm", "2026-06-01"); // fired the 1st, NOT the 2nd
    expect(miss(state)).toBe("2026-06-02");
  });

  test("yesterday fired → null", () => {
    let state = markFiredToday(EMPTY, "dm", "2026-06-01");
    state = markFiredToday(state, "dm", "2026-06-02");
    expect(miss(state)).toBe(null);
  });

  test("no older fire (first day after enabling) → null, no false alarm", () => {
    expect(miss(EMPTY)).toBe(null);
  });

  test("older fire on a DIFFERENT thread doesn't count → null", () => {
    const state = markFiredToday(EMPTY, "4915", "2026-06-01");
    expect(miss(state)).toBe(null);
  });

  test("marking the returned ymd makes the alert one-shot", () => {
    const state = markFiredToday(EMPTY, "dm", "2026-06-01");
    const ymd = miss(state);
    expect(ymd).toBe("2026-06-02");
    const marked = markFiredToday(state, "dm", ymd as string);
    expect(miss(marked)).toBe(null);
  });
});

describe("shouldFire — happy path", () => {
  test("fires when past digest time, not yet fired today, no quiet hours, idle", () => {
    const r = shouldFire(input());
    expect(r.fire).toBe(true);
    if (r.fire) expect(r.ymd).toBe("2026-06-01");
  });

  test("ymd is in the user's TZ, not UTC", () => {
    // 2026-06-01T15:00:00Z = 2026-06-02 00:00 JST → ymd should be 2026-06-02
    // But digestTime is 09:00, so at 15:00Z (00:00 JST) digestTime hasn't been
    // reached. Use a later moment to actually fire.
    // 2026-06-02T00:30:00Z = 2026-06-02 09:30 JST → past 09:00, fires for 2026-06-02
    const r = shouldFire(input({ now: utc(2026, 6, 2, 0, 30) }));
    expect(r.fire).toBe(true);
    if (r.fire) expect(r.ymd).toBe("2026-06-02");
  });
});

describe("shouldFire — skip reasons (priority order)", () => {
  test("already-fired skip wins over all other gates", () => {
    let state = EMPTY;
    state = markFiredToday(state, "42", "2026-06-01");
    const r = shouldFire(input({
      state,
      isInFlight: () => true,
      isMidTurn: () => true,
      quietHours: { start: "23:00", end: "07:00" }, // also currently quiet
    }));
    expect(r.fire).toBe(false);
    if (!r.fire) expect(r.reason).toBe("already-fired");
  });

  test("not-yet when before digest time (08:59 JST = 23:59 UTC prior day)", () => {
    // 2026-05-31T23:59Z = 2026-06-01 08:59 JST → before 09:00 fire time
    const r = shouldFire(input({ now: utc(2026, 5, 31, 23, 59) }));
    expect(r.fire).toBe(false);
    if (!r.fire) expect(r.reason).toBe("not-yet");
  });

  test("quiet-hours skip when past digest time but inside the quiet window", () => {
    // 22:00 JST = 13:00 UTC. Quiet window 21:00 - 06:00 (wraps), so inside.
    const r = shouldFire(input({
      now: utc(2026, 6, 1, 13, 0),
      quietHours: { start: "21:00", end: "06:00" },
    }));
    expect(r.fire).toBe(false);
    if (!r.fire) expect(r.reason).toBe("quiet-hours");
  });

  test("quiet-hours DEFERS — fires when window ends if still not-fired-today", () => {
    // 06:30 JST = 21:30 UTC prior day. Window 21:00 - 06:00 has just ended.
    const r = shouldFire(input({
      now: utc(2026, 5, 31, 21, 30),
      quietHours: { start: "21:00", end: "06:00" },
    }));
    // 21:30 UTC = 06:30 JST → after window, but digestTime is 09:00 → not-yet.
    // Confirms: quiet-hours doesn't poison the state, the next gate (not-yet
    // or fire) runs normally once window ends.
    expect(r.fire).toBe(false);
    if (!r.fire) expect(r.reason).toBe("not-yet");
  });

  test("in-flight skip", () => {
    const r = shouldFire(input({ isInFlight: () => true }));
    expect(r.fire).toBe(false);
    if (!r.fire) expect(r.reason).toBe("in-flight");
  });

  test("user-busy skip when interactive bot is mid-turn", () => {
    const r = shouldFire(input({ isMidTurn: () => true }));
    expect(r.fire).toBe(false);
    if (!r.fire) expect(r.reason).toBe("user-busy");
  });

  test("in-flight wins over user-busy (closer to fire site = sooner gate)", () => {
    const r = shouldFire(input({ isInFlight: () => true, isMidTurn: () => true }));
    expect(r.fire).toBe(false);
    if (!r.fire) expect(r.reason).toBe("in-flight");
  });

  test("not-yet wins over quiet-hours (don't even consider quiet until time)", () => {
    // 08:30 JST = 23:30 UTC prior day. Also inside a 06:00-10:00 quiet window.
    const r = shouldFire(input({
      now: utc(2026, 5, 31, 23, 30),
      quietHours: { start: "06:00", end: "10:00" },
    }));
    expect(r.fire).toBe(false);
    if (!r.fire) expect(r.reason).toBe("not-yet");
  });
});

describe("shouldFire — DST + tz fixity", () => {
  test("per-thread isolation: same day, different thread, both can fire", () => {
    let state = EMPTY;
    state = markFiredToday(state, "42", "2026-06-01");
    const r = shouldFire(input({ state, threadId: "43" }));
    expect(r.fire).toBe(true);
  });

  test("crossing midnight in user TZ moves to a new ymd (digest fires once per local day)", () => {
    let state = EMPTY;
    state = markFiredToday(state, "42", "2026-06-01");
    // 2026-06-02T00:30:00Z = 2026-06-02 09:30 JST. New JST day → fires.
    const r = shouldFire(input({ state, now: utc(2026, 6, 2, 0, 30) }));
    expect(r.fire).toBe(true);
    if (r.fire) expect(r.ymd).toBe("2026-06-02");
  });

  test("LAX→NRT same wall-clock moment: ymd differs by tz", () => {
    // 2026-06-01T16:30:00Z = 09:30 PDT (LAX, UTC-7) = 01:30 next-day JST (NRT)
    const m = utc(2026, 6, 1, 16, 30);
    const ptResult = shouldFire(input({ now: m, timezone: "America/Los_Angeles" }));
    const jstResult = shouldFire(input({ now: m, timezone: "Asia/Tokyo" }));
    expect(ptResult.fire).toBe(true);
    if (ptResult.fire) expect(ptResult.ymd).toBe("2026-06-01");
    // In JST it's 01:30 — before 09:00 digest time → not-yet.
    expect(jstResult.fire).toBe(false);
    if (!jstResult.fire) expect(jstResult.reason).toBe("not-yet");
  });

  test("malformed digestTime → not-yet (defensive, doesn't fire on typo)", () => {
    const r = shouldFire(input({ digestTime: "garbage" }));
    expect(r.fire).toBe(false);
    if (!r.fire) expect(r.reason).toBe("not-yet");
  });

  test("malformed quietHours → treated as no window, fires normally", () => {
    const r = shouldFire(input({
      quietHours: { start: "garbage", end: "07:00" },
    }));
    expect(r.fire).toBe(true);
  });
});
