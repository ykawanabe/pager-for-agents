import { describe, expect, test } from "bun:test";
import { parseDays, parseTaskName, parseTime, parseTopic } from "./tasks-store";

describe("parseTaskName", () => {
  test("accepts letters/digits/._-", () => {
    expect(parseTaskName("morning-briefing")).toBe("morning-briefing");
    expect(parseTaskName("watch.X_v2")).toBe("watch.X_v2");
  });
  test("rejects names that would break paths or state keys", () => {
    for (const bad of ["", "a/b", "../etc", "a:b", "has space", "-leadingdash"]) {
      expect(() => parseTaskName(bad)).toThrow();
    }
  });
});

describe("parseTime", () => {
  test("normalizes to zero-padded HH:MM", () => {
    expect(parseTime("9:05")).toBe("09:05");
    expect(parseTime("06:57")).toBe("06:57");
  });
  test("rejects malformed/out-of-range", () => {
    for (const bad of ["", "24:00", "9", "9:5", "09:60", "garbage"]) {
      expect(() => parseTime(bad)).toThrow();
    }
  });
});

describe("parseDays", () => {
  test("presets", () => {
    expect(parseDays("daily")).toBe("daily");
    expect(parseDays("")).toBe("daily");
    expect(parseDays("weekdays")).toBe("weekdays");
  });
  test("explicit list, case-insensitive", () => {
    expect(parseDays("Mon,wed,FRI")).toEqual(["mon", "wed", "fri"]);
  });
  test("rejects unknown days", () => {
    expect(() => parseDays("mon,funday")).toThrow();
  });
});

describe("parseTopic", () => {
  test("dm and positive ids", () => {
    expect(parseTopic("dm")).toBe("dm");
    expect(parseTopic("4915")).toBe(4915);
  });
  test("rejects wildcard/zero/garbage", () => {
    for (const bad of ["*", "0", "-3", "abc", ""]) {
      expect(() => parseTopic(bad)).toThrow();
    }
  });
});
