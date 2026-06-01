/**
 * HEARTBEAT.md parser (Design A format).
 *
 * Under Design A, HEARTBEAT.md is a list of check IDs (one per line) plus
 * an optional free-form context section the model reads via the Read tool.
 * Format:
 *
 *   # comment lines start with #, ignored
 *   open-prs                      ← a check ID
 *   ci-red
 *
 *   ## Free-form context (everything from the first ## onward)
 *   Project context: this is the agent's own repo; treat ChatTransport-
 *   related issues as higher urgency.
 *
 * Parser contract:
 * - `checkIds`: every line above the first `##` heading that isn't blank
 *   and doesn't start with `#`. Whitespace-trimmed. Order preserved.
 * - `context`: everything from the first `##` to EOF, verbatim (the model
 *   needs the original markdown — `##` heading included).
 * - Missing file → empty result (`{ checkIds: [], context: "" }`). Caller
 *   decides whether absence is a skip or an error.
 */

export interface ParsedHeartbeatMd {
  readonly checkIds: readonly string[];
  readonly context: string;
}

export function parseHeartbeatMd(content: string): ParsedHeartbeatMd {
  const lines = content.split(/\r?\n/);
  const checkIds: string[] = [];
  let contextStart = -1;

  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (trimmed.startsWith("##")) {
      contextStart = i;
      break;
    }
    if (trimmed.length === 0) continue;
    if (trimmed.startsWith("#")) continue;
    // Strip inline comments (`open-prs  # this is what we want`).
    // Keep `open-prs` only — everything after the first `#` is comment.
    const hashIdx = trimmed.indexOf("#");
    const id = (hashIdx === -1 ? trimmed : trimmed.slice(0, hashIdx)).trim();
    if (id.length === 0) continue;
    checkIds.push(id);
  }

  const context = contextStart === -1 ? "" : lines.slice(contextStart).join("\n");
  return { checkIds, context };
}
