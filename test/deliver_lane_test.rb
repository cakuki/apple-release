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
    assert_equal false, opts[:submit_for_review],  "never auto-submit for review by default"
    assert_equal false, opts[:phased_release],     "never phase-release by default (opt-in DELIVER_PHASED_RELEASE)"
    assert_equal false, opts[:automatic_release],  "never auto-release from this lane (phased release is the controlled alternative)"
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

  # --- submit-for-review: a SECOND opt-in layered on DELIVER_SUBMIT (slice 2) ---
  #
  # submit_for_review only makes sense during a live upload, so it requires BOTH
  # DELIVER_SUBMIT_FOR_REVIEW=true AND DELIVER_SUBMIT=true. The cross-flag guard
  # raises if review is requested without the live upload that carries it, so a
  # caller can't believe they submitted when they only validated.

  def test_submit_for_review_false_by_default
    # Neither opt-in set => verify-only, and certainly not submitting for review.
    assert_equal false, DeliverOptions.build(env)[:submit_for_review]
  end

  def test_submit_for_review_false_when_only_deliver_submit_set
    # Live upload but no review opt-in => upload happens, review does not.
    opts = DeliverOptions.build(env("DELIVER_SUBMIT" => "true"))
    assert_equal false, opts[:verify_only], "DELIVER_SUBMIT=true should go live"
    assert_equal false, opts[:submit_for_review],
                 "live upload without DELIVER_SUBMIT_FOR_REVIEW must NOT submit for review"
  end

  def test_submit_for_review_true_only_when_both_opt_ins_set
    opts = DeliverOptions.build(
      env("DELIVER_SUBMIT" => "true", "DELIVER_SUBMIT_FOR_REVIEW" => "true")
    )
    assert_equal false, opts[:verify_only],       "DELIVER_SUBMIT=true should go live"
    assert_equal true,  opts[:submit_for_review], "both opt-ins set => submit for review"
  end

  # The cross-flag guard: review-on but submit-off is a misconfiguration (you'd be
  # validating, not submitting), so fail fast rather than silently not submitting.
  def test_submit_for_review_without_deliver_submit_raises
    assert_raises(ArgumentError) do
      DeliverOptions.build(env("DELIVER_SUBMIT_FOR_REVIEW" => "true"))
    end
  end

  def test_submit_for_review_without_deliver_submit_raises_even_if_submit_falsey
    # An explicit non-"true" DELIVER_SUBMIT still isn't a live upload, so a review
    # opt-in on top of it is still the same misconfiguration => raise.
    assert_raises(ArgumentError) do
      DeliverOptions.build(env("DELIVER_SUBMIT" => "false", "DELIVER_SUBMIT_FOR_REVIEW" => "true"))
    end
  end

  # Table-drive the DELIVER_SUBMIT_FOR_REVIEW truthiness parse, mirroring the
  # DELIVER_SUBMIT parse exactly. Only an exact "true" (case-insensitive, trimmed)
  # flips it on; everything else leaves submit_for_review false. All "true" cases
  # are paired with DELIVER_SUBMIT=true so the guard doesn't fire.
  SUBMIT_FOR_REVIEW_TRUE = ["true", "TRUE", "  true", "true\n", " TrUe "].freeze
  SUBMIT_FOR_REVIEW_FALSE = [
    "false", "FALSE", "0", "1", "yes", "no", "", "  ", "truee", "nottrue",
  ].freeze

  def test_submit_for_review_true_variants
    SUBMIT_FOR_REVIEW_TRUE.each do |raw|
      opts = DeliverOptions.build(
        env("DELIVER_SUBMIT" => "true", "DELIVER_SUBMIT_FOR_REVIEW" => raw)
      )
      assert_equal true, opts[:submit_for_review],
                   "DELIVER_SUBMIT_FOR_REVIEW=#{raw.inspect} (with DELIVER_SUBMIT=true) should submit for review"
    end
  end

  def test_non_true_submit_for_review_stays_off
    SUBMIT_FOR_REVIEW_FALSE.each do |raw|
      opts = DeliverOptions.build(
        env("DELIVER_SUBMIT" => "true", "DELIVER_SUBMIT_FOR_REVIEW" => raw)
      )
      assert_equal false, opts[:submit_for_review],
                   "DELIVER_SUBMIT_FOR_REVIEW=#{raw.inspect} must NOT submit for review"
    end
  end

  # --- phased release: a THIRD opt-in layered on DELIVER_SUBMIT (slice 3) ---
  #
  # phased_release governs how an APPROVED version rolls out to users gradually,
  # so it's only meaningful on a real (live) upload. Like submit-for-review it is
  # an independent opt-in that requires DELIVER_SUBMIT=true; unlike it, it does NOT
  # depend on DELIVER_SUBMIT_FOR_REVIEW — phased rollout is configured on the
  # version regardless of whether THIS run also submits for review (Apple applies
  # it when the version is approved + released). automatic_release stays false:
  # phased release is the controlled alternative to an immediate auto-release.

  def test_phased_release_false_by_default
    # No opt-in set => verify-only, and certainly not a phased release.
    assert_equal false, DeliverOptions.build(env)[:phased_release]
  end

  def test_phased_release_false_when_only_deliver_submit_set
    # Live upload but no phased-release opt-in => upload happens, no phased rollout.
    opts = DeliverOptions.build(env("DELIVER_SUBMIT" => "true"))
    assert_equal false, opts[:verify_only], "DELIVER_SUBMIT=true should go live"
    assert_equal false, opts[:phased_release],
                 "live upload without DELIVER_PHASED_RELEASE must NOT enable phased rollout"
  end

  def test_phased_release_true_only_when_both_submit_and_phased_set
    opts = DeliverOptions.build(
      env("DELIVER_SUBMIT" => "true", "DELIVER_PHASED_RELEASE" => "true")
    )
    assert_equal false, opts[:verify_only],     "DELIVER_SUBMIT=true should go live"
    assert_equal true,  opts[:phased_release],  "submit + phased opt-in => phased release"
    assert_equal false, opts[:automatic_release], "phased release is the controlled alternative to auto-release"
  end

  # phased_release is INDEPENDENT of submit_for_review: it can be on with review
  # off, and review on with phased off — both ride the same live upload.
  def test_phased_release_independent_of_submit_for_review
    opts = DeliverOptions.build(
      env("DELIVER_SUBMIT" => "true", "DELIVER_PHASED_RELEASE" => "true")
    )
    assert_equal true,  opts[:phased_release],
                 "phased release does not require DELIVER_SUBMIT_FOR_REVIEW"
    assert_equal false, opts[:submit_for_review],
                 "phased release on its own must not flip submit_for_review"
  end

  def test_submit_for_review_and_phased_release_can_both_be_on
    # The two roll-out opt-ins are orthogonal: submitting for review AND requesting
    # a phased rollout in the same live upload must both take effect (guard against
    # a future change accidentally making them mutually exclusive).
    opts = DeliverOptions.build(
      env("DELIVER_SUBMIT" => "true",
          "DELIVER_SUBMIT_FOR_REVIEW" => "true",
          "DELIVER_PHASED_RELEASE" => "true")
    )
    assert_equal true, opts[:submit_for_review], "both opt-ins on: submit_for_review must be true"
    assert_equal true, opts[:phased_release],    "both opt-ins on: phased_release must be true"
  end

  # The cross-flag guard: phased-on but submit-off is a misconfiguration (you'd be
  # validating, not releasing), so fail fast rather than silently not releasing.
  def test_phased_release_without_deliver_submit_raises
    assert_raises(ArgumentError) do
      DeliverOptions.build(env("DELIVER_PHASED_RELEASE" => "true"))
    end
  end

  def test_phased_release_without_deliver_submit_raises_even_if_submit_falsey
    # An explicit non-"true" DELIVER_SUBMIT still isn't a live upload, so a phased
    # opt-in on top of it is still the same misconfiguration => raise.
    assert_raises(ArgumentError) do
      DeliverOptions.build(env("DELIVER_SUBMIT" => "false", "DELIVER_PHASED_RELEASE" => "true"))
    end
  end

  # Table-drive the DELIVER_PHASED_RELEASE truthiness parse, mirroring the
  # DELIVER_SUBMIT parse exactly. Only an exact "true" (case-insensitive, trimmed)
  # flips it on; everything else leaves phased_release false. All "true" cases are
  # paired with DELIVER_SUBMIT=true so the guard doesn't fire.
  PHASED_RELEASE_TRUE = ["true", "TRUE", "  true", "true\n", " TrUe "].freeze
  PHASED_RELEASE_FALSE = [
    "false", "FALSE", "0", "1", "yes", "no", "", "  ", "truee", "nottrue",
  ].freeze

  def test_phased_release_true_variants
    PHASED_RELEASE_TRUE.each do |raw|
      opts = DeliverOptions.build(
        env("DELIVER_SUBMIT" => "true", "DELIVER_PHASED_RELEASE" => raw)
      )
      assert_equal true, opts[:phased_release],
                   "DELIVER_PHASED_RELEASE=#{raw.inspect} (with DELIVER_SUBMIT=true) should enable phased release"
    end
  end

  def test_non_true_phased_release_stays_off
    PHASED_RELEASE_FALSE.each do |raw|
      opts = DeliverOptions.build(
        env("DELIVER_SUBMIT" => "true", "DELIVER_PHASED_RELEASE" => raw)
      )
      assert_equal false, opts[:phased_release],
                   "DELIVER_PHASED_RELEASE=#{raw.inspect} must NOT enable phased release"
    end
  end

  # --- the api_key is the lane's responsibility, NOT this pure builder's ---

  def test_does_not_include_api_key
    refute DeliverOptions.build(env).key?(:api_key),
           "api_key is merged by the lane from the live ASC helper; not built here"
  end
end
