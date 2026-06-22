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
- `screenshots` — capture App Store screenshots from UI tests (`snapshot`), optionally
  add device frames (`frameit`). **Local only — never uploads** (see [Screenshots](#screenshots))
- `reviews` — pull the app's App Store customer reviews from ASC and print a digest
  (totals, average + per-star breakdown, flagged low ratings). **Read-only** (see
  [Reviews digest](#reviews-digest))

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

To enable it, set the **three required** values below for the app (any one
missing/blank ⇒ the step is a clean no-op, never a failure); `sentry-url` is
optional:

| Where | Name | Required? | What |
| --- | --- | --- | --- |
| repo **secret** | `SENTRY_AUTH_TOKEN` | yes | Sentry auth token with dSYM-upload scope (never logged) |
| workflow input | `sentry-org` | yes | your Sentry org slug |
| workflow input | `sentry-project` | yes | your Sentry project slug |
| workflow input | `sentry-url` | no | self-hosted instance base URL; omit for sentry.io |

> **What gets uploaded:** the lane runs `sentry-cli debug-files upload --include-sources`, so in addition to the dSYMs it uploads **embedded source context** for your app's code where available — handy for readable stack traces, but be aware your source is sent to the configured Sentry/GlitchTip server.

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

The reporting backend is Sentry, but a self-hosted **GlitchTip** is a drop-in:
nothing is hardcoded to `sentry.io`. Point `sentry-cli` at your instance by
setting the **`sentry-url`** input (e.g. `https://glitchtip.example.com`) — it
maps to `SENTRY_URL`, which sentry-cli reads natively — and keep using the same
`SENTRY_AUTH_TOKEN`/`sentry-org`/`sentry-project`. Leave `sentry-url` empty for
Sentry's SaaS (sentry.io).

## Screenshots

The `screenshots` lane captures versioned App Store screenshots by driving your app's
**UI-test target** on simulators (fastlane [`snapshot`](https://docs.fastlane.tools/actions/snapshot/)),
and can optionally add **device frames** ([`frameit`](https://docs.fastlane.tools/actions/frameit/)).
The [`ios-app-template`](https://github.com/cakuki/ios-app-template) ships a sample UI test
(`{{APP_NAME}}UITests`) that takes one launch screenshot — replace it with your real flows.

> **It is NON-LIVE.** The lane only writes images into a local output directory and **never
> uploads to App Store Connect.** Uploading screenshots is a separate, owner-gated step (the
> `deliver` slice). So running it has no effect on your live listing.

Run it locally (from the app repo, with `SCHEME` set to a UI-test-capable scheme):

```sh
SCHEME=App-Dev bundle exec fastlane screenshots
```

It writes captures to `fastlane/screenshots/` (an HTML summary plus per-device/per-language
PNGs). Tune it via environment variables (all optional):

| Env var | Required? | Default | What |
| --- | --- | --- | --- |
| `SCHEME` | yes | — | scheme whose `test` action runs the UI-test target |
| `SNAPSHOT_DEVICES` | no | `iPhone 16` | comma/newline-separated simulator device names |
| `SNAPSHOT_LANGUAGES` | no | `en-US` | comma/newline-separated language codes |
| `SNAPSHOT_OUTPUT_DIR` | no | `./screenshots` | where images are written (relative to `fastlane/`) |
| `SNAPSHOT_FRAMES` / `FRAMEIT` | no | `false` | set `true` to run `frameit` and add device frames |
| `XCODEPROJ` | no | inferred | path to the `.xcodeproj` (passed to snapshot when set) |

frameit is **off by default** — device frames are heavy (extra assets) and opinionated (a
specific marketing look), so bare screenshots are the default; opt in with `SNAPSHOT_FRAMES=true`.

Via the reusable workflow, pass `lane: screenshots` and the optional `snapshot-*` inputs:

```yaml
# .github/workflows/screenshots.yml
jobs:
  shots:
    uses: cakuki/apple-release/.github/workflows/apple-release.yml@v1
    with:
      app-identifier: com.example.App
      scheme: App-Dev
      xcodeproj: App.xcodeproj
      lane: screenshots
      snapshot-devices: "iPhone 16 Pro, iPad Pro (12.9-inch)"  # optional
      snapshot-frames: "false"                                  # optional
    secrets: inherit
```

The pure decision logic lives in `fastlane/snapshot_options.rb` (`SnapshotOptions.build` /
`SnapshotOptions.frame?`) and is unit-tested fastlane-free in `test/snapshot_options_test.rb`.

## Reviews digest

The `reviews` lane pulls your app's **App Store customer reviews** from App Store Connect and
prints a plain-text **digest** so a rating drop surfaces early:

- **Total** reviews, and how many are **new since** a date you pass.
- **Average rating** (rounded to 2 decimals) and a **per-star breakdown** (5★…1★).
- **Flagged low ratings** — every review at or below a threshold (default **2★**), listed with
  its rating, territory, and title so you can act on the complaints.

> **It is READ-ONLY.** The lane only `GET`s App Store Connect — `/v1/apps?filter[bundleId]=…`
> to resolve the app id, then `/v1/apps/{id}/customerReviews` — using the same App Store Connect
> API key as `beta`/`deliver`; it **never writes to App Store Connect** and has no effect on your listing.

Tune it via environment variables:

| Env var | Required? | Default | What |
| --- | --- | --- | --- |
| `APP_IDENTIFIER` | yes | — | bundle id whose reviews to pull |
| `REVIEWS_SINCE` | no | — | ISO8601 instant; counts reviews created **strictly after** it as "new" |
| `REVIEWS_LOW_RATING_THRESHOLD` | no | `2` | flag reviews with `rating` ≤ this value |

Run it locally (with the ASC API key env set, as for `beta`):

```sh
REVIEWS_SINCE=2026-06-01T00:00:00Z bundle exec fastlane reviews
```

The digest math + text live in `fastlane/review_digest.rb` (`ReviewDigest.build` /
`ReviewDigest.format`) and are unit-tested fastlane-free in `test/review_digest_test.rb`; the
thin ASC fetch is the only un-unit-tested part (it's live I/O, the same as the dSYM upload).

Architecture, signing, CI reference, and the new-app runbook live in the private `atelier` repo.
