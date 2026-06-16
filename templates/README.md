# templates/ — canonical config inherited by apps

Single source of truth for config that every Atelier app should share, kept here in
the hub so it can't drift per-app. Consumed by the EPIC-01 template / EPIC-04 generator.

| File | Purpose |
|------|---------|
| `cog.toml` | Canonical [cocogitto](https://docs.cocogitto.io) config — Conventional-Commits → changelog/semver mapping (EPIC-02). |
| `githooks/commit-msg` | Local `commit-msg` hook running `cog verify` for fast feedback. Authoritative gate is the CI lint check (EPIC-02 task 2). |

These are static canonical files. Installing them into an app (hook wiring, `make setup`)
is EPIC-02 task 6 and rides the EPIC-01 template; the CI `cog check` lint is task 2.
