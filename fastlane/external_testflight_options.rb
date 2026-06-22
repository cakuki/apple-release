# Pure option builder for the central `distribute_external` (external TestFlight)
# lane (EPIC-08 slice 1, cakuki/atelier#8).
#
# ExternalTestFlightOptions.build(env) maps the process ENV to the exact kwargs
# hash the `distribute_external` lane passes to fastlane's `pilot` /
# `upload_to_testflight` action — minus the ASC `api_key` and the `changelog`,
# which the lane merges in at call time (the api_key from the local `asc_api_key`
# helper, the changelog from `changelog_from_md`, the same source `beta` ships).
# Keeping the assembly pure (no fastlane, no IO, no network) means the whole
# external-distribution contract is unit-testable under stdlib minitest, the same
# way DeliverOptions / ReleasePlan / CoverageGate keep their logic fastlane-free.
#
# The lane is OFF by default: `distribute_external` is an explicit
# `TESTFLIGHT_DISTRIBUTE_EXTERNAL=true` opt-in (exact "true", case-insensitive,
# trimmed — mirroring DeliverOptions' DELIVER_SUBMIT), so CI never pushes a build
# to external testers implicitly. The `groups` key is attached ONLY when the
# opt-in is ON, so the default build can't even name an external group.
# `skip_waiting_for_build_processing: true` keeps the lane fast: it reuses the
# already-processed build `beta` uploaded rather than blocking on processing.
module ExternalTestFlightOptions
  module_function

  # A TestFlight group name as it appears in App Store Connect. Deliberately
  # forbids path separators (`/`, `\`) and control chars — a name flows straight
  # into pilot as an argument, so reject anything traversal-y or non-printable up
  # front (mirrors DeliverReleaseNotes' LOCALE_PATTERN fail-fast).
  INVALID_GROUP_CHARS = %r{[/\\\x00-\x1f\x7f]}.freeze

  # ENV -> kwargs for `pilot`. `app_identifier` uses ENV.fetch so a missing value
  # fails fast (KeyError), matching beta/sync_signing/deliver. The api_key and
  # changelog are deliberately NOT here — the lane builds them (asc_api_key /
  # changelog_from_md) and merges them in.
  def build(env)
    on = distribute_external?(env)
    opts = {
      app_identifier:                    env.fetch("APP_IDENTIFIER"),
      distribute_external:               on,
      skip_waiting_for_build_processing: true,
    }
    # Attach `groups` ONLY when opted in — and require at least one valid group,
    # since distributing externally to no one is a misconfiguration, not a no-op.
    opts[:groups] = groups(env) if on
    opts
  end

  # External-distribution opt-in: only an exact "true" (case-insensitive,
  # whitespace-trimmed) turns it on. Anything else (unset, "false", "0", "yes",
  # ...) stays internal-only — mirrors DeliverOptions' DELIVER_SUBMIT parse so the
  # two opt-ins behave identically and CI never distributes externally implicitly.
  def distribute_external?(env)
    env["TESTFLIGHT_DISTRIBUTE_EXTERNAL"].to_s.strip.downcase == "true"
  end

  # TESTFLIGHT_GROUPS -> validated, non-empty list of group names. Comma-split,
  # each stripped, empties rejected. Raises ArgumentError if the result is empty
  # (opted in but named no group) or if any name carries a path separator /
  # control char. Only called when the opt-in is ON, so OFF builds never validate.
  def groups(env)
    names = env["TESTFLIGHT_GROUPS"].to_s.split(",").map(&:strip).reject(&:empty?)
    if names.empty?
      raise ArgumentError,
            "TESTFLIGHT_GROUPS must name at least one external TestFlight group " \
            "when TESTFLIGHT_DISTRIBUTE_EXTERNAL=true (got none)"
    end
    bad = names.find { |n| n.match?(INVALID_GROUP_CHARS) }
    if bad
      raise ArgumentError,
            "TESTFLIGHT_GROUPS contains an invalid group name #{bad.inspect}: " \
            "group names cannot contain `/`, `\\`, or control characters"
    end
    names
  end
end
