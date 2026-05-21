/**
 * Tests for the P4 buttons-marker parser. claude (which no longer has the
 * mcp-telegram send_telegram tool) signals "offer these tap choices" by
 * emitting a marker line in its stream-json text. The poller parses it and
 * routes to ChatTransport.sendButtons instead of sendText.
 */
import { describe, expect, test } from "bun:test";
import { parseButtonsMarker } from "./buttons-marker";

describe("parseButtonsMarker", () => {
  test("no marker → body unchanged, buttons null", () => {
    const r = parseButtonsMarker("just a normal reply, no choices here");
    expect(r.buttons).toBeNull();
    expect(r.body).toBe("just a normal reply, no choices here");
  });

  test("JSON-array marker → labels parsed, marker stripped from body", () => {
    const r = parseButtonsMarker('Pick a path:\n[[buttons]]["Rebuild","Patch","Skip"]');
    expect(r.buttons).toEqual(["Rebuild", "Patch", "Skip"]);
    expect(r.body).toBe("Pick a path:");
  });

  test("pipe-separated marker (LLM didn't emit JSON) → split on |", () => {
    const r = parseButtonsMarker("Proceed?\n[[buttons]] Yes | No ");
    expect(r.buttons).toEqual(["Yes", "No"]);
    expect(r.body).toBe("Proceed?");
  });

  test("marker is case-insensitive", () => {
    const r = parseButtonsMarker("[[Buttons]][\"A\",\"B\"]");
    expect(r.buttons).toEqual(["A", "B"]);
  });

  test("caps at 8 buttons", () => {
    const labels = Array.from({ length: 12 }, (_, i) => `opt${i}`);
    const r = parseButtonsMarker(`choose\n[[buttons]]${JSON.stringify(labels)}`);
    expect(r.buttons).toHaveLength(8);
  });

  test("trims each label to 50 chars", () => {
    const long = "x".repeat(80);
    const r = parseButtonsMarker(`[[buttons]]["${long}"]`);
    expect(r.buttons![0].length).toBe(50);
  });

  test("marker with no usable labels → treated as plain text (no buttons)", () => {
    const r = parseButtonsMarker("[[buttons]]   ");
    expect(r.buttons).toBeNull();
  });

  test("body with only a marker (no preceding text) → empty body + buttons", () => {
    const r = parseButtonsMarker('[[buttons]]["Go","Stop"]');
    expect(r.buttons).toEqual(["Go", "Stop"]);
    expect(r.body).toBe("");
  });
});
