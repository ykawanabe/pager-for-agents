import { describe, expect, test } from "bun:test";
import { parseHeartbeatMd } from "./heartbeat-md";

describe("parseHeartbeatMd", () => {
  test("parses bare check IDs, one per line", () => {
    const r = parseHeartbeatMd("open-prs\nci-red\ndependabot-alerts\n");
    expect(r.checkIds).toEqual(["open-prs", "ci-red", "dependabot-alerts"]);
    expect(r.context).toBe("");
  });

  test("skips blank lines and # comments", () => {
    const r = parseHeartbeatMd(`
# Engineering pulse
open-prs

# External pulse
ci-red
`);
    expect(r.checkIds).toEqual(["open-prs", "ci-red"]);
  });

  test("strips inline # comments from check ID lines", () => {
    const r = parseHeartbeatMd("open-prs   # PRs older than 24h\nci-red  #failed runs\n");
    expect(r.checkIds).toEqual(["open-prs", "ci-red"]);
  });

  test("captures free-form context from first ## heading to EOF", () => {
    const r = parseHeartbeatMd(`open-prs
ci-red

## Free-form context
Project context: agent's own repo.
Treat ChatTransport issues as higher urgency.
`);
    expect(r.checkIds).toEqual(["open-prs", "ci-red"]);
    expect(r.context).toContain("## Free-form context");
    expect(r.context).toContain("Project context");
    expect(r.context).toContain("higher urgency");
  });

  test("check IDs after the first ## are ignored (they belong to context)", () => {
    const r = parseHeartbeatMd(`open-prs
## Context
ci-red   # this looks like a check but it's inside the context block
`);
    expect(r.checkIds).toEqual(["open-prs"]);
    expect(r.context).toContain("ci-red");
  });

  test("empty content → empty result, doesn't throw", () => {
    const r = parseHeartbeatMd("");
    expect(r.checkIds).toEqual([]);
    expect(r.context).toBe("");
  });

  test("only comments → empty checkIds", () => {
    const r = parseHeartbeatMd("# nothing here\n# just comments\n");
    expect(r.checkIds).toEqual([]);
    expect(r.context).toBe("");
  });

  test("CRLF line endings handled", () => {
    const r = parseHeartbeatMd("open-prs\r\nci-red\r\n");
    expect(r.checkIds).toEqual(["open-prs", "ci-red"]);
  });

  test("preserves check ID order (parallel dispatch needs a deterministic list for logging)", () => {
    const r = parseHeartbeatMd("ci-red\nopen-prs\ndependabot-alerts\n");
    expect(r.checkIds).toEqual(["ci-red", "open-prs", "dependabot-alerts"]);
  });
});
