/**
 * ClaudeDaemonRegistry — manages one long-lived ClaudeDaemon per topic.
 *
 * Owns the full message lifecycle for Phase 4:
 *   - lazy spawn on first message
 *   - per-topic debounce (collapse rapid user sends into one claude turn)
 *   - mid-turn queue (next batch waits for current turn-end)
 *   - text streaming → onText callback (multi-message UX)
 *   - "released for terminal" state (β handoff for "Open in Terminal")
 *   - crash detection + automatic respawn with backoff
 *
 * Lifecycle state machine per topic:
 *
 *     idle ─enqueue─→ pending ─timer─→ inFlight ─turn-end─→ idle/pending
 *     idle ─release─→ released
 *     released ─reacquire─→ idle (flushes any queued messages)
 *     any ─crash─→ crashed ─enqueue─→ idle (respawn on next message)
 */
import { ClaudeDaemon, type ClaudeDaemonOptions, type TurnEndInfo, type CrashInfo } from "./claude-daemon";

export interface RegistryOptions {
  /** Default 2000ms — collapse messages arriving within this window. */
  debounceMs?: number;
  /** Override the claude binary path (tests inject the fake). */
  claudeBin?: string;
  /** Per-topic daemon options — called lazily to build cwd/uuid/etc. */
  daemonOptsFor: (threadId: string) => Omit<ClaudeDaemonOptions, "claudeBin">;
  /** Called for every assistant text block — Telegram-post side effect. */
  onText: (threadId: string, text: string) => void;
  /** Optional: called when a batch is flushed to claude (text already sent). */
  onFlush?: (threadId: string, combinedText: string) => void;
  /** Optional: turn-end callback (post-result event) — cost logging. */
  onTurnEnd?: (threadId: string, info: TurnEndInfo) => void;
  /** Optional: backoff escalation cap. Default 60s. */
  maxBackoffMs?: number;
  /** Optional: how long a topic may sit "released" (β handoff to terminal)
   *  before an incoming message self-heals it back. Guards the orphaned-
   *  handoff failure (terminal died without signaling reacquire → topic stuck
   *  released → messages silently queued forever). Default 10min. The window
   *  must be long enough not to yank a daemon out from under a terminal the
   *  user is actively using. */
  releaseMaxMs?: number;
  /** Optional: inactivity watchdog for an inFlight turn. If the daemon emits
   *  no text and no turn-end/crash for this long, the turn is presumed wedged
   *  (the 2026-05-21 incident: daemon posted text then died without a result
   *  event → registry stuck inFlight). The watchdog kills the daemon so the
   *  crash path respawns. Reset on every text block (so a long-but-active turn
   *  is never killed). Default 5min. */
  inFlightTimeoutMs?: number;
}

type DaemonState = "idle" | "pending" | "inFlight" | "released" | "crashed";

interface DaemonHandle {
  daemon: ClaudeDaemon | null;
  state: DaemonState;
  /** Outstanding text pieces for the next batch. */
  queue: string[];
  /** Debounce timer (cleared if a new message arrives before fire). */
  debounceTimer: ReturnType<typeof setTimeout> | null;
  /** Exponential backoff on crash respawn. */
  backoffMs: number;
  /** Spawned count — exposed for tests to detect respawns. */
  spawnedCount: number;
  /** Wall-clock ms when releaseForTerminal was last called; null when not
   *  released. Drives the orphaned-handoff TTL self-heal. */
  releasedAt: number | null;
  /** Inactivity watchdog for the current inFlight turn (B2). Cleared on
   *  turn-end / crash / release / reset; reset on each text block. */
  inFlightTimer: ReturnType<typeof setTimeout> | null;
  /** Wall-clock ms of the last activity on this topic (enqueue or turn-end).
   *  Drives idle-daemon eviction (sweepIdle): a topic idle longer than the
   *  configured threshold is evicted to reclaim RAM. The session UUID on disk
   *  is preserved, so the next message respawns + --resumes — cold start, no
   *  context loss. */
  lastActivityAt: number;
  /** True only during stopTurn()'s intentional teardown. The on('crash')
   *  handler checks it to treat the SIGTERM-driven close as a clean stop
   *  (no backoff escalation, no respawn schedule) rather than a real crash —
   *  same idea as the "released" guard, but for /stop. */
  stopping: boolean;
}

export class ClaudeDaemonRegistry {
  private readonly opts: RegistryOptions;
  private readonly handles: Map<string, DaemonHandle> = new Map();

  constructor(opts: RegistryOptions) {
    this.opts = opts;
  }

  /** Total number of live daemons (state != released/crashed). */
  get daemonCount(): number {
    let n = 0;
    for (const h of this.handles.values()) {
      if (h.daemon && h.daemon.isAlive) n++;
    }
    return n;
  }

  /** Total spawn count across all topics, including respawns. Test hook. */
  get spawnedCount(): number {
    let n = 0;
    for (const h of this.handles.values()) n += h.spawnedCount;
    return n;
  }

  /** Inspect a topic's current state. */
  getStatus(threadId: string): DaemonState | "absent" {
    const h = this.handles.get(threadId);
    return h ? h.state : "absent";
  }

  /** Snapshot every topic's outstanding queue. Used by pair-switch teardown
   *  to preserve in-flight messages across registry replacement — without
   *  this, the user's pending text vanishes when their paired chat changes
   *  mid-conversation. Returned as `[threadId, queueCopy][]` tuples (queue
   *  arrays are copies, safe for the caller to mutate). */
  snapshotQueues(): Array<[string, string[]]> {
    const out: Array<[string, string[]]> = [];
    for (const [threadId, handle] of this.handles) {
      out.push([threadId, [...handle.queue]]);
    }
    return out;
  }

  /**
   * Enqueue a user message. Spawns the daemon if needed. The debounce
   * timer collapses rapid sends; mid-turn enqueues hold until turn-end.
   */
  enqueue(threadId: string, text: string): void {
    let handle = this.handles.get(threadId);
    if (!handle) {
      handle = {
        daemon: null,
        state: "idle",
        queue: [],
        debounceTimer: null,
        backoffMs: 0,
        spawnedCount: 0,
        releasedAt: null,
        inFlightTimer: null,
        lastActivityAt: Date.now(),
        stopping: false,
      };
      this.handles.set(threadId, handle);
    }
    handle.queue.push(text);
    // Activity stamp → keeps the idle-eviction sweep from reaping a topic the
    // user is actively messaging (the eviction clock restarts on every send).
    handle.lastActivityAt = Date.now();

    // If terminal is holding the daemon, the message normally just sits in the
    // queue until reacquireFromTerminal fires. BUT if it's been released
    // longer than releaseMaxMs, the terminal almost certainly died without
    // signaling reacquire (the orphaned-handoff incident 2026-05-21) — so
    // self-heal: reacquire now and let this message (plus any backlog) flush,
    // rather than swallowing it forever.
    if (handle.state === "released") {
      const maxMs = this.opts.releaseMaxMs ?? 10 * 60_000;
      if (handle.releasedAt != null && Date.now() - handle.releasedAt > maxMs) {
        void this.reacquireFromTerminal(threadId);
      }
      return;
    }

    // If a turn is in progress, leave the queue alone — turn-end will
    // re-arm the debounce timer.
    if (handle.state === "inFlight") return;

    this.armDebounce(threadId, handle);
  }

  /** Kill the topic's daemon for β handoff (Open in Terminal). Incoming
   *  messages queue silently until reacquireFromTerminal. */
  async releaseForTerminal(threadId: string): Promise<void> {
    const handle = this.handles.get(threadId);
    if (!handle) return;
    // Set "released" BEFORE awaiting daemon.stop() so the on('crash') handler
    // that fires during teardown sees the released state and doesn't flip
    // us to "crashed" — which would race with the post-await write of
    // "released" below and leave a stale state. Also stops new enqueues
    // from arming a debounce timer mid-teardown.
    handle.state = "released";
    handle.releasedAt = Date.now();
    if (handle.debounceTimer) {
      clearTimeout(handle.debounceTimer);
      handle.debounceTimer = null;
    }
    if (handle.inFlightTimer) {
      clearTimeout(handle.inFlightTimer);
      handle.inFlightTimer = null;
    }
    if (handle.daemon) {
      // SIGTERM gives claude a chance to close the session lock file
      // cleanly — necessary so the user's TUI `claude --resume` doesn't
      // refuse with "Session ID already in use".
      await handle.daemon.stop("SIGTERM");
      handle.daemon = null;
    }
  }

  /** Respawn the daemon after the user closes their terminal. Flushes
   *  any queued messages that arrived during the released window. */
  async reacquireFromTerminal(threadId: string): Promise<void> {
    const handle = this.handles.get(threadId);
    if (!handle) return;
    handle.state = "idle";
    handle.releasedAt = null;
    // If there's queued work, arm the debounce now. Otherwise the
    // daemon stays unspawned until the next enqueue (lazy).
    if (handle.queue.length > 0) {
      this.armDebounce(threadId, handle);
    }
  }

  /** Fully reset a topic's state — stop the daemon, drop the queue, drop
   *  the handle entry entirely. Next enqueue lazy-spawns a fresh daemon
   *  using whatever options daemonOptsFor() returns at that moment (so
   *  callers can rotate session UUIDs etc. *before* the next message).
   *
   *  Distinct from releaseForTerminal: that one expects reacquire from a
   *  terminal handoff and preserves the queue. resetTopic is for /clear
   *  semantics — "throw the conversation away, restart with whatever the
   *  caller has just configured."
   *
   *  Pending queue is intentionally dropped (matches user expectation:
   *  /clear means "forget what was going on"). If the caller wants to
   *  preserve a message across the reset, they should re-enqueue it. */
  async resetTopic(threadId: string): Promise<void> {
    const handle = this.handles.get(threadId);
    if (!handle) return;
    if (handle.debounceTimer) {
      clearTimeout(handle.debounceTimer);
      handle.debounceTimer = null;
    }
    if (handle.inFlightTimer) {
      clearTimeout(handle.inFlightTimer);
      handle.inFlightTimer = null;
    }
    if (handle.daemon) {
      await handle.daemon.stop("SIGTERM");
    }
    this.handles.delete(threadId);
  }

  /** Abort the in-flight turn for a topic WITHOUT discarding the session or
   *  queue. Mirrors the kill side of resetTopic but PRESERVES the handle and
   *  does NOT rotate the session UUID — the on-disk session is untouched, so
   *  the next enqueue lazy-respawns and --resumes the SAME conversation. Only
   *  the running turn is dropped.
   *
   *  Returns true if a turn was actually aborted, false if nothing was running
   *  (idle/pending/released/crashed/absent) — lets the caller pick the reply
   *  copy ("Stopped." vs "Nothing running to stop.").
   *
   *  v1 is the reliable fallback (SIGTERM→SIGKILL the subprocess, lazy respawn
   *  on next message). The raw `claude -p --input-format stream-json` CLI has
   *  no in-band interrupt control message and SIGINT kills the whole headless
   *  process (verified 2026-05-22, CLI v2.1.148), so a "leave the subprocess
   *  alive" graceful path is not available yet. */
  async stopTurn(threadId: string): Promise<boolean> {
    const handle = this.handles.get(threadId);
    if (!handle) return false;
    if (handle.state !== "inFlight") return false;
    this.clearInFlightTimer(handle);
    if (handle.debounceTimer) {
      clearTimeout(handle.debounceTimer);
      handle.debounceTimer = null;
    }
    // Mark intentional stop BEFORE awaiting stop() so the on('crash') handler
    // that fires during teardown takes the clean-stop branch (mirrors how
    // releaseForTerminal sets "released" before the await).
    handle.stopping = true;
    if (handle.daemon) {
      // SIGTERM (not SIGKILL): gives claude a chance to release its session
      // .lock cleanly so the next --resume doesn't refuse with "Session ID
      // already in use". stop() escalates to SIGKILL after 5s if needed.
      await handle.daemon.stop("SIGTERM");
      handle.daemon = null;
    }
    handle.stopping = false;
    handle.state = "idle";
    handle.backoffMs = 0;
    handle.lastActivityAt = Date.now();
    // Preserve the queue: any messages that arrived during the aborted turn
    // resume processing on the lazy respawn.
    if (handle.queue.length > 0) this.armDebounce(threadId, handle);
    return true;
  }

  /** Tear down all daemons. Called on poller graceful exit. */
  async shutdown(): Promise<void> {
    const promises: Promise<void>[] = [];
    for (const handle of this.handles.values()) {
      if (handle.debounceTimer) {
        clearTimeout(handle.debounceTimer);
        handle.debounceTimer = null;
      }
      if (handle.inFlightTimer) {
        clearTimeout(handle.inFlightTimer);
        handle.inFlightTimer = null;
      }
      if (handle.daemon) {
        promises.push(handle.daemon.stop("SIGTERM"));
      }
    }
    await Promise.all(promises);
    this.handles.clear();
  }

  /** Evict daemons that have sat idle (quiescent, empty queue) for at least
   *  idleMs, reclaiming their RAM. Eviction reuses resetTopic — it SIGTERMs
   *  the daemon and drops the handle, but leaves the session UUID on disk
   *  untouched, so the next inbound message lazy-respawns and --resumes the
   *  same conversation (cold start, no context loss). Idle eviction is thus
   *  an automatic `/restart` triggered by inactivity.
   *
   *  No-op when idleMs <= 0 (feature disabled). Only "idle" handles with an
   *  alive daemon and an empty queue are eligible — pending/inFlight/released/
   *  crashed are never touched, so a live turn or a β-handoff is never raced.
   *  Returns the evicted threadIds (for logging). */
  async sweepIdle(idleMs: number): Promise<string[]> {
    if (idleMs <= 0) return [];
    const now = Date.now();
    const evictable: string[] = [];
    for (const [threadId, h] of this.handles) {
      if (h.state !== "idle") continue;
      if (h.queue.length > 0) continue;
      if (!h.daemon || !h.daemon.isAlive) continue;
      if (now - h.lastActivityAt < idleMs) continue;
      evictable.push(threadId);
    }
    for (const threadId of evictable) {
      await this.resetTopic(threadId);
    }
    return evictable;
  }

  // ─── internals ─────────────────────────────────────────────────────────────

  private armDebounce(threadId: string, handle: DaemonHandle): void {
    if (handle.debounceTimer) {
      clearTimeout(handle.debounceTimer);
    }
    handle.state = "pending";
    handle.debounceTimer = setTimeout(() => {
      void this.flush(threadId);
    }, this.opts.debounceMs ?? 2000);
  }

  private clearInFlightTimer(handle: DaemonHandle): void {
    if (handle.inFlightTimer) {
      clearTimeout(handle.inFlightTimer);
      handle.inFlightTimer = null;
    }
  }

  /** (Re)arm the inactivity watchdog for an inFlight turn. If it fires, the
   *  turn produced no text/turn-end/crash for inFlightTimeoutMs — presumed
   *  wedged (the 2026-05-21 incident: a daemon that posted text then died
   *  without a result event left the registry stuck inFlight forever). We
   *  SIGKILL the daemon; its 'close' → 'crash' event drives respawn through
   *  the existing crash handler (which also frees the session lock for the
   *  resume). Reset on every text block so an active turn is never killed. */
  private armInFlightWatchdog(threadId: string, handle: DaemonHandle): void {
    this.clearInFlightTimer(handle);
    const timeoutMs = this.opts.inFlightTimeoutMs ?? 5 * 60_000;
    handle.inFlightTimer = setTimeout(() => {
      const h = this.handles.get(threadId);
      if (!h || h.state !== "inFlight") return;
      h.inFlightTimer = null;
      const wedged = h.daemon;
      if (wedged) {
        // SIGKILL (not SIGTERM): the daemon is wedged and won't honor a
        // graceful shutdown. The crash event recovers state + respawns.
        void wedged.stop("SIGKILL");
      } else {
        // No daemon object but stuck inFlight — recover directly.
        h.state = "crashed";
        h.backoffMs = 0;
        h.state = "idle";
        if (h.queue.length > 0) this.armDebounce(threadId, h);
      }
    }, timeoutMs);
  }

  private async flush(threadId: string): Promise<void> {
    const handle = this.handles.get(threadId);
    if (!handle || handle.queue.length === 0) return;
    handle.debounceTimer = null;

    // Spawn the daemon if not running.
    if (!handle.daemon || !handle.daemon.isAlive) {
      const ok = await this.spawn(threadId, handle);
      if (!ok) {
        handle.state = "crashed";
        return;
      }
    }

    // Combine queued text into one user event. Single newline between
    // entries reads naturally for "I'm sending a few thoughts" patterns;
    // multi-paragraph claude prompts use blank line. Single newline is
    // the safer default.
    const combined = handle.queue.join("\n");
    handle.queue = [];
    handle.state = "inFlight";

    try {
      this.opts.onFlush?.(threadId, combined);
      await handle.daemon!.send(combined);
      // Start the inactivity watchdog: if the daemon emits no text and no
      // turn-end/crash before it fires, the turn is presumed wedged.
      this.armInFlightWatchdog(threadId, handle);
    } catch (err) {
      // Daemon went away between the alive-check and the write. Re-queue
      // the message so the user doesn't lose it, then rearm the debounce
      // so the respawn path actually fires — without rearm, the message
      // sits in the queue forever if no follow-up enqueue ever happens.
      handle.state = "crashed";
      handle.queue.unshift(combined);
      // Defer the rearm so the on('crash') handler (which may fire in the
      // same tick) finishes setting state first. The crash handler will
      // transition crashed→idle after backoff and arm-debounce; if a write
      // error fires before crash, we self-recover via the next tick.
      setTimeout(() => {
        const h = this.handles.get(threadId);
        if (!h) return;
        // Only rearm if state is still crashed (avoid double-arming if the
        // crash handler already armed during its backoff timer).
        if (h.state === "crashed" && h.queue.length > 0) {
          h.state = "idle";
          this.armDebounce(threadId, h);
        }
      }, 0);
    }
  }

  /** Create a fresh ClaudeDaemon, wire its events to registry callbacks,
   *  start it, and stash in the handle. Returns true on success. */
  private async spawn(threadId: string, handle: DaemonHandle): Promise<boolean> {
    const daemonOpts = this.opts.daemonOptsFor(threadId);
    const daemon = new ClaudeDaemon({
      ...daemonOpts,
      claudeBin: this.opts.claudeBin,
    });

    daemon.on("text", (text: string) => {
      // Activity → reset the inactivity watchdog so a long-but-active turn is
      // never killed (only true silence trips it).
      const h = this.handles.get(threadId);
      if (h && h.state === "inFlight") this.armInFlightWatchdog(threadId, h);
      this.opts.onText(threadId, text);
    });

    daemon.on("turn-end", (info: TurnEndInfo) => {
      this.opts.onTurnEnd?.(threadId, info);
      const h = this.handles.get(threadId);
      if (!h) return;
      this.clearInFlightTimer(h);
      if (h.state === "released") return; // user yanked the daemon mid-turn
      // Healthy turn — reset crash backoff.
      h.backoffMs = 0;
      h.state = "idle";
      // Idle clock starts now: the daemon just went quiescent. sweepIdle
      // measures from here.
      h.lastActivityAt = Date.now();
      // If more messages arrived while we were in-flight, arm next debounce.
      if (h.queue.length > 0) this.armDebounce(threadId, h);
    });

    daemon.on("crash", (info: CrashInfo) => {
      const h = this.handles.get(threadId);
      if (!h) return;
      this.clearInFlightTimer(h);
      // Clean exit during release-for-terminal is expected; don't treat as crash.
      if (h.state === "released") return;
      // Intentional /stop teardown: stopTurn() owns the post-stop transition
      // and re-arming. Don't apply crash backoff or schedule a respawn here.
      if (h.stopping) { h.daemon = null; return; }
      h.daemon = null;
      h.state = "crashed";
      // Schedule a respawn attempt with exponential backoff. If the queue
      // is non-empty, the respawn will flush; otherwise stays idle until
      // the next enqueue.
      const max = this.opts.maxBackoffMs ?? 60_000;
      h.backoffMs = h.backoffMs === 0 ? 500 : Math.min(h.backoffMs * 2, max);
      setTimeout(() => {
        const handle = this.handles.get(threadId);
        if (!handle) return;
        if (handle.state !== "crashed") return; // user did something in the meantime
        // Eager respawn if there's work to do; otherwise stay crashed and
        // let the next enqueue trigger spawn.
        if (handle.queue.length > 0) {
          handle.state = "idle";
          this.armDebounce(threadId, handle);
        } else {
          handle.state = "idle";
        }
      }, h.backoffMs);
    });

    try {
      await daemon.start();
    } catch {
      return false;
    }
    handle.daemon = daemon;
    handle.spawnedCount += 1;
    handle.state = "idle";
    return true;
  }
}
