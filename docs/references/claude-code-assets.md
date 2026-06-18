# Claude Code assets

The Claude Code assets Atelier actually uses to build and ship — each with a
one-line *"use it for X."* This is a catalog of what's in use, not a wishlist;
keep it accurate.

- **Owner:** Platform (cakuki)
- **Last reviewed:** 2026-06-18

## Recommendation

Drive delivery through the **delivery-loop** and reach for the assets below rather
than re-deriving tooling (re-deriving `gh` commands, signing steps, or release
mechanics burns context and invites drift). Prefer the platform's scripts/skills
over ad-hoc commands; prefer Context7 over memory for library docs.

## The catalog

### Delivery & orchestration

- **Delivery loop** ([`atelier/docs/delivery-loop.md`](https://github.com/cakuki/atelier/blob/main/docs/delivery-loop.md))
  — use it to run the autonomous PR pipeline: each fire advances open PRs (Copilot
  is the merge gate), tops up to 3 in-flight tasks, and fans out a subagent per
  task. The single source of truth for the operating procedure.
- **`/loop`** — use it to run a prompt or slash command on a recurring interval;
  this is how the delivery loop is invoked: `/loop 10m run docs/delivery-loop.md`.
  Session-only (dies with the session).
- **`/schedule` (cron)** — use it instead of `/loop` when you need a recurring run
  that **survives** the session (a scheduled cloud agent on a cron cadence), or a
  one-time future run.
- **Subagents / parallel agents** — use them to fan out one independent task per
  branch while keeping the main session's context minimal; the loop dispatches one
  per ready task.

### Skills

- **superpowers TDD skill** (`superpowers:test-driven-development`) — use it for
  any pure logic: RED → watch it fail → GREEN → refactor. The platform's pure
  Ruby/bash units (`commit_range.rb`, `version_bumper.rb`, the script harness) are
  built this way.
- **`pr-workflow` skill** — use it for the PR lifecycle in repos that ship the PR
  scripts (it documents the scripts, the exit-code contract, and the bounded-wait
  policy).

### CLIs & scripts

- **`newapp` CLI** ([`atelier/scripts/newapp.sh`](https://github.com/cakuki/atelier/blob/main/scripts/newapp.sh))
  — use it to scaffold a new app from the `cakuki/ios-app-template` GitHub
  template and wire it to `apple-release@v1`: token substitution, `xcodegen
  generate`, commit, `make setup`, plus the autonomous secret/deploy-key checks
  and copy-pasteable guidance for the owner-run signing steps. Run
  `scripts/newapp.sh --help` for flags.
- **PR scripts** (`atelier/scripts/{pr-open,pr-review,pr-merge}.sh`) — use them
  instead of re-deriving `gh` commands:
  - `pr-open.sh` — push the current branch and open a PR with Copilot requested.
  - `pr-review.sh <pr>` — report review status (exit `0` safe to merge, `10`
    pending, `20` changes requested / unresolved threads).
  - `pr-merge.sh <pr>` — squash-merge (default) and delete the branch;
    `--lockstep-main` performs the `apple-release` main→v1 lockstep.
  > `apple-release` itself does **not** ship these scripts — there, use raw `gh`
  > plus the REST Copilot request
  > (`gh api -X POST repos/<o>/<r>/pulls/<n>/requested_reviewers -f
  > "reviewers[]=copilot-pull-request-reviewer[bot]"`).
- **Test harnesses** — use them to validate changes with no network/deps:
  `apple-release` → `ruby test/all.rb` (system-ruby minitest); `atelier` →
  `scripts/test/run.sh` (mock-based bash harness).

### MCP & external knowledge

- **Context7 MCP** — use it to fetch current library/framework/CLI docs (fastlane,
  GitHub Actions, cocogitto, Swift tooling, etc.) instead of relying on possibly
  stale memory. Prefer it over web search for library docs.

### Review gate

- **Copilot PR review** (`copilot-pull-request-reviewer[bot]`) — use it as the
  **merge gate**: nothing merges until Copilot has reviewed the latest head SHA and
  all threads are resolved. Requested on every PR the platform opens.

## A note on these notes

This catalog is itself produced and shipped via the assets above (delivery loop →
subagent → PR → Copilot review). When an asset changes or a new one is adopted,
update this note at the next review (or sooner — see the library's
[quarterly cadence](README.md#review-cadence)).
