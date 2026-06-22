# Pure option builder for the central `deliver` (metadata-only) lane
# (EPIC-07 slice 1, cakuki/atelier#7).
#
# DeliverOptions.build(env) maps the process ENV to the exact kwargs hash the
# `deliver` lane passes to fastlane's `upload_to_app_store` action — minus the
# ASC `api_key`, which the lane merges in from the local `asc_api_key` helper
# (a thin wrapper over `app_store_connect_api_key`) at call time. Keeping the
# assembly pure (no fastlane, no IO, no network)
# means the whole metadata contract is unit-testable under stdlib minitest, the
# same way ReleasePlan / CoverageGate keep their logic fastlane-free.
#
# The lane is metadata-only and NON-LIVE by default: `verify_only` is the inverse
# of an explicit `DELIVER_SUBMIT=true` opt-in, so CI validates the listing against
# App Store Connect without ever mutating the store unless a caller deliberately
# opts in (the owner-gated slice 4). `skip_binary_upload`/`skip_screenshots` keep
# the lane single-purpose: `beta` owns binaries, slice 3 owns screenshots.
#
# Submitting the listing for App Store review (EPIC-08 slice 2) is a SECOND,
# independent opt-in layered on top of the live upload: `submit_for_review` is
# only true when `DELIVER_SUBMIT_FOR_REVIEW=true` (same exact-"true" parse as
# `DELIVER_SUBMIT`). Because a submission can only ride a live upload, requesting
# review without `DELIVER_SUBMIT=true` is a misconfiguration — `build` fails fast
# (ArgumentError) rather than silently validating, so a caller can't believe they
# submitted when they only ran a verify.
#
# Phased release (EPIC-08 slice 3) is a THIRD, independent opt-in, also layered on
# the live upload: `phased_release` is only true when `DELIVER_PHASED_RELEASE=true`
# (same exact-"true" parse). It governs how an APPROVED version rolls out to users
# gradually, so it too requires `DELIVER_SUBMIT=true` and fails fast otherwise. It
# is independent of `DELIVER_SUBMIT_FOR_REVIEW` (phased rollout is configured on the
# version regardless of whether this run submits for review). `automatic_release`
# stays false — phased release is the controlled alternative to an immediate
# auto-release, not a companion to it.
module DeliverOptions
  module_function

  # Lanes run with CWD = `fastlane/` (the Fastfile reads `../CHANGELOG.md` etc.),
  # so the scaffold at <repo>/fastlane/metadata is `./metadata` from here — NOT
  # `./fastlane/metadata`, which would resolve to fastlane/fastlane/metadata.
  DEFAULT_METADATA_PATH = "./metadata".freeze

  # ENV -> kwargs for `upload_to_app_store`. `app_identifier` uses ENV.fetch so a
  # missing value fails fast (KeyError), matching beta/sync_signing. The api_key
  # is deliberately NOT here — the lane builds it via `asc_api_key` and merges it.
  def build(env)
    {
      app_identifier:             env.fetch("APP_IDENTIFIER"),
      metadata_path:              metadata_path(env),
      skip_binary_upload:         true,
      skip_screenshots:           true,
      force:                      true,
      run_precheck_before_submit: false,
      submit_for_review:          submit_for_review?(env),
      phased_release:             phased_release?(env),
      automatic_release:          false,
      verify_only:                !submit?(env),
    }
  end

  # METADATA_PATH override, defaulting to deliver's conventional layout — which
  # the ios-app-template scaffold matches exactly (zero per-app mapping).
  def metadata_path(env)
    path = env["METADATA_PATH"].to_s.strip
    path.empty? ? DEFAULT_METADATA_PATH : path
  end

  # Live-upload opt-in: only an exact "true" (case-insensitive, whitespace-trimmed)
  # flips the lane live. Anything else (unset, "false", "0", "yes", ...) stays
  # non-live so CI never pushes to ASC implicitly (AC2 / slice-4 isolation).
  def submit?(env)
    env["DELIVER_SUBMIT"].to_s.strip.downcase == "true"
  end

  # Submit-for-review opt-in (slice 2): only an exact "true" (case-insensitive,
  # whitespace-trimmed, mirroring DELIVER_SUBMIT) requests App Store review. A
  # submission can only ride a live upload, so requesting review without
  # DELIVER_SUBMIT=true is a misconfiguration — raise ArgumentError (fail fast)
  # so a caller can't think they submitted when they only validated. When the
  # review opt-in is unset/non-"true", it stays false regardless of DELIVER_SUBMIT.
  def submit_for_review?(env)
    return false unless env["DELIVER_SUBMIT_FOR_REVIEW"].to_s.strip.downcase == "true"

    unless submit?(env)
      raise ArgumentError,
            "DELIVER_SUBMIT_FOR_REVIEW=true requires DELIVER_SUBMIT=true: submitting " \
            "for App Store review only makes sense during a live upload. Set " \
            "DELIVER_SUBMIT=true to go live, or unset DELIVER_SUBMIT_FOR_REVIEW to " \
            "validate only."
    end
    true
  end

  # Phased-release opt-in (slice 3): only an exact "true" (case-insensitive,
  # whitespace-trimmed, mirroring DELIVER_SUBMIT) enables App Store phased release
  # — the gradual, day-by-day rollout of an APPROVED version to users. Like
  # submit-for-review it can only ride a live upload, so requesting it without
  # DELIVER_SUBMIT=true is a misconfiguration — raise ArgumentError (fail fast) so
  # a caller can't think they'll phase-release when they only validated. It is
  # INDEPENDENT of DELIVER_SUBMIT_FOR_REVIEW: phased rollout is configured on the
  # version regardless of whether this run also submits for review (Apple applies
  # it once the version is approved + released), so the guard is on submit only.
  # When the opt-in is unset/non-"true", it stays false regardless of the others.
  def phased_release?(env)
    return false unless env["DELIVER_PHASED_RELEASE"].to_s.strip.downcase == "true"

    unless submit?(env)
      raise ArgumentError,
            "DELIVER_PHASED_RELEASE=true requires DELIVER_SUBMIT=true: a phased " \
            "release only makes sense during a live upload. Set DELIVER_SUBMIT=true " \
            "to go live, or unset DELIVER_PHASED_RELEASE to validate only."
    end
    true
  end
end
