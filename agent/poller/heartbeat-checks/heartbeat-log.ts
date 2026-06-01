/**
 * Per-fire JSONL log writer for H2 digests.
 *
 * Shape on disk: append-only `heartbeat-log/<threadId>.jsonl`. One JSON
 * object per line. Schema (informal — `cta digest log` and `cta digest costs`
 * are the consumers, both read fields by name):
 *
 *   {
 *     "thread_id": "42",
 *     "started_at": "2026-06-01T09:00:00.000Z",
 *     "trigger": "daily" | "dry-run",
 *     "duration_ms": 12340,
 *     "checks_ran":     ["open-prs", "ci-red"],
 *     "checks_errored": ["ci-red"],
 *     "result":         "sent" | "empty" | "error" | "timeout" | "no-heartbeat-md",
 *     "total_cost_usd": 0.0184,
 *     "skip_reason":    null | "no-heartbeat-md" | …
 *   }
 *
 * Append semantics: a single `appendFileSync` with mode `a` is atomic at
 * the OS level for writes shorter than PIPE_BUF (4096+ bytes on macOS), and
 * each record is well under that. No locking needed for single-writer; the
 * scheduler is the only producer.
 */

import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { heartbeatLogFile } from "../../lib/paths";

export interface FireLogRecord {
  readonly thread_id: string;
  readonly started_at: string;            // ISO8601
  readonly trigger: "daily" | "dry-run";
  readonly duration_ms: number;
  readonly checks_ran: readonly string[];
  readonly checks_errored: readonly string[];
  readonly result: "sent" | "empty" | "error" | "timeout" | "no-heartbeat-md";
  readonly total_cost_usd: number;
  readonly skip_reason?: string | null;
  readonly error_message?: string;
}

/** Append a fire record to heartbeat-log/<threadId>.jsonl. Creates the log
 *  dir if absent. Failure is non-fatal (caller logs to agent.log instead) —
 *  losing a log entry shouldn't take down the run. */
export function appendFireLog(
  record: FireLogRecord,
  path: string = heartbeatLogFile(record.thread_id),
): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  // Single write call so the record can't be split mid-line by a concurrent
  // append. Single-writer assumption (scheduler is the only producer) means
  // no fsync needed per record — the JSONL is recoverable from the next
  // append even if the OS-buffered tail is lost in a crash.
  appendFileSync(path, JSON.stringify(record) + "\n", { mode: 0o600 });
}
