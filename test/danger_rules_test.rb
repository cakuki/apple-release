require "minitest/autorun"
require_relative "../fastlane/danger_rules"

# Behavior of the pure predicates behind the shared Dangerfile's PR nudges
# (EPIC-05 slice 3). The Dangerfile is thin glue over these; the rule logic —
# the large-PR threshold and the Swift-source-vs-test-file classification —
# lives here so it can be unit-tested without the Danger DSL or any gem. Pure:
# the functions take plain Integers/Arrays of path strings and return
# booleans/Arrays.
class DangerRulesTest < Minitest::Test
  # --- big_pr?: strictly-greater-than threshold (boundary) ---

  def test_big_pr_true_above_threshold
    assert DangerRules.big_pr?(501, 500)
  end

  def test_big_pr_false_at_threshold
    refute DangerRules.big_pr?(500, 500)
  end

  def test_big_pr_false_below_threshold
    refute DangerRules.big_pr?(499, 500)
  end

  # --- swift_sources / test_files: classification ---

  def test_swift_sources_picks_non_test_swift
    files = ["Sources/Foo.swift", "Sources/FooTests.swift", "README.md"]
    assert_equal ["Sources/Foo.swift"], DangerRules.swift_sources(files)
  end

  def test_test_files_picks_tests_fragment
    files = ["Sources/Foo.swift", "Tests/FooTests.swift", "Other/Tests/Bar.swift"]
    assert_equal ["Tests/FooTests.swift", "Other/Tests/Bar.swift"],
                 DangerRules.test_files(files)
  end

  def test_non_swift_non_test_files_classified_as_neither
    files = ["docs/guide.md", "Package.swift.txt", "script.rb"]
    assert_empty DangerRules.swift_sources(files)
    assert_empty DangerRules.test_files(files)
  end

  # --- missing_tests?: the full rule, on classified lists ---

  def test_missing_tests_fires_when_swift_changed_without_tests
    files = ["Sources/Foo.swift", "Sources/Bar.swift"]
    swift = DangerRules.swift_sources(files)
    tests = DangerRules.test_files(files)
    assert DangerRules.missing_tests?(swift, tests)
  end

  def test_missing_tests_silent_when_swift_changed_with_tests
    files = ["Sources/Foo.swift", "Tests/FooTests.swift"]
    swift = DangerRules.swift_sources(files)
    tests = DangerRules.test_files(files)
    refute DangerRules.missing_tests?(swift, tests)
  end

  def test_non_swift_file_under_tests_path_counts_as_a_touched_test
    # test_files matches by PATH (`/Tests/`), not extension: a non-Swift fixture
    # under a Tests/ dir still counts as touching tests, so the nudge stays
    # silent. (This is also why deleting a *Tests* file — merged into the touched
    # list by the Dangerfile — keeps the rule quiet.)
    files = ["Sources/Foo.swift", "Tests/fixtures/sample.json"]
    swift = DangerRules.swift_sources(files)
    tests = DangerRules.test_files(files)
    assert_equal ["Tests/fixtures/sample.json"], tests
    refute DangerRules.missing_tests?(swift, tests)
  end

  def test_missing_tests_silent_when_no_swift_changed
    files = ["README.md", "docs/guide.md"]
    swift = DangerRules.swift_sources(files)
    tests = DangerRules.test_files(files)
    refute DangerRules.missing_tests?(swift, tests)
  end

  def test_missing_tests_silent_when_only_tests_changed
    files = ["Tests/FooTests.swift"]
    swift = DangerRules.swift_sources(files)
    tests = DangerRules.test_files(files)
    refute DangerRules.missing_tests?(swift, tests)
  end
end
