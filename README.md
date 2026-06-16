# apple-release

The code-only **hub** of **Atelier** — cakuki's platform for building & releasing Apple-platform apps.
It holds the shared [Fastlane](https://fastlane.tools) lanes, the reusable GitHub Actions release
workflow, and the signing-bootstrap script, so build/sign/release logic lives in exactly one place.

## Lanes
- `test` — unit tests on a simulator
- `sync_signing` — install signing assets via `match` (read-only on CI)
- `beta` — build + upload to TestFlight

Lanes are app-agnostic; per-app config arrives as environment variables set by the workflow.

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
