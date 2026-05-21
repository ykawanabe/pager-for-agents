#!/usr/bin/env bun
/**
 * watch-render — render a topic's recent conversation transcript from its
 * claude session JSONL.
 *
 * P6b: `cta watch` used to `tmux capture-pane` a per-topic tmux session, but
 * Phase 4 daemon mode has no per-topic panes (only the `poller` + `watchdog`
 * sessions), so that path always returned "session not alive". This renders
 * the same conversation directly from claude's on-disk transcript instead:
 *
 *   mount(thread_id) → path  +  $STATE_DIR/sessions/<thread_id> → session uuid
 *   → ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl  → user/assistant text
 *
 * CLI: `bun run watch-render.ts <thread_id> [--lines N]`. Output is the last N
 * lines of the rendered transcript on stdout. Exit codes mirror the old
 * `cta watch`: 0 ok, 1 no mount / bad args, 2 mount exists but no transcript yet.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { findMountByThreadId, parseThreadId, type ThreadId } from "../mount-store/mount-store";
import { jsonlPathForSession } from "./slash-commands";
import { sessionsDir } from "../lib/paths";

function sessionUuidFor(threadId: ThreadId): string | null {
  const f = join(sessionsDir(), String(threadId));
  if (!existsSync(f)) return null;
  try {
    const u = readFileSync(f, "utf8").trim();
    return u || null;
  } catch {
    return null;
  }
}

/** Pull the printable text out of a claude transcript content field, which is
 *  either a plain string or an array of typed blocks. Only `text` blocks are
 *  surfaced — `thinking` and `tool_use`/`tool_result` are noise for a watch view. */
function blockText(content: unknown): string {
  if (typeof content === "string") return content.trim();
  if (Array.isArray(content)) {
    return content
      .filter((b) => b && typeof b === "object" && (b as { type?: string }).type === "text")
      .map((b) => (b as { text?: string }).text ?? "")
      .join("")
      .trim();
  }
  return "";
}

/** Render the user/assistant turns of a session JSONL, newest-last, then keep
 *  the last `lines` output lines (so the contract matches the old tmux
 *  capture-pane `--lines N` budget). */
export function renderTranscript(jsonlPath: string, lines: number): string {
  if (!existsSync(jsonlPath)) return "";
  let raw: string;
  try {
    raw = readFileSync(jsonlPath, "utf8");
  } catch {
    return "";
  }
  const turns: string[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let ev: { type?: string; message?: { content?: unknown } };
    try {
      ev = JSON.parse(line);
    } catch {
      continue;
    }
    if (ev.type !== "user" && ev.type !== "assistant") continue;
    const text = blockText(ev.message?.content);
    if (!text) continue;
    turns.push(`${ev.type === "user" ? "You" : "Claude"}: ${text}`);
  }
  const all = turns.join("\n\n").split("\n");
  return all.slice(-lines).join("\n");
}

function fail(msg: string, code: number): never {
  process.stderr.write(`watch-render: ${msg}\n`);
  process.exit(code);
}

function main(): void {
  const args = process.argv.slice(2);
  let lines = 200;
  let threadRaw = "";
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--lines") {
      const v = args[++i];
      if (!v || !/^[0-9]+$/.test(v)) fail("--lines requires a non-negative integer", 1);
      lines = Number(v);
    } else if (a === "--ansi" || a === "--follow") {
      // accepted for CLI compatibility; JSONL has no ANSI and streaming was
      // dropped in P6 (one-shot snapshot only).
    } else if (!a.startsWith("-") && !threadRaw) {
      threadRaw = a;
    }
  }
  if (!threadRaw) fail("usage: watch-render <thread_id|dm> [--lines N]", 1);

  let threadId: ThreadId;
  try {
    threadId = parseThreadId(threadRaw);
  } catch (e) {
    fail(e instanceof Error ? e.message : String(e), 1);
  }

  const mount = findMountByThreadId(threadId);
  if (!mount) fail(`no mount for thread '${threadRaw}'`, 1);

  const uuid = sessionUuidFor(threadId);
  if (!uuid) fail(`no session yet for '${threadRaw}' — send a message in this topic first`, 2);

  const jsonl = jsonlPathForSession(mount.path, uuid);
  const out = renderTranscript(jsonl, lines);
  if (!out) fail(`no transcript yet at ${jsonl}`, 2);
  process.stdout.write(out + "\n");
}

if (import.meta.main) main();
