require "minitest/autorun"
require_relative "../fastlane/snapshot_options"

# Behavior of the pure option builder behind the central `screenshots` lane
# (EPIC-07 slice/Task 2, cakuki/atelier#123).
#
# SnapshotOptions.build(env) turns the process ENV into the exact kwargs hash the
# `screenshots` lane feeds to fastlane's `capture_screenshots` (snapshot) action,
# and SnapshotOptions.frame?(env) answers the separate "should we run frameit
# afterwards?" question. Keeping both decisions pure means the whole
# screenshot-capture contract is asserted here WITHOUT fastlane, a simulator,
# Xcode, or any Apple call — mirroring how DeliverOptions / SentryDsymOptions /
# ExternalTestFlightOptions stay fastlane-free.
#
# SAFETY: the lane is NON-LIVE — it only generates local screenshots into an
# output dir and NEVER uploads (upload rides the owner-gated `deliver` slice 4).
# There's nothing to keep "off by default" here; the safety is purely that no
# kwarg this builder produces can reach App Store Connect. frameit is OFF by
# default (frames are heavy/opinionated) and toggled on via SNAPSHOT_FRAMES /
# FRAMEIT. These tests lock the defaults + parsing down.
class SnapshotOptionsTest < Minitest::Test
  SCHEME = "MyApp-Dev".freeze

  # A minimal env with the one required key present, so individual tests can
  # tweak a single variable without re-stating the whole hash.
  def env(overrides = {})
    { "SCHEME" => SCHEME }.merge(overrides)
  end

  # --- scheme comes straight from ENV (fail fast) ---

  def test_scheme_from_env
    assert_equal SCHEME, SnapshotOptions.build(env)[:scheme]
  end

  def test_missing_scheme_raises
    # Mirrors the ENV.fetch fail-fast contract used by beta/deliver (SCHEME, like
    # those lanes' app_identifier, is required — there's nothing to capture without it).
    assert_raises(KeyError) { SnapshotOptions.build({}) }
  end

  # --- the static, single-purpose flags ---

  def test_static_flags
    opts = SnapshotOptions.build(env)
    assert_equal true, opts[:clear_previous_screenshots],
                 "wipe the output dir each run so captures are deterministic, never stale-mixed"
    assert_equal false, opts[:skip_open_summary],
                 "let snapshot decide; we never auto-open anything in CI (HTML summary stays a local convenience)"
  end

  # --- output_dir: default + override ---

  def test_output_directory_defaults
    # Lanes run with CWD = fastlane/, so `./screenshots` resolves to fastlane/screenshots —
    # a local, git-ignorable artifact dir. Default mirrors deliver's `./metadata` style.
    assert_equal "./screenshots", SnapshotOptions.build(env)[:output_directory]
  end

  def test_output_directory_override_from_env
    opts = SnapshotOptions.build(env("SNAPSHOT_OUTPUT_DIR" => "./shots/out"))
    assert_equal "./shots/out", opts[:output_directory]
  end

  def test_blank_output_directory_falls_back_to_default
    ["", "   ", "\n", "\t"].each do |blank|
      assert_equal "./screenshots", SnapshotOptions.build(env("SNAPSHOT_OUTPUT_DIR" => blank))[:output_directory],
                   "blank SNAPSHOT_OUTPUT_DIR=#{blank.inspect} => default ./screenshots"
    end
  end

  # --- devices: default + list parsing ---

  def test_devices_default_is_single_representative_device
    # Default a single representative device when unset: a multi-device matrix is
    # slow + opinionated, so opt into more via SNAPSHOT_DEVICES rather than defaulting wide.
    assert_equal ["iPhone 16 Pro"], SnapshotOptions.build(env)[:devices]
  end

  def test_devices_parsed_from_comma_list
    opts = SnapshotOptions.build(env("SNAPSHOT_DEVICES" => "iPhone 16 Pro, iPad Pro (12.9-inch)"))
    assert_equal ["iPhone 16 Pro", "iPad Pro (12.9-inch)"], opts[:devices]
  end

  def test_devices_split_on_comma_and_newline_strip_and_reject_empties
    # Robust list parse: split on commas AND newlines (a YAML block-scalar input
    # arrives newline-separated), strip each, drop empty fragments. Spaces WITHIN a
    # device name (e.g. "iPhone 16 Pro") are preserved — we split on commas/newlines, not spaces.
    opts = SnapshotOptions.build(
      env("SNAPSHOT_DEVICES" => "  iPhone 16 Pro ,, \n iPad mini \n, ")
    )
    assert_equal ["iPhone 16 Pro", "iPad mini"], opts[:devices]
  end

  def test_single_device
    opts = SnapshotOptions.build(env("SNAPSHOT_DEVICES" => "iPhone SE (3rd generation)"))
    assert_equal ["iPhone SE (3rd generation)"], opts[:devices]
  end

  def test_blank_devices_falls_back_to_default
    ["", "   ", ",", " , ,", "\n"].each do |blank|
      assert_equal ["iPhone 16 Pro"], SnapshotOptions.build(env("SNAPSHOT_DEVICES" => blank))[:devices],
                   "blank/empty SNAPSHOT_DEVICES=#{blank.inspect} => default single device"
    end
  end

  # --- languages: default + list parsing ---

  def test_languages_default_is_en_us
    assert_equal ["en-US"], SnapshotOptions.build(env)[:languages]
  end

  def test_languages_parsed_from_comma_list
    opts = SnapshotOptions.build(env("SNAPSHOT_LANGUAGES" => "en-US, de-DE, fr-FR"))
    assert_equal ["en-US", "de-DE", "fr-FR"], opts[:languages]
  end

  def test_languages_split_strip_and_reject_empties
    opts = SnapshotOptions.build(env("SNAPSHOT_LANGUAGES" => " en-US ,, \n tr \n, "))
    assert_equal ["en-US", "tr"], opts[:languages]
  end

  def test_blank_languages_falls_back_to_default
    ["", "   ", ",", "\n"].each do |blank|
      assert_equal ["en-US"], SnapshotOptions.build(env("SNAPSHOT_LANGUAGES" => blank))[:languages],
                   "blank/empty SNAPSHOT_LANGUAGES=#{blank.inspect} => default en-US"
    end
  end

  # --- project: attached only when XCODEPROJ is set ---

  def test_project_attached_when_xcodeproj_set
    opts = SnapshotOptions.build(env("XCODEPROJ" => "MyApp.xcodeproj"))
    assert_equal "MyApp.xcodeproj", opts[:project]
  end

  def test_project_omitted_when_xcodeproj_unset_or_blank
    refute SnapshotOptions.build(env).key?(:project),
           "no XCODEPROJ => omit project entirely (let snapshot infer from cwd)"
    ["", "   ", "\n"].each do |blank|
      refute SnapshotOptions.build(env("XCODEPROJ" => blank)).key?(:project),
             "blank XCODEPROJ=#{blank.inspect} => omit project entirely"
    end
  end

  # --- never any upload / live key (the NON-LIVE guarantee) ---

  def test_no_upload_keys
    # The lane is local-only; assert no kwarg could push to ASC. (capture_screenshots
    # has no upload option, but lock the contract so a future edit can't sneak one in.)
    opts = SnapshotOptions.build(env("XCODEPROJ" => "MyApp.xcodeproj"))
    %i[api_key app_identifier upload submit_for_review].each do |k|
      refute opts.key?(k), "screenshots is NON-LIVE; must never carry #{k.inspect}"
    end
  end

  # --- frameit toggle: OFF by default, on via SNAPSHOT_FRAMES / FRAMEIT ---

  def test_frame_off_by_default
    refute SnapshotOptions.frame?(env),
           "frameit is OFF by default (frames are heavy/opinionated); opt in explicitly"
  end

  # Table-drive the truthiness parse (case/whitespace), mirroring DeliverOptions'
  # DELIVER_SUBMIT: only an exact "true" (case-insensitive, trimmed) toggles frames.
  ON_VARIANTS  = ["true", "TRUE", "  true", "true\n", " TrUe "].freeze
  OFF_VARIANTS = ["false", "FALSE", "0", "1", "yes", "no", "", "  ", "truee", "nottrue"].freeze

  def test_frame_on_via_snapshot_frames
    ON_VARIANTS.each do |raw|
      assert SnapshotOptions.frame?(env("SNAPSHOT_FRAMES" => raw)),
             "SNAPSHOT_FRAMES=#{raw.inspect} should enable frameit"
    end
  end

  def test_frame_on_via_frameit_alias
    ON_VARIANTS.each do |raw|
      assert SnapshotOptions.frame?(env("FRAMEIT" => raw)),
             "FRAMEIT=#{raw.inspect} (alias) should enable frameit"
    end
  end

  def test_frame_off_for_non_true_values
    OFF_VARIANTS.each do |raw|
      refute SnapshotOptions.frame?(env("SNAPSHOT_FRAMES" => raw, "FRAMEIT" => raw)),
             "SNAPSHOT_FRAMES/FRAMEIT=#{raw.inspect} must NOT enable frameit"
    end
  end

  def test_either_toggle_enables_frames
    # Either env var alone is sufficient (OR), so a caller can use whichever reads
    # better in their workflow without setting both.
    assert SnapshotOptions.frame?(env("SNAPSHOT_FRAMES" => "true", "FRAMEIT" => "false"))
    assert SnapshotOptions.frame?(env("SNAPSHOT_FRAMES" => "false", "FRAMEIT" => "true"))
  end

  # --- build is pure: no output, no surprise keys ---

  def test_build_prints_nothing
    assert_output("", "") { SnapshotOptions.build(env) }
  end

  def test_kwargs_are_exactly_the_expected_keys
    # No surprise extra keys with a fully-set env (project included). The lane owns
    # the frameit call + any I/O; this builder only assembles capture kwargs.
    opts = SnapshotOptions.build(
      env("XCODEPROJ" => "MyApp.xcodeproj", "SNAPSHOT_DEVICES" => "iPhone 16 Pro",
          "SNAPSHOT_LANGUAGES" => "en-US", "SNAPSHOT_OUTPUT_DIR" => "./screenshots")
    )
    expected = %i[scheme devices languages output_directory clear_previous_screenshots
                  skip_open_summary project].sort
    assert_equal expected, opts.keys.sort
  end
end
