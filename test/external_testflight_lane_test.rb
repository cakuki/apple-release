require "minitest/autorun"
require_relative "../fastlane/external_testflight_options"

# Behavior of the pure option builder behind the central `distribute_external`
# (external TestFlight) lane (EPIC-08 slice 1, cakuki/atelier#8).
#
# ExternalTestFlightOptions.build(env) turns the process ENV into the exact kwargs
# hash the `distribute_external` lane feeds to fastlane's `pilot` /
# `upload_to_testflight` action — minus the ASC `api_key` and `changelog`, which
# the lane merges in at call time (the api_key built via the live
# `app_store_connect_api_key` helper, the changelog via `changelog_from_md`).
# Keeping the option assembly pure means the whole external-distribution contract
# is asserted here WITHOUT fastlane, a simulator, or any network/ASC call —
# mirroring how DeliverOptions / ReleasePlan / CoverageGate stay fastlane-free.
#
# SAFETY: external distribution is OFF by default. `distribute_external` is the
# inverse-free mirror of DeliverOptions' DELIVER_SUBMIT: only an explicit
# `TESTFLIGHT_DISTRIBUTE_EXTERNAL=true` opt-in flips it on AND attaches `groups`.
# With the opt-in OFF the build never even carries a `groups` key, so a build can
# never be pushed to external testers implicitly. These tests lock that down.
class ExternalTestFlightLaneTest < Minitest::Test
  IDENTIFIER = "com.example.app".freeze

  # A minimal env with the one required key present, so individual tests can
  # tweak a single variable without re-stating the whole hash.
  def env(overrides = {})
    { "APP_IDENTIFIER" => IDENTIFIER }.merge(overrides)
  end

  # --- the static, single-purpose flags ---

  def test_static_flags
    opts = ExternalTestFlightOptions.build(env)
    assert_equal true, opts[:skip_waiting_for_build_processing],
                 "the lane reuses the already-processed beta build; never block on processing"
  end

  # --- app_identifier comes straight from ENV (fail fast) ---

  def test_app_identifier_from_env
    assert_equal IDENTIFIER, ExternalTestFlightOptions.build(env)[:app_identifier]
  end

  def test_missing_app_identifier_raises
    # Mirrors the ENV.fetch fail-fast contract used by beta/sync_signing/deliver.
    assert_raises(KeyError) { ExternalTestFlightOptions.build({}) }
  end

  # --- api_key / changelog are the lane's responsibility, NOT this builder's ---

  def test_does_not_include_api_key
    refute ExternalTestFlightOptions.build(env).key?(:api_key),
           "api_key is merged by the lane from the live ASC helper; not built here"
  end

  def test_does_not_include_changelog
    refute ExternalTestFlightOptions.build(env).key?(:changelog),
           "changelog is merged by the lane from changelog_from_md; not built here"
  end

  # --- the OFF-by-default opt-in: distribute_external + groups ---

  def test_distribute_external_false_by_default
    # TESTFLIGHT_DISTRIBUTE_EXTERNAL unset => internal only, no external push.
    opts = ExternalTestFlightOptions.build(env)
    assert_equal false, opts[:distribute_external],
                 "external distribution must be OFF unless explicitly opted in"
  end

  def test_no_groups_key_when_off
    # The default-safety lock: with the opt-in OFF the build never even carries a
    # `groups` key, so pilot can't target external groups implicitly.
    refute ExternalTestFlightOptions.build(env).key?(:groups),
           "groups must be omitted entirely when the opt-in is OFF"
  end

  # Table-drive the TESTFLIGHT_DISTRIBUTE_EXTERNAL truthiness parse (case/whitespace),
  # mirroring DeliverOptions' DELIVER_SUBMIT. Only an exact "true" (case-insensitive,
  # trimmed) opts in; everything else stays internal-only.
  ON_VARIANTS  = ["true", "TRUE", "  true", "true\n", " TrUe "].freeze
  OFF_VARIANTS = ["false", "FALSE", "0", "1", "yes", "no", "", "  ", "truee", "nottrue"].freeze

  def test_opt_in_true_variants_distribute_external
    ON_VARIANTS.each do |raw|
      opts = ExternalTestFlightOptions.build(
        env("TESTFLIGHT_DISTRIBUTE_EXTERNAL" => raw, "TESTFLIGHT_GROUPS" => "Beta")
      )
      assert_equal true, opts[:distribute_external],
                   "TESTFLIGHT_DISTRIBUTE_EXTERNAL=#{raw.inspect} should opt into external distribution"
    end
  end

  def test_non_true_opt_in_stays_internal
    OFF_VARIANTS.each do |raw|
      opts = ExternalTestFlightOptions.build(
        env("TESTFLIGHT_DISTRIBUTE_EXTERNAL" => raw, "TESTFLIGHT_GROUPS" => "Beta")
      )
      assert_equal false, opts[:distribute_external],
                   "TESTFLIGHT_DISTRIBUTE_EXTERNAL=#{raw.inspect} must NOT distribute externally"
      refute opts.key?(:groups),
             "TESTFLIGHT_DISTRIBUTE_EXTERNAL=#{raw.inspect} (OFF) must omit groups entirely"
    end
  end

  # --- group-list parsing (only when opt-in ON) ---

  def test_groups_parsed_when_on
    opts = ExternalTestFlightOptions.build(
      env("TESTFLIGHT_DISTRIBUTE_EXTERNAL" => "true",
          "TESTFLIGHT_GROUPS" => "Beta Testers, External, QA")
    )
    assert_equal ["Beta Testers", "External", "QA"], opts[:groups]
  end

  def test_groups_strip_and_reject_empties
    opts = ExternalTestFlightOptions.build(
      env("TESTFLIGHT_DISTRIBUTE_EXTERNAL" => "true",
          "TESTFLIGHT_GROUPS" => "  Beta ,, , External ,")
    )
    assert_equal ["Beta", "External"], opts[:groups],
                 "split on comma, strip each, reject empty fragments"
  end

  def test_single_group
    opts = ExternalTestFlightOptions.build(
      env("TESTFLIGHT_DISTRIBUTE_EXTERNAL" => "true", "TESTFLIGHT_GROUPS" => "External Testers")
    )
    assert_equal ["External Testers"], opts[:groups]
  end

  # When opted in, at least one valid group is required — distributing externally
  # with no group is a misconfiguration, not a silent no-op.
  def test_on_with_no_groups_raises
    [nil, "", "  ", ",", " , ,"].each do |raw|
      e = env("TESTFLIGHT_DISTRIBUTE_EXTERNAL" => "true")
      e["TESTFLIGHT_GROUPS"] = raw unless raw.nil?
      err = assert_raises(ArgumentError) { ExternalTestFlightOptions.build(e) }
      assert_includes err.message, "TESTFLIGHT_GROUPS"
    end
  end

  # --- group-name validation (mirror LOCALE_PATTERN's path-traversal defense) ---

  # A group name becomes an argument to pilot; reject anything carrying a path
  # separator or control char up front (ArgumentError), like DeliverReleaseNotes
  # rejects a traversal-y locale before it can become a path segment.
  def test_group_validation_rejects_dangerous_names
    ["../x", "a/b", "back\\slash", "x\x00y", "del\x7fhere", "tab\ty", "new\nline"].each do |bad|
      err = assert_raises(ArgumentError) do
        ExternalTestFlightOptions.build(
          env("TESTFLIGHT_DISTRIBUTE_EXTERNAL" => "true",
              "TESTFLIGHT_GROUPS" => "Good, #{bad}")
        )
      end
      assert_includes err.message, "TESTFLIGHT_GROUPS",
                      "a dangerous group name (#{bad.inspect}) must fail fast"
    end
  end

  def test_group_validation_skipped_when_off
    # A dangerous-looking TESTFLIGHT_GROUPS with the opt-in OFF must NOT raise —
    # groups are ignored entirely when off, so there's nothing to validate.
    opts = ExternalTestFlightOptions.build(
      env("TESTFLIGHT_DISTRIBUTE_EXTERNAL" => "false", "TESTFLIGHT_GROUPS" => "../evil")
    )
    assert_equal false, opts[:distribute_external]
    refute opts.key?(:groups)
  end
end
