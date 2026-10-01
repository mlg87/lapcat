/**
 * beads-reconcile.ts
 *
 * Keeps the beads execution graph in step with GitHub and with main, so no
 * agent has to remember the bookkeeping. Four idempotent passes:
 *
 *   1. Mirror   — open GitHub issues -> epic beads (create/reopen/close, edges).
 *                 One-way: GitHub is authoritative, this script never writes
 *                 to GitHub. Native `bd github sync` is deliberately unused: it
 *                 imports every closed issue and does not dedupe against our
 *                 `external_ref gh-N` refs (verified against bd 1.2.2).
 *   2. Sweep    — commits merged to origin/main whose subject carries `(lc-xxx)`
 *                 close the named bead. Merge is detected where the graph lives,
 *                 which is why this is not a GitHub Action (CI has no .beads/).
 *   3. Gates    — `bd gate check --type=gh` resolves PR-merge gates.
 *   4. Recompute— repairs the denormalized is_blocked flag after closes.
 *
 * Passes are independent: a failure is reported and the remaining passes still
 * run, with a non-zero exit at the end.
 *
 * Usage: npx tsx scripts/beads-reconcile.ts [--dry-run] [--verbose]
 *        RECONCILE_MAIN_REF=<ref> …   (sweep against another ref; tests only)
 *
 * Auth: ambient `gh` CLI auth. bd's own GitHub token is intentionally left
 * unconfigured so nobody can accidentally run `bd github sync`.
 *
 * Runs correctly from any linked worktree: worktrees share the primary
 * checkout's object store and remote refs, and `bd` auto-discovers the shared
 * `.beads/` workspace, so no repo-root resolution is needed.
 */

import { execFileSync } from "node:child_process";

// ============================================================================
// Configuration
// ============================================================================

const REPO = "mlg87/lapcat";
const CMD_TIMEOUT_MS = 30_000;
const WATERMARK_KEY = "reconcile.main-sha";
/** First-run scan depth: enough to cover recent history without scanning all of main. */
const DEFAULT_MAIN_REF = "origin/main";
/**
 * Ref the landed-work sweep treats as "merged". Overridable via
 * RECONCILE_MAIN_REF so the close path can be exercised against a scratch
 * commit without waiting for a real merge; nothing but tests should set it.
 */
const MAIN_REF = process.env.RECONCILE_MAIN_REF ?? DEFAULT_MAIN_REF;
const FIRST_RUN_BASE = `${MAIN_REF}~200`;
const BEAD_ID_IN_MESSAGE = /\((lc-[a-z0-9]+(?:\.[0-9]+)*)\)/g;
/** The id the docs use when quoting the convention itself. */
const PLACEHOLDER_ID = "lc-xxx";
/** git-log record framing: control characters cannot occur in a commit message. */
const FIELD_SEP = "\u001f";
const RECORD_SEP = "\u001e";
const SHA_PATTERN = /^[0-9a-f]{7,40}$/;

interface Options {
  readonly dryRun: boolean;
  readonly verbose: boolean;
}

let options: Options = { dryRun: false, verbose: false };

// ============================================================================
// Types
// ============================================================================

interface GhIssue {
  readonly number: number;
  readonly title: string;
  readonly body: string | null;
  readonly labels: readonly string[];
}

export interface Bead {
  readonly id: string;
  readonly title: string;
  readonly status: string;
  readonly issue_type: string;
  readonly external_ref: string | null;
  readonly priority: number;
  readonly labels?: readonly string[];
  readonly description: string;
}

interface BeadDep {
  readonly id: string;
  readonly dependency_type: string;
}

/** Desired edge state derived from GitHub, keyed by bead id. */
interface DesiredEdges {
  /** bead id -> bead ids it is blocked by */
  readonly blockers: Map<string, Set<string>>;
  /** child bead id -> parent bead id */
  readonly parents: Map<string, string>;
}

// ============================================================================
// Epic field derivation (pure; GH labels/title -> bead priority/labels/title)
// ============================================================================

/** GitHub `priority:*` label -> bd priority (0=highest). No `priority:*` label -> 2 (medium). */
const PRIORITY_LABELS: Record<string, number> = {
  "priority:critical": 0,
  "priority:high": 1,
  "priority:medium": 2,
  "priority:low": 3,
};

/** Several `priority:*` labels present -> the highest-urgency (lowest number) wins. */
export function priorityFromLabels(labels: readonly string[]): number {
  const matched = labels
    .filter((label) => Object.hasOwn(PRIORITY_LABELS, label))
    .map((label) => PRIORITY_LABELS[label]);
  return matched.length === 0 ? 2 : Math.min(...matched);
}

/**
 * Every GitHub label verbatim (spaces included, e.g. `front end`) except
 * `priority:*` (mirrored as priority instead), deduped and sorted. The
 * `epic` GitHub label is mirrored as a plain label too; harmless, and keeps
 * the rule "everything except priority:*" with no allowlist to maintain.
 */
export function beadLabelsFor(labels: readonly string[]): string[] {
  const kept = new Set(
    labels.filter((label) => !label.startsWith("priority:")),
  );
  for (const label of kept) {
    if (label.includes(",")) {
      throw new Error(
        `GitHub label "${label}" contains a comma, which "bd create -l"/"--add-label" cannot encode; rename the label on GitHub`,
      );
    }
  }
  return [...kept].sort();
}

export function epicTitle(issue: Pick<GhIssue, "number" | "title">): string {
  return `Epic: ${issue.title} (GH#${String(issue.number)})`;
}

export const SUCCESS_CRITERIA_HEADING = "## Success Criteria";

export function successCriteria(number: number): string {
  return (
    `${SUCCESS_CRITERIA_HEADING}\n\n` +
    `GH#${String(number)} is closed by a merged PR (\`Closes #${String(number)}\`). ` +
    "This bead closes from GitHub state, never from child completion."
  );
}

/** Set difference both ways, sorted; empty arrays on both sides when equal. */
export function labelDiff(
  current: readonly string[],
  desired: readonly string[],
): { add: string[]; remove: string[] } {
  const currentSet = new Set(current);
  const desiredSet = new Set(desired);
  return {
    add: desired.filter((label) => !currentSet.has(label)).sort(),
    remove: current.filter((label) => !desiredSet.has(label)).sort(),
  };
}
// ============================================================================
// Output
// ============================================================================

function out(line: string): void {
  process.stdout.write(`${line}\n`);
}

function warn(line: string): void {
  process.stderr.write(`${line}\n`);
}

function vlog(line: string): void {
  if (options.verbose) {
    out(`  ${line}`);
  }
}

function describeError(error: unknown): string {
  if (!(error instanceof Error)) {
    return String(error);
  }
  // execFileSync attaches the child's stderr to the thrown Error; the Error
  // message alone is just "Command failed".
  if (
    "stderr" in error &&
    error.stderr !== null &&
    error.stderr !== undefined
  ) {
    return `${error.message} :: ${String(error.stderr).trim().slice(0, 500)}`;
  }
  return error.message;
}

// ============================================================================
// Process helpers
// ============================================================================

function exec(file: string, args: readonly string[], input?: string): string {
  return execFileSync(file, [...args], {
    encoding: "utf8",
    timeout: CMD_TIMEOUT_MS,
    maxBuffer: 64 * 1024 * 1024,
    ...(input === undefined ? {} : { input }),
  });
}

function bd(args: readonly string[], input?: string): string {
  return exec("bd", args, input);
}

function bdJson<T>(args: readonly string[]): T[] {
  const raw = bd([...args, "--json"]).trim();
  if (raw === "" || raw === "null") {
    return [];
  }
  const parsed: unknown = JSON.parse(raw);
  return Array.isArray(parsed) ? (parsed as T[]) : [parsed as T];
}

/** Write-side bd call: printed but not executed under --dry-run. */
function bdWrite(args: readonly string[], input?: string): void {
  if (options.dryRun) {
    out(`  would run: bd ${args.join(" ")}`);
    return;
  }
  bd(args, input);
}

function bdShow(id: string): Bead | null {
  try {
    return bdJson<Bead>(["show", id])[0] ?? null;
  } catch {
    return null;
  }
}

/** Newline-delimited `gh api --paginate` output, one line per jq result. */
function ghLines(apiPath: string, jqExpr: string): string[] {
  const raw = exec("gh", ["api", "--paginate", apiPath, "--jq", jqExpr]);
  return raw.split("\n").filter((line) => line.trim() !== "");
}

function ghAuthenticated(): boolean {
  try {
    exec("gh", ["auth", "status"]);
    return true;
  } catch {
    return false;
  }
}

// ============================================================================
// Pass 1: GitHub -> beads mirror
// ============================================================================

/**
 * Open, non-PR issues. Endpoint filters out pull requests, which the issues API
 * returns alongside issues.
 */
function fetchOpenIssues(): GhIssue[] {
  const lines = ghLines(
    `repos/${REPO}/issues?state=open&per_page=100`,
    ".[] | select(.pull_request == null) | " +
      "{number, title, body, labels: [.labels[].name]} | @json",
  );
  return lines.map((line) => JSON.parse(line) as GhIssue);
}

/** Epic beads (including closed ones, so a reopened issue is never duplicated). */
function loadEpicBeads(): Map<number, Bead> {
  const beads = bdJson<Bead>([
    "list",
    "--type",
    "epic",
    "--all",
    "--limit",
    "0",
  ]);
  const byIssue = new Map<number, Bead>();
  for (const bead of beads) {
    const match =
      bead.external_ref === null ? null : /^gh-(\d+)$/.exec(bead.external_ref);
    if (match !== null) {
      byIssue.set(Number(match[1]), bead);
    }
  }
  return byIssue;
}

function createEpicBead(issue: GhIssue): void {
  const body =
    `GitHub: https://github.com/${REPO}/issues/${String(issue.number)}\n\n` +
    `${issue.body ?? ""}\n\n${successCriteria(issue.number)}`;
  out(`+ create epic bead for GH#${String(issue.number)}: ${issue.title}`);
  const labels = beadLabelsFor(issue.labels);
  bdWrite(
    [
      "create",
      epicTitle(issue),
      "-t",
      "epic",
      "-p",
      String(priorityFromLabels(issue.labels)),
      "--external-ref",
      `gh-${String(issue.number)}`,
      "--body-file",
      "-",
      "--silent",
      ...(labels.length > 0 ? ["--labels", labels.join(",")] : []),
    ],
    body,
  );
}

/**
 * Keeps an existing epic bead's title, priority, labels and Success Criteria
 * section in step with GitHub. Idempotent: builds one `bd update` call from
 * only the fields that actually differ, and does nothing when none do.
 */
function syncEpicFields(issue: GhIssue, bead: Bead): void {
  const desiredTitle = epicTitle(issue);
  const desiredPriority = priorityFromLabels(issue.labels);
  const desiredLabels = beadLabelsFor(issue.labels);
  const { add, remove } = labelDiff(bead.labels ?? [], desiredLabels);
  const needsSuccessCriteria = !bead.description.includes(
    SUCCESS_CRITERIA_HEADING,
  );
  const changes: string[] = [];
  const args = ["update", bead.id];
  if (bead.title !== desiredTitle) {
    changes.push(`title`);
    args.push("--title", desiredTitle);
  }
  if (bead.priority !== desiredPriority) {
    changes.push(
      `priority ${String(bead.priority)} -> ${String(desiredPriority)}`,
    );
    args.push("-p", String(desiredPriority));
  }
  for (const label of add) {
    changes.push(`+${label}`);
    args.push("--add-label", label);
  }
  for (const label of remove) {
    changes.push(`-${label}`);
    args.push("--remove-label", label);
  }
  let input: string | undefined;
  if (needsSuccessCriteria) {
    changes.push("+success criteria");
    input = `${bead.description}\n\n${successCriteria(issue.number)}`;
    args.push("--stdin");
  }
  if (changes.length === 0) {
    return;
  }
  out(`~ update ${bead.id}: ${changes.join(" | ")}`);
  bdWrite(args, input);
  propagateNewLabels(bead.id, add);
}

/**
 * bd only inherits labels at creation time; push newly added ones down to
 * existing children so they pick up the label without a manual pass.
 */
function propagateNewLabels(beadId: string, labels: readonly string[]): void {
  for (const label of labels) {
    try {
      bdWrite(["label", "propagate", beadId, label]);
    } catch (error) {
      warn(
        `! label propagate ${beadId} ${label} failed: ${describeError(error)}`,
      );
    }
  }
}

/** Creates or updates a single epic's bead; one issue's own body. */
function syncOneEpic(issue: GhIssue, bead: Bead | undefined): void {
  if (bead === undefined) {
    createEpicBead(issue);
    return;
  }
  if (bead.status === "closed") {
    out(`^ reopen ${bead.id} (GH#${String(issue.number)} is open again)`);
    bdWrite(["reopen", bead.id]);
  }
  syncEpicFields(issue, bead);
}

/** Reconciles bead existence/status with the open-issue set. */
function syncEpicExistence(
  issues: readonly GhIssue[],
  epics: Map<number, Bead>,
): void {
  const openNumbers = new Set(issues.map((issue) => issue.number));
  for (const issue of issues) {
    try {
      syncOneEpic(issue, epics.get(issue.number));
    } catch (error) {
      warn(
        `! GH#${String(issue.number)} mirror failed: ${describeError(error)}`,
      );
    }
  }
  for (const [number, bead] of epics) {
    if (openNumbers.has(number) || bead.status === "closed") {
      continue;
    }
    closeIfGhClosed(number, bead);
  }
}

function closeIfGhClosed(number: number, bead: Bead): void {
  let state: string;
  try {
    state = exec("gh", [
      "api",
      `repos/${REPO}/issues/${String(number)}`,
      "--jq",
      ".state",
    ]).trim();
  } catch {
    warn(
      `! GH#${String(number)} is not readable (transferred or deleted); leaving ${bead.id} open`,
    );
    return;
  }
  if (state !== "closed") {
    vlog(
      `GH#${String(number)} is ${state} but absent from the open page; skipping`,
    );
    return;
  }
  const warning = openChildrenWarning(
    number,
    bead.id,
    bdJson<Bead>(["list", "--parent", bead.id, "--all", "--limit", "0"]),
  );
  if (warning !== null) {
    warn(warning);
    return;
  }
  out(`- close ${bead.id} (GH#${String(number)} closed)`);
  bdWrite(["close", bead.id, "--reason", `GH#${String(number)} closed`]);
}

/**
 * The warning to print instead of closing, or null when the close may go
 * ahead. `bd close` refuses an epic with any non-closed child (open,
 * in_progress, blocked, deferred) unless forced, and forcing would hide
 * unfinished work behind a closed epic — so the mirror leaves the epic open
 * and says why (GH#1148). Pure: the caller fetches the children.
 */
export function openChildrenWarning(
  number: number,
  beadId: string,
  children: readonly Bead[],
): string | null {
  const open = children.filter((child) => child.status !== "closed");
  if (open.length === 0) {
    return null;
  }
  const ids = open.map((child) => child.id).join(", ");
  return `! GH#${String(number)} closed but ${String(open.length)} open child bead(s) remain (${ids}); leaving ${beadId} open`;
}

/**
 * Edges between *open* issues only — a closed blocker is a satisfied blocker
 * (.claude/guides/beads-workflow.md, "GitHub edges are mirrored into beads").
 */
function computeDesiredEdges(
  issues: readonly GhIssue[],
  epics: Map<number, Bead>,
): DesiredEdges {
  const blockers = new Map<string, Set<string>>();
  const parents = new Map<string, string>();
  for (const issue of issues) {
    const bead = epics.get(issue.number);
    if (bead === undefined) {
      continue; // created this run under --dry-run; edges land on the next run
    }
    const blockerIds = mapToBeadIds(
      ghNumbers(`issues/${String(issue.number)}/dependencies/blocked_by`),
      epics,
    );
    if (blockerIds.size > 0) {
      blockers.set(bead.id, blockerIds);
    }
    if (!issue.labels.includes("epic")) {
      continue; // sub-issues are only read for epics, as the dashboard does
    }
    for (const childId of mapToBeadIds(
      ghNumbers(`issues/${String(issue.number)}/sub_issues`),
      epics,
    )) {
      parents.set(childId, bead.id);
    }
  }
  vlog(
    `desired edges: ${String(parents.size)} parent-child, ` +
      `${String(blockers.size)} blocked beads`,
  );
  return { blockers, parents };
}

function ghNumbers(suffix: string): number[] {
  try {
    return ghLines(`repos/${REPO}/${suffix}?per_page=100`, ".[].number").map(
      Number,
    );
  } catch (error) {
    warn(`! ${suffix} unreadable: ${describeError(error)}`);
    return [];
  }
}

/** Open, mirrored issue numbers -> bead ids. Closed/unmirrored are dropped. */
function mapToBeadIds(
  numbers: readonly number[],
  epics: Map<number, Bead>,
): Set<string> {
  const ids = new Set<string>();
  for (const number of numbers) {
    const bead = epics.get(number);
    if (bead !== undefined && bead.status !== "closed") {
      ids.add(bead.id);
    }
  }
  return ids;
}

function currentDeps(beadId: string): BeadDep[] {
  try {
    return bdJson<BeadDep>(["dep", "list", beadId]);
  } catch (error) {
    warn(`! cannot read deps of ${beadId}: ${describeError(error)}`);
    return [];
  }
}

/**
 * Applies the desired edges. Only edges whose *other* end is a mirrored epic
 * bead are ever removed, so decomposition children (Phase 4) are untouched.
 */
function syncEdges(edges: DesiredEdges, epics: Map<number, Bead>): void {
  const mirrored = new Set([...epics.values()].map((bead) => bead.id));
  for (const beadId of mirrored) {
    const deps = currentDeps(beadId);
    const desiredParent = edges.parents.get(beadId);
    syncParentEdge(beadId, deps, desiredParent, mirrored);
    syncBlockerEdges(
      beadId,
      deps,
      edges.blockers.get(beadId) ?? new Set<string>(),
      mirrored,
    );
  }
}

function syncParentEdge(
  beadId: string,
  deps: readonly BeadDep[],
  desiredParent: string | undefined,
  mirrored: ReadonlySet<string>,
): void {
  const current = deps.find((dep) => dep.dependency_type === "parent-child");
  if (current?.id === desiredParent) {
    return;
  }
  if (desiredParent === undefined) {
    if (current === undefined || !mirrored.has(current.id)) {
      return; // hand-made or decomposition parentage: not ours to remove
    }
    out(`- unparent ${beadId} (GH sub-issue link gone)`);
    bdWrite(["update", beadId, "--parent", ""]);
    return;
  }
  // A pre-existing `blocks` edge to the same bead makes the reparent fail:
  // bd stores one typed edge per pair.
  if (deps.some((dep) => dep.id === desiredParent)) {
    bdWrite(["dep", "remove", beadId, desiredParent]);
  }
  out(`~ parent ${beadId} -> ${desiredParent}`);
  bdWrite(["update", beadId, "--parent", desiredParent]);
}

function syncBlockerEdges(
  beadId: string,
  deps: readonly BeadDep[],
  desired: ReadonlySet<string>,
  mirrored: ReadonlySet<string>,
): void {
  const parentId = deps.find(
    (dep) => dep.dependency_type === "parent-child",
  )?.id;
  const present = new Set(
    deps.filter((dep) => dep.dependency_type === "blocks").map((dep) => dep.id),
  );
  for (const blockerId of desired) {
    if (present.has(blockerId) || blockerId === parentId) {
      continue; // parent-child already expresses this pair
    }
    out(`+ ${beadId} blocked by ${blockerId}`);
    bdWrite(["dep", "add", beadId, blockerId]);
  }
  for (const blockerId of present) {
    if (desired.has(blockerId) || !mirrored.has(blockerId)) {
      continue;
    }
    out(`- ${beadId} no longer blocked by ${blockerId}`);
    bdWrite(["dep", "remove", beadId, blockerId]);
  }
}

function mirrorPass(): void {
  if (!ghAuthenticated()) {
    warn("! gh is not authenticated; skipping the GitHub mirror pass");
    return;
  }
  const issues = fetchOpenIssues();
  const epics = loadEpicBeads();
  vlog(
    `${String(issues.length)} open GH issues, ${String(epics.size)} epic beads`,
  );
  syncEpicExistence(issues, epics);
  // Re-read after existence changes so new beads carry their ids into edges.
  const settled = loadEpicBeads();
  syncEdges(computeDesiredEdges(issues, settled), settled);
}

// ============================================================================
// Pass 2: landed-work sweep
// ============================================================================

function readWatermark(): string {
  let stored = "";
  try {
    stored = bd(["kv", "get", WATERMARK_KEY]).trim();
  } catch {
    vlog("no watermark yet");
  }
  const candidate = SHA_PATTERN.test(stored) ? stored : FIRST_RUN_BASE;
  try {
    exec("git", ["cat-file", "-e", `${candidate}^{commit}`]);
    return candidate;
  } catch {
    vlog(`${candidate} is not a known commit; scanning from ${MAIN_REF} only`);
    return MAIN_REF;
  }
}

/**
 * bead id -> short sha of the newest commit naming it.
 *
 * Scans the whole commit message, not just the subject: this repo squash-merges
 * with `squash_merge_commit_message = COMMIT_MESSAGES`, so a multi-commit PR's
 * squash subject is the PR title and the branch commits' `(lc-xxx)` suffixes
 * survive only in the body.
 */
export function beadIdsInMessages(log: string): Map<string, string> {
  const named = new Map<string, string>();
  for (const record of log.split(RECORD_SEP)) {
    const separator = record.indexOf(FIELD_SEP);
    if (separator === -1) {
      continue; // trailing newline after the last record
    }
    const sha = record.slice(0, separator).trim();
    for (const match of record.matchAll(BEAD_ID_IN_MESSAGE)) {
      const id = match[1];
      // The docs quote `(lc-xxx)` as the convention's placeholder; a commit
      // touching them would otherwise be reported as naming a missing bead.
      if (id !== PLACEHOLDER_ID && !named.has(id)) {
        named.set(id, sha);
      }
    }
  }
  return named;
}

function beadsNamedInRange(base: string, tip: string): Map<string, string> {
  const log = exec("git", [
    "log",
    `${base}..${tip}`,
    `--format=%h${FIELD_SEP}%B${RECORD_SEP}`,
  ]);
  return beadIdsInMessages(log);
}

function landedSweep(): void {
  // Explicit refspec: `git fetch origin main` only moves FETCH_HEAD, leaving
  // refs/remotes/origin/main stale, which would hide just-merged commits.
  if (MAIN_REF === DEFAULT_MAIN_REF) {
    exec("git", [
      "fetch",
      "origin",
      "+refs/heads/main:refs/remotes/origin/main",
    ]);
  }
  const head = exec("git", ["rev-parse", MAIN_REF]).trim();
  const base = readWatermark();
  const named = beadsNamedInRange(base, MAIN_REF);
  vlog(`${String(named.size)} bead ids named in ${base}..${MAIN_REF}`);
  closeLandedBeads(named);
  // Epics are never closed from child completion: they close from GitHub state
  // in pass 1, which keeps "GitHub owns deliverables" true.
  bdWrite(["kv", "set", WATERMARK_KEY, head]);
}

/**
 * Closes every open bead named by a landed commit.
 *
 * `bd close` refuses a bead that is blocked by an open bead, and commit order is
 * not dependency order, so a blocked bead can come up before its blocker. Retry
 * in rounds until a round closes nothing: a chain of landed beads drains in
 * dependency order without asking bd for the graph. Anything still blocked is
 * blocked by work that did not land, which is a real signal, not an error — and
 * one bead's failure never costs the rest of the sweep.
 */
function closeLandedBeads(named: Map<string, string>): void {
  const pending = new Map<string, string>();
  for (const [id, sha] of named) {
    const bead = bdShow(id);
    if (bead === null) {
      warn(`! commit ${sha} names ${id}, which does not exist`);
    } else if (bead.status !== "closed") {
      pending.set(id, sha);
    }
  }
  let lastError = "";
  while (pending.size > 0) {
    const closed = closeRound(pending, (message) => (lastError = message));
    if (closed === 0) {
      break;
    }
  }
  for (const [id, sha] of pending) {
    warn(
      `! ${id} landed in ${sha} but could not be closed: ${lastError.trim()}`,
    );
  }
}

/** One pass over the pending beads; returns how many closed. */
function closeRound(
  pending: Map<string, string>,
  recordError: (message: string) => void,
): number {
  let closed = 0;
  for (const [id, sha] of [...pending]) {
    try {
      bdWrite(["close", id, "--reason", `landed on main in ${sha}`]);
      // Reported after the fact: a blocked bead is retried in a later round,
      // and announcing the attempt would print it once per round.
      out(`- close ${id} (landed on main in ${sha})`);
      pending.delete(id);
      closed += 1;
    } catch (error) {
      recordError(describeError(error));
    }
  }
  return closed;
}

// ============================================================================
// Passes 3-4: gates and readiness
// ============================================================================

function gatePass(): void {
  const gates = bdJson<{ id: string }>(["gate", "list"]);
  if (gates.length === 0) {
    vlog("no gates");
    return;
  }
  if (!ghAuthenticated()) {
    warn("! gh is not authenticated; skipping gate check");
    return;
  }
  out(`~ checking ${String(gates.length)} gate(s)`);
  bdWrite(["gate", "check", "--type=gh"]);
}

function recomputePass(): void {
  // Closes in earlier passes can leave is_blocked stale; bd ready trusts it.
  bdWrite(["recompute-blocked"]);
}

// ============================================================================
// Entry point
// ============================================================================

function runPass(name: string, pass: () => void, failures: string[]): void {
  out(`== ${name}`);
  try {
    pass();
  } catch (error) {
    const message = describeError(error);
    failures.push(`${name}: ${message}`);
    warn(`! pass "${name}" failed: ${message}`);
  }
}

function main(): number {
  const argv = process.argv.slice(2);
  options = {
    dryRun: argv.includes("--dry-run"),
    verbose: argv.includes("--verbose"),
  };
  if (options.dryRun) {
    out("dry run: no writes, watermark not advanced");
  }
  const failures: string[] = [];
  runPass("mirror", mirrorPass, failures);
  runPass("landed-work sweep", landedSweep, failures);
  runPass("gates", gatePass, failures);
  runPass("ready recompute", recomputePass, failures);
  if (failures.length > 0) {
    warn(`reconcile finished with ${String(failures.length)} failed pass(es)`);
    return 1;
  }
  out("reconcile complete");
  return 0;
}

if (process.argv[1]?.endsWith("beads-reconcile.ts")) {
  process.exit(main());
}
