# Pure App Store Connect build-processing classifier — the testable core of a
# future "wait-for-processing" poll loop (EPIC-08 slice 4, cakuki/atelier#8).
#
# Real external distribution (slice 1) and review submission (slice 2) both need
# a *processed* build, so the eventual promotion path has to poll ASC for a
# build/version `processingState` and decide whether to keep waiting, proceed, or
# fail. That live poll (the loop that actually sleeps and queries ASC for a real
# build) is the owner/live follow-up step and is deliberately NOT in this module.
#
# What lands now is the PURE decision logic: classify a `processingState` string
# into a small set of typed outcomes and expose the predicates + a pure
# poll_decision the loop would branch on — with NO sleep, NO network/ASC, NO
# fastlane. Keeping it pure (the same way DeliverOptions / ExternalTestFlightOptions
# / ChangelogFormatter stay fastlane-free) means the whole contract is unit-testable
# under stdlib minitest.
#
# State -> outcome mapping (the TL decision; comparison is case-insensitive and
# whitespace-trimmed, mirroring the DELIVER_SUBMIT / TESTFLIGHT_DISTRIBUTE_EXTERNAL
# opt-in parse so the whole pipeline reads states the same way):
#
#   "PROCESSING"        => :processing  (build still being processed; keep waiting)
#   "VALID"             => :ready        (processing succeeded; safe to proceed)
#   "INVALID", "FAILED" => :failed       (processing failed; stop and raise)
#   nil / "" / anything => :unknown      (CONSERVATIVE DEFAULT — see below)
#
# CONSERVATIVE DEFAULT — nil, empty/blank, and any unrecognized value (a new or
# renamed ASC state, a typo, an unexpected status object) map to :unknown, which
# is treated as NON-terminal: a poll loop keeps waiting (until its timeout) rather
# than ever interpreting an unfamiliar state as :ready and proceeding to
# distribute/submit on an unproven build. Unknown never proceeds; at worst it
# times out. This biases toward "don't ship on a state we don't understand."
module BuildProcessingStatus
  module_function

  # Canonical ASC processingState (upcased) -> outcome. Anything not present here
  # (incl. nil / blank) falls through to the conservative :unknown default.
  STATES = {
    "PROCESSING" => :processing,
    "VALID"      => :ready,
    "INVALID"    => :failed,
    "FAILED"     => :failed,
  }.freeze

  # The non-terminal outcomes: a poll loop should keep waiting on these. :unknown
  # is deliberately non-terminal (conservative) — see the module note.
  NONTERMINAL = [:processing, :unknown].freeze

  # processingState (String|nil) -> one of :processing / :ready / :failed /
  # :unknown. Case-insensitive and whitespace-trimmed; unrecognized/nil/blank =>
  # :unknown (conservative default). Pure.
  def classify(state)
    STATES.fetch(normalize(state), :unknown)
  end

  # The eventual poll loop can STOP polling: a terminal outcome (ready OR failed).
  # :processing and :unknown are NOT done — the loop keeps waiting. Pure.
  def done?(state)
    !NONTERMINAL.include?(classify(state))
  end

  # Processing succeeded; safe to proceed with promotion. Pure.
  def ready?(state)
    classify(state) == :ready
  end

  # Processing failed; the loop should stop and raise. Pure.
  def failed?(state)
    classify(state) == :failed
  end

  # Still being processed; the loop should keep waiting. Pure.
  def processing?(state)
    classify(state) == :processing
  end

  # Pure poll decision: given the latest state and the elapsed-vs-timeout budget,
  # return what the loop should do next WITHOUT sleeping or calling anything.
  #
  #   :stop     - the state is terminal (ready or failed): stop polling. A known
  #               result wins over the clock, so a terminal state reports :stop
  #               even past the deadline (don't mask a real result as a timeout).
  #   :timeout  - non-terminal but the budget is spent (elapsed >= timeout): give
  #               up. The boundary is inclusive: elapsed == timeout is over budget.
  #   :continue - non-terminal and still within budget (elapsed < timeout): the
  #               loop should sleep (its own concern) and poll again.
  #
  # All branching/arithmetic; no sleep, no network, no fastlane. Pure.
  def poll_decision(state, elapsed:, timeout:)
    elapsed = non_negative_number!(elapsed, "elapsed")
    timeout = non_negative_number!(timeout, "timeout")
    return :stop if done?(state)
    return :timeout if elapsed >= timeout

    :continue
  end

  # nil/blank/any -> upcased, trimmed lookup key (or nil for blank). Internal helper.
  def normalize(state)
    s = state.to_s.strip
    s.empty? ? nil : s.upcase
  end
  private_class_method :normalize

  # Coerce to a finite, non-negative Float or fail fast with a clear, typed error
  # (mirrors the validate-up-front style of the other pure helpers) — so a bad
  # caller gets an actionable message, not an opaque `>=` TypeError. Numeric
  # strings are accepted (Float("30") == 30.0).
  def non_negative_number!(value, name)
    f = begin
      Float(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a finite, non-negative number (got #{value.inspect})"
    end
    unless f.finite? && f >= 0
      raise ArgumentError, "#{name} must be a finite, non-negative number (got #{value.inspect})"
    end
    f
  end
  private_class_method :non_negative_number!
end
