/**
 * Pure scheduler decision function for H2 daily digest.
 *
 * The actual wiring into `poller.ts:housekeep` lands in Unit 4 (after
 * mount-store v3 + settings.json schema land — the housekeep needs to know
 * which mounts have digest enabled + the user's digestTime/quietHours/tz).
 * This file is the testable core: given the current state and inputs, fire
 * or skip and explain why.
 *
 * Decision order (first-true wins as "skip" reason):
 *   1. Already fired today  → skip "already-fired"
 *   2. Digest time not yet reached → skip "not-yet"
 *   3. In quiet hours  → skip "quiet-hours" (H2 DEFERS, never pierces;
 *      i.e. when quiet hours end, the next tick will fire because
 *      digestTime is already past)
 *   4. A runner is already in flight for this thread → skip "in-flight"
 *   5. The interactive bot is mid-turn → skip "user-busy"
 *   6. → FIRE
 *
 * "Skip reason" is exposed so the scheduler's housekeep loop can log it
 * and `cta digest doctor <thread>` can show "last skip reason" to the
 * operator. Surfacing why-not is half the observability story for a
 * background job.
 */

import { alreadyFiredToday, type HeartbeatState } from "./heartbeat-state";
import { dayOfMonthInTz, digestTimeReached, isInQuietHours, todayInTz, weekdayInTz, type QuietWindow } from "./quiet-hours";

export interface ShouldFireInput {
  /** Persisted scheduler state (output of readState). */
  readonly state: HeartbeatState;
  /** Telegram thread_id this digest belongs to. Used in the dedupe key. */
  readonly threadId: string;
  /** User-configured local time to fire the digest (HH:MM). */
  readonly digestTime: string;
  /** User-configured quiet window. Inside the window we DEFER (skip), not
   *  drop — the next tick after the window ends will fire because the
   *  alreadyFiredToday check returns false. */
  readonly quietHours: QuietWindow | null | undefined;
  /** IANA tz (e.g. "Asia/Tokyo"). All time-of-day comparisons happen in
   *  this tz. Fixed across DST transitions so the digest fires at the
   *  user's actual local 09:00, not at "whatever 09:00 means today". */
  readonly timezone: string;
  /** Has the runner already started a fire for this thread this minute?
   *  Re-entry guard for the rare case where two ticks land inside the
   *  same minute boundary. Closure captured from housekeep state. */
  readonly isInFlight: () => boolean;
  /** Is the interactive bot currently processing a turn for this thread?
   *  Heartbeat never races the user. Closure into daemonRegistry.getStatus. */
  readonly isMidTurn: () => boolean;
  /** Current wall-clock moment. Injected so tests can pin specific times. */
  readonly now: Date;
}

export type ShouldFireDecision =
  | { readonly fire: false; readonly reason: SkipReason }
  | { readonly fire: true; readonly ymd: string };

export type SkipReason =
  | "already-fired"
  | "not-yet"
  | "quiet-hours"
  | "in-flight"
  | "user-busy";

// ─── Scheduled tasks (proactive task scheduling) ─────────────────────────────

/** Day spec for a scheduled task. Either an explicit weekday list, or one of
 *  the string forms: "daily", "weekdays", "monthly:<1-31>", "every:<N days>". */
export type TaskDays = string | readonly string[];

/** Weekday-only matcher (daily / weekdays / explicit list). Kept separate so
 *  monthly:/every: strings never reach `Array/String.includes(weekday)` — a
 *  string like "monthly:15" would false-match .includes("mon"). */
export function dayMatches(days: TaskDays, weekday: string): boolean {
  if (days === "daily") return true;
  if (days === "weekdays") return weekday !== "sat" && weekday !== "sun";
  if (Array.isArray(days)) return days.includes(weekday);
  return false; // monthly:/every: string → not a weekday match
}

/** Unified "is the task scheduled to fire on this calendar date?" predicate.
 *  Weekday specs + monthly:<day> are stateless; every:<N> needs
 *  daysSinceLastFire (null = never fired ⇒ fire now). */
export function taskScheduledOn(
  days: TaskDays,
  ctx: { weekday: string; dayOfMonth: number; daysSinceLastFire: number | null },
): boolean {
  if (typeof days === "string") {
    const monthly = /^monthly:(\d{1,2})$/.exec(days);
    if (monthly) return ctx.dayOfMonth === parseInt(monthly[1], 10);
    const every = /^every:(\d{1,3})$/.exec(days);
    if (every) {
      const n = parseInt(every[1], 10);
      return ctx.daysSinceLastFire === null || ctx.daysSinceLastFire >= n;
    }
  }
  return dayMatches(days, ctx.weekday);
}

/** Whole-day difference a−b for two YYYY-MM-DD strings (both computed in the
 *  same tz, so UTC-midnight math is exact). */
function ymdDiffDays(a: string, b: string): number {
  const [ay, am, ad] = a.split("-").map(Number);
  const [by, bm, bd] = b.split("-").map(Number);
  return Math.round((Date.UTC(ay, am - 1, ad) - Date.UTC(by, bm - 1, bd)) / 86_400_000);
}

/** Most recent fire strictly before `beforeYmd` for this task key, or null. */
function lastFiredBefore(state: HeartbeatState, taskKey: string, beforeYmd: string): string | null {
  const prefix = `${taskKey}:`;
  let max: string | null = null;
  for (const k of Object.keys(state.firedToday)) {
    if (!k.startsWith(prefix)) continue;
    const ymd = k.slice(prefix.length);
    if (ymd < beforeYmd && (max === null || ymd > max)) max = ymd;
  }
  return max;
}

/** daysSinceLastFire context for taskScheduledOn at `todayYmd`. */
function daysSinceLastFire(state: HeartbeatState, taskKey: string, todayYmd: string): number | null {
  const last = lastFiredBefore(state, taskKey, todayYmd);
  return last === null ? null : ymdDiffDays(todayYmd, last);
}

export interface ShouldFireTaskInput {
  readonly state: HeartbeatState;
  /** Canonical task state key, e.g. "task:morning-briefing" — used verbatim
   *  as the dayKey threadId segment, giving "task:<name>:<ymd>" keys that
   *  can't collide with the legacy digest's "<threadId>:<ymd>". */
  readonly taskKey: string;
  /** Task-local fire time (HH:MM). */
  readonly time: string;
  readonly days: TaskDays;
  readonly quietHours: QuietWindow | null | undefined;
  readonly timezone: string;
  /** The TARGET TOPIC's agentic in-flight guard. Critical: deciding "skip"
   *  here (instead of marking fired and letting launchAgentic bounce off its
   *  busy guard) means a busy topic DEFERS the task to the next tick rather
   *  than silently losing it for the day. */
  readonly isInFlight: () => boolean;
  readonly isMidTurn: () => boolean;
  readonly now: Date;
}

export type TaskSkipReason = SkipReason | "day-mismatch";

export type ShouldFireTaskDecision =
  | { readonly fire: false; readonly reason: TaskSkipReason }
  | { readonly fire: true; readonly ymd: string };

/** shouldFire generalized for scheduled tasks: same decision order with a
 *  day-of-week gate inserted after the dedupe check. */
export function shouldFireTask(input: ShouldFireTaskInput): ShouldFireTaskDecision {
  const ymd = todayInTz(input.now, input.timezone);

  if (alreadyFiredToday(input.state, input.taskKey, ymd)) {
    return { fire: false, reason: "already-fired" };
  }
  const scheduled = taskScheduledOn(input.days, {
    weekday: weekdayInTz(input.now, input.timezone),
    dayOfMonth: dayOfMonthInTz(input.now, input.timezone),
    daysSinceLastFire: daysSinceLastFire(input.state, input.taskKey, ymd),
  });
  if (!scheduled) {
    return { fire: false, reason: "day-mismatch" };
  }
  if (!digestTimeReached(input.now, input.time, input.timezone)) {
    return { fire: false, reason: "not-yet" };
  }
  if (isInQuietHours(input.now, input.quietHours, input.timezone)) {
    return { fire: false, reason: "quiet-hours" };
  }
  if (input.isInFlight()) {
    return { fire: false, reason: "in-flight" };
  }
  if (input.isMidTurn()) {
    return { fire: false, reason: "user-busy" };
  }
  return { fire: true, ymd };
}

export interface MissedTaskFireInput {
  readonly state: HeartbeatState;
  readonly taskKey: string;
  readonly days: TaskDays;
  readonly timezone: string;
  readonly now: Date;
}

/** detectMissedFire generalized for tasks: a day the task wasn't SCHEDULED to
 *  run is never "missed" (a weekdays task must not alert every Monday about
 *  the correctly-skipped Sunday). Same older-key guard against first-day
 *  false alarms. */
export function detectMissedTaskFire(input: MissedTaskFireInput): string | null {
  // every:<N> is a relative cadence — there is no fixed "missed day" to alert
  // about (a skipped day just shifts the next fire). Only fixed-date schedules
  // (daily/weekdays/list/monthly) have a missable day.
  if (typeof input.days === "string" && input.days.startsWith("every:")) return null;
  const todayYmd = todayInTz(input.now, input.timezone);
  const yesterday = new Date(input.now.getTime() - 86_400_000);
  const yYmd = todayInTz(yesterday, input.timezone);
  if (yYmd === todayYmd) return null; // degenerate tz math — bail safe
  const scheduledYesterday = taskScheduledOn(input.days, {
    weekday: weekdayInTz(yesterday, input.timezone),
    dayOfMonth: dayOfMonthInTz(yesterday, input.timezone),
    daysSinceLastFire: null, // only consulted by every:, which returned above
  });
  if (!scheduledYesterday) return null;
  if (alreadyFiredToday(input.state, input.taskKey, yYmd)) return null;
  const prefix = `${input.taskKey}:`;
  const hasOlderFire = Object.keys(input.state.firedToday).some(
    (k) => k.startsWith(prefix) && k.slice(prefix.length) < yYmd,
  );
  return hasOlderFire ? yYmd : null;
}

export interface MissedFireInput {
  /** Persisted scheduler state (output of readState). */
  readonly state: HeartbeatState;
  readonly threadId: string;
  readonly timezone: string;
  readonly now: Date;
}

/**
 * Detect a silently-skipped day. If the host slept past digestTime clear into
 * the NEXT calendar day (in the digest tz), that day's `firedToday` key was
 * never written and the digest was skipped with zero signal — silence
 * indistinguishable from success. Returns yesterday's ymd when it was missed,
 * else null. Caller marks the returned ymd (markFiredToday) so the alert
 * fires exactly once.
 *
 * Guard against false alarms: only report a miss when some OLDER key exists
 * for this thread — proof the digest was enabled and firing before. The first
 * day after enabling has no older key and is never reported.
 */
export function detectMissedFire(input: MissedFireInput): string | null {
  const todayYmd = todayInTz(input.now, input.timezone);
  const yesterdayYmd = todayInTz(new Date(input.now.getTime() - 86_400_000), input.timezone);
  if (yesterdayYmd === todayYmd) return null; // degenerate tz math — bail safe
  if (alreadyFiredToday(input.state, input.threadId, yesterdayYmd)) return null;
  const prefix = `${input.threadId}:`;
  const hasOlderFire = Object.keys(input.state.firedToday).some(
    (k) => k.startsWith(prefix) && k.slice(prefix.length) < yesterdayYmd,
  );
  return hasOlderFire ? yesterdayYmd : null;
}

export function shouldFire(input: ShouldFireInput): ShouldFireDecision {
  const ymd = todayInTz(input.now, input.timezone);

  if (alreadyFiredToday(input.state, input.threadId, ymd)) {
    return { fire: false, reason: "already-fired" };
  }
  if (!digestTimeReached(input.now, input.digestTime, input.timezone)) {
    return { fire: false, reason: "not-yet" };
  }
  if (isInQuietHours(input.now, input.quietHours, input.timezone)) {
    return { fire: false, reason: "quiet-hours" };
  }
  if (input.isInFlight()) {
    return { fire: false, reason: "in-flight" };
  }
  if (input.isMidTurn()) {
    return { fire: false, reason: "user-busy" };
  }
  return { fire: true, ymd };
}
