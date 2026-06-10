#!/usr/bin/env bun
/**
 * tasks-store — read/write helper for $STATE_DIR/tasks.json (scheduled tasks).
 *
 * Proactive task scheduling: each task fires a gated agentic run at its own
 * time-of-day, on its own days, into its own topic. The morning briefing is
 * just the first task; "watch X and tell me", weekly reports etc. are more
 * rows. This store is the single source of truth that:
 *   - the poller imports for taskDispatch routing (hot-reloaded on mtime),
 *   - `cta task <verb>` shells out to for mutations,
 *   - Pager reads via `cta task list --json`.
 *
 * Why TS instead of bash: same reason as mount-store — macOS doesn't ship
 * flock, and the poller wants typed reads of the same module. Mirrors
 * mount-store's O_EXCL lock + atomic tmp/fsync/rename write verbatim.
 *
 * Schema (version 1):
 *   {
 *     "version": 1,
 *     "tasks": [
 *       {
 *         "name": "morning-briefing",
 *         "time": "07:30",
 *         "days": "daily",                       // "daily" | "weekdays" | ["mon","wed",...]
 *         "checklist": "/abs/path/HEARTBEAT.md", // exactly one of checklist | prompt
 *         "topic": "dm",                          // "dm" or a numeric topic id
 *         "model": "sonnet",                      // optional — falls back to agenticModel
 *         "effort": "medium",                     // optional — falls back to agenticEffort
 *         "enabled": true,
 *         "created_at": "2026-06-10T07:00:00.000Z"
 *       }
 *     ]
 *   }
 *
 * Unknown per-task fields are preserved verbatim through read+write cycles
 * via the [extraField] forward-compat carrier (same contract as Mount).
 *
 * Task names become filenames (task-run/<name>, agentic session keys) and
 * firedToday key segments ("task:<name>:<ymd>") — so names are restricted to
 * [A-Za-z0-9._-] (no ':' to keep the state key unambiguous, no '/' for
 * filesystem safety).
 */

import {
  closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync,
  renameSync, statSync, unlinkSync, writeFileSync,
} from "node:fs";
import { stateDir, tasksJson } from "../lib/paths";

const STATE_DIR = stateDir();
const TASKS_JSON = tasksJson();
const LOCK_FILE = `${TASKS_JSON}.lock`;
const STALE_LOCK_MS = 30_000;
const LOCK_RETRY_MS = 50;
const LOCK_RETRY_MAX = 200;

export type TaskDaysSpec = "daily" | "weekdays" | string[];
export type TaskTopic = number | "dm";

export interface ScheduledTask {
  name: string;
  /** Fire time "HH:MM" (interpreted in the global settings.json timezone). */
  time: string;
  days: TaskDaysSpec;
  /** Absolute path to a checklist markdown — exactly one of checklist|prompt. */
  checklist?: string;
  /** Inline task prompt — exactly one of checklist|prompt. */
  prompt?: string;
  /** Target topic the run fires into (must be a mounted topic). */
  topic: TaskTopic;
  /** Per-task model/effort override; absent → global agenticModel/agenticEffort. */
  model?: string;
  effort?: string;
  /** Conditional delivery: when set, the run's final summary is delivered to
   *  Telegram ONLY if it contains this substring (the task's checklist tells
   *  the agent to include it on a noteworthy day). Absent → always deliver,
   *  streamed live. Kills "nothing changed" daily noise. */
  notifyOnlyIf?: string;
  enabled: boolean;
  created_at: string;
  // Forward-compat carrier — unknown fields round-trip untouched.
  [extraField: string]: unknown;
}

export interface TasksFile {
  version: 1;
  tasks: ScheduledTask[];
}

// ─── validation ─────────────────────────────────────────────────────────────

const TASK_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const HHMM_RE = /^(\d{1,2}):(\d{2})$/;
const WEEKDAYS = new Set(["mon", "tue", "wed", "thu", "fri", "sat", "sun"]);

export function parseTaskName(raw: string): string {
  const name = raw.trim();
  if (!TASK_NAME_RE.test(name)) {
    throw new Error(
      `invalid task name ${JSON.stringify(raw)} — use letters/digits/._- (it becomes a filename and a state key)`);
  }
  return name;
}

export function parseTime(raw: string): string {
  const m = HHMM_RE.exec(raw.trim());
  if (!m) throw new Error(`invalid time ${JSON.stringify(raw)} — expected HH:MM`);
  const h = parseInt(m[1], 10);
  const min = parseInt(m[2], 10);
  if (h > 23 || min > 59) throw new Error(`invalid time ${JSON.stringify(raw)} — expected HH:MM`);
  return `${String(h).padStart(2, "0")}:${m[2]}`;
}

export function parseDays(raw: string): TaskDaysSpec {
  const s = raw.trim().toLowerCase();
  if (s === "" || s === "daily") return "daily";
  if (s === "weekdays") return "weekdays";
  const monthly = /^monthly:(\d{1,2})$/.exec(s);
  if (monthly) {
    const d = parseInt(monthly[1], 10);
    if (d < 1 || d > 31) throw new Error(`invalid days ${JSON.stringify(raw)} — monthly day must be 1-31`);
    return `monthly:${d}`;
  }
  const every = /^every:(\d{1,3})$/.exec(s);
  if (every) {
    const n = parseInt(every[1], 10);
    if (n < 1) throw new Error(`invalid days ${JSON.stringify(raw)} — every:<N> needs N>=1`);
    return `every:${n}`;
  }
  const days = s.split(",").map((d) => d.trim()).filter(Boolean);
  for (const d of days) {
    if (!WEEKDAYS.has(d)) {
      throw new Error(`invalid days ${JSON.stringify(raw)} — expected daily | weekdays | mon..sun list | monthly:<1-31> | every:<N>`);
    }
  }
  if (days.length === 0) throw new Error(`invalid days ${JSON.stringify(raw)}`);
  return days;
}

export function parseTopic(raw: string): TaskTopic {
  const s = raw.trim();
  if (s === "dm") return "dm";
  const n = Number(s);
  if (!Number.isInteger(n) || n <= 0) {
    throw new Error(`invalid topic ${JSON.stringify(raw)} — expected "dm" or a positive topic id`);
  }
  return n;
}

// ─── locking (mirrors mount-store) ──────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function acquireLock(): Promise<number> {
  for (let i = 0; i < LOCK_RETRY_MAX; i++) {
    try {
      return openSync(LOCK_FILE, "wx", 0o600); // O_EXCL — atomic on POSIX
    } catch {
      try {
        const age = Date.now() - statSync(LOCK_FILE).mtimeMs;
        if (age > STALE_LOCK_MS) {
          unlinkSync(LOCK_FILE);
          continue;
        }
      } catch { /* race with a legitimate release — retry */ }
      await sleep(LOCK_RETRY_MS);
    }
  }
  throw new Error(`tasks-store: could not acquire lock at ${LOCK_FILE} after ${LOCK_RETRY_MAX * LOCK_RETRY_MS}ms`);
}

async function withLock<T>(fn: () => Promise<T> | T): Promise<T> {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const fd = await acquireLock();
  try {
    return await fn();
  } finally {
    closeSync(fd);
    try { unlinkSync(LOCK_FILE); } catch { /* already gone */ }
  }
}

// ─── read / write ───────────────────────────────────────────────────────────

/** Read tasks.json. Missing file → empty store (so deleting the file empties
 *  the poller's cache instead of going stale). Unparseable → throw (callers
 *  decide; the poller keeps its last good cache). */
export function readTasks(): TasksFile {
  if (!existsSync(TASKS_JSON)) return { version: 1, tasks: [] };
  try {
    const parsed = JSON.parse(readFileSync(TASKS_JSON, "utf8")) as Partial<TasksFile>;
    if (parsed.version !== 1 || !Array.isArray(parsed.tasks)) {
      throw new Error("tasks.json: unrecognized schema");
    }
    // Defense-in-depth: name validation runs on the add path, but the poller
    // builds filesystem paths + state keys from task.name on every read. A
    // hand-edited / corrupted file must never let a name with '/' or ':' reach
    // path construction — drop (and warn about) any row that fails the name
    // rule rather than trusting the file.
    const tasks = (parsed.tasks as ScheduledTask[]).filter((t) => {
      try { parseTaskName(String(t?.name ?? "")); return true; }
      catch { process.stderr.write(`tasks-store: dropping task with invalid name ${JSON.stringify(t?.name)}\n`); return false; }
    });
    return { version: 1, tasks };
  } catch (e) {
    throw new Error(`tasks.json: ${e instanceof Error ? e.message : String(e)}`);
  }
}

function writeTasksAtomic(data: TasksFile): void {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const tmp = `${TASKS_JSON}.tmp.${process.pid}`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeFileSync(fd, `${JSON.stringify(data, null, 2)}\n`);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, TASKS_JSON);
}

export function findTask(name: string): ScheduledTask | null {
  return readTasks().tasks.find((t) => t.name === name) ?? null;
}

// ─── mutations ──────────────────────────────────────────────────────────────

export async function addTask(args: {
  name: string;
  time: string;
  days: TaskDaysSpec;
  checklist?: string;
  prompt?: string;
  topic: TaskTopic;
  model?: string;
  effort?: string;
  notifyOnlyIf?: string;
}): Promise<ScheduledTask> {
  if (!!args.checklist === !!args.prompt) {
    throw new Error("add: exactly one of --checklist or --prompt is required");
  }
  return withLock(() => {
    const file = readTasks();
    if (file.tasks.some((t) => t.name === args.name)) {
      throw new Error(`add: task ${JSON.stringify(args.name)} already exists (remove it first)`);
    }
    const task: ScheduledTask = {
      name: args.name,
      time: args.time,
      days: args.days,
      ...(args.checklist ? { checklist: args.checklist } : {}),
      ...(args.prompt ? { prompt: args.prompt } : {}),
      topic: args.topic,
      ...(args.model ? { model: args.model } : {}),
      ...(args.effort ? { effort: args.effort } : {}),
      ...(args.notifyOnlyIf ? { notifyOnlyIf: args.notifyOnlyIf } : {}),
      enabled: true,
      created_at: new Date().toISOString(),
    };
    file.tasks.push(task);
    writeTasksAtomic(file);
    return task;
  });
}

export async function removeTask(name: string): Promise<ScheduledTask> {
  return withLock(() => {
    const file = readTasks();
    const idx = file.tasks.findIndex((t) => t.name === name);
    if (idx < 0) throw new Error(`remove: no task named ${JSON.stringify(name)}`);
    const [removed] = file.tasks.splice(idx, 1);
    writeTasksAtomic(file);
    return removed;
  });
}

export async function setTaskEnabled(name: string, enabled: boolean): Promise<ScheduledTask> {
  return withLock(() => {
    const file = readTasks();
    const task = file.tasks.find((t) => t.name === name);
    if (!task) throw new Error(`set-enabled: no task named ${JSON.stringify(name)}`);
    task.enabled = enabled;
    writeTasksAtomic(file);
    return task;
  });
}

// ─── CLI entry point ────────────────────────────────────────────────────────
// Bash callers do: `bun run tasks-store.ts <op> [args]`. JSON on stdout,
// errors to stderr with nonzero exit (same contract as mount-store).

function bail(msg: string): never {
  process.stderr.write(`tasks-store: ${msg}\n`);
  process.exit(1);
}

/** Pull `--flag value` out of an argv array; returns [value, rest]. */
function takeFlag(args: string[], flag: string): [string | undefined, string[]] {
  const i = args.indexOf(flag);
  if (i < 0) return [undefined, args];
  const value = args[i + 1];
  const rest = args.filter((_, j) => j !== i && j !== i + 1);
  return [value, rest];
}

async function main(): Promise<void> {
  const [op, ...rest] = process.argv.slice(2);
  switch (op) {
    case "list": {
      process.stdout.write(`${JSON.stringify(readTasks(), null, 2)}\n`);
      return;
    }
    case "get": {
      try {
        process.stdout.write(`${JSON.stringify(findTask(parseTaskName(rest[0] ?? "")))}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    case "add": {
      // Args: <name> --time HH:MM [--days spec] (--checklist path | --prompt text)
      //       [--topic dm|<id>] [--model m] [--effort e] [--notify-only-if str]
      try {
        let args = rest.slice();
        const name = parseTaskName(args[0] ?? "");
        args = args.slice(1);
        const [time, a1] = takeFlag(args, "--time");
        const [days, a2] = takeFlag(a1, "--days");
        const [checklist, a3] = takeFlag(a2, "--checklist");
        const [prompt, a4] = takeFlag(a3, "--prompt");
        const [topic, a5] = takeFlag(a4, "--topic");
        const [model, a6] = takeFlag(a5, "--model");
        const [effort, a7] = takeFlag(a6, "--effort");
        const [notifyOnlyIf, leftover] = takeFlag(a7, "--notify-only-if");
        if (leftover.length > 0) bail(`add: unrecognized args: ${leftover.join(" ")}`);
        if (!time) bail("add: --time HH:MM is required");
        const task = await addTask({
          name,
          time: parseTime(time),
          days: parseDays(days ?? "daily"),
          checklist,
          prompt,
          topic: parseTopic(topic ?? "dm"),
          model,
          effort,
          notifyOnlyIf,
        });
        process.stdout.write(`${JSON.stringify(task)}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    case "remove": {
      try {
        const removed = await removeTask(parseTaskName(rest[0] ?? ""));
        process.stdout.write(`${JSON.stringify(removed)}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    case "set-enabled": {
      // Args: <name> on|off
      const val = rest[1];
      if (val !== "on" && val !== "off") bail("set-enabled: second arg must be 'on' or 'off'");
      try {
        const task = await setTaskEnabled(parseTaskName(rest[0] ?? ""), val === "on");
        process.stdout.write(`${JSON.stringify(task)}\n`);
      } catch (e) {
        bail(e instanceof Error ? e.message : String(e));
      }
      return;
    }
    default:
      bail(`unknown op: ${op ?? "(none)"}. Try: list, get, add, remove, set-enabled`);
  }
}

if (import.meta.main) {
  main().catch((e) => {
    process.stderr.write(`tasks-store: ${e instanceof Error ? e.stack ?? e.message : String(e)}\n`);
    process.exit(1);
  });
}
