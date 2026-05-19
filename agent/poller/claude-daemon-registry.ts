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
      };
      this.handles.set(threadId, handle);
    }
    handle.queue.push(text);

    // If terminal is holding the daemon, the message just sits in the
    // queue until reacquireFromTerminal fires.
    if (handle.state === "released") return;

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
    if (handle.debounceTimer) {
      clearTimeout(handle.debounceTimer);
      handle.debounceTimer = null;
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
    // If there's queued work, arm the debounce now. Otherwise the
    // daemon stays unspawned until the next enqueue (lazy).
    if (handle.queue.length > 0) {
      this.armDebounce(threadId, handle);
    }
  }

  /** Tear down all daemons. Called on poller graceful exit. */
  async shutdown(): Promise<void> {
    const promises: Promise<void>[] = [];
    for (const handle of this.handles.values()) {
      if (handle.debounceTimer) {
        clearTimeout(handle.debounceTimer);
        handle.debounceTimer = null;
      }
      if (handle.daemon) {
        promises.push(handle.daemon.stop("SIGTERM"));
      }
    }
    await Promise.all(promises);
    this.handles.clear();
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
      this.opts.onText(threadId, text);
    });

    daemon.on("turn-end", (info: TurnEndInfo) => {
      this.opts.onTurnEnd?.(threadId, info);
      const h = this.handles.get(threadId);
      if (!h) return;
      if (h.state === "released") return; // user yanked the daemon mid-turn
      // Healthy turn — reset crash backoff.
      h.backoffMs = 0;
      h.state = "idle";
      // If more messages arrived while we were in-flight, arm next debounce.
      if (h.queue.length > 0) this.armDebounce(threadId, h);
    });

    daemon.on("crash", (info: CrashInfo) => {
      const h = this.handles.get(threadId);
      if (!h) return;
      // Clean exit during release-for-terminal is expected; don't treat as crash.
      if (h.state === "released") return;
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
