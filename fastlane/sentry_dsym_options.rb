# Pure decision/option builder for the `beta` lane's dSYM-upload step
# (EPIC-06 slice 2, cakuki/atelier#6).
#
# SentryDsymOptions.build(env) answers the only question the lane needs: "should
# we upload dSYMs to Sentry, and if so with what identity?" It returns either
# `nil` — a clean NO-OP: Sentry isn't configured, so the lane skips the upload
# entirely and `beta` archives + ships to TestFlight exactly as today — or the
# params hash the lane feeds to `sentry-cli debug-files upload`:
#
#   { auth_token:, org_slug:, project_slug: }
#
# The dSYM PATH and the exact argv are NOT here — the lane owns the I/O (globbing
# the gym archive's `dSYMs` / `./build` and shelling out). Keeping this decision
# pure (no fastlane, no IO, no network, no sentry-cli) means the whole upload
# contract is unit-testable under stdlib minitest, the same way DeliverOptions /
# ExternalTestFlightOptions / BuildProcessingStatus stay fastlane-free.
#
# OFF BY DEFAULT — fail-safe when unconfigured (the central EPIC-06 policy, the
# fastlane-side mirror of slice 1's "no DSN => no-op"): the upload happens ONLY
# when ALL THREE of SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT are present
# and "usable" (non-blank, and not an unexpanded `$(...)`/`${...}` placeholder).
# Any required piece missing / blank / a placeholder => `build` returns nil. So
# an app with no Sentry account still ships, and its CI stays green; the lane is
# NEVER failed just because Sentry isn't set up. Requiring all three (not just
# the token) means a half-configured app no-ops cleanly rather than erroring
# inside sentry-cli on a missing org/project.
#
# SECRET HYGIENE: SENTRY_AUTH_TOKEN is secret material. This module never logs
# (it's pure — returns data, prints nothing); the token only ever lives in the
# returned hash, and the lane passes it to sentry-cli WITHOUT echoing it.
#
# BACKEND-AGNOSTIC: the reporting backend is Sentry, but GlitchTip is a future
# drop-in via the same sentry-cli + an org/project (and SENTRY_URL if ever
# needed) — so nothing here hardcodes "sentry.io". Only the generic
# token/org/project identity is modeled.
module SentryDsymOptions
  module_function

  # The three ENV keys that together configure a dSYM upload. ALL are required —
  # absence/blank/placeholder of ANY one makes the whole step a no-op.
  ORG_ENV     = "SENTRY_ORG".freeze
  PROJECT_ENV = "SENTRY_PROJECT".freeze
  # ENV-backed secret name for the Sentry auth token (the reversible TL call;
  # documented in the workflow + README). Never logged.
  AUTH_TOKEN_ENV = "SENTRY_AUTH_TOKEN".freeze

  # An UNEXPANDED variable reference — a `$(VAR)` or `${VAR}` that some upstream
  # (a workflow input, a build setting) was supposed to substitute but didn't,
  # e.g. an app with no Sentry account whose template passes the literal
  # `$(SENTRY_AUTH_TOKEN)` straight through. We must treat that as UNSET, not as
  # a real credential — otherwise we'd ship the literal placeholder to
  # sentry-cli. A bare `$` inside an otherwise-real value is NOT a placeholder
  # (don't over-reject legitimate tokens), so the whole trimmed value must BE the
  # reference for it to count.
  PLACEHOLDER_PATTERN = /\A\$[({].*[)}]\z/.freeze

  # ENV -> nil (no-op) or { auth_token:, org_slug:, project_slug: }. Pure: no
  # fastlane, no IO, no network, no logging. Returns nil unless ALL THREE pieces
  # are usable; the lane treats nil as "skip the upload, ship to TestFlight as
  # usual".
  def build(env)
    token   = usable(env[AUTH_TOKEN_ENV])
    org     = usable(env[ORG_ENV])
    project = usable(env[PROJECT_ENV])
    return nil unless token && org && project

    {
      auth_token:   token,
      org_slug:     org,
      project_slug: project,
    }
  end

  # True iff env is fully configured for a dSYM upload (all three usable). Thin
  # predicate over `build` so the lane can branch readably without duplicating
  # the rule.
  def configured?(env)
    !build(env).nil?
  end

  # Normalize a raw ENV value to a usable string, or nil if it can't be used.
  # nil/blank => nil; an unexpanded `$(...)`/`${...}` placeholder => nil;
  # otherwise the whitespace-trimmed value. Internal helper.
  def usable(raw)
    s = raw.to_s.strip
    return nil if s.empty?
    return nil if s.match?(PLACEHOLDER_PATTERN)

    s
  end
  private_class_method :usable
end
