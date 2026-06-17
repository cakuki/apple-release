# apple-release

The code-only **hub** of **Atelier** — cakuki's platform for building & releasing Apple-platform apps.
It holds the shared [Fastlane](https://fastlane.tools) lanes, the reusable GitHub Actions release
workflow, and the signing-bootstrap script, so build/sign/release logic lives in exactly one place.

## Lanes
- `test` — unit tests on a simulator
- `sync_signing` — install signing assets via `match` (read-only on CI)
- `prepare_release` — regenerate `CHANGELOG.md` (`cog changelog`), bump `MARKETING_VERSION`
  (semver, via `VersionBumper`), and create a `v<semver>` tag
- `beta` — build + upload to TestFlight

Lanes are app-agnostic; per-app config arrives as environment variables set by the workflow.

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

Architecture, signing, CI reference, and the new-app runbook live in the private `atelier` repo.
