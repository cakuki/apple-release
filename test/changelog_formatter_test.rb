require "minitest/autorun"
require "tempfile"
require_relative "../fastlane/changelog_formatter"

# Behavior of the converged TestFlight changelog formatter (EPIC-02, Task 3).
# Merges LoopApp's `format_changelog_for_testflight` richness into the central
# `changelog_from_md`: strip markdown headers, convert bullets, drop commit-hash
# /committer trailers, collapse whitespace, take only the top section, and fall
# back to "Automated build".
class ChangelogFormatterTest < Minitest::Test
  # --- clean: pure section-body cleanup ---

  def test_strips_markdown_subheaders
    assert_equal "Features\n• add foo",
                 ChangelogFormatter.clean("#### Features\n- add foo")
  end

  def test_converts_dash_bullets_to_utf_bullets
    assert_equal "• one\n• two",
                 ChangelogFormatter.clean("- one\n- two")
  end

  def test_drops_commit_hash_and_committer_trailer
    assert_equal "• add looping",
                 ChangelogFormatter.clean("- add looping - (a1b2c3d) - Can Kinay")
  end

  def test_drops_commit_hash_only_trailer
    assert_equal "• fix crash",
                 ChangelogFormatter.clean("- fix crash - (abc1234)")
  end

  def test_collapses_three_or_more_newlines
    assert_equal "• a\n\n• b",
                 ChangelogFormatter.clean("• a\n\n\n\n• b")
  end

  def test_clean_strips_surrounding_whitespace
    assert_equal "• a", ChangelogFormatter.clean("\n\n• a\n\n")
  end

  # --- top_section: only the latest "## " block ---

  def test_top_section_returns_only_latest_block
    md = "## Build 5\n\n#### Features\n- new thing\n\n## Build 4\n\n- old thing"
    section = ChangelogFormatter.top_section(md)
    assert_includes section, "new thing"
    refute_includes section, "old thing"
  end

  def test_top_section_nil_when_no_heading
    assert_nil ChangelogFormatter.top_section("just prose, no headings here")
  end

  # Edge case: the first "## " header is immediately followed by another header
  # with NO content line between them (empty top section). The next header must
  # terminate the captured region even though it sits at the very START of the
  # capture (i.e. it's NOT preceded by a "\n" inside the captured body). The top
  # section is empty/whitespace and must NOT leak the second header's content.
  def test_top_section_empty_first_section_does_not_leak_next_header
    md = "## 1.2.0\n## 1.1.0\n- old"
    section = ChangelogFormatter.top_section(md)
    refute_nil section
    assert_empty section.strip
    refute_includes section, "## 1.1.0"
    refute_includes section, "old"
  end

  # cog's `default` changelog template (EPIC-02, Task 5) emits the section body
  # on the line *immediately* after the "## " header, with NO blank line between
  # them (e.g. "## Unreleased (a..b)\n#### Features\n- x"). The formatter must
  # still pick up that body so `beta` gets real notes from the regenerated file.
  def test_top_section_handles_cog_default_no_blank_line_after_header
    md = "## Unreleased (21c5cd8..8342447)\n#### Features\n- shiny thing - (21c5cd8) - t"
    section = ChangelogFormatter.top_section(md)
    refute_nil section
    assert_includes section, "shiny thing"
    refute_includes section, "## Unreleased"
  end

  # --- notes: end-to-end on a string ---

  def test_notes_takes_top_section_only_and_cleans_it
    md = "## Build 5\n\n#### Features\n- add looping - (e401b45) - Can Kinay\n\n" \
         "## Build 4\n\n#### Features\n- old feature - (8108362) - Can Kinay"
    out = ChangelogFormatter.notes(md)
    assert_includes out, "• add looping"
    refute_includes out, "old feature"
    refute_includes out, "####"
    refute_includes out, "e401b45"
    refute_includes out, "Can Kinay"
  end

  def test_notes_fallback_when_no_section
    assert_equal "Automated build", ChangelogFormatter.notes("nothing here")
  end

  def test_notes_fallback_when_section_is_blank
    assert_equal "Automated build", ChangelogFormatter.notes("## Build 1\n\n\n")
  end

  def test_notes_on_cog_default_output_produces_clean_notes
    # The literal shape `cog changelog <range>` emits with the canonical cog.toml
    # (h4 type headers, dash bullets, " - (hash) - committer" trailers).
    md = "## Unreleased (21c5cd8..8342447)\n" \
         "#### Features\n" \
         "- shiny new feature - (21c5cd8) - t\n" \
         "#### Bug Fixes\n" \
         "- a small bug - (ce1b018) - t\n"
    out = ChangelogFormatter.notes(md)
    assert_includes out, "• shiny new feature"
    assert_includes out, "• a small bug"
    refute_includes out, "####"
    refute_includes out, "21c5cd8"
    refute_includes out, "Unreleased"
  end

  # --- from_file: IO wrapper + fallback ---

  def test_from_file_missing_returns_fallback
    assert_equal "Automated build",
                 ChangelogFormatter.from_file("/no/such/CHANGELOG.md")
  end

  def test_from_file_reads_and_formats
    Tempfile.create(["CHANGELOG", ".md"]) do |f|
      f.write("## Build 7\n\n#### Features\n- ship it - (deadbee) - Dev\n")
      f.flush
      assert_equal "Features\n• ship it", ChangelogFormatter.from_file(f.path)
    end
  end

  # --- realistic LoopApp fixture: zero artifacts, zero hashes ---

  def test_loopapp_style_fixture_produces_clean_notes
    md = <<~MD
      ## Build 5 (2026-01-01)

      #### Features
      - add track menu with mute, trim, duplicate - (e401b45) - Can Kinay
      - add timeline view with drag-to-arrange clips - (b1927b1) - Can Kinay
      #### Performance
      - smoother playhead animation - (b14abb2) - Can Kinay



      ## Build 4 (2025-12-27)

      #### Features
      - add settings view - (8108362) - Can Kinay
    MD
    out = ChangelogFormatter.notes(md)
    refute_match(/#+/, out)            # no markdown headers
    refute_match(/\([0-9a-f]{7}\)/, out) # no commit hashes
    refute_includes out, "Build 4"     # only the latest section
    refute_match(/\n{3,}/, out)        # whitespace collapsed
    assert_includes out, "• add track menu with mute, trim, duplicate"
  end
end
