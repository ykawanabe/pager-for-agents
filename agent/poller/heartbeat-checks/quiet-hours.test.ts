import { describe, expect, test } from "bun:test";
import {
  digestTimeReached,
  isInQuietHours,
  minuteOfDayInTz,
  parseHhMm,
  todayInTz,
} from "./quiet-hours";

// Helpers — construct UTC moments so the test is portable across CI TZs.
function utc(y: number, mo: number, d: number, h: number, mi: number): Date {
  return new Date(Date.UTC(y, mo - 1, d, h, mi));
}

describe("parseHhMm", () => {
  test("valid HH:MM", () => {
    expect(parseHhMm("00:00")).toBe(0);
    expect(parseHhMm("09:00")).toBe(540);
    expect(parseHhMm("23:59")).toBe(23 * 60 + 59);
    expect(parseHhMm("7:30")).toBe(7 * 60 + 30); // 1-digit hour accepted
  });

  test("malformed returns null", () => {
    expect(parseHhMm("")).toBeNull();
    expect(parseHhMm("9")).toBeNull();
    expect(parseHhMm("9am")).toBeNull();
    expect(parseHhMm("24:00")).toBeNull();
    expect(parseHhMm("12:60")).toBeNull();
    expect(parseHhMm("-1:00")).toBeNull();
  });
});

describe("todayInTz", () => {
  test("UTC midnight maps to the right local date in JST and PT", () => {
    // 2026-06-01T15:00:00Z = 2026-06-02 00:00 JST = 2026-06-01 08:00 PT
    const m = utc(2026, 6, 1, 15, 0);
    expect(todayInTz(m, "Asia/Tokyo")).toBe("2026-06-02");
    expect(todayInTz(m, "America/Los_Angeles")).toBe("2026-06-01");
  });

  test("UTC late evening rolls forward in JST but not in UTC", () => {
    // 2026-06-01T23:00:00Z = 2026-06-02 08:00 JST = 2026-06-01 23:00 UTC
    const m = utc(2026, 6, 1, 23, 0);
    expect(todayInTz(m, "UTC")).toBe("2026-06-01");
    expect(todayInTz(m, "Asia/Tokyo")).toBe("2026-06-02");
  });

  test("unknown tz falls back to UTC date (defensive, no throw)", () => {
    const m = utc(2026, 6, 1, 23, 0);
    expect(todayInTz(m, "Not/A_Real_Zone")).toBe("2026-06-01");
  });
});

describe("minuteOfDayInTz", () => {
  test("UTC moment translates correctly to JST minute-of-day", () => {
    // 2026-06-01T00:30:00Z = 2026-06-01 09:30 JST = 9*60+30 = 570
    expect(minuteOfDayInTz(utc(2026, 6, 1, 0, 30), "Asia/Tokyo")).toBe(570);
  });

  test("midnight in tz", () => {
    // 2026-06-01T15:00:00Z = 2026-06-02 00:00 JST
    expect(minuteOfDayInTz(utc(2026, 6, 1, 15, 0), "Asia/Tokyo")).toBe(0);
  });

  test("unknown tz falls back to UTC clock", () => {
    expect(minuteOfDayInTz(utc(2026, 6, 1, 14, 30), "Not/A_Zone")).toBe(14 * 60 + 30);
  });
});

describe("isInQuietHours", () => {
  test("null window → never quiet", () => {
    expect(isInQuietHours(utc(2026, 6, 1, 0, 0), null, "UTC")).toBe(false);
    expect(isInQuietHours(utc(2026, 6, 1, 0, 0), undefined, "UTC")).toBe(false);
  });

  test("non-wrapping window (13:00–17:00 UTC)", () => {
    const w = { start: "13:00", end: "17:00" };
    expect(isInQuietHours(utc(2026, 6, 1, 13, 0), w, "UTC")).toBe(true);  // boundary in
    expect(isInQuietHours(utc(2026, 6, 1, 15, 0), w, "UTC")).toBe(true);
    expect(isInQuietHours(utc(2026, 6, 1, 16, 59), w, "UTC")).toBe(true);
    expect(isInQuietHours(utc(2026, 6, 1, 17, 0), w, "UTC")).toBe(false); // boundary out
    expect(isInQuietHours(utc(2026, 6, 1, 12, 59), w, "UTC")).toBe(false);
  });

  test("wrap-midnight window (23:00–07:00 UTC, common 'sleep')", () => {
    const w = { start: "23:00", end: "07:00" };
    expect(isInQuietHours(utc(2026, 6, 1, 23, 0), w, "UTC")).toBe(true);  // start
    expect(isInQuietHours(utc(2026, 6, 1, 23, 30), w, "UTC")).toBe(true); // late-night
    expect(isInQuietHours(utc(2026, 6, 1, 2, 0), w, "UTC")).toBe(true);   // overnight
    expect(isInQuietHours(utc(2026, 6, 1, 6, 59), w, "UTC")).toBe(true);  // pre-wake
    expect(isInQuietHours(utc(2026, 6, 1, 7, 0), w, "UTC")).toBe(false);  // wake
    expect(isInQuietHours(utc(2026, 6, 1, 12, 0), w, "UTC")).toBe(false); // midday
  });

  test("wrap-midnight window evaluated in tz (23:00–07:00 JST)", () => {
    const w = { start: "23:00", end: "07:00" };
    // 14:00 UTC = 23:00 JST → in (start)
    expect(isInQuietHours(utc(2026, 6, 1, 14, 0), w, "Asia/Tokyo")).toBe(true);
    // 03:00 UTC = 12:00 JST → out
    expect(isInQuietHours(utc(2026, 6, 1, 3, 0), w, "Asia/Tokyo")).toBe(false);
    // 21:00 UTC = 06:00 JST → in (pre-wake)
    expect(isInQuietHours(utc(2026, 6, 1, 21, 0), w, "Asia/Tokyo")).toBe(true);
  });

  test("degenerate start==end → never quiet (typo protection)", () => {
    const w = { start: "13:00", end: "13:00" };
    expect(isInQuietHours(utc(2026, 6, 1, 13, 0), w, "UTC")).toBe(false);
    expect(isInQuietHours(utc(2026, 6, 1, 0, 0), w, "UTC")).toBe(false);
  });

  test("malformed HH:MM → never quiet", () => {
    const w = { start: "garbage", end: "07:00" };
    expect(isInQuietHours(utc(2026, 6, 1, 2, 0), w, "UTC")).toBe(false);
  });
});

describe("digestTimeReached", () => {
  test("before target → false; at/after → true", () => {
    expect(digestTimeReached(utc(2026, 6, 1, 8, 59), "09:00", "UTC")).toBe(false);
    expect(digestTimeReached(utc(2026, 6, 1, 9, 0), "09:00", "UTC")).toBe(true);
    expect(digestTimeReached(utc(2026, 6, 1, 12, 0), "09:00", "UTC")).toBe(true);
  });

  test("respects tz", () => {
    // Target 09:00 JST = 00:00 UTC. 23:00 UTC is "08:00 next-day JST" → not yet.
    expect(digestTimeReached(utc(2026, 5, 31, 23, 0), "09:00", "Asia/Tokyo")).toBe(false);
    // 00:30 UTC = 09:30 JST → yes.
    expect(digestTimeReached(utc(2026, 6, 1, 0, 30), "09:00", "Asia/Tokyo")).toBe(true);
  });

  test("malformed target → false (defensive)", () => {
    expect(digestTimeReached(utc(2026, 6, 1, 12, 0), "garbage", "UTC")).toBe(false);
  });
});
