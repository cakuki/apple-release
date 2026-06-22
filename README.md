# apple-release

The code-only **hub** of **Atelier** — cakuki's platform for building & releasing Apple-platform apps.
It holds the shared [Fastlane](https://fastlane.tools) lanes, the reusable GitHub Actions release
workflow, and the signing-bootstrap script, so build/sign/release logic lives in exactly one place.

## Lanes
- `test` — unit tests on a simulator
- `sync_signing` — install signing assets via `match` (read-only on CI)
- `prepare_release` — regenerate `CHANGELOG.md` (`cog changelog`), bump `MARKETING_VERSION`
  (semver, via `VersionBumper`), and create a `v<semver>` tag
- `beta` — build + upload to TestFlight (optionally uploads dSYMs to Sentry — see
  [Crash-report symbolication](#crash-report-symbolication-dsym-upload-to-sentry))

Lanes are app-agnostic; per-app config arrives as environment variables set by the workflow.

## Testing

The shared Ruby core (changelog formatter, version bumper, release planner) is covered by a
fast pure-**stdlib-minitest** suite — no bundler, runs on the system Ruby 2.6. Run the whole
suite with one command:

```sh
ruby test/all.rb
```

New `test/*_test.rb` files are auto-discovered, so the suite needs no edits to grow.

### Real-cog integration test (drift guard)

`test/changelog_pipeline_integration_test.rb` is the canonical guard against **tool-output
drift**: every other test asserts against a *hand-written* idea of cog's output (proving only
"code matches the test"), so a `ChangelogFormatter` regex once shipped that never matched cog's
real `default`-template output. This test closes that gap by running the **real `cog` binary**
end-to-end — it builds a throwaway git repo with conventional commits + a tag, runs the actual
`cog changelog <range>`, pipes the output through `ChangelogFormatter` + `ReleasePlan`, and
asserts both the TestFlight notes and the derived `v<semver>` tag. It **fails** if the
cog↔formatter contract drifts.

- **Locally:** it runs automatically via `ruby test/all.rb` **when `cog` is on `PATH`**, and
  **SKIPs cleanly** (never fails) when cog is absent — so the fast suite still passes on a
  cog-less box.
- **In CI:** the `commit-lint` workflow installs the pinned **cog 6.5.0** binary (sha256-verified)
  and re-runs `ruby test/all.rb` afterwards, so the integration test actually executes there. If
  you bump the pinned cog version, update `COG_VERSION` + `COG_SHA256` in `.github/workflows/commit-lint.yml`.

## Release flow (tag-driven)

Cutting a release is split into a cheap **prep** half and the macOS **build** half so a
single `v<semver>` tag is the seam between them:

1. `apple-release-prepare.yml` (ubuntu) runs `prepare_release`: regenerates `CHANGELOG.md`
   over `<lastTag>..HEAD`, derives the next semver from Conventional-Commit subjects and
   bumps `MARKETING_VERSION` (the build number is left alone), commits, and pushes a
   `v<semver>` tag.
2. The tag push fires the consumer's `on: push: tags: ['v*']`, which calls
   `apple-release.yml` with `lane: beta`.
3. `beta` builds + uploads to TestFlight, reading `CHANGELOG.md` for the `pilot` notes.

`MARKETING_VERSION` is the `cog`-derived semver; `CURRENT_PROJECT_VERSION` stays the
stateless TestFlight-latest+1 injected at build time via `xcargs` — deliberately decoupled,
so the two never collide.

## Consume it (per app)

```ruby
# fastlane/Fastfile
import_from_git(url: "https://github.com/cakuki/apple-release.git", branch: "v1", path: "fastlane/Fastfile")
```

```yaml
# .github/workflows/release.yml
jobs:
  ios:
    uses: cakuki/apple-release/.github/workflows/apple-release.yml@v1
    with: { app-identifier: com.example.App, scheme: App, xcodeproj: App.xcodeproj }
    secrets: inherit
```

### Crash-report symbolication (dSYM upload to Sentry)

The `beta` lane can upload your build's dSYMs to **Sentry** so crash reports are
symbolicated. It is **off by default and fully optional** — apps with no Sentry
account ship to TestFlight exactly as before, and CI stays green.

To enable it, set **all three** of these for the app (any one missing/blank ⇒
the step is a clean no-op, never a failure):

| Where | Name | What |
| --- | --- | --- |
| repo **secret** | `SENTRY_AUTH_TOKEN` | Sentry auth token with dSYM-upload scope (never logged) |
| workflow input | `sentry-org` | your Sentry org slug |
| workflow input | `sentry-project` | your Sentry project slug |

```yaml
# .github/workflows/release.yml
jobs:
  ios:
    uses: cakuki/apple-release/.github/workflows/apple-release.yml@v1
    with:
      app-identifier: com.example.App
      scheme: App
      xcodeproj: App.xcodeproj
      sentry-org: your-org        # omit both to keep dSYM upload off
      sentry-project: your-project
    secrets: inherit              # SENTRY_AUTH_TOKEN flows in if the repo has it
```

The reporting backend is Sentry, but a self-hosted **GlitchTip** is a drop-in via
the same token/org/project — nothing is hardcoded to `sentry.io`.

Architecture, signing, CI reference, and the new-app runbook live in the private `atelier` repo.
