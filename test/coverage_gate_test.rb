require "minitest/autorun"
require "json"
require_relative "../fastlane/coverage_gate"

# Behavior of the code-coverage threshold gate (EPIC-05 slice 2, cakuki/atelier#60).
#
# CoverageGate parses `xcrun xccov view --report --json <xcresult>` output and
# computes OVERALL line coverage as sum(coveredLines)/sum(executableLines) across
# non-test targets, then compares it against a required minimum.
#
# THRESHOLD UNIT: percentage 0-100 (human-friendly). `MIN_COVERAGE=80` means 80%.
# `check`/`line_coverage` return a 0.0-1.0 fraction internally; `check` takes the
# minimum as a percentage to mirror the `MIN_COVERAGE` env the lane reads.
class CoverageGateTest < Minitest::Test
  # --- helpers to build inline xccov-style JSON fixtures ---

  def report(targets)
    { "targets" => targets }.to_json
  end

  def target(name, covered, executable, extra = {})
    {
      "name"            => name,
      "coveredLines"    => covered,
      "executableLines" => executable,
      "lineCoverage"    => executable.zero? ? 0.0 : covered.to_f / executable
    }.merge(extra)
  end

  # --- line_coverage: aggregate by lines across non-test targets ---

  def test_line_coverage_single_target
    json = report([target("App", 80, 100)])
    assert_in_delta 0.80, CoverageGate.line_coverage(json), 1e-9
  end

  # Aggregation must be sum(covered)/sum(executable), NOT the naive mean of the
  # per-target lineCoverage values. Here per-target coverages are 0.50 and 1.00
  # (naive mean 0.75), but the line-weighted answer is 110/200 = 0.55.
  def test_line_coverage_aggregates_by_lines_not_naive_average
    json = report([target("A", 10, 100), target("B", 100, 100)])
    assert_in_delta 0.55, CoverageGate.line_coverage(json), 1e-9
    refute_in_delta 0.75, CoverageGate.line_coverage(json), 1e-9
  end

  # --- test-bundle exclusion from the denominator ---

  def test_excludes_targets_named_with_tests_suffix
    json = report([target("App", 50, 100), target("AppTests", 0, 1000)])
    # AppTests' 1000 executable lines must NOT dilute the result toward 50/1100.
    assert_in_delta 0.50, CoverageGate.line_coverage(json), 1e-9
  end

  def test_excludes_targets_named_with_xctest_suffix
    json = report([target("App", 90, 100), target("AppUITests.xctest", 0, 500)])
    assert_in_delta 0.90, CoverageGate.line_coverage(json), 1e-9
  end

  def test_excludes_targets_flagged_as_test_product
    json = report([
      target("App", 70, 100),
      target("Weird", 0, 900, "productType" => "com.apple.product-type.bundle.unit-test")
    ])
    assert_in_delta 0.70, CoverageGate.line_coverage(json), 1e-9
  end

  # Non-test targets whose names merely CONTAIN "test" (case-insensitively) must
  # NOT be excluded: only a real `Tests`/`.xctest` suffix or a test product-type
  # marks a bundle as a test target. "Latest" / "Contest" end in "test" but are
  # ordinary app/framework targets and must count toward coverage.
  def test_includes_targets_whose_name_merely_contains_test
    # Real apps ship product/buildable metadata. A normal framework whose name
    # contains "test" (e.g. "Contest", "Latest") gets a buildableName like
    # "Contest.framework" — whose stringified metadata contains the substring
    # "test". The exclusion rule must key off the *suffix* / *test product-type*,
    # NOT a bare "test" substring in joined metadata, or these get wrongly dropped.
    json = report([
      target("Latest", 40, 100,
             "productType" => "com.apple.product-type.framework",
             "buildable"   => { "buildableName" => "Latest.framework" }),
      target("Contest", 60, 100,
             "productType" => "com.apple.product-type.framework",
             "buildable"   => { "buildableName" => "Contest.framework" })
    ])
    # Both included: (40+60)/(100+100) = 0.50. If either were wrongly excluded
    # the aggregate would shift (e.g. 0.40 or 0.60).
    assert_in_delta 0.50, CoverageGate.line_coverage(json), 1e-9
  end

  # A framework like "TestabilityHelpers" starts with "Test" but is not a test
  # bundle; it must be measured, not excluded. Its buildableName also contains
  # the "test" substring that the naive metadata check would trip on.
  def test_includes_target_named_like_a_test_helper
    json = report([
      target("App", 80, 100),
      target("TestabilityHelpers", 20, 100,
             "productType" => "com.apple.product-type.framework",
             "buildable"   => { "buildableName" => "TestabilityHelpers.framework" })
    ])
    assert_in_delta 0.50, CoverageGate.line_coverage(json), 1e-9
  end

  # UI-testing product type is a test bundle and must be excluded.
  def test_excludes_targets_flagged_as_ui_testing_product
    json = report([
      target("App", 70, 100),
      target("Flows", 0, 900, "productType" => "com.apple.product-type.bundle.ui-testing")
    ])
    assert_in_delta 0.70, CoverageGate.line_coverage(json), 1e-9
  end

  def test_accepts_parsed_hash_as_well_as_string
    hash = JSON.parse(report([target("App", 25, 100)]))
    assert_in_delta 0.25, CoverageGate.line_coverage(hash), 1e-9
  end

  # --- check: pass/fail relative to the required minimum (percentage) ---

  def test_check_passes_when_above_threshold
    result = CoverageGate.check(report([target("App", 90, 100)]), 80)
    assert result.passed
    assert_in_delta 90.0, result.actual_percent, 1e-9
    assert_in_delta 80.0, result.required_percent, 1e-9
  end

  def test_check_fails_when_below_threshold
    result = CoverageGate.check(report([target("App", 70, 100)]), 80)
    refute result.passed
    assert_in_delta 70.0, result.actual_percent, 1e-9
  end

  # Boundary is INCLUSIVE: actual == required passes.
  def test_check_passes_exactly_at_threshold
    result = CoverageGate.check(report([target("App", 80, 100)]), 80)
    assert result.passed
  end

  # Default MIN_COVERAGE = 0 is non-enforcing: any coverage (even 0%) passes.
  def test_check_default_zero_always_passes
    result = CoverageGate.check(report([target("App", 0, 100)]), 0)
    assert result.passed
    assert_in_delta 0.0, result.actual_percent, 1e-9
  end

  # --- check: min_percent must be a finite number in [0, 100] ---
  # `check` documents min_percent as a 0-100 percentage. Since the helper is
  # reusable beyond the lane (which already self-validates), it must reject
  # out-of-range / non-finite / non-numeric minimums with the single Error type
  # rather than coercing silently via #to_f.
  def test_check_rejects_negative_min_percent
    assert_raises(CoverageGate::Error) { CoverageGate.check(report([target("App", 90, 100)]), -1) }
  end

  def test_check_rejects_min_percent_above_100
    assert_raises(CoverageGate::Error) { CoverageGate.check(report([target("App", 90, 100)]), 200) }
  end

  def test_check_rejects_nan_min_percent
    assert_raises(CoverageGate::Error) { CoverageGate.check(report([target("App", 90, 100)]), Float::NAN) }
  end

  def test_check_rejects_infinity_min_percent
    assert_raises(CoverageGate::Error) { CoverageGate.check(report([target("App", 90, 100)]), Float::INFINITY) }
  end

  def test_check_rejects_non_numeric_min_percent
    assert_raises(CoverageGate::Error) { CoverageGate.check(report([target("App", 90, 100)]), "abc") }
  end

  # A valid in-range minimum (including numeric strings) still works.
  def test_check_accepts_in_range_min_percent
    result = CoverageGate.check(report([target("App", 90, 100)]), 80)
    assert result.passed
    assert_in_delta 80.0, result.required_percent, 1e-9
  end

  def test_check_accepts_numeric_string_min_percent
    result = CoverageGate.check(report([target("App", 90, 100)]), "80")
    assert result.passed
    assert_in_delta 80.0, result.required_percent, 1e-9
  end

  # A non-Hash entry in `targets` (e.g. nil) must surface as the single
  # CoverageGate::Error type from test_target?, not a bare NoMethodError.
  def test_non_hash_target_entry_raises_coverage_error
    err = assert_raises(CoverageGate::Error) do
      CoverageGate.line_coverage(report([target("App", 80, 100), nil]))
    end
    assert_match(/not an object/i, err.message)
  end

  def test_non_hash_string_target_entry_raises_coverage_error
    err = assert_raises(CoverageGate::Error) do
      CoverageGate.line_coverage(report([target("App", 80, 100), "x"]))
    end
    assert_match(/not an object/i, err.message)
  end

  # --- robust error handling ---

  def test_empty_targets_raises
    err = assert_raises(CoverageGate::Error) { CoverageGate.line_coverage(report([])) }
    assert_match(/no.*target/i, err.message)
  end

  # Only test targets present -> nothing measurable after exclusion.
  def test_all_targets_excluded_raises
    err = assert_raises(CoverageGate::Error) do
      CoverageGate.line_coverage(report([target("AppTests", 0, 10)]))
    end
    assert_match(/no.*target/i, err.message)
  end

  # Zero total executable lines among included targets -> div-by-zero guard.
  # Defined behavior: raise a clear error (no measurable code), NOT 0% silently.
  # A present-but-non-numeric numeric field is malformed input and must surface
  # as the single CoverageGate::Error type, not a bare NoMethodError from #to_i.
  def test_non_numeric_line_field_raises_coverage_error
    json = report([target("App", 80, 100).merge("executableLines" => {})])
    assert_raises(CoverageGate::Error) { CoverageGate.line_coverage(json) }
  end

  # A nil numeric field defaults to 0 (does not raise).
  def test_nil_line_field_defaults_to_zero
    # App contributes 0 executable lines (nil->0); B carries the measurable lines.
    json = report([target("App", 0, 0).merge("executableLines" => nil),
                   target("B", 50, 100)])
    assert_in_delta 0.50, CoverageGate.line_coverage(json), 1e-9
  end

  def test_zero_executable_lines_raises
    err = assert_raises(CoverageGate::Error) do
      CoverageGate.line_coverage(report([target("App", 0, 0)]))
    end
    assert_match(/no measurable|executable/i, err.message)
  end

  def test_blank_json_raises
    err = assert_raises(CoverageGate::Error) { CoverageGate.line_coverage("") }
    assert_match(/json|empty|blank/i, err.message)
  end

  def test_malformed_json_raises
    err = assert_raises(CoverageGate::Error) { CoverageGate.line_coverage("{not json") }
    assert_match(/json|parse/i, err.message)
  end

  # A hash missing the `targets` key is malformed input, not an empty report.
  def test_missing_targets_key_raises
    err = assert_raises(CoverageGate::Error) { CoverageGate.line_coverage('{"foo":1}') }
    assert_match(/target/i, err.message)
  end

  # Valid JSON that is not an object (array/string/number) must surface as the
  # single CoverageGate::Error type, not a bare NoMethodError/TypeError from the
  # downstream `report["targets"]` access. `parse` is contracted to return a Hash.
  def test_non_object_json_array_raises_coverage_error
    err = assert_raises(CoverageGate::Error) { CoverageGate.line_coverage("[]") }
    assert_match(/json object/i, err.message)
  end

  def test_non_object_json_string_raises_coverage_error
    err = assert_raises(CoverageGate::Error) { CoverageGate.line_coverage('"foo"') }
    assert_match(/json object/i, err.message)
  end

  def test_non_object_json_number_raises_coverage_error
    err = assert_raises(CoverageGate::Error) { CoverageGate.line_coverage("42") }
    assert_match(/json object/i, err.message)
  end
end
