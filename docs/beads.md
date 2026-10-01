# Beads Workflow Guide

This repo runs a **two-tier task tracker**. [beads](https://github.com/gastownhall/beads) (`bd`, a Dolt-backed graph issue tracker) holds the fine-grained agent execution graph; GitHub Issues stay the human-legible deliverable tracker. Beads never replaces GitHub — it sits underneath it.

See [AGENTS.md § Task graph: beads](../AGENTS.md) for the non-negotiable rules; this guide is the detail.

## Table of Contents

1. [Two-Tier Contract](#two-tier-contract)
2. [Lifecycle](#lifecycle)
3. [Bulk decomposition](#bulk-decomposition)
4. [Session Boundary Rule](#session-boundary-rule)
5. [Memory](#memory)
6. [Commit Linkage](#commit-linkage)
7. [Editing Beads](#editing-beads)
8. [Ops: Worktrees and Backup](#ops-worktrees-and-backup)
9. [Ops: Automation](#ops-automation)

---

## Two-Tier Contract

| Tier            | Tool          | Holds                                                                                                                                       |
| --------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Deliverables    | GitHub Issues | Milestones, epics, `blocked_by`/sub-issue edges, issue-linked branch names, PR auto-linking, deploy gates                                   |
| Execution graph | beads (`bd`)  | Implementation tasks, atomic work claiming across worktrees, `bd ready` ordering, repo-scoped operational memory                            |

Rules that make the two tiers line up:

- **Every epic bead mirrors one GitHub issue.** Its title ends with `(GH#N)` and the first line of its description is `GitHub: https://github.com/mlg87/lapcat/issues/N`. The bead also carries `--external-ref gh-N`.
- **Child beads have no GitHub counterpart.** Fine-grained implementation tasks live only in beads, created with `--parent <epic-bead-id>` (or a `parent-child` dep edge).
- **GitHub edges are mirrored into beads, not the reverse.** A GH `blocked_by` becomes a `blocks` dep edge (`bd dep add <blocked> <blocker>`); a GH sub-issue becomes a `parent-child` edge. Only edges between _open_ GH issues are mirrored — a closed blocker is a satisfied blocker.
- **The mirror is automated and one-way.** `scripts/beads-reconcile.ts` (run in the background by the omp extension, and by hand as `npx tsx scripts/beads-reconcile.ts [--dry-run] [--verbose]`) creates an epic bead for every open GH issue that lacks one, reopens a bead whose issue reopened, closes a bead whose issue is confirmed `closed`, unless that bead still has open children — then it warns and leaves the bead open (an epic with open children is unfinished work; the mirror never `--force`s), and syncs the two edge kinds above. It also keeps each epic's **priority** (from a `priority:critical|high|medium|low` GH label, defaulting to P2), **labels** (every other GH label verbatim, e.g. `front end`, propagated down to existing children since bd only inherits labels at creation), and **title** in step with GitHub, and appends a `## Success Criteria` section (`GH#N is closed by a merged PR…`) so `bd lint` only flags beads genuinely missing criteria. It is idempotent, keyed on `external_ref gh-N`, and has **no GitHub write path at all** — GitHub stays authoritative, and a bead created without `--external-ref gh-N` will be duplicated by the next run (`bd find-duplicates` is the repair tool). Native `bd github sync` is deliberately unused: it imports every closed issue and does not dedupe against our refs, so `bd config set github.token` must stay unset.
- Formulas/molecules (`bd mol pour`) stay unused: plans already produce a bespoke child graph per epic (see [Bulk decomposition](#bulk-decomposition)), and a second decomposition path would be a rival pattern.

## Lifecycle

Planning a deliverable:

1. Create or verify the **GitHub issue** first — unchanged from before beads existed.
2. Its **epic bead** appears on its own: the reconcile mirror creates one for every open issue within a debounce window. Create it by hand only when you need it in this session:

   ```bash
   bd create "Epic: Example feature (GH#1)" -t epic -p 2 \
     --external-ref gh-1 --stdin <<'EOF'
   GitHub: https://github.com/mlg87/lapcat/issues/1

   <copy of the GH body, or a summary>
   EOF
   ```

3. Create the **child beads** for the implementation steps — in bulk from the plan graph, see [Bulk decomposition](#bulk-decomposition). By hand, one at a time:

   ```bash
   bd create "Migration + repository functions" -t task -p 2 --parent lc-6g8
   bd create "Lambda handlers + CDK routes"      -t task -p 2 --parent lc-6g8
   bd dep add <handlers-bead> <migration-bead>   # handlers blocked by migration
   ```

   Child nodes inherit the epic's labels at creation, so `bd ready --label backend --exclude-type epic` works without labelling children by hand. A `description` with a `## Acceptance Criteria` section keeps `bd lint` green (the `acceptance` field is dropped by `--graph` — see below).

Working:

```bash
bd ready --exclude-type epic --label <area> --claim   # one call: find + claim the next matching task
bd update <id> --claim         # or claim a specific bead by id
# ... implement in this task's worktree (see Ops: Worktrees and Backup) ...
bd close <id> --reason "…"     # close as soon as the work lands
```

- `bd update <id> --claim` is the concurrency primitive. Two agents racing for the same bead: one wins, the other gets an error and picks the next `bd ready` entry. Never skip the claim — an unclaimed bead is an invitation for duplicate work.
- **Closing is automated for merged work.** The reconcile sweep closes any open bead whose id appears as `(lc-xxx)` anywhere in a commit message that reached `origin/main` — subject or body, so squash merges work — watermarked in `bd kv reconcile.main-sha`. Close by hand when work lands without that suffix, or when a bead is abandoned. `bd stale` surfaces beads that were claimed and then forgotten.
- Epic beads are **not** closed from child completion: they close from GitHub state, so "GitHub owns deliverables" stays true. **The GitHub issue is still closed by PR merge** (`Closes #N` in the PR body) — closing a bead never closes a GH issue.
- The priming injection also shows `bd list --status in_progress` (crash recovery: a fresh session sees what is already claimed) and, when any open epic has zero children, an `Epics with no child beads — decompose with bd create --graph before claiming` list.

## Bulk decomposition

When a plan targets an epic bead, emit the whole child graph in one file and create it with one command. `bd create --graph` accepts this schema (derived empirically — it is not documented upstream, so this guide is the reference):

```json
{
  "nodes": [
    {
      "key": "a",
      "title": "Migration + repository functions",
      "type": "task",
      "priority": 2,
      "description": "…",
      "labels": ["backend"],
      "parent_id": "lc-6g8"
    },
    {
      "key": "b",
      "title": "Lambda handlers + CDK routes",
      "type": "task",
      "priority": 2,
      "parent_id": "lc-6g8"
    }
  ],
  "edges": [{ "from_key": "b", "to_key": "a", "type": "blocks" }]
}
```

```bash
bd create --graph plan-graph.json --dry-run   # prints the ids it would create
bd create --graph plan-graph.json
```

- **Edge direction, verified:** `from_key` is the **blocked** bead and `to_key` the **blocker** — the same order as `bd dep add <blocked> <blocker>`. In the example above `b` is blocked by `a`, so only `a` appears in `bd ready`.
- `parent_id` takes an existing bead id (the epic); `parent_key` refers to another node in the same file. Nodes default to `type: "task"`, `priority: 2`.
- Unknown fields are dropped with a warning, not an error: `deps`, `parent`, `estimate`, `acceptance`, and `dependencies` are all silently ignored. Check the `--dry-run` output rather than assuming a field landed.
- A `parent-child` and a `blocks` edge cannot coexist between the same pair — bd stores one typed edge per pair and rejects the second with a "remove it first" error.
- Children are invisible to the mirror (no `gh-N` ref), so reconcile never touches them.
- **A parent-child edge does not block the parent.** An epic with open children still appears in `bd ready` — verified. Ordering between children is what `blocks` edges are for; the epic staying ready is why you close it from GitHub state rather than from child completion.

## Session Boundary Rule

- omp's in-session `todo` tool and `local://` plan files stay correct for **single-session** work: the current turn's checklist, a plan artifact being executed now.
- **A multi-step plan is decomposed into beads first, and only then burned down in `todo`.** The `todo` list tracks the claimed child bead's steps within this turn; it is not where the plan lives. A five-phase plan sitting only in `todo` is a plan no other agent can pick up and no crashed session can resume — see [Bulk decomposition](#bulk-decomposition).
- Anything that must **survive the session** or be **visible to another agent** goes in beads.
- Never write a markdown TODO/backlog file for cross-session tracking. Beads is the only durable agent-side task store.

## Memory

Beads doubles as repo-scoped operational memory, complementing (not replacing) each agent's own memory:

```bash
bd prime                       # injected automatically each session; run by hand only outside omp
bd remember "…"                # store one durable fact, one paragraph max
```

Store durable _repo-operational_ facts: environment quirks, gotchas that cost a debugging cycle, decisions whose rationale is not obvious from the code. Do not store ephemeral task state — that is what beads issues are for.

## Commit Linkage

Append the bead ID to the commit subject:

```
fix(core): reject stale input (lc-a1b2)
```

The suffix is free-form subject text, so any conventional-commit tooling added later is unaffected, and it makes `git log` reviewable against the graph — `git log --oneline --grep lc-a1b2` shows every commit for a bead, which is how you audit whether a closed bead actually shipped, or whether committed work has an open bead nobody closed.

**This is what closes the bead.** The reconcile sweep scans every commit message that reached `origin/main` — subject *and* body — for `(lc-xxx)`. Child ids contain a dot (`lc-8il.4`) and the sweep matches the whole id, including the dotted suffix — include the whole id, not just the epic prefix. `main` has no branch protection and allows merge, squash and rebase; `squash_merge_commit_message` is `COMMIT_MESSAGES`, so on a squash merge the branch commits' subjects land in the squash body and the suffixes survive there. Scanning the body is the common path, not a contingency. A branch whose commits all carry the suffix is therefore safe regardless of how the PR is titled.

`bd doctor` is **not available in embedded-Dolt mode** (the mode this repo uses), so do not rely on it for that correlation; grep the log instead. `bd preflight` and `bd doctor` are also beads-project-internal / unsupported here — use `bd lint`, `bd stale`, `bd orphans` for hygiene instead.

## Editing Beads

Never run `bd edit` — it opens `$EDITOR` and will hang a non-interactive agent session. Use the flag forms instead:

```bash
bd update <id> --description "…"    # or --notes / --design / --acceptance
bd update <id> --stdin              # description from stdin; use for bodies with backticks or quotes
bd create "…" --body-file -         # same, at creation time
bd update <id> -p 1                 # priority
bd update <id> --status open        # explicit status change
```

## Ops: Worktrees and Backup

- **`.beads/` lives only in the primary checkout** (`/Users/masongoetz/workspace/lapcat` on the maintainer machine) and is fully gitignored. Running `bd` from any linked worktree (`../lapcat-<task>`) resolves to that shared workspace automatically, which is exactly what lets concurrent agents in separate worktrees share one work graph.
- **Never run `bd init` inside a worktree.** That would create a second, divergent graph.
- **Backup/sync is Dolt, not git branches.** `bd dolt push` writes the graph to the `refs/dolt/data` ref on `origin` — a custom ref namespace, so main's branch protection does not apply and no PR is involved. **The omp extension owns this push** (15-minute debounce plus session stop, whenever the graph is dirty), which is what satisfies the "push when authorized" step in `bd prime`'s own session-close protocol. Run it by hand only outside omp, or to flush immediately:

  ```bash
  bd dolt push
  git ls-remote origin 'refs/dolt/*'   # refs/dolt/data should be listed
  ```

  `dolt.auto-push` stays off: upstream documents it as unsafe with concurrent writers, and this repo always has several `bd` processes. One lock-serialized owner replaces it.

  Durability is in fact doubly covered: bd's own throttled backup (`bd backup status` — `enabled=true (auto: git remote detected) interval=15m`) does advance `refs/dolt/data` on its own, observed with no manual push. The extension's push is the guaranteed one — it is not throttled behind a 15-minute window at session stop — and the lockfile plus Dolt fast-forward make the overlap harmless.

  On a fresh machine: install `bd` (`brew install beads`), confirm `bd config get metrics.disabled` is `true` (global config; bd otherwise posts usage telemetry to `gastownhall-eventsapi.com` on every command), then `bd init --prefix lc --skip-hooks --skip-agents --non-interactive` at the repo root, drop the `bd init:` commit it makes (`git reset --mixed HEAD~1 && git checkout -- .gitignore`, see below), `bd config set dolt.auto-commit on`, `bd dolt pull`, `npm install`.

- `bd init` writes a `bd init: initialize beads issue tracking` commit and a `.gitignore` entry even with `--skip-agents --skip-hooks`. Since `.beads/` is already gitignored here, drop that commit immediately (`git reset --mixed HEAD~1 && git checkout -- .gitignore`) — never let it ride on `main`.

## Ops: Automation

| What runs it                                                       | What it does                                                                                                                                                             |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `.omp/extensions/beads.ts` (omp extension, auto-discovered)        | Injects `bd prime`, `bd ready --exclude-type epic`, `bd list --status in_progress`, and the undecomposed-epic list once per session; owns `bd dolt push` (15-min debounce + session stop, only when dirty); triggers the reconcile script in the background |
| `scripts/beads-reconcile.ts` (called by the extension, or by hand) | GitHub→beads mirror; closes beads named by commits merged to `origin/main`; `bd gate check --type=gh`; `bd recompute-blocked`                                            |

```bash
LAPCAT_BEADS_HOOK=off omp                       # kill switch: disables the whole extension
npx tsx scripts/beads-reconcile.ts --dry-run    # see what the mirror/sweep would do
npx tsx scripts/beads-reconcile.ts --verbose    # run it now, with diagnostics
```

State the automation keeps: `bd kv reconcile.main-sha` (sweep watermark), `bd kv reconcile.last-run` (cross-session debounce), `.beads/omp-dirty` (unpushed-writes marker), `.beads/omp-push.lock` and `.beads/omp-reconcile.lock` (single-owner election).

Recovery:

- **Stale automation lock** (a crashed session): `rm .beads/omp-*.lock`. Locks older than 10 minutes are stolen automatically, so this is only for impatience.
- **Stale embedded-Dolt lock** after a crash: `rm .beads/embeddeddolt/LOCK`. Embedded Dolt is single-writer — concurrent writes block on that lock rather than corrupting, so blocking is expected under a wide subagent batch.
- **Sweep closed the wrong bead** (a commit named a bead it did not finish): `bd reopen <id>`.
- **Duplicate epic beads** (one created without `--external-ref gh-N`): `bd find-duplicates`, then delete the ref-less one.
- The automation is fail-open by construction: if `bd` is missing or slow, sessions run normally with nothing injected.
