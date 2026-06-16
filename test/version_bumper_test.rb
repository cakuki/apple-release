require "minitest/autorun"
require_relative "../fastlane/version_bumper"

# Behavior of the pure semver bump + project.yml MARKETING_VERSION rewriter
# (EPIC-02, Task 4). Maps Conventional Commit subjects to a release level,
# folds an array of subjects to the highest level, bumps a semver string, and
# rewrites the xcodegen `MARKETING_VERSION:` value byte-for-byte otherwise.
class VersionBumperTest < Minitest::Test
  # --- commit_level: one conventional-commit subject -> level ---

  def test_feat_is_minor
    assert_equal :minor, VersionBumper.commit_level("feat: x")
  end

  def test_feat_with_scope_is_minor
    assert_equal :minor, VersionBumper.commit_level("feat(scope): x")
  end

  def test_fix_is_patch
    assert_equal :patch, VersionBumper.commit_level("fix: x")
  end

  def test_perf_is_patch
    assert_equal :patch, VersionBumper.commit_level("perf: x")
  end

  def test_fix_with_scope_is_patch
    assert_equal :patch, VersionBumper.commit_level("fix(api): x")
  end

  def test_feat_bang_is_major
    assert_equal :major, VersionBumper.commit_level("feat!: x")
  end

  def test_fix_scope_bang_is_major
    assert_equal :major, VersionBumper.commit_level("fix(scope)!: x")
  end

  def test_non_releasing_types_are_nil
    %w[docs chore refactor style test build ci].each do |type|
      assert_nil VersionBumper.commit_level("#{type}: x"),
                 "expected #{type} to be non-releasing"
    end
  end

  def test_garbage_subject_is_nil
    assert_nil VersionBumper.commit_level("no convention here")
  end

  # --- level_for: highest-precedence level across an array ---

  def test_level_for_picks_minor_over_patch
    assert_equal :minor, VersionBumper.level_for(["fix: a", "feat: b"])
  end

  def test_level_for_picks_major
    assert_equal :major, VersionBumper.level_for(["feat: a", "fix!: b"])
  end

  def test_level_for_all_non_releasing_is_nil
    assert_nil VersionBumper.level_for(["docs: a", "chore: b"])
  end

  def test_level_for_empty_is_nil
    assert_nil VersionBumper.level_for([])
  end

  # --- bump: next semver string ---

  def test_bump_patch
    assert_equal "1.2.4", VersionBumper.bump("1.2.3", :patch)
  end

  def test_bump_minor
    assert_equal "1.3.0", VersionBumper.bump("1.2.3", :minor)
  end

  def test_bump_major
    assert_equal "2.0.0", VersionBumper.bump("1.2.3", :major)
  end

  def test_bump_minor_from_zero
    assert_equal "0.2.0", VersionBumper.bump("0.1.0", :minor)
  end

  def test_bump_nil_is_noop
    assert_equal "1.2.3", VersionBumper.bump("1.2.3", nil)
  end

  # --- set_marketing_version: rewrite project.yml value, preserve the rest ---

  def test_set_marketing_version_quoted
    assert_equal %(MARKETING_VERSION: "2.0"),
                 VersionBumper.set_marketing_version(%(MARKETING_VERSION: "1.0"), "2.0")
  end

  def test_set_marketing_version_unquoted_emits_quoted
    assert_equal %(MARKETING_VERSION: "2.0"),
                 VersionBumper.set_marketing_version("MARKETING_VERSION: 1.0", "2.0")
  end

  def test_set_marketing_version_is_idempotent
    once = VersionBumper.set_marketing_version(%(MARKETING_VERSION: "1.0"), "2.0")
    twice = VersionBumper.set_marketing_version(once, "2.0")
    assert_equal once, twice
  end

  def test_set_marketing_version_preserves_surrounding_lines
    yml = <<~YML
      name: Loop
      settings:
        base:
          MARKETING_VERSION: "1.4.2"
          CURRENT_PROJECT_VERSION: 12
          PRODUCT_BUNDLE_IDENTIFIER: com.example.loop
    YML
    expected = <<~YML
      name: Loop
      settings:
        base:
          MARKETING_VERSION: "2.0.0"
          CURRENT_PROJECT_VERSION: 12
          PRODUCT_BUNDLE_IDENTIFIER: com.example.loop
    YML
    assert_equal expected, VersionBumper.set_marketing_version(yml, "2.0.0")
  end
end
