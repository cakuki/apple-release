# Pure, testable predicates behind the shared Dangerfile's PR nudges.
#
# EPIC-05 slice 3 (cakuki/atelier#5). The Dangerfile is thin glue: it pulls the
# diff/PR facts from the Danger DSL (`git.*`, `github.*`) and hands them to the
# pure functions here, which carry the actual rule logic — the large-PR
# threshold and the Swift-source-vs-test-file classification. Keeping the logic
# here (no Danger DSL, no git/IO) makes it unit-testable under plain minitest,
# the same way `commit_range.rb` / `coverage_gate.rb` are. Pure stdlib only — no
# gems — so the test suite runs without bundler/Danger installed.
module DangerRules
  module_function

  # A PR touching more than `threshold` lines (additions + deletions) is "big"
  # and earns a split-it-up nudge. Strictly greater-than: exactly `threshold`
  # lines is NOT big.
  def big_pr?(lines, threshold)
    lines > threshold
  end

  # Default globs: "Swift source" = `*.swift` that is NOT a test file; "test
  # file" = the conventional `*Tests*` path fragment (FooTests.swift, `…/Tests/…`).
  SWIFT_SOURCE_PATTERN = /\.swift$/.freeze
  TEST_FILE_PATTERN = /Tests/.freeze

  # Swift source files among `files` (Swift, excluding test files).
  def swift_sources(files, source_pattern: SWIFT_SOURCE_PATTERN, test_pattern: TEST_FILE_PATTERN)
    files.select { |f| f =~ source_pattern && f !~ test_pattern }
  end

  # Test files among `files` (matched by the `*Tests*` fragment).
  def test_files(files, test_pattern: TEST_FILE_PATTERN)
    files.select { |f| f =~ test_pattern }
  end

  # Missing-tests rule: Swift sources changed but no test files touched. The
  # caller passes the already-classified lists (so deleted test files, included
  # in `tests`, correctly suppress the nudge). Pure.
  def missing_tests?(swift, tests)
    !swift.empty? && tests.empty?
  end
end
