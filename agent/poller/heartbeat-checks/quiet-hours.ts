/**
 * Quiet-hours + time-of-day predicates for the H2 daily-digest scheduler.
 *
 * Two responsibilities:
 *  - `isInQuietHours(now, window, tz)` — is the current wall-clock time
 *    inside the user's configured quiet window? Wrap-midnight supported
 *    (start > end means the window straddles midnight).
 *  - `digestTimeReached(now, target, tz)` — is the current wall-clock time
 *    past today's `target` HH:MM? Combined with persisted "fired today" the
 *    scheduler gets a "fire once after target, but not again today".
 *  - `todayInTz(now, tz)` — formats now as "YYYY-MM-DD" in the user's TZ.
 *    The scheduler uses this as the per-day dedupe key suffix. Fixed-TZ
 *    semantics prevent travel-day duplicates/skips (LAX→NRT mid-day).
 *
 * All functions take `now` explicitly so tests can pin specific wall-clock
 * moments without mocking the global Date. The TZ parameter is an IANA
 * identifier ("Asia/Tokyo", "America/Los_Angeles") — the Node Intl runtime
 * resolves it; an unknown TZ falls back to UTC (defensive, won't crash).
 */

export interface QuietWindow {
  /** "HH:MM" 24-hour. Inclusive lower bound. */
  readonly start: string;
  /** "HH:MM" 24-hour. Exclusive upper bound. */
  readonly end: string;
}

/** Format `now` as "YYYY-MM-DD" in the given IANA tz. */
export function todayInTz(now: Date, tz: string): string {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(now);
    const y = parts.find(p => p.type === "year")?.value ?? "0000";
    const m = parts.find(p => p.type === "month")?.value ?? "00";
    const d = parts.find(p => p.type === "day")?.value ?? "00";
    return `${y}-${m}-${d}`;
  } catch {
    // Unknown tz — fall back to UTC. Better than throwing inside a tick.
    return now.toISOString().slice(0, 10);
  }
}

/** Lowercase short weekday ("mon".."sun") for `now` in the given IANA tz.
 *  DST-safe (Intl resolves the wall-clock per tz). Compute this and todayInTz
 *  from the SAME `now` so a midnight boundary can't split them. */
export function weekdayInTz(now: Date, tz: string): string {
  try {
    return new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short" })
      .format(now)
      .toLowerCase();
  } catch {
    // Unknown tz — fall back to UTC weekday.
    return ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][now.getUTCDay()];
  }
}

/** Extract minute-of-day (0-1439) for `now` in the given IANA tz. */
export function minuteOfDayInTz(now: Date, tz: string): number {
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    }).formatToParts(now);
    const h = parts.find(p => p.type === "hour")?.value ?? "0";
    const m = parts.find(p => p.type === "minute")?.value ?? "0";
    // Intl can emit "24" for midnight on some platforms (hour12:false + node
    // versions). Normalize: 24 → 0.
    const hourNum = parseInt(h, 10) % 24;
    const minNum = parseInt(m, 10);
    return hourNum * 60 + minNum;
  } catch {
    // Unknown tz → use UTC clock.
    return now.getUTCHours() * 60 + now.getUTCMinutes();
  }
}

/** Parse "HH:MM" to minutes-of-day. Returns null on malformed. */
export function parseHhMm(s: string): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(s);
  if (!m) return null;
  const h = parseInt(m[1], 10);
  const min = parseInt(m[2], 10);
  if (h < 0 || h > 23 || min < 0 || min > 59) return null;
  return h * 60 + min;
}

/**
 * Is `now` (in `tz`) inside the quiet window?
 *
 * - Non-wrapping (`start < end`, e.g. 13:00–17:00): inside iff
 *   `start <= now < end`.
 * - Wrapping (`start > end`, e.g. 23:00–07:00): inside iff `now >= start` OR
 *   `now < end`. This is the common case (sleep window).
 * - Degenerate (`start === end`): treated as empty window (never inside) so
 *   a typo doesn't silently lock the digest off forever.
 * - Malformed HH:MM: treated as no quiet window (returns false). Caller's
 *   validation at config-set time prints a warning; runtime defense.
 */
export function isInQuietHours(now: Date, window: QuietWindow | null | undefined, tz: string): boolean {
  if (!window) return false;
  const start = parseHhMm(window.start);
  const end = parseHhMm(window.end);
  if (start === null || end === null) return false;
  if (start === end) return false; // empty window
  const cur = minuteOfDayInTz(now, tz);
  if (start < end) {
    return cur >= start && cur < end;
  }
  // Wrapping: e.g. 23:00 → 07:00. Inside if now is past start (same day) OR
  // before end (next morning).
  return cur >= start || cur < end;
}

/**
 * Has the digest fire time been reached today?
 *
 * Returns true iff the current minute-of-day in `tz` is >= the target
 * minute-of-day. The "already-fired-today" check (separate from this
 * predicate) prevents re-fire after the target has been reached.
 *
 * Malformed target → false (defensive: better to skip than to fire on a typo).
 */
export function digestTimeReached(now: Date, targetHhMm: string, tz: string): boolean {
  const target = parseHhMm(targetHhMm);
  if (target === null) return false;
  return minuteOfDayInTz(now, tz) >= target;
}
