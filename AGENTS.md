# AGENTS.md

Project instructions for coding agents working in lapcat.

## Task graph: beads

The agent-facing execution graph lives in [beads](https://github.com/gastownhall/beads)
(`bd`). GitHub Issues remain the deliverable tracker — the PR/branch workflow
and issue linking are unchanged.

### Rules

1. **Priming is automatic.** The omp extension `.omp/extensions/beads.ts`
   injects `bd prime`, `bd ready --exclude-type epic`, `bd list --status
   in_progress`, and any undecomposed open epics once per session (re-armed
   after compaction/branch/switch). Run `bd prime` by hand only outside omp.
   Kill switch for the whole extension: `LAPCAT_BEADS_HOOK=off`.
2. **Claim before working:** `bd ready --exclude-type epic --claim` finds and
   claims the next matching task in one call, or `bd update <id> --claim` to
   take a specific bead (atomic — sets assignee and `in_progress`),
   `bd close <id> --reason "…"` when the work lands. Never edit code for an
   unclaimed bead. This is the one step that is deliberately not automated —
   enforcing it would need a fail-closed tool gate, and subagents legitimately
   edit under a parent's claim.
3. **Epic beads mirror GitHub issues.** Title ends with `(GH#N)`, description's
   first line is the issue URL, and the bead carries `--external-ref gh-N` — the
   mirror dedupes on that ref, so a bead without it gets duplicated. Child beads
   are implementation tasks with no GitHub counterpart, created in bulk from a
   plan graph (see docs/beads.md § Bulk decomposition). **Decompose before
   editing:** a plan with more than one implementation step becomes child beads
   under its epic (`bd create --graph`) before the first edit — otherwise
   `bd ready` can only ever offer whole epics, so no second agent can be handed
   a sub-task of work already claimed, and a crashed session loses its phase
   breakdown. Closing a bead never closes a GitHub issue — the PR does that
   (`Closes #N`), exactly as today.
   `scripts/beads-reconcile.ts` mirrors open GitHub issues into epic beads and
   closes an epic bead when its issue closes; it never writes to GitHub.
4. **No markdown TODO files for cross-session tracking.** omp's `todo` tool and
   `local://` plans cover the current session; anything that outlives it or must
   be visible to another agent goes in beads. The in-session `todo` list is a
   burn-down of the claimed bead — never a substitute for decomposing into
   child beads (rule 3).
5. **Put the bead id in every commit subject** — `fix(core): … (lc-a1b2)`.
   Child ids contain a dot (`lc-8il.4`) — include the whole id, not just the
   epic prefix. The reconcile sweep closes beads named anywhere in a commit
   message that reached `origin/main` (subject or body, so squash merges
   work), which makes that suffix load-bearing rather than merely auditable.
   Work that lands without it leaves its bead open for someone to close by
   hand.
6. **Dolt push is automatic** (extension: 15-minute debounce plus session stop,
   whenever the graph is dirty). `bd dolt push` remains the manual fallback.
   `.beads/` is gitignored and lives only in the primary checkout
   (`~/workspace/lapcat`); never `bd init` inside a worktree, and never
   `bd edit` (it opens `$EDITOR` and hangs).

See [docs/beads.md](./docs/beads.md) for the full convention, including how
GitHub edges are mirrored and what the automation does not cover.

### Why

Concurrent agents each own a separate worktree but share one work graph, so
claiming has to be atomic — two agents cannot discover the same unstarted task
and both start it. And `bd ready` encodes the blocked-by edges that agents would
otherwise re-derive from the GitHub API at the start of every session.

The bookkeeping around that claim is automated because every manual step in it
was a step an agent could forget: an unprimed session does not know the rules, an
unpushed graph is invisible to the next machine, and a bead left open after its
work merged sends the next agent to redo it.
