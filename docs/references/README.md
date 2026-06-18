# References library

Dated, opinionated one-pagers that consolidate how the **Atelier** Apple-release
platform actually builds and ships. Each note answers one question — *"what's the
recommended way to do X here, today?"* — and **links** the deep docs and external
sources rather than restating them.

This library is the fast path: skim a note for the recommendation and the
hard-won gotchas, then follow its links to the authoritative source when you need
the full detail.

## Rules of this library

1. **Dated.** Every note carries a `Last reviewed: YYYY-MM-DD` line. A note older
   than its review cadence (below) is suspect until re-reviewed.
2. **Opinionated.** Each note states a single clear recommendation — the
   platform's actual blessed approach — not a survey of options.
3. **Link, don't duplicate.** Notes link upstream docs (the platform's own deep
   references and vetted external docs). They do **not** copy their content; when
   the source changes, the note's links stay correct and only its recommendation
   may need a re-review. If you find yourself restating a doc, link it instead.
4. **One page.** If a topic needs more than a page, the long form belongs in a
   deep reference doc that this note links to.

## Index

| Topic | Note | Owner | Last reviewed | Recommendation (one line) |
| --- | --- | --- | --- | --- |
| CI/CD | [ci-cd.md](ci-cd.md) | Platform (cakuki) | 2026-06-18 | Centralized fastlane in `apple-release`, `match` signing, the reusable GH Actions workflow pinned `@v1`, cog-driven changelog/version. |
| Claude Code assets | [claude-code-assets.md](claude-code-assets.md) | Platform (cakuki) | 2026-06-18 | Use the delivery-loop + the catalogued skills/CLIs/MCP below to build and ship; don't re-derive tooling. |
| Architecture | _planned (slice 2, retroactive from EPIC-01)_ | Platform (cakuki) | — | The three-repo model + ENV contract; see [atelier `docs/reference/ARCHITECTURE.md`](https://github.com/cakuki/atelier/blob/main/docs/reference/ARCHITECTURE.md) until consolidated. |
| Crash analytics | _planned (slice 3, JIT with EPIC-06)_ | Platform (cakuki) | — | TBD — written just-in-time when crash analytics lands. |
| ASO / analytics | _planned (slice 4)_ | Platform (cakuki) | — | TBD. |
| Testing / a11y / l10n | _planned (slice 4)_ | Platform (cakuki) | — | TBD. |

Only the two `2026-06-18` notes exist today; the rest are listed so the index is
complete and the backlog is visible. Planned notes are written **just-in-time**,
when the underlying capability lands — not speculatively.

## Review cadence

**Quarterly.** Each note is re-reviewed at least once per quarter by its owner:
re-read the linked sources, confirm the recommendation still matches what the
platform does, and bump `Last reviewed:` (even if nothing else changes — the date
is the signal that someone checked). A note also gets an **ad-hoc** review the
moment the thing it describes changes (e.g. a workflow input changes, a pinned
tool version moves) — don't wait for the quarter boundary for a known drift.

A note whose `Last reviewed:` date is more than a quarter old should be treated as
**stale**: still useful as a starting point, but verify against the linked sources
before relying on it.

## Ownership model

Every note has **exactly one owner** (the entry in the index table). The owner is
accountable for keeping it accurate — running the quarterly review, reacting to
drift, and signing off on edits. Today every note is owned by the **Platform**
(the `cakuki` owner/operator of Atelier); as the team grows, ownership of a topic
can move to whoever owns that area. Changes still go through the normal PR +
Copilot-review gate; the owner is the reviewer of record for their notes.
