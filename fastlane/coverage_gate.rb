# Pure, testable code-coverage threshold gate (EPIC-05 slice 2, cakuki/atelier#60).
#
# Parses the JSON emitted by `xcrun xccov view --report --json <path.xcresult>`
# and computes OVERALL line coverage, then compares it against a required
# minimum so the `test` lane can fail when coverage regresses. No fastlane
# dependencies — unit-tested with stdlib minitest (mirrors changelog_formatter.rb).
#
# THRESHOLD UNIT: percentage on a 0-100 scale (human-friendly), matching the
# `MIN_COVERAGE` env the lane reads. `MIN_COVERAGE=80` means "require >= 80%".
# `line_coverage` returns a 0.0-1.0 FRACTION (the natural xccov unit); `check`
# takes/reports PERCENTAGES so the gate's numbers line up with the env knob.
#
# xccov `--report --json` shape (only the fields we use):
#   { "targets": [ { "name": "App",
#                    "executableLines": 100, "coveredLines": 80,
#                    "lineCoverage": 0.8, "productType"/"buildable": ... }, ... ] }
#
# Overall coverage is sum(coveredLines)/sum(executableLines) across INCLUDED
# (non-test) targets — line-weighted, which is more accurate than averaging the
# per-target `lineCoverage` fractions (small targets would otherwise dominate).
require "json" # JSON isn't guaranteed preloaded (e.g. some Fastlane contexts).

module CoverageGate
  # Single, actionable error type so callers (and the lane) can rescue one thing
  # instead of a grab-bag of JSON::ParserError / ZeroDivisionError / NoMethodError.
  class Error < StandardError; end

  # Outcome of a gate check. `passed` is the inclusive-boundary verdict; the
  # percentages are for the lane's "actual % vs required %" message.
  Result = Struct.new(:passed, :actual_percent, :required_percent)

  module_function

  # Parsed-or-raw JSON -> overall line coverage as a 0.0-1.0 fraction.
  # Raises CoverageGate::Error on blank/malformed JSON, a missing `targets`
  # key, no included (non-test) targets, or zero total executable lines.
  def line_coverage(input)
    targets = included_targets(parse(input))
    raise Error, "coverage report has no non-test targets to measure" if targets.empty?

    executable = targets.sum { |t| integer(t, "executableLines") }
    covered    = targets.sum { |t| integer(t, "coveredLines") }
    # Guard div-by-zero. Defined behavior: zero measurable code is an ERROR (a
    # broken/empty build), NOT a silent 0% that a positive gate would reject as
    # a "regression". The caller should treat this as a misconfiguration.
    raise Error, "no measurable code: included targets report 0 executable lines" if executable.zero?

    covered.to_f / executable
  end

  # Gate verdict. `min_percent` is a 0-100 percentage (default 0 = non-enforcing).
  # Passes when actual >= required (boundary INCLUSIVE). Returns a Result.
  def check(input, min_percent = 0)
    required = percentage(min_percent)
    actual   = line_coverage(input) * 100.0
    Result.new(actual + 1e-9 >= required, actual, required)
  end

  # --- internals ---

  # Coerce min_percent to a 0-100 PERCENTAGE or raise. `check` documents this as
  # a finite number in [0, 100]; the helper is reusable beyond the lane, so it
  # self-validates rather than coercing silently via #to_f. Reject non-numeric
  # ("abc"), negative (-1), >100 (200), NaN, and Infinity. Numeric strings like
  # "80" are accepted via strict Float().
  def percentage(min_percent)
    value =
      begin
        Float(min_percent)
      rescue ArgumentError, TypeError
        raise Error, "minimum coverage percent is not a number: #{min_percent.inspect}"
      end

    unless value.finite? && value >= 0 && value <= 100
      raise Error, "minimum coverage percent must be a number in 0-100; got: #{min_percent.inspect}"
    end

    value
  end

  # Robustly turn a String or already-parsed Hash into a Hash, or raise.
  def parse(input)
    return input if input.is_a?(Hash)

    text = input.to_s
    raise Error, "coverage report JSON is blank/empty" if text.strip.empty?

    parsed =
      begin
        JSON.parse(text)
      rescue JSON::ParserError => e
        raise Error, "could not parse coverage report JSON: #{e.message}"
      end

    # Valid JSON can still be a non-object (array/string/number). The contract is
    # a Hash; otherwise downstream `report["targets"]` raises a bare
    # NoMethodError/TypeError. Normalize to the single CoverageGate::Error type.
    raise Error, "coverage report is not a JSON object: #{parsed.class}" unless parsed.is_a?(Hash)

    parsed
  end

  # The `targets` array with test bundles removed. Raises if `targets` is absent
  # (malformed input) — distinct from an empty-but-present array (no targets).
  def included_targets(report)
    targets = report["targets"]
    raise Error, "coverage report is missing the 'targets' array" unless targets.is_a?(Array)

    targets.reject { |t| test_target?(t) }
  end

  # Explicit, testable exclusion rule: a target is a test bundle iff its NAME ends
  # in `Tests` or `.xctest`, OR its `productType` is a real test product type.
  # We deliberately do NOT key off a bare "test" substring in joined metadata:
  # ordinary targets like "Latest"/"Contest"/"TestabilityHelpers" (and their
  # `Contest.framework` buildableNames) contain "test" yet must be measured.
  def test_target?(target)
    raise Error, "coverage report target is not an object: #{target.inspect}" unless target.is_a?(Hash)

    name = target["name"].to_s
    return true if name.end_with?("Tests", ".xctest")

    # Apple's test product types are the unit-test bundle and the ui-testing
    # bundle: com.apple.product-type.bundle.unit-test / .ui-testing. Match the
    # product-type token precisely rather than scanning all metadata for "test".
    product_type = target["productType"].to_s
    product_type.include?("product-type.bundle.unit-test") ||
      product_type.include?("product-type.bundle.ui-testing")
  end

  # Coerce a numeric field to Integer, defaulting a missing or nil field to 0.
  # A present-but-non-numeric value (or a non-object target) is malformed input,
  # so raise CoverageGate::Error — our single error type — rather than letting a
  # bare NoMethodError/TypeError escape from #to_i / #fetch.
  def integer(target, key)
    raise Error, "coverage report target is not an object: #{target.inspect}" unless target.is_a?(Hash)

    value = target.fetch(key, 0)
    return 0 if value.nil?
    return value.to_i if value.is_a?(Numeric)
    return value.to_i if value.is_a?(String) && value.strip.match?(/\A-?\d+\z/)

    raise Error, "coverage report field #{key.inspect} is not numeric: #{value.inspect}"
  end
end
