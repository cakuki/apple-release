require "minitest/autorun"
require_relative "../fastlane/deliver_options"

# Behavior of the pure option builder behind the central `deliver` (metadata-only)
# lane (EPIC-07 slice 1, cakuki/atelier#7).
#
# DeliverOptions.build(env) turns the process ENV into the exact kwargs hash the
# `deliver` lane feeds to fastlane's `upload_to_app_store` action — minus the ASC
# api_key, which the lane merges in at call time (built via the live
# `app_store_connect_api_key` helper). Keeping the option assembly pure means the
# whole metadata contract is asserted here WITHOUT fastlane, a simulator, or any
# network/ASC call — mirroring how ReleasePlan/CoverageGate stay fastlane-free.
#
# SAFETY: the lane is metadata-only and NON-LIVE by default. `verify_only` is the
# inverse of an explicit `DELIVER_SUBMIT=true` opt-in, so CI validates the listing
# against ASC but never mutates the store unless a caller deliberately opts in
# (the owner-gated slice 4). These tests lock that default down.
class DeliverLaneTest < Minitest::Test
  IDENTIFIER = "com.example.app".freeze

  # A minimal env with the one required key present, so individual tests can
  # tweak a single variable without re-stating the whole hash.
  def env(overrides = {})
    { "APP_IDENTIFIER" => IDENTIFIER }.merge(overrides)
  end

  # --- the static, single-purpose metadata-only flags ---

  def test_metadata_only_flags
    opts = DeliverOptions.build(env)
    assert_equal true,  opts[:skip_binary_upload], "deliver is metadata-only; beta owns binaries"
    assert_equal true,  opts[:skip_screenshots],   "screenshots are slice 3 (snapshot/frameit)"
    assert_equal true,  opts[:force],              "CI is non-interactive: no HTML preview confirm"
    assert_equal false, opts[:run_precheck_before_submit], "precheck needs live/network; off until slice 4"
    assert_equal false, opts[:submit_for_review],  "never auto-submit for review from this lane"
    assert_equal false, opts[:automatic_release],  "never auto-release from this lane"
  end

  # --- app_identifier comes straight from ENV ---

  def test_app_identifier_from_env
    assert_equal IDENTIFIER, DeliverOptions.build(env)[:app_identifier]
  end

  def test_missing_app_identifier_raises
    # Mirrors the ENV.fetch fail-fast contract used by beta/sync_signing.
    assert_raises(KeyError) { DeliverOptions.build({}) }
  end

  # --- metadata_path: default + override ---

  def test_metadata_path_defaults_to_metadata_relative_to_fastlane_cwd
    # Lanes run with CWD = fastlane/, so the <repo>/fastlane/metadata scaffold is "./metadata".
    assert_equal "./metadata", DeliverOptions.build(env)[:metadata_path]
  end

  def test_metadata_path_override_from_env
    opts = DeliverOptions.build(env("METADATA_PATH" => "./custom/metadata"))
    assert_equal "./custom/metadata", opts[:metadata_path]
  end

  # --- the non-live default: verify_only is the inverse of DELIVER_SUBMIT ---

  def test_verify_only_true_by_default
    # DELIVER_SUBMIT unset => non-live => validate only, never push to ASC.
    assert_equal true, DeliverOptions.build(env)[:verify_only]
  end

  # Table-drive the DELIVER_SUBMIT truthiness parse (case/whitespace variants),
  # like the MIN_COVERAGE parsing tests. Only an exact "true" (case-insensitive,
  # trimmed) opts into a live upload; everything else stays verify-only.
  SUBMIT_FLIPS_LIVE = {
    "true"   => false,
    "TRUE"   => false,
    "  true" => false,
    "true\n" => false,
    " TrUe " => false,
  }.freeze

  NON_SUBMIT_STAYS_VERIFY = [
    "false", "FALSE", "0", "1", "yes", "no", "", "  ", "truee", "nottrue",
  ].freeze

  def test_deliver_submit_true_variants_make_it_live
    SUBMIT_FLIPS_LIVE.each do |raw, expected_verify_only|
      opts = DeliverOptions.build(env("DELIVER_SUBMIT" => raw))
      assert_equal expected_verify_only, opts[:verify_only],
                   "DELIVER_SUBMIT=#{raw.inspect} should opt into a live upload (verify_only=false)"
    end
  end

  def test_non_true_deliver_submit_stays_verify_only
    NON_SUBMIT_STAYS_VERIFY.each do |raw|
      opts = DeliverOptions.build(env("DELIVER_SUBMIT" => raw))
      assert_equal true, opts[:verify_only],
                   "DELIVER_SUBMIT=#{raw.inspect} must NOT push to ASC (verify_only=true)"
    end
  end

  # --- the api_key is the lane's responsibility, NOT this pure builder's ---

  def test_does_not_include_api_key
    refute DeliverOptions.build(env).key?(:api_key),
           "api_key is merged by the lane from the live ASC helper; not built here"
  end
end
