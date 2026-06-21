require "minitest/autorun"
require "tmpdir"
require_relative "../fastlane/deliver_release_notes"

# Behavior of the pure release-notes wiring behind the central `deliver`
# (metadata-only) lane (EPIC-07 slice 2, cakuki/atelier#7).
#
# Slice 1 shipped the lane reading hand-written `release_notes.txt` per locale.
# Slice 2 lets `deliver` source the default locale's "what's new" from the top
# section of the generated `CHANGELOG.md` (reusing the already-pure, already-tested
# `ChangelogFormatter`), so notes come from the same place as the TestFlight
# `beta` changelog instead of being maintained twice.
#
# SAFETY: this is **opt-in and OFF by default**. Hand-written `release_notes.txt`
# is the source of truth unless a caller explicitly sets
# `RELEASE_NOTES_FROM_CHANGELOG=true`, so the changelog never silently clobbers
# carefully written store copy. The decision logic (enabled?, locale, notes, the
# target path) is fastlane-free so it's asserted here without fastlane, a
# simulator, ASC, or the network — the suite's only IO is local `Dir.mktmpdir`
# files exercising `from_file` (mirroring ChangelogFormatter/DeliverOptions).
class DeliverReleaseNotesTest < Minitest::Test
  CHANGELOG = <<~MD.freeze
    ## v1.2.0 - 2026-06-20

    #### Features
    - add dark mode - (abc1234) - atelier-ci
    - faster sync

    ## v1.1.0 - 2026-06-01

    #### Features
    - old stuff
  MD

  def env(overrides = {})
    overrides
  end

  # --- opt-in flag: OFF by default, only an exact "true" turns it on ---

  def test_disabled_by_default
    refute DeliverReleaseNotes.enabled?(env),
           "must be OFF by default so hand-written release_notes.txt is never clobbered"
  end

  ENABLED_VARIANTS = ["true", "TRUE", "  true", "true\n", " TrUe "].freeze
  DISABLED_VARIANTS = ["false", "FALSE", "0", "1", "yes", "no", "", "  ", "truee"].freeze

  def test_enabled_only_for_true_variants
    ENABLED_VARIANTS.each do |raw|
      assert DeliverReleaseNotes.enabled?(env("RELEASE_NOTES_FROM_CHANGELOG" => raw)),
             "RELEASE_NOTES_FROM_CHANGELOG=#{raw.inspect} should enable changelog-sourced notes"
    end
  end

  def test_disabled_for_non_true_variants
    DISABLED_VARIANTS.each do |raw|
      refute DeliverReleaseNotes.enabled?(env("RELEASE_NOTES_FROM_CHANGELOG" => raw)),
             "RELEASE_NOTES_FROM_CHANGELOG=#{raw.inspect} must NOT clobber hand-written notes"
    end
  end

  # --- default locale: en-US, overridable ---

  def test_default_locale_is_en_us
    assert_equal "en-US", DeliverReleaseNotes.default_locale(env)
  end

  def test_default_locale_override
    assert_equal "fr-FR",
                 DeliverReleaseNotes.default_locale(env("DELIVER_DEFAULT_LOCALE" => "fr-FR"))
  end

  def test_blank_locale_override_falls_back_to_en_us
    assert_equal "en-US", DeliverReleaseNotes.default_locale(env("DELIVER_DEFAULT_LOCALE" => "  "))
  end

  def test_valid_region_locales_accepted
    %w[en-US de-DE pt-BR zh-Hans fr].each do |loc|
      assert_equal loc, DeliverReleaseNotes.default_locale(env("DELIVER_DEFAULT_LOCALE" => loc))
    end
  end

  def test_path_traversal_locale_rejected
    ["../..", "../../etc", "en/US", "en\\US", "..", "en-US/../..", "."].each do |bad|
      # NB: assert_raises treats a trailing String as another expected class, not a
      # message, so identify the case via the asserted return value instead.
      err = assert_raises(ArgumentError) do
        DeliverReleaseNotes.default_locale(env("DELIVER_DEFAULT_LOCALE" => bad))
      end
      assert_includes err.message, bad.inspect
    end
  end

  # --- notes extraction reuses ChangelogFormatter (latest section, cleaned) ---

  def test_notes_extracts_and_cleans_latest_section
    notes = DeliverReleaseNotes.notes(CHANGELOG)
    assert_includes notes, "• add dark mode", "bullets converted, commit trailer stripped"
    assert_includes notes, "• faster sync"
    refute_includes notes, "old stuff", "must be the LATEST section only"
    refute_includes notes, "abc1234", "commit hash trailer must be stripped"
  end

  def test_notes_empty_changelog_falls_back
    assert_equal "Automated build", DeliverReleaseNotes.notes("")
  end

  def test_notes_missing_section_falls_back
    assert_equal "Automated build", DeliverReleaseNotes.notes("no sections here\njust text")
  end

  # --- target path: <metadata_path>/<locale>/release_notes.txt ---

  def test_target_path_joins_metadata_locale
    assert_equal "./metadata/en-US/release_notes.txt",
                 DeliverReleaseNotes.target_path("./metadata", "en-US")
  end

  def test_target_path_respects_override_locale_and_path
    assert_equal "./custom/de-DE/release_notes.txt",
                 DeliverReleaseNotes.target_path("./custom", "de-DE")
  end

  # --- from_file: reads a changelog path, safe fallback when missing ---

  def test_from_file_missing_changelog_falls_back
    assert_equal "Automated build",
                 DeliverReleaseNotes.from_file("/no/such/CHANGELOG.md")
  end

  def test_from_file_reads_and_extracts
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CHANGELOG.md")
      File.write(path, CHANGELOG)
      notes = DeliverReleaseNotes.from_file(path)
      assert_includes notes, "• add dark mode"
      refute_includes notes, "old stuff"
    end
  end
end
