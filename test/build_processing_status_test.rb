require "minitest/autorun"
require_relative "../fastlane/build_processing_status"

# Behavior of the pure App Store Connect build-processing classifier
# (EPIC-08 slice 4, cakuki/atelier#8).
#
# BuildProcessingStatus is the testable CORE of a future "wait-for-processing"
# poll loop: given an ASC build/version `processingState` string, it classifies
# the state into a small set of typed outcomes (:processing / :ready / :failed /
# :unknown) and exposes the predicates (done?/ready?/failed?) the eventual loop
# would branch on, plus a pure poll_decision(state, elapsed:, timeout:) that
# decides continue/stop/timeout with NO sleeping and NO network/ASC/fastlane.
#
# The live poll itself (the loop that actually sleeps and queries ASC for a real
# build) is the owner/live follow-up step and is deliberately NOT in this module.
# These tests lock the classification + decision contract WITHOUT any network,
# sleep, or fastlane — mirroring how DeliverOptions / ExternalTestFlightOptions /
# ChangelogFormatter stay fastlane-free.
class BuildProcessingStatusTest < Minitest::Test
  # --- classify: the canonical ASC processingState values ---

  def test_processing_state_classifies_as_processing
    assert_equal :processing, BuildProcessingStatus.classify("PROCESSING")
  end

  def test_valid_state_classifies_as_ready
    assert_equal :ready, BuildProcessingStatus.classify("VALID")
  end

  def test_invalid_state_classifies_as_failed
    assert_equal :failed, BuildProcessingStatus.classify("INVALID")
  end

  def test_failed_state_classifies_as_failed
    assert_equal :failed, BuildProcessingStatus.classify("FAILED")
  end

  # --- case / whitespace handling (decided: case-insensitive, trimmed) ---

  def test_classify_is_case_insensitive_and_trimmed
    {
      "processing"   => :processing,
      "  Processing" => :processing,
      "valid\n"      => :ready,
      " Valid "      => :ready,
      "invalid"      => :failed,
      " FaIlEd "     => :failed,
    }.each do |raw, expected|
      assert_equal expected, BuildProcessingStatus.classify(raw),
                   "classify(#{raw.inspect}) should be #{expected.inspect}"
    end
  end

  # --- conservative default: nil / empty / unrecognized => :unknown ---

  def test_nil_classifies_as_unknown
    assert_equal :unknown, BuildProcessingStatus.classify(nil)
  end

  def test_empty_and_blank_classify_as_unknown
    ["", "  ", "\n", "\t"].each do |raw|
      assert_equal :unknown, BuildProcessingStatus.classify(raw),
                   "blank state #{raw.inspect} must classify conservatively as :unknown"
    end
  end

  def test_unrecognized_state_classifies_as_unknown
    # Any ASC value we don't explicitly map (a new/renamed state, a typo, a
    # status object we didn't expect) is treated conservatively as :unknown —
    # NOT silently as ready — so a poll loop keeps waiting rather than proceeding.
    ["PENDING", "UPLOADED", "EXPIRED", "garbage", "validish"].each do |raw|
      assert_equal :unknown, BuildProcessingStatus.classify(raw),
                   "unrecognized state #{raw.inspect} must classify as :unknown"
    end
  end

  # --- predicates the eventual loop branches on ---

  def test_ready_predicate
    assert BuildProcessingStatus.ready?("VALID")
    refute BuildProcessingStatus.ready?("PROCESSING")
    refute BuildProcessingStatus.ready?("FAILED")
    refute BuildProcessingStatus.ready?(nil)
  end

  def test_failed_predicate
    assert BuildProcessingStatus.failed?("INVALID")
    assert BuildProcessingStatus.failed?("FAILED")
    refute BuildProcessingStatus.failed?("VALID")
    refute BuildProcessingStatus.failed?("PROCESSING")
    refute BuildProcessingStatus.failed?(nil)
  end

  def test_processing_predicate
    assert BuildProcessingStatus.processing?("PROCESSING")
    refute BuildProcessingStatus.processing?("VALID")
    refute BuildProcessingStatus.processing?(nil)
  end

  # done? = the loop can stop polling: a terminal outcome (ready OR failed).
  # :processing and :unknown are NOT done — keep waiting.
  def test_done_predicate
    assert BuildProcessingStatus.done?("VALID"),   "a ready build is done (stop, proceed)"
    assert BuildProcessingStatus.done?("INVALID"), "a failed build is done (stop, raise)"
    assert BuildProcessingStatus.done?("FAILED"),  "a failed build is done (stop, raise)"
    refute BuildProcessingStatus.done?("PROCESSING"), "still processing => not done, keep waiting"
    refute BuildProcessingStatus.done?(nil),          "unknown => conservatively not done, keep waiting"
    refute BuildProcessingStatus.done?("garbage"),    "unknown => conservatively not done, keep waiting"
  end

  # --- poll_decision: pure continue / stop / timeout (no sleep, no network) ---

  # A terminal, ready/failed state => :stop, regardless of the clock.
  def test_poll_decision_stops_on_terminal_states
    assert_equal :stop, BuildProcessingStatus.poll_decision("VALID", elapsed: 0, timeout: 600)
    assert_equal :stop, BuildProcessingStatus.poll_decision("INVALID", elapsed: 0, timeout: 600)
    assert_equal :stop, BuildProcessingStatus.poll_decision("FAILED", elapsed: 5, timeout: 600)
  end

  # Non-terminal (:processing / :unknown) within the budget => :continue.
  def test_poll_decision_continues_while_processing_within_budget
    assert_equal :continue, BuildProcessingStatus.poll_decision("PROCESSING", elapsed: 0, timeout: 600)
    assert_equal :continue, BuildProcessingStatus.poll_decision("PROCESSING", elapsed: 599, timeout: 600)
    assert_equal :continue, BuildProcessingStatus.poll_decision(nil, elapsed: 10, timeout: 600),
                 "unknown within budget keeps waiting (conservative)"
  end

  # The timeout boundary: elapsed < timeout => continue; elapsed >= timeout => timeout.
  def test_poll_decision_timeout_boundary
    assert_equal :continue, BuildProcessingStatus.poll_decision("PROCESSING", elapsed: 599, timeout: 600)
    assert_equal :timeout,  BuildProcessingStatus.poll_decision("PROCESSING", elapsed: 600, timeout: 600),
                 "elapsed == timeout is over budget => :timeout (>= boundary)"
    assert_equal :timeout,  BuildProcessingStatus.poll_decision("PROCESSING", elapsed: 601, timeout: 600)
  end

  # A terminal state wins over the clock: even past the deadline, a ready/failed
  # build reports :stop, not :timeout — the result is known, so don't mask it.
  def test_poll_decision_terminal_beats_timeout
    assert_equal :stop, BuildProcessingStatus.poll_decision("VALID", elapsed: 9999, timeout: 600)
    assert_equal :stop, BuildProcessingStatus.poll_decision("FAILED", elapsed: 9999, timeout: 600)
  end

  # An unknown/blank state past the deadline => :timeout (we never proved it
  # terminal, so the budget is what stops us).
  def test_poll_decision_unknown_past_deadline_times_out
    assert_equal :timeout, BuildProcessingStatus.poll_decision(nil, elapsed: 600, timeout: 600)
    assert_equal :timeout, BuildProcessingStatus.poll_decision("garbage", elapsed: 700, timeout: 600)
  end

  # poll_decision is pure arithmetic/branching: it must not sleep. Deterministic
  # (no wall-clock/timing) — stub sleep to raise, then prove poll_decision returns
  # normally without ever touching it.
  def test_poll_decision_never_sleeps
    BuildProcessingStatus.stub(:sleep, ->(*) { raise "poll_decision must not sleep" }) do
      assert_equal :continue,
                   BuildProcessingStatus.poll_decision("PROCESSING", elapsed: 0, timeout: 86_400)
    end
  end

  # Inputs are validated up front: a bad elapsed/timeout fails fast with a clear,
  # typed ArgumentError rather than an opaque `>=` TypeError.
  def test_poll_decision_rejects_non_numeric_inputs
    [nil, "abc", :x, Float::INFINITY, Float::NAN, -1, -0.5].each do |bad|
      err = assert_raises(ArgumentError) do
        BuildProcessingStatus.poll_decision("PROCESSING", elapsed: bad, timeout: 100)
      end
      assert_includes err.message, "elapsed"
      assert_raises(ArgumentError) do
        BuildProcessingStatus.poll_decision("PROCESSING", elapsed: 0, timeout: bad)
      end
    end
  end

  def test_poll_decision_accepts_numeric_strings
    assert_equal :timeout, BuildProcessingStatus.poll_decision("PROCESSING", elapsed: "100", timeout: "100")
    assert_equal :continue, BuildProcessingStatus.poll_decision("PROCESSING", elapsed: "0", timeout: "100")
  end
end
