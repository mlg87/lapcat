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
5. **Put the bead id in every branch commit subject and in the PR body.**
   Branch commits use `fix(core): … (lc-a1b2)`. Only the squash commit
   reaches `main`, and its body is the PR body. Thus the PR body's `Beads:`
   line must list every bead the PR completes, each as `(lc-…)`. The PR title
   must not contain a bead id. Child ids contain a dot (`lc-8il.4`) — include
   the whole id, not just the epic prefix. The reconcile sweep closes beads
   named anywhere in a commit message that reached `origin/main` (subject or
   body), which makes the `Beads:` line load-bearing rather than merely
   auditable. Work that lands without it leaves its bead open for someone to
   close by hand.
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

## Branches, worktrees and pull requests

### Worktrees

1. Make all changes in a linked worktree:
   `git worktree add -b <type>/<short-name> ../lapcat-<short-name> main`.
2. Name the branch `<type>/<short-name>` with a conventional-commit type, for
   example `feat/release-notes` or `fix/echo-dedup`.
3. Never check out a branch other than `main` in the primary checkout
   (`~/workspace/lapcat`).
4. Never commit on `main`.
5. After the PR merges, run `git pull --ff-only` in the primary checkout.
6. Then remove the worktree: `git worktree remove ../lapcat-<short-name>`.

### Protected `main`

Rulesets protect `main`, and nobody can bypass them. The rules are:

- Changes reach `main` only through a pull request.
- `main` accepts only squash merges.
- The checks `lint`, `typecheck`, `build`, `test` and `pr-title` must pass.
- Only the repository admin can merge.

Nobody can push to `main` directly. Merge with
`gh pr merge --squash --auto`, which merges after the checks pass. Do not try
to bypass a failing check. Correct the cause.

Before you push, run these checks locally:

```bash
swift format lint --strict --recursive Sources Tests Package.swift scripts/make-icons.swift
npx tsc -p tsconfig.json
scripts/test.sh
```

To correct the format, run
`swift format format -i --recursive Sources Tests Package.swift scripts/make-icons.swift`.

### PR title

The PR title is the squash commit subject. It is also one line of the release
notes. Use this format: `type(scope): description`.

- Write the description in lowercase, in the imperative mood.
- Keep the title at 72 characters or fewer, with no period at the end.
- Do not put a bead id in the title.
- Use one of these types: `feat`, `fix`, `perf`, `refactor`, `docs`, `style`,
  `test`, `build`, `ci`, `chore`, `revert`.
- For a breaking change, use `type(scope)!:` and add a `BREAKING CHANGE:`
  footer to the PR body.
- Use one of these scopes: `core`, `audio`, `speech`, `llm`, `speakers`, `app`,
  `dev` (the `lapcat-dev` CLI), `scripts`, `ci`, `docs`. Omit the scope when a
  change touches more than one package.

The `pr-title` check enforces the type, the lowercase start and the missing
bead id.

### PR body

The PR body is the squash commit body. Follow
`.github/pull_request_template.md`:

1. `## Summary`: two to five sentences about what changed and why.
2. `Closes #N` when the PR completes a GitHub issue.
3. `Beads: (lc-…)` with every bead that the PR completes.
4. `## Release notes` (optional): one extra `type(scope): description` line
   for each additional change that a user can see. Put a blank line between
   the lines. release-please makes a changelog entry from each line.

The HTML comments of the template also go into the squash body. GitHub hides
them, so they do no harm. To correct the release notes after a merge, edit the
merged PR body. Add a `BEGIN_COMMIT_OVERRIDE` … `END_COMMIT_OVERRIDE` block
with the correct lines.

### Releases

Releases are automatic:

1. release-please opens a release PR, `chore(main): release X.Y.Z`, after a
   `feat` or `fix` merges.
2. The admin merges the release PR.
3. release-please tags `vX.Y.Z` and publishes the GitHub Release with the
   changelog section.
4. The `release-assets` workflow attaches `LapCat-vX.Y.Z-universal.zip`.

Do not edit `CHANGELOG.md`, `version.txt`, `.release-please-manifest.json` or
the version strings in `Resources/Info.plist` manually. release-please owns
them. The secret `RELEASE_PLEASE_TOKEN` (a fine-grained token) lets the release
PR start the required checks.

### Prose

Before you write a PR title or body, a commit message, README text or release
notes, read `skill://asd-ste100`. Write in its STE-flavored mode. If the skill
is missing, install it with
`npx -y skills add danyuchn/asd-ste100-skill@asd-ste100 -g -y`. Code comments
are exempt.
