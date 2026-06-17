require "minitest/autorun"
require_relative "../fastlane/commit_range"

# Behavior of the pure base..HEAD commit-range resolver used by the commit-lint
# CI check (EPIC-02, Task 2). On a PR, `cog check` must lint only the commits
# the PR introduces, i.e. `<base>..<head>`. GitHub Actions exposes the base/head
# refs (or SHAs) via env; this maps those inputs to the range string `cog check`
# expects: a blank/missing head falls back to `HEAD`, while a missing/blank base
# is a hard error (a range needs a base). Pure — no git/IO.
class CommitRangeTest < Minitest::Test
  # --- resolve: base + head -> "base..head" ---

  def test_resolve_builds_range_from_base_and_head
    assert_equal "main..feature",
                 CommitRange.resolve(base: "main", head: "feature")
  end

  def test_resolve_accepts_shas
    assert_equal "abc123..def456",
                 CommitRange.resolve(base: "abc123", head: "def456")
  end

  def test_resolve_strips_whitespace
    assert_equal "main..HEAD",
                 CommitRange.resolve(base: "  main \n", head: "\tHEAD ")
  end

  # --- resolve: head defaults to HEAD when blank/missing ---

  def test_resolve_defaults_head_to_HEAD_when_nil
    assert_equal "main..HEAD", CommitRange.resolve(base: "main", head: nil)
  end

  def test_resolve_defaults_head_to_HEAD_when_empty
    assert_equal "main..HEAD", CommitRange.resolve(base: "main", head: "")
  end

  # --- resolve: missing base is an error (can't lint a range without it) ---

  def test_resolve_raises_when_base_missing
    assert_raises(ArgumentError) { CommitRange.resolve(base: nil, head: "x") }
    assert_raises(ArgumentError) { CommitRange.resolve(base: "  ", head: "x") }
  end

  # --- resolve: refs may carry an "origin/" prefix from the runner ---

  def test_resolve_preserves_remote_prefixed_refs
    assert_equal "origin/main..HEAD",
                 CommitRange.resolve(base: "origin/main", head: "HEAD")
  end

  # --- from_env: read GitHub Actions env -> range ---

  def test_from_env_uses_base_and_head_refs
    env = { "GITHUB_BASE_REF" => "main", "GITHUB_SHA" => "deadbeef" }
    assert_equal "origin/main..deadbeef", CommitRange.from_env(env)
  end

  def test_from_env_prefers_explicit_head_ref_over_sha
    env = {
      "GITHUB_BASE_REF" => "main",
      "GITHUB_HEAD_SHA" => "feedface",
      "GITHUB_SHA" => "deadbeef",
    }
    assert_equal "origin/main..feedface", CommitRange.from_env(env)
  end

  def test_from_env_falls_back_to_HEAD_without_sha
    env = { "GITHUB_BASE_REF" => "main" }
    assert_equal "origin/main..HEAD", CommitRange.from_env(env)
  end

  def test_from_env_does_not_double_prefix_origin
    env = { "GITHUB_BASE_REF" => "origin/main", "GITHUB_SHA" => "abc" }
    assert_equal "origin/main..abc", CommitRange.from_env(env)
  end

  def test_from_env_raises_outside_pull_request
    assert_raises(ArgumentError) { CommitRange.from_env({}) }
  end
end
