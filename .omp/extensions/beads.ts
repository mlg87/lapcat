/**
 * beads.ts — omp extension that makes the beads graph maintain itself.
 *
 * Automates the four bookkeeping steps agents used to be told to remember:
 *
 *   - priming     `bd prime`, `bd ready --exclude-type epic`, and
 *                 `bd list --status in_progress` are cached at session start
 *                 and injected once, on the first turn that actually runs.
 *   - durability  `bd dolt push` runs on a 15-minute debounce and at session
 *                 stop, but only when this session issued a bd write.
 *   - mirroring   scripts/beads-reconcile.ts runs in the background (GitHub ->
 *                 beads mirror, merged-work sweep), debounced across sessions.
 *   - safety      every handler is observe-only and fail-open. Nothing here can
 *                 block a tool call, cancel an event, or delay session settle.
 *
 * Claiming is deliberately NOT automated: a `tool_call` gate is fail-closed
 * (a throwing handler blocks the tool), each bd call costs ~1.5 s of embedded
 * Dolt startup, subagents legitimately edit under a parent's claim, and docs
 * work has no bead. What is automated is that the claim instructions are always
 * present, which is what the priming injection guarantees.
 *
 * Kill switch: `LAPCAT_BEADS_HOOK=off omp …` disables everything below.
 *
 * Loaded by native project discovery from `<cwd>/.omp/extensions` — that is the
 * project extension-module root; there is no `.omp/hooks/` root.
 *
 * The `ExtensionAPI` types live in the globally installed omp package, which is
 * not a dependency of this repo — importing them would break `tsc` and ESLint
 * for every developer. The narrow structural types below describe exactly the
 * surface this file uses.
 */

import { existsSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

// ============================================================================
// Configuration
// ============================================================================

const PRIME_TIMEOUT_MS = 5_000;
const PUSH_TIMEOUT_MS = 60_000;
const RECONCILE_TIMEOUT_MS = 120_000;
const GIT_TIMEOUT_MS = 5_000;
/** Flush cadence; also the reconcile trigger. */
const FLUSH_INTERVAL_MS = 15 * 60_000;
/** Cross-session reconcile debounce, stored in `bd kv`. */
const RECONCILE_DEBOUNCE_MS = 10 * 60_000;
/** A lock older than this belonged to a crashed process. */
const STALE_LOCK_MS = 10 * 60_000;
const RECONCILE_STAMP_KEY = "reconcile.last-run";
/** Cross-session "the graph has unpushed writes" flag, in `.beads/`. */
const DIRTY_MARKER = "omp-dirty";
const PRIME_MESSAGE_TYPE = "lapcat.beads.prime";
const REPRIME_EVENTS = ["session_compact", "session_branch", "session_switch"];

/** bd subcommands that mutate the graph, so the Dolt remote is now behind. */
const BD_WRITE =
  /\bbd\s+(?:create|update|close|reopen|delete|dep|label|defer|undefer|remember|forget|gate|kv\s+set|q\s)/;

const AUTOMATION_NOTICE = [
  "",
  "— beads automation (omp extension `.omp/extensions/beads.ts`) —",
  "Automatic: this priming injection, `bd dolt push` (15-min debounce plus",
  "session stop), the GitHub->beads mirror and the merged-work sweep",
  "(scripts/beads-reconcile.ts). Still yours: claim before editing",
  "(`bd update <id> --claim`), close with a reason, and put the bead id in the",
  "commit subject — the sweep closes beads by that suffix. Disable everything",
  "with LAPCAT_BEADS_HOOK=off.",
  "`bd ready --exclude-type epic --label <area> --claim` claims the next",
  "matching task in one call.",
].join("\n");

// ============================================================================
// Minimal structural view of the extension API
// ============================================================================

interface ExecResult {
  readonly stdout: string;
  readonly stderr: string;
  readonly code: number;
}

interface ExecOptions {
  readonly timeout?: number;
  readonly cwd?: string;
}

interface Logger {
  readonly error: (message: string) => void;
  readonly info: (message: string) => void;
}

interface ExtensionContext {
  readonly hasUI: boolean;
  readonly cwd: string;
  readonly setInterval: (handler: () => void, ms: number) => unknown;
}

interface PrimeMessage {
  readonly message: {
    readonly customType: string;
    readonly content: string;
    readonly display: boolean;
  };
}

type HandlerResult = PrimeMessage | undefined;

type Handler = (
  event: unknown,
  ctx: ExtensionContext,
) => HandlerResult | Promise<HandlerResult>;

interface ExtensionAPI {
  readonly logger: Logger;
  readonly on: (event: string, handler: Handler) => void;
  readonly exec: (
    command: string,
    args: string[],
    options?: ExecOptions,
  ) => Promise<ExecResult>;
  readonly setLabel: (label: string) => void;
}

/** Everything mutable in one place, so the helpers below can stay top-level. */
interface State {
  primeText: string | null;
  needsPrime: boolean;
  dirty: boolean;
  flushing: boolean;
  /** Primary checkout's `.beads/`; every worktree shares it. */
  beadsDir: string | null;
}

// ============================================================================
// Entry point
// ============================================================================

export default function beadsExtension(pi: ExtensionAPI): void {
  if (process.env.LAPCAT_BEADS_HOOK === "off") {
    return;
  }
  pi.setLabel("beads");
  const state: State = {
    primeText: null,
    needsPrime: false,
    dirty: false,
    flushing: false,
    beadsDir: null,
  };
  registerSessionHandlers(pi, state);
  registerPrimeHandlers(pi, state);
  registerWriteTracking(pi, state);
}

function registerSessionHandlers(pi: ExtensionAPI, state: State): void {
  pi.on("session_start", (_event, ctx) => {
    state.needsPrime = true;
    if (!ctx.hasUI) {
      // Verified: project extensions DO load in subagent/headless sessions
      // (a scout subagent produced a second session_start). They stay inert —
      // no priming (nothing would ever read the cache without a UI to inject
      // into), no interval, no reconcile — so a 32-wide task batch adds zero
      // bd calls. Their `tool_call` observation still marks the graph dirty,
      // and `session_stop` never fires for them, so the parent's flush covers
      // their writes.
      return undefined;
    }
    // Detached: session start must not wait on the Dolt engine (~1.5 s a call).
    void cachePrime(pi, state, ctx.cwd);
    void reconcile(pi, state, ctx.cwd);
    ctx.setInterval(() => {
      void pushIfDirty(pi, state, ctx.cwd);
      void reconcile(pi, state, ctx.cwd);
    }, FLUSH_INTERVAL_MS);
    return undefined;
  });

  pi.on("session_stop", (_event, ctx) => {
    // Detached and unawaited: `session_stop` handlers are awaited before
    // settle, and a push can take ~20 s.
    void pushIfDirty(pi, state, ctx.cwd).catch((error: unknown) => {
      logIssue(pi, "stop-time push failed", error);
    });
    return undefined;
  });
}

function registerPrimeHandlers(pi: ExtensionAPI, state: State): void {
  pi.on("before_agent_start", (_event, ctx) => {
    if (!state.needsPrime || !ctx.hasUI || state.primeText === null) {
      return undefined;
    }
    state.needsPrime = false;
    return {
      message: {
        customType: PRIME_MESSAGE_TYPE,
        content: state.primeText,
        display: true,
      },
    };
  });

  // Recovery contexts lose the injected message, so re-arm for the next turn.
  for (const event of REPRIME_EVENTS) {
    pi.on(event, () => {
      state.needsPrime = true;
      return undefined;
    });
  }
}

function registerWriteTracking(pi: ExtensionAPI, state: State): void {
  pi.on("tool_call", (event, ctx) => {
    // Observe-only. `tool_call` is fail-closed — a throw here would block the
    // tool — so this swallows everything and returns nothing.
    try {
      if (isBdWrite(event)) {
        state.dirty = true;
        // Subagents get their own extension instance and never fire
        // `session_stop`, so in-memory dirtiness alone would strand their
        // writes. `bd dolt push` pushes the whole graph, so any session's
        // flush covers every session's writes — the marker is what tells it
        // there is something to flush.
        void markDirty(pi, state, ctx.cwd);
      }
    } catch {
      /* unreachable in practice; a bug here must not block a tool */
    }
    return undefined;
  });
}

async function markDirty(
  pi: ExtensionAPI,
  state: State,
  cwd: string,
): Promise<void> {
  const dir = await resolveBeadsDir(pi, state, cwd);
  if (dir === null) {
    return;
  }
  try {
    writeFileSync(join(dir, DIRTY_MARKER), `${new Date().toISOString()}\n`);
  } catch (error) {
    logIssue(pi, "cannot record the dirty marker", error);
  }
}

// ============================================================================
// Background work
// ============================================================================

/** Structural view of `bd list --type epic --status open --json` rows. */
interface EpicRow {
  readonly id: string;
  readonly title: string;
  readonly priority: number;
  readonly dependent_count: number;
}

/**
 * Nudges toward decomposing an epic before claiming it: `bd ready` can only
 * ever offer a whole epic once it has zero children, which blocks a second
 * agent from picking up a sub-task of already-claimed work. "" when every
 * open epic already has at least one child (or the read/parse failed).
 */
export function renderUndecomposedEpics(json: string): string {
  let rows: EpicRow[];
  try {
    const parsed: unknown = JSON.parse(json);
    rows = Array.isArray(parsed) ? (parsed as EpicRow[]) : [];
  } catch {
    return "";
  }
  const childless = rows.filter((row) => row.dependent_count === 0);
  if (childless.length === 0) {
    return "";
  }
  const lines = childless.map(
    (row) => `${row.id} P${String(row.priority)} ${row.title}`,
  );
  return [
    "Epics with no child beads — decompose with bd create --graph before claiming:",
    ...lines,
  ].join("\n");
}

/** null when the command failed or produced nothing worth showing. */
function sectionText(
  result: ExecResult | null,
  render: (result: ExecResult) => string | null,
): string | null {
  if (result === null || result.code !== 0) {
    return null;
  }
  return render(result);
}

async function cachePrime(
  pi: ExtensionAPI,
  state: State,
  cwd: string,
): Promise<void> {
  const [prime, ready, inProgress, undecomposed] = await Promise.all([
    run(pi, ["bd", "prime"], PRIME_TIMEOUT_MS, cwd),
    run(pi, ["bd", "ready", "--exclude-type", "epic"], PRIME_TIMEOUT_MS, cwd),
    run(pi, ["bd", "list", "--status", "in_progress"], PRIME_TIMEOUT_MS, cwd),
    run(
      pi,
      ["bd", "list", "--type", "epic", "--status", "open", "--json"],
      PRIME_TIMEOUT_MS,
      cwd,
    ),
  ]);
  if (prime === null || prime.code !== 0) {
    state.primeText = null; // bd missing or slow: inject nothing at all
    return;
  }
  const sections = [
    sectionText(
      ready,
      (r) => `$ bd ready --exclude-type epic\n${r.stdout.trim()}`,
    ),
    sectionText(inProgress, (r) =>
      r.stdout.trim() === ""
        ? null
        : `$ bd list --status in_progress\n${r.stdout.trim()}`,
    ),
    sectionText(undecomposed, (r) => renderUndecomposedEpics(r.stdout) || null),
  ].filter((section): section is string => section !== null);
  const body = sections.length === 0 ? "" : `\n\n${sections.join("\n\n")}`;
  state.primeText = `${prime.stdout.trim()}${body}${AUTOMATION_NOTICE}`;
}

async function pushIfDirty(
  pi: ExtensionAPI,
  state: State,
  cwd: string,
): Promise<void> {
  if (state.flushing) {
    return;
  }
  const dir = await resolveBeadsDir(pi, state, cwd);
  if (dir === null) {
    return;
  }
  const marker = join(dir, DIRTY_MARKER);
  if (!state.dirty && !existsSync(marker)) {
    return;
  }
  state.flushing = true;
  try {
    await withLock(pi, join(dir, "omp-push.lock"), async () => {
      // Cleared before the push: a write during it re-marks for the next flush.
      state.dirty = false;
      rmSync(marker, { force: true });
      const result = await run(
        pi,
        ["bd", "dolt", "push"],
        PUSH_TIMEOUT_MS,
        cwd,
      );
      if (result !== null && result.code !== 0) {
        state.dirty = true;
        logIssue(
          pi,
          `bd dolt push exited ${String(result.code)}`,
          result.stderr.trim(),
        );
      }
    });
  } finally {
    state.flushing = false;
  }
}

async function reconcile(
  pi: ExtensionAPI,
  state: State,
  cwd: string,
): Promise<void> {
  const dir = await resolveBeadsDir(pi, state, cwd);
  if (dir === null || !(await reconcileDue(pi, cwd))) {
    return;
  }
  const root = dirname(dir);
  await withLock(pi, join(dir, "omp-reconcile.lock"), async () => {
    const result = await run(
      pi,
      ["npx", "tsx", join(root, "scripts", "beads-reconcile.ts")],
      RECONCILE_TIMEOUT_MS,
      root,
    );
    if (result !== null && result.code !== 0) {
      logIssue(
        pi,
        `reconcile exited ${String(result.code)}`,
        result.stderr.trim(),
      );
    }
  });
}

/** Cross-session debounce: the stamp lives in the shared graph, not in memory. */
async function reconcileDue(pi: ExtensionAPI, cwd: string): Promise<boolean> {
  const stamp = await run(
    pi,
    ["bd", "kv", "get", RECONCILE_STAMP_KEY],
    PRIME_TIMEOUT_MS,
    cwd,
  );
  const previous = Number(stamp?.code === 0 ? stamp.stdout.trim() : "");
  if (
    Number.isFinite(previous) &&
    Date.now() - previous < RECONCILE_DEBOUNCE_MS
  ) {
    return false;
  }
  await run(
    pi,
    ["bd", "kv", "set", RECONCILE_STAMP_KEY, String(Date.now())],
    PRIME_TIMEOUT_MS,
    cwd,
  );
  return true;
}

// ============================================================================
// Helpers
// ============================================================================

function logIssue(pi: ExtensionAPI, message: string, detail?: unknown): void {
  try {
    if (detail === undefined) {
      pi.logger.info(`[beads] ${message}`);
    } else {
      pi.logger.error(`[beads] ${message}: ${String(detail)}`);
    }
  } catch {
    /* a broken logger must not be able to break a session */
  }
}

/** Command runner that never throws and never rejects. */
async function run(
  pi: ExtensionAPI,
  argv: readonly [string, ...string[]],
  timeout: number,
  cwd: string,
): Promise<ExecResult | null> {
  const [command, ...args] = argv;
  try {
    return await pi.exec(command, args, { timeout, cwd });
  } catch (error) {
    logIssue(pi, `${argv.join(" ")} failed`, error);
    return null;
  }
}

async function resolveBeadsDir(
  pi: ExtensionAPI,
  state: State,
  cwd: string,
): Promise<string | null> {
  if (state.beadsDir !== null) {
    return state.beadsDir;
  }
  // `--git-common-dir` resolves to the primary checkout's .git even from a
  // worktree, which is where the single shared `.beads/` workspace lives.
  const result = await run(
    pi,
    ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
    GIT_TIMEOUT_MS,
    cwd,
  );
  if (result === null || result.code !== 0) {
    return null;
  }
  const common = result.stdout.trim();
  if (common === "") {
    return null;
  }
  state.beadsDir = join(dirname(common), ".beads");
  return state.beadsDir;
}

/**
 * Exclusive lockfile so concurrent sessions elect one owner per task.
 * Contention is not an error: the holder does the same work.
 */
async function withLock(
  pi: ExtensionAPI,
  file: string,
  task: () => Promise<void>,
): Promise<void> {
  if (!claimLock(pi, file)) {
    return;
  }
  try {
    await task();
  } finally {
    try {
      rmSync(file, { force: true });
    } catch (error) {
      logIssue(pi, `cannot release ${file}`, error);
    }
  }
}

function claimLock(pi: ExtensionAPI, file: string): boolean {
  const stamp = `${String(process.pid)} ${new Date().toISOString()}\n`;
  try {
    writeFileSync(file, stamp, { flag: "wx" });
    return true;
  } catch {
    return stealStaleLock(pi, file, stamp);
  }
}

function stealStaleLock(
  pi: ExtensionAPI,
  file: string,
  stamp: string,
): boolean {
  try {
    if (Date.now() - statSync(file).mtimeMs < STALE_LOCK_MS) {
      return false; // live holder: it will do the same work
    }
    rmSync(file, { force: true });
    writeFileSync(file, stamp, { flag: "wx" });
    logIssue(pi, `stole stale lock ${file}`);
    return true;
  } catch {
    return false;
  }
}

function isBdWrite(event: unknown): boolean {
  if (typeof event !== "object" || event === null) {
    return false;
  }
  if (!("toolName" in event) || event.toolName !== "bash") {
    return false;
  }
  if (
    !("input" in event) ||
    typeof event.input !== "object" ||
    event.input === null ||
    !("command" in event.input)
  ) {
    return false;
  }
  const command = event.input.command;
  return typeof command === "string" && BD_WRITE.test(command);
}
