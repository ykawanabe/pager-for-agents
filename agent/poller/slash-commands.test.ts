/**
 * Tests for bot-side slash command handlers (Phase 1 of stream-json migration).
 *
 * Strategy: these functions are intentionally pure — they take dependencies
 * (file paths, fetch fn, etc.) as args so tests don't need network/keychain.
 * Integration tests for the poller wiring live in poller.test.ts.
 */
import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  aggregateCostFromJsonl,
  contextWindowFor,
  formatCostMessage,
  formatUsageMessage,
  fetchUsageStats,
  lastContextFromJsonl,
  resolveCredentialToken,
  type CostSummary,
} from "./slash-commands";

const SANDBOX = join(tmpdir(), `slash-cmd-test-${process.pid}-${Date.now()}`);
mkdirSync(SANDBOX, { recursive: true });
afterAll(() => rmSync(SANDBOX, { recursive: true, force: true }));

describe("aggregateCostFromJsonl", () => {
  test("sums tokens across assistant entries by model", () => {
    const jsonl = join(SANDBOX, "session-a.jsonl");
    const entries = [
      { type: "user", message: { content: "hi" } }, // ignored
      {
        type: "assistant",
        message: {
          model: "claude-opus-4-7",
          usage: { input_tokens: 100, output_tokens: 50, cache_read_input_tokens: 1000, cache_creation_input_tokens: 200 },
        },
      },
      {
        type: "assistant",
        message: {
          model: "claude-opus-4-7",
          usage: { input_tokens: 200, output_tokens: 80, cache_read_input_tokens: 1500, cache_creation_input_tokens: 0 },
        },
      },
      {
        type: "assistant",
        message: {
          model: "claude-sonnet-4-6",
          usage: { input_tokens: 50, output_tokens: 30, cache_read_input_tokens: 500, cache_creation_input_tokens: 100 },
        },
      },
    ];
    writeFileSync(jsonl, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");

    const summary = aggregateCostFromJsonl(jsonl);

    expect(summary.byModel["claude-opus-4-7"]).toEqual({
      input: 300, output: 130, cacheRead: 2500, cacheWrite: 200,
    });
    expect(summary.byModel["claude-sonnet-4-6"]).toEqual({
      input: 50, output: 30, cacheRead: 500, cacheWrite: 100,
    });
  });

  test("returns empty summary when JSONL is missing", () => {
    const summary = aggregateCostFromJsonl(join(SANDBOX, "does-not-exist.jsonl"));
    expect(Object.keys(summary.byModel)).toHaveLength(0);
    expect(summary.totalCostUsd).toBe(0);
  });

  test("tolerates malformed JSONL lines (skips bad lines, sums good ones)", () => {
    const jsonl = join(SANDBOX, "malformed.jsonl");
    const content = [
      "not json",
      JSON.stringify({ type: "assistant", message: { model: "claude-opus-4-7", usage: { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } }),
      "{broken",
      "",
    ].join("\n");
    writeFileSync(jsonl, content);
    const summary = aggregateCostFromJsonl(jsonl);
    expect(summary.byModel["claude-opus-4-7"]?.input).toBe(10);
    expect(summary.byModel["claude-opus-4-7"]?.output).toBe(5);
  });

  test("computes totalCostUsd from known Opus rates", () => {
    // Opus rates (per million tokens): input $15, output $75, cache_read $1.50, cache_write $18.75
    const jsonl = join(SANDBOX, "cost-calc.jsonl");
    const entries = [
      {
        type: "assistant",
        message: {
          model: "claude-opus-4-7",
          // 1M input, 1M output, 1M cache_read, 1M cache_write
          usage: { input_tokens: 1_000_000, output_tokens: 1_000_000, cache_read_input_tokens: 1_000_000, cache_creation_input_tokens: 1_000_000 },
        },
      },
    ];
    writeFileSync(jsonl, entries.map((e) => JSON.stringify(e)).join("\n"));
    const summary = aggregateCostFromJsonl(jsonl);
    // 15 + 75 + 1.50 + 18.75 = 110.25
    expect(summary.totalCostUsd).toBeCloseTo(110.25, 2);
  });

  test("unknown model contributes tokens but $0 cost (no rate lookup)", () => {
    const jsonl = join(SANDBOX, "unknown-model.jsonl");
    writeFileSync(jsonl, JSON.stringify({
      type: "assistant",
      message: { model: "future-model-x", usage: { input_tokens: 1000, output_tokens: 500, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } },
    }));
    const summary = aggregateCostFromJsonl(jsonl);
    expect(summary.byModel["future-model-x"]?.input).toBe(1000);
    expect(summary.totalCostUsd).toBe(0);
  });
});

describe("formatCostMessage", () => {
  test("renders human-readable session summary", () => {
    const summary: CostSummary = {
      byModel: {
        "claude-opus-4-7": { input: 100, output: 50, cacheRead: 1000, cacheWrite: 200 },
      },
      totalCostUsd: 0.123456,
    };
    const out = formatCostMessage(summary);
    expect(out).toContain("Session cost");
    expect(out).toContain("$0.12"); // 2-decimal display
    expect(out).toContain("claude-opus-4-7");
    expect(out).toContain("100"); // input tokens
  });

  test("empty summary explains there's nothing to bill yet", () => {
    const out = formatCostMessage({ byModel: {}, totalCostUsd: 0 });
    expect(out.toLowerCase()).toContain("no usage");
  });
});

describe("resolveCredentialToken", () => {
  test("returns null when no credential source is available", async () => {
    // Both paths unavailable: file missing, keychain command missing.
    const token = await resolveCredentialToken({
      credentialsJsonPath: join(SANDBOX, "no-such-credentials.json"),
      runKeychain: async () => null,
    });
    expect(token).toBeNull();
  });

  test("reads accessToken from credentials.json when present", async () => {
    const credPath = join(SANDBOX, "credentials.json");
    writeFileSync(credPath, JSON.stringify({ claudeAiOauth: { accessToken: "tok-abc" } }));
    const token = await resolveCredentialToken({
      credentialsJsonPath: credPath,
      runKeychain: async () => null,
    });
    expect(token).toBe("tok-abc");
  });

  test("falls back to keychain when credentials.json missing", async () => {
    const token = await resolveCredentialToken({
      credentialsJsonPath: join(SANDBOX, "still-no-file.json"),
      runKeychain: async () => JSON.stringify({ claudeAiOauth: { accessToken: "tok-keychain" } }),
    });
    expect(token).toBe("tok-keychain");
  });
});

describe("fetchUsageStats + formatUsageMessage", () => {
  test("fetchUsageStats POSTs Bearer token and parses response", async () => {
    let capturedAuth: string | null = null;
    const stubFetch = async (_url: string | URL, init?: RequestInit): Promise<Response> => {
      capturedAuth = (init?.headers as Record<string, string>)?.["Authorization"] ?? null;
      return new Response(
        JSON.stringify({ five_hour: { utilization: 0.42 }, seven_day: { utilization: 0.18 } }),
        { headers: { "Content-Type": "application/json" } },
      );
    };
    const stats = await fetchUsageStats("tok-xyz", stubFetch as unknown as typeof fetch);
    expect(capturedAuth).toBe("Bearer tok-xyz");
    expect(stats.fiveHourPct).toBeCloseTo(42, 1);
    expect(stats.sevenDayPct).toBeCloseTo(18, 1);
  });

  test("fetchUsageStats returns null fields on non-OK response", async () => {
    const stubFetch = async (): Promise<Response> =>
      new Response("Unauthorized", { status: 401 });
    const stats = await fetchUsageStats("bad-token", stubFetch as unknown as typeof fetch);
    expect(stats.fiveHourPct).toBeNull();
    expect(stats.sevenDayPct).toBeNull();
    expect(stats.error).toContain("401");
  });

  test("formatUsageMessage renders percentages", () => {
    const msg = formatUsageMessage({ fiveHourPct: 25.5, sevenDayPct: 10.0, error: null });
    expect(msg).toContain("25.5%");
    expect(msg).toContain("10.0%");
    expect(msg).toContain("5h");
    expect(msg).toContain("7d");
  });

  test("formatUsageMessage shows error when stats unavailable", () => {
    const msg = formatUsageMessage({ fiveHourPct: null, sevenDayPct: null, error: "401: unauthorized" });
    expect(msg).toContain("Couldn't fetch");
    expect(msg).toContain("401");
  });
});

describe("lastContextFromJsonl / contextWindowFor", () => {
  test("returns the LAST assistant turn's prompt size + model", () => {
    const jsonl = join(SANDBOX, "ctx.jsonl");
    const entries = [
      { type: "assistant", message: { model: "claude-sonnet-4-6", usage: { input_tokens: 10, cache_read_input_tokens: 1000, cache_creation_input_tokens: 5, output_tokens: 50 } } },
      { type: "user", message: { content: "next" } },
      { type: "assistant", message: { model: "claude-sonnet-4-6", usage: { input_tokens: 20, cache_read_input_tokens: 8000, cache_creation_input_tokens: 30, output_tokens: 60 } } },
    ];
    writeFileSync(jsonl, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
    const ctx = lastContextFromJsonl(jsonl);
    expect(ctx).not.toBeNull();
    expect(ctx!.tokens).toBe(20 + 8000 + 30); // last turn, output excluded
    expect(ctx!.model).toBe("claude-sonnet-4-6");
  });

  test("null when file missing or no assistant turn", () => {
    expect(lastContextFromJsonl(join(SANDBOX, "nope.jsonl"))).toBeNull();
    const onlyUser = join(SANDBOX, "useronly.jsonl");
    writeFileSync(onlyUser, JSON.stringify({ type: "user", message: { content: "hi" } }) + "\n");
    expect(lastContextFromJsonl(onlyUser)).toBeNull();
  });

  test("skips a truncated trailing line", () => {
    const jsonl = join(SANDBOX, "trunc.jsonl");
    const good = JSON.stringify({ type: "assistant", message: { model: "m", usage: { input_tokens: 5, cache_read_input_tokens: 100 } } });
    writeFileSync(jsonl, good + "\n" + '{"type":"assistant","mess'); // truncated
    const ctx = lastContextFromJsonl(jsonl);
    expect(ctx!.tokens).toBe(105);
  });

  test("contextWindowFor defaults 200k, 1M for 1m variants", () => {
    expect(contextWindowFor("claude-sonnet-4-6")).toBe(200_000);
    expect(contextWindowFor("claude-sonnet-4-6[1m]")).toBe(1_000_000);
  });
});
