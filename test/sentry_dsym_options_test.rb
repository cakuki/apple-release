require "minitest/autorun"
require_relative "../fastlane/sentry_dsym_options"

# Behavior of the pure option builder behind the `beta` lane's dSYM-upload step
# (EPIC-06 slice 2, cakuki/atelier#6).
#
# SentryDsymOptions.build(env) turns the process ENV into either nil (a clean
# no-op: Sentry isn't configured, so the lane skips the upload entirely) or the
# exact params hash the `beta` lane feeds to `sentry-cli debug-files upload`
# (auth_token / org_slug / project_slug). Keeping the decision pure means the
# whole "should we upload? with what params?" contract is asserted here WITHOUT
# fastlane, sentry-cli, a simulator, or any network/Sentry call — mirroring how
# DeliverOptions / ExternalTestFlightOptions / BuildProcessingStatus stay
# fastlane-free.
#
# SAFETY (the central EPIC-06 policy, mirroring slice 1's "no DSN => no-op"):
# dSYM upload is OFF unless ALL of SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT
# are present and non-blank. Any missing / blank / unexpanded `$(...)` placeholder
# value makes `build` return nil, so an app with no Sentry account still archives
# + uploads to TestFlight exactly as today and its CI stays green. The lane NEVER
# fails just because Sentry isn't configured. These tests lock that down — and
# verify the secret token is carried as data, never logged (the lane owns the
# I/O; the secret only ever lives in the returned hash).
class SentryDsymOptionsTest < Minitest::Test
  TOKEN   = "sntrys_exampletoken".freeze
  ORG     = "acme".freeze
  PROJECT = "ios-app".freeze

  # A fully-configured env, so individual tests can blank one key at a time
  # without re-stating the whole hash.
  def configured(overrides = {})
    {
      "SENTRY_AUTH_TOKEN" => TOKEN,
      "SENTRY_ORG"        => ORG,
      "SENTRY_PROJECT"    => PROJECT,
    }.merge(overrides)
  end

  # --- configured => params hash ---

  def test_fully_configured_returns_params
    opts = SentryDsymOptions.build(configured)
    assert_equal TOKEN,   opts[:auth_token]
    assert_equal ORG,     opts[:org_slug]
    assert_equal PROJECT, opts[:project_slug]
  end

  def test_params_are_exactly_the_three_keys
    # No surprise extra keys: the lane owns the dSYM path/argv; this builder only
    # decides identity (token/org/project). Keep the contract tight.
    opts = SentryDsymOptions.build(configured)
    assert_equal [:auth_token, :org_slug, :project_slug].sort, opts.keys.sort
  end

  def test_values_are_whitespace_trimmed
    # Surrounding whitespace (e.g. a stray newline from a secret store) is
    # trimmed so the value flows cleanly into sentry-cli as an argument.
    opts = SentryDsymOptions.build(
      configured("SENTRY_AUTH_TOKEN" => "  #{TOKEN}\n",
                 "SENTRY_ORG"        => " #{ORG} ",
                 "SENTRY_PROJECT"    => "#{PROJECT}\t")
    )
    assert_equal TOKEN,   opts[:auth_token]
    assert_equal ORG,     opts[:org_slug]
    assert_equal PROJECT, opts[:project_slug]
  end

  # --- unconfigured => nil (clean no-op) ---

  def test_empty_env_is_noop
    assert_nil SentryDsymOptions.build({}),
               "no Sentry config at all => no-op (nil), lane still ships to TestFlight"
  end

  def test_missing_token_is_noop
    e = configured
    e.delete("SENTRY_AUTH_TOKEN")
    assert_nil SentryDsymOptions.build(e),
               "missing SENTRY_AUTH_TOKEN => no-op (never upload without an auth token)"
  end

  def test_missing_org_is_noop
    e = configured
    e.delete("SENTRY_ORG")
    assert_nil SentryDsymOptions.build(e), "missing SENTRY_ORG => no-op"
  end

  def test_missing_project_is_noop
    e = configured
    e.delete("SENTRY_PROJECT")
    assert_nil SentryDsymOptions.build(e), "missing SENTRY_PROJECT => no-op"
  end

  # Each required key, blanked one at a time (empty + whitespace-only), must
  # no-op — a present-but-blank secret is as good as unset.
  def test_blank_value_for_any_required_key_is_noop
    %w[SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT].each do |key|
      ["", "   ", "\n", "\t"].each do |blank|
        assert_nil SentryDsymOptions.build(configured(key => blank)),
                   "blank #{key}=#{blank.inspect} => no-op (treated as unset)"
      end
    end
  end

  # An UNEXPANDED `$(...)` placeholder (a secret/env reference that was never
  # substituted — e.g. an app with no Sentry account whose workflow passes the
  # literal `$(SENTRY_AUTH_TOKEN)` through) must be treated as unset => no-op,
  # NOT shipped to sentry-cli as a literal credential. This mirrors how the
  # template's no-DSN path no-ops rather than using a placeholder DSN.
  def test_unexpanded_placeholder_for_any_required_key_is_noop
    %w[SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT].each do |key|
      [
        "$(SENTRY_AUTH_TOKEN)", "$(SENTRY_ORG)", "$(SENTRY_PROJECT)",
        "$(ANYTHING)", "  $(VAR)  ", "${VAR}",
      ].each do |placeholder|
        assert_nil SentryDsymOptions.build(configured(key => placeholder)),
                   "unexpanded placeholder #{key}=#{placeholder.inspect} => no-op"
      end
    end
  end

  # A legitimate value that merely CONTAINS a `$` (but isn't a `$(...)`/`${...}`
  # placeholder) is configured normally — don't over-reject real tokens.
  def test_value_with_bare_dollar_is_not_a_placeholder
    opts = SentryDsymOptions.build(configured("SENTRY_AUTH_TOKEN" => "abc$def"))
    refute_nil opts, "a bare `$` inside a value is not an unexpanded placeholder"
    assert_equal "abc$def", opts[:auth_token]
  end

  # --- no logging of secrets: build is pure (returns data, prints nothing) ---

  def test_build_prints_nothing
    # The token is secret material. The pure builder must never echo it (or
    # anything) — it returns data; the lane owns any (token-free) logging.
    assert_output("", "") { SentryDsymOptions.build(configured) }
    assert_output("", "") { SentryDsymOptions.build({}) }
  end
end
