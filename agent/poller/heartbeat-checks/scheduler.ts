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
import { digestTimeReached, isInQuietHours, todayInTz, type QuietWindow } from "./quiet-hours";

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
