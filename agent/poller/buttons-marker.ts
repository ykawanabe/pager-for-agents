/**
 * P4 buttons marker — the platform-neutral replacement for the retired
 * mcp-telegram `send_telegram(buttons=…)` tool. claude has zero chat tools
 * now; to offer the user a small fixed set of tap choices it emits a marker
 * line in its reply text:
 *
 *     Pick one:
 *     [[buttons]]["Rebuild","Patch","Skip"]
 *
 * The poller parses the marker out of each assistant text block and routes to
 * ChatTransport.sendButtons (which renders native components per platform)
 * instead of sendText. JSON array is the documented form; a `|`-separated
 * fallback covers the case where the model didn't emit valid JSON.
 */

export interface ParsedButtons {
  /** The reply text with the marker line removed. May be empty. */
  body: string;
  /** Parsed labels, or null when there is no (valid) marker. */
  buttons: string[] | null;
}

/** Telegram's inline-keyboard practical limits, mirrored from the old
 *  mcp-telegram encoding: ≤8 buttons, each label ≤50 chars (callback_data is
 *  capped at 64 bytes by the Bot API and carries `ans:<tid>:<label>`). */
const MAX_BUTTONS = 8;
const MAX_LABEL_LEN = 50;

// Matches the marker and the rest of ITS line (`.` excludes newline). Case-
// insensitive so `[[Buttons]]` works too.
const MARKER_RE = /\[\[buttons\]\][ \t]*(.*)$/im;

export function parseButtonsMarker(text: string): ParsedButtons {
  const m = text.match(MARKER_RE);
  if (!m) return { body: text, buttons: null };

  const raw = (m[1] ?? "").trim();
  let labels: string[] = [];

  // Preferred form: a JSON array of strings on the same line.
  if (raw.startsWith("[")) {
    try {
      const arr: unknown = JSON.parse(raw);
      if (Array.isArray(arr)) labels = arr.map((v) => String(v));
    } catch {
      /* malformed JSON → fall through to pipe-split */
    }
  }
  // Fallback: pipe-separated labels.
  if (labels.length === 0) {
    labels = raw.split("|");
  }

  labels = labels
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .slice(0, MAX_BUTTONS)
    .map((s) => s.slice(0, MAX_LABEL_LEN));

  // A marker with no usable labels is not a button prompt — leave the text
  // untouched so the user still sees whatever the model wrote.
  if (labels.length === 0) return { body: text, buttons: null };

  const body = text.replace(MARKER_RE, "").trim();
  return { body, buttons: labels };
}
