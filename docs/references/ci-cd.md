# CI/CD

How Atelier builds, signs, and ships Apple-platform apps — and the recommended
way to wire a new one up.

- **Owner:** Platform (cakuki)
- **Last reviewed:** 2026-06-18

## Recommendation

Use the platform's centralized setup — **don't** hand-roll per-app CI:

1. **Centralized fastlane in [`cakuki/apple-release`](https://github.com/cakuki/apple-release).**
   The build/sign/upload lanes (`test` / `sync_signing` / `beta`) live once in the
   hub's `fastlane/Fastfile`. Apps import them via `import_from_git(... branch: "v1")`
   — no build logic is copy-pasted between apps.
2. **`match` signing.** Distribution cert + App Store profiles live
   `match`-encrypted in the private `cakuki/ios-signing` repo; CI consumes them
   **read-only**. Raw credentials live only in GitHub secrets, never in a repo.
3. **The reusable GitHub Actions workflow, pinned `@v1`.** Apps call
   `uses: cakuki/apple-release/.github/workflows/apple-release.yml@v1` with
   `secrets: inherit`. Pinning to `v1` (not `main`) gives apps a stable, versioned
   contract.
4. **cog-driven changelog & versioning.** Conventional Commits drive a
   cocogitto-generated `CHANGELOG.md` and the semver `MARKETING_VERSION`; the build
   number is a stateless *"TestFlight latest + 1"* counter. The two version axes
   are decoupled on purpose.

The fastest way to stand up a new app is the **`newapp` CLI** (see the
Claude-assets note and the onboarding runbook) — it stamps the template, wires it
to `apple-release@v1`, and runs the secret/deploy-key checks for you.

## The platform docs (read these for detail — don't duplicate them here)

These are the authoritative sources. This note links them; it does not restate
them.

- [`../CI.md`](../CI.md) — the reusable workflows (`apple-release.yml`,
  `apple-release-prepare.yml`, `quality-gates.yml`): inputs, secrets, triggers,
  how to adopt them per app.
- [SIGNING.md](https://github.com/cakuki/atelier/blob/main/docs/reference/SIGNING.md)
  — how `match` + the ASC API key work, where the five secrets live, and the
  rotation runbook. (Canonical copy currently lives in the `atelier` hub; a
  retroactive in-repo consolidation is slice 2 of this library.)
- [ARCHITECTURE.md](https://github.com/cakuki/atelier/blob/main/docs/reference/ARCHITECTURE.md)
  — the three-repo model, the secrets split, the ENV-var contract, and the
  stateless build-number strategy. (Canonical copy currently lives in the
  `atelier` hub; a retroactive in-repo consolidation is slice 2 of this library.)
- [ONBOARD-NEW-APP.md](https://github.com/cakuki/atelier/blob/main/docs/reference/ONBOARD-NEW-APP.md)
  — the numbered runbook to take a brand-new app from zero to a TestFlight build.
- [CHANGELOG-VERSIONING.md](https://github.com/cakuki/atelier/blob/main/docs/reference/CHANGELOG-VERSIONING.md)
  — Conventional Commits → changelog → semver, and the two-version-axes model.

> Note: `CI.md` is linked relative to this directory because it lives in
> `apple-release/docs/`. `SIGNING.md`, `ARCHITECTURE.md`, `ONBOARD-NEW-APP.md`, and
> `CHANGELOG-VERSIONING.md` are currently canonical in the `atelier` hub and are
> linked by absolute URL until they are consolidated into this repo (slice 2).

## Hard-won gotchas

These cost real CI iterations to discover (from the platform's `PROGRESS.md` and
the first green TestFlight run). Bake them in up front:

- **ASC API key roles: Admin vs App Manager.** Creating signing material with
  `match` / `seed-signing.sh` needs an **Admin** App Store Connect API key — a
  lower-privilege key returns *"forbidden"*. Routine CI uploads (the `beta` lane,
  TestFlight build-number lookups) only need an **App Manager** key. Use the
  least-privileged key that works: Admin for the one-time owner-run seed, App
  Manager for everything CI does.
- **Pin the iOS SDK / Xcode.** App Store validation requires a current iOS SDK
  (the platform selects the matching Xcode — e.g. **Xcode 26.3** for the iOS 26
  SDK on `macos-15` runners). An unpinned/older toolchain produces builds Apple
  rejects (409 / validation errors). Pin the Xcode/SDK in the workflow; don't
  rely on the runner default drifting.
- **AppIcon + interface orientations are required for App Store validation.** A
  build with no AppIcon asset catalog or missing `UISupportedInterfaceOrientations`
  gets **409'd** at upload. The EPIC-01 template ships both; if you scaffold by
  hand, add a real 1024×1024 AppIcon and declare orientations before the first
  upload.
- **Pin every tool by version *and* sha256.** The lint/format tools (and cog) are
  pinned by version and verified by digest against the official release assets, so
  the enforced rule set can't silently drift or be tampered with. Bumping a tool
  means changing **both** the version and its matching sha256 — a mismatch is a
  hard error by design.
- **`fetch-depth: 0` for commit-range checks.** The Conventional-Commits gate
  needs full history so the PR base is reachable; a shallow checkout breaks the
  `base..head` range resolution.
- **Local fastlane needs Homebrew Ruby.** The Mac's system Ruby 2.6 can't build
  fastlane's native gems — `export PATH="/usr/local/opt/ruby/bin:$PATH"`. CI is
  unaffected (it uses `ruby/setup-ruby`).

## External references (vetted)

- **fastlane** — <https://docs.fastlane.tools> — the lanes, actions, and the
  `pilot`/`gym` tooling the `beta` lane drives.
- **fastlane `match`** — <https://docs.fastlane.tools/actions/match/> — the
  git-stored, encrypted code-signing approach (and `match --readonly` for CI).
- **GitHub Actions — reusing workflows** —
  <https://docs.github.com/en/actions/using-workflows/reusing-workflows> — the
  `workflow_call` / `uses:` + `secrets: inherit` mechanism the platform pins at
  `@v1`.
- **cocogitto (cog)** — <https://docs.cocogitto.io> — the Conventional-Commits
  engine behind the changelog + semver bump.
