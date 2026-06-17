require "minitest/autorun"
require_relative "../fastlane/release_plan"

# Behavior of the pure release-planning glue (EPIC-02, Task 5). Given the last
# release tag (or none) and the Conventional-Commit subjects since it, decide:
#   - the cog changelog range (`<lastTag>..HEAD`, or full history when no tag),
#   - the current semver baseline (last tag stripped of its `v`, or 0.0.0),
#   - the next semver (via the already-tested VersionBumper.level_for/bump),
#   - the `v<semver>` tag name to create.
# Pure — no git/IO; the workflow/lane feeds in the resolved tag + subjects and
# acts on the returned plan. VersionBumper itself is tested separately and is
# only *reused* here, never re-tested.
class ReleasePlanTest < Minitest::Test
  # --- changelog_range: <lastTag>..HEAD, robust to a missing last tag ---

  def test_range_uses_last_tag_when_present
    assert_equal "v1.2.3..HEAD", ReleasePlan.changelog_range("v1.2.3")
  end

  def test_range_strips_whitespace_around_tag
    assert_equal "v1.2.3..HEAD", ReleasePlan.changelog_range("  v1.2.3\n")
  end

  def test_range_falls_back_to_head_only_without_tag
    # No prior tag -> full history. `cog changelog HEAD` walks the whole history.
    assert_equal "HEAD", ReleasePlan.changelog_range(nil)
    assert_equal "HEAD", ReleasePlan.changelog_range("")
    assert_equal "HEAD", ReleasePlan.changelog_range("  ")
  end

  # --- current_version: last tag stripped of leading `v`, else 0.0.0 ---

  def test_current_version_strips_v_prefix
    assert_equal "1.2.3", ReleasePlan.current_version("v1.2.3")
  end

  def test_current_version_accepts_unprefixed_tag
    assert_equal "1.2.3", ReleasePlan.current_version("1.2.3")
  end

  def test_current_version_defaults_to_zero_without_tag
    assert_equal "0.0.0", ReleasePlan.current_version(nil)
    assert_equal "0.0.0", ReleasePlan.current_version("")
  end

  # --- next_version: baseline + highest commit level (reuses VersionBumper) ---

  def test_next_version_minor_for_feat
    assert_equal "1.3.0", ReleasePlan.next_version("v1.2.3", ["feat: a", "fix: b"])
  end

  def test_next_version_patch_for_fix
    assert_equal "1.2.4", ReleasePlan.next_version("v1.2.3", ["fix: a"])
  end

  def test_next_version_major_for_breaking
    assert_equal "2.0.0", ReleasePlan.next_version("v1.2.3", ["feat!: a"])
  end

  def test_next_version_from_zero_without_tag
    assert_equal "0.1.0", ReleasePlan.next_version(nil, ["feat: first"])
  end

  def test_next_version_nil_when_no_releasing_commits
    # Only housekeeping commits -> no release. Caller skips cutting a release.
    assert_nil ReleasePlan.next_version("v1.2.3", ["docs: a", "chore: b"])
    assert_nil ReleasePlan.next_version("v1.2.3", [])
  end

  # --- tag_name: compose `v<semver>` ---

  def test_tag_name_prefixes_v
    assert_equal "v1.3.0", ReleasePlan.tag_name("1.3.0")
  end

  def test_tag_name_does_not_double_prefix
    assert_equal "v1.3.0", ReleasePlan.tag_name("v1.3.0")
  end

  def test_tag_name_strips_whitespace
    assert_equal "v1.3.0", ReleasePlan.tag_name("  1.3.0\n")
  end

  # --- plan: the whole decision in one struct-ish hash ---

  def test_plan_composes_range_next_version_and_tag
    plan = ReleasePlan.plan(last_tag: "v1.2.3", subjects: ["feat: a"])
    assert_equal "v1.2.3..HEAD", plan[:range]
    assert_equal "1.3.0",        plan[:next_version]
    assert_equal "v1.3.0",       plan[:tag]
    assert plan[:release?]
  end

  def test_plan_marks_no_release_when_nothing_to_ship
    plan = ReleasePlan.plan(last_tag: "v1.2.3", subjects: ["docs: a"])
    refute plan[:release?]
    assert_nil plan[:next_version]
    assert_nil plan[:tag]
    # Range is still resolvable so the changelog regen can be a no-op safely.
    assert_equal "v1.2.3..HEAD", plan[:range]
  end

  def test_plan_handles_first_release_without_tag
    plan = ReleasePlan.plan(last_tag: nil, subjects: ["feat: first"])
    assert_equal "HEAD",  plan[:range]
    assert_equal "0.1.0", plan[:next_version]
    assert_equal "v0.1.0", plan[:tag]
    assert plan[:release?]
  end
end
