require "minitest/autorun"
require_relative "../fastlane/sentry_alert"

# Behavior of the pure Sentry issue-alert formatter (EPIC-06 slice 3 — alerting,
# cakuki/atelier#6).
#
# SentryAlert.build(payload) turns an ALREADY-PARSED Sentry issue-alert webhook
# Hash (top-level `action` + `data.event` + `data.triggered_rule`) into a short
# plain-text Telegram alert line set: project, issue title, level, culprit, an
# event count, and a link to the issue. Keeping the formatter pure (no fastlane,
# no IO, no network, no JSON parsing, no Telegram) means the whole alert-message
# contract is asserted here WITHOUT any HTTP — the relay owns only the I/O (verify
# signature, parse JSON, POST to Telegram), mirroring how DeliverOptions /
# SentryDsymOptions / ReviewDigest stay fastlane-free and push their I/O out to a
# lane/relay rather than the module.
#
# The relay's HTTP serving + the live Telegram POST are I/O and are NOT exercised
# here; this locks the message text so the tested surface is the formatting logic.
# A core invariant: a MALFORMED payload (missing/nil keys, a non-Hash `data`) must
# never raise — `build` degrades to a best-effort message so the relay can still
# alert "something happened" rather than 500-ing on Sentry's webhook.
class SentryAlertTest < Minitest::Test
  # --- fixture: a realistic Sentry issue-alert webhook payload ---

  # The ASC-equivalent for Sentry: a hand-built `event_alert` webhook body in the
  # shape Sentry POSTs (top-level `action`, `data.event` with title/level/culprit/
  # metadata/web_url/issue_url, `data.triggered_rule`). Overridable per test.
  def event(overrides = {})
    {
      "title"     => "ReferenceError: heck is not defined",
      "level"     => "error",
      "culprit"   => "static/app.js in onClick",
      "metadata"  => { "type" => "ReferenceError", "value" => "heck is not defined" },
      "web_url"   => "https://acme.sentry.io/issues/123/events/abc/",
      "issue_url" => "https://sentry.io/api/0/issues/123/",
    }.merge(overrides)
  end

  def payload(event_overrides = {}, data_overrides = {}, top_overrides = {})
    {
      "action" => "triggered",
      "data"   => {
        "event"          => event(event_overrides),
        "triggered_rule" => "New issue alert",
      }.merge(data_overrides),
    }.merge(top_overrides)
  end

  # --- a normal alert: all the headline facts are present ---

  def test_includes_issue_title
    assert_includes SentryAlert.build(payload), "ReferenceError: heck is not defined"
  end

  def test_includes_level_uppercased
    # Level is surfaced prominently (ERROR/FATAL/WARNING) so severity reads at a glance.
    assert_includes SentryAlert.build(payload), "ERROR"
  end

  def test_includes_culprit
    assert_includes SentryAlert.build(payload), "static/app.js in onClick"
  end

  def test_includes_triggered_rule
    assert_includes SentryAlert.build(payload), "New issue alert"
  end

  def test_includes_web_url_link
    # The browser `web_url` is the link a human follows — prefer it over the API issue_url.
    assert_includes SentryAlert.build(payload), "https://acme.sentry.io/issues/123/events/abc/"
  end

  def test_returns_a_string
    assert_kind_of String, SentryAlert.build(payload)
  end

  # --- link selection: web_url preferred, issue_url fallback, then none ---

  def test_falls_back_to_issue_url_when_web_url_missing
    text = SentryAlert.build(payload("web_url" => nil))
    assert_includes text, "https://sentry.io/api/0/issues/123/"
  end

  def test_falls_back_to_issue_url_when_web_url_blank
    text = SentryAlert.build(payload("web_url" => "   "))
    assert_includes text, "https://sentry.io/api/0/issues/123/"
  end

  def test_no_link_line_when_neither_url_present
    # Neither URL => no link line at all (don't print "Link: " with nothing after it).
    text = SentryAlert.build(payload("web_url" => nil, "issue_url" => nil))
    refute_includes text, "https://"
    refute_includes text, "Link:"
  end

  # --- title fallback: metadata when `title` is missing ---

  def test_title_falls_back_to_metadata_type_and_value
    # Sentry sometimes omits a flat `title`; build a "Type: value" from metadata.
    text = SentryAlert.build(payload("title" => nil))
    assert_includes text, "ReferenceError: heck is not defined"
  end

  def test_title_falls_back_to_metadata_type_only
    text = SentryAlert.build(payload("title" => nil, "metadata" => { "type" => "Timeout" }))
    assert_includes text, "Timeout"
  end

  def test_title_uses_placeholder_when_nothing_available
    # No title and no usable metadata => a clear placeholder, never a blank/nil.
    text = SentryAlert.build(payload("title" => nil, "metadata" => nil))
    assert_includes text, "(no title)"
  end

  # --- level variations ---

  def test_level_fatal
    assert_includes SentryAlert.build(payload("level" => "fatal")), "FATAL"
  end

  def test_level_warning
    assert_includes SentryAlert.build(payload("level" => "warning")), "WARNING"
  end

  def test_level_defaults_when_missing
    # No level => a neutral "UNKNOWN" rather than a blank severity.
    assert_includes SentryAlert.build(payload("level" => nil)), "UNKNOWN"
  end

  # --- project name (top-level or under data) ---

  def test_includes_project_slug_when_present
    text = SentryAlert.build(payload({}, {}, "project_slug" => "ios-app"))
    assert_includes text, "ios-app"
  end

  def test_project_falls_back_to_data_project_when_top_missing
    text = SentryAlert.build(payload({}, "project" => "fallback-proj"))
    assert_includes text, "fallback-proj"
  end

  # --- count variations (data.event_count / data.count) ---

  def test_includes_event_count_when_present
    text = SentryAlert.build(payload({}, "event_count" => 42))
    assert_includes text, "42"
  end

  def test_count_omitted_when_absent
    # No count anywhere => no "Events:" line (a single new issue has no spike count).
    # (Check the labeled line, not the bare word — the fixture web_url has "/events/".)
    text = SentryAlert.build(payload)
    refute_includes text, "Events:"
  end

  def test_falls_back_to_count_when_event_count_is_nil
    # event_count present-but-nil must NOT shadow a real count — fall back per the
    # documented "event_count or count" contract.
    text = SentryAlert.build(payload({}, "event_count" => nil, "count" => 7))
    assert_includes text, "Events: 7"
  end

  def test_event_count_wins_over_count_when_both_present
    text = SentryAlert.build(payload({}, "event_count" => 99, "count" => 7))
    assert_includes text, "Events: 99"
    refute_includes text, "Events: 7"
  end

  # --- DEFENSIVE: malformed payloads must never raise ---

  def test_empty_hash_payload_does_not_raise
    assert_kind_of String, SentryAlert.build({})
  end

  def test_nil_payload_does_not_raise
    assert_kind_of String, SentryAlert.build(nil)
  end

  def test_non_hash_data_does_not_raise
    # `data` arrives as an Array/String/Integer (garbage) => best-effort message, no crash.
    ["not-a-hash", [], 42, nil].each do |bad|
      out = SentryAlert.build("action" => "triggered", "data" => bad)
      assert_kind_of String, out, "non-Hash data #{bad.inspect} must not raise"
    end
  end

  def test_non_hash_event_does_not_raise
    out = SentryAlert.build("data" => { "event" => "not-a-hash" })
    assert_kind_of String, out
  end

  def test_non_hash_metadata_does_not_raise
    out = SentryAlert.build(payload("title" => nil, "metadata" => "not-a-hash"))
    assert_kind_of String, out
    assert_includes out, "(no title)"
  end

  def test_completely_empty_payload_still_has_a_headline
    # Even with nothing usable, the message names Sentry + a placeholder title so an
    # operator at least knows an alert fired (and can open Sentry directly).
    text = SentryAlert.build({})
    assert_includes text, "Sentry"
    assert_includes text, "(no title)"
  end

  # --- build is pure: returns data, prints nothing (no secret/PII leak to logs) ---

  def test_build_prints_nothing
    assert_output("", "") { SentryAlert.build(payload) }
    assert_output("", "") { SentryAlert.build({}) }
    assert_output("", "") { SentryAlert.build(nil) }
  end
end
