# CI reference

Reusable GitHub Actions workflows shipped by `apple-release`. Apps consume them
by `uses:`-ing the pinned `@v1` ref — build/sign/release/quality logic lives in
exactly one place, so apps inherit it without per-repo wiring or forking.

| Workflow | Purpose |
| --- | --- |
| `apple-release.yml` | Build + upload to TestFlight (`beta` lane). |
| `apple-release-prepare.yml` | Regenerate `CHANGELOG.md`, bump `MARKETING_VERSION`, push the `v<semver>` tag. |
| `quality-gates.yml` | Enforce SwiftLint (strict) + SwiftFormat (`--lint`) on every PR. |

## Quality gates (`quality-gates.yml`)

A reusable (`workflow_call`) lint/format gate. It runs **SwiftLint in strict
mode** (any violation fails the job) and **SwiftFormat `--lint`** (check-only;
any formatting drift fails the job) against the `.swiftlint.yml` and
`.swiftformat` config the app commits (shipped by the EPIC-01 template). This
gives every consuming app an enforced quality bar with no per-repo wiring.

Like the rest of the platform, the lint tools are **pinned by version and
verified by sha256** against the official GitHub Release assets before they run,
so the enforced rule set can't silently drift (or be tampered with) between runs.

### Adopt it (per app)

Add a PR-triggered caller workflow:

```yaml
# .github/workflows/quality.yml
name: quality
on:
  pull_request:
jobs:
  quality-gates:
    uses: cakuki/apple-release/.github/workflows/quality-gates.yml@v1
```

No secrets are required (lint only), so `secrets: inherit` is unnecessary.

### Inputs

All inputs are optional; the defaults are the platform's blessed versions.

| Input | Default | Description |
| --- | --- | --- |
| `swift-paths` | `.` | Space-separated paths to lint / format-check (relative to repo root). |
| `swiftlint-version` | `0.63.3` | Pinned SwiftLint version (must match `swiftlint-sha256`). |
| `swiftlint-sha256` | `fb045e85…810b6` | sha256 of the pinned SwiftLint `portable_swiftlint.zip` asset. |
| `swiftformat-version` | `0.61.1` | Pinned SwiftFormat version (must match `swiftformat-sha256`). |
| `swiftformat-sha256` | `b9904007…4c584` | sha256 of the pinned SwiftFormat `swiftformat.zip` asset. |
| `strict` | `true` | Fail on any SwiftLint violation (strict mode). Set `false` for serious-violations-only while migrating. |
| `runs-on` | `macos-15` | Runner label (the Swift lint tools need macOS). |

Bumping a tool means changing **both** the `*-version` and its matching
`*-sha256` together — a version/digest mismatch is a hard error (the install
step refuses to run the bytes), which is the point of the pin.

To tune without forking, override inputs in the caller:

```yaml
jobs:
  quality-gates:
    uses: cakuki/apple-release/.github/workflows/quality-gates.yml@v1
    with:
      swift-paths: "Sources Tests"
      strict: false
```

### What fails the gate

- **SwiftLint:** any violation reported by `.swiftlint.yml` (in `strict` mode,
  every warning is escalated to an error). With `strict: false`, only
  serious (error-level) violations fail.
- **SwiftFormat:** any file that `--lint` would reformat — i.e. any drift from
  `.swiftformat` — fails the job (nothing is written).
- **Tooling integrity:** a failed download, an asset sha256 mismatch, or an
  installed binary whose reported version doesn't exactly match the pin.
