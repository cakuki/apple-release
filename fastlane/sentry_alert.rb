# Pure formatter that turns a Sentry issue-alert webhook payload into a concise
# Telegram alert message (EPIC-06 slice 3 — alerting, cakuki/atelier#6).
#
# SentryAlert.build(payload) takes the ALREADY-PARSED Sentry issue-alert webhook
# Hash — top-level `action`, `data.event` (with `title`, `level`, `culprit`,
# `metadata`, `web_url`/`issue_url`) and `data.triggered_rule` — and returns a
# short plain-text message: project, issue title, level, culprit, an optional
# event count, the triggered rule, and a link to the issue. This is the reusable,
# tested CORE: the relay (untested I/O) parses Sentry's JSON, calls this, and POSTs
# the result to the Telegram Bot API.
#
# Keeping the formatter pure (no fastlane, no IO, no network, no JSON parsing, no
# Telegram) means the whole alert-message contract is unit-testable under stdlib
# minitest — the same way DeliverOptions / SentryDsymOptions / ReviewDigest stay
# fastlane-free, and the actual HTTP (signature verify, JSON parse, sendMessage)
# lives in the relay rather than here.
#
# DEFENSIVE BY CONTRACT (critical): the input is an UNTRUSTED webhook body. A
# missing/nil key, a non-Hash `data`/`event`/`metadata`, or an entirely empty
# payload must NEVER raise — `build` always returns a best-effort String so the
# relay can still alert "something fired" (and the operator can open Sentry) rather
# than 500-ing on a malformed payload. Every nested access is guarded before
# indexing; only String values are trusted.
#
# TL DECISIONS (documented here + in the PR body):
#   * Output is plain text (NOT Markdown/HTML): Telegram's `sendMessage` defaults to
#     no parse_mode, so a raw title like `ReferenceError: x` or a URL with `_` can't
#     break formatting or trigger a 400 from an unescaped entity. The relay sends it
#     as-is. Concise + multi-line so it reads on a phone lock screen.
#   * Level is upcased (ERROR/FATAL/WARNING) so severity reads at a glance; a missing
#     level is "UNKNOWN", never blank.
#   * Title prefers the flat `title`; falls back to "Type: value" (or just "Type")
#     built from `metadata`; finally "(no title)" — never blank/nil.
#   * Link prefers the browser `web_url` (what a human clicks) over the API
#     `issue_url`; if neither is a usable URL, the link line is omitted entirely
#     rather than printing an empty "Link:".
#   * A count is shown only when present (`data.event_count` or `data.count`) — a
#     single new issue has no spike count, so we don't invent a "1".
module SentryAlert
  module_function

  # payload (the parsed Sentry issue-alert webhook Hash, or anything) -> a short
  # plain-text alert String. Pure: no fastlane, no IO, no network, no logging.
  # NEVER raises on a malformed payload — returns a best-effort message instead.
  def build(payload)
    payload = payload.is_a?(Hash) ? payload : {}
    data    = hash_at(payload, "data")
    event   = hash_at(data, "event")

    lines = ["\u{1F6A8} Sentry alert: #{project(payload, data)}"]
    lines << "#{level(event)} — #{title(event)}"

    culprit = string_or_nil(event["culprit"])
    lines << "Culprit: #{culprit}" if culprit

    count = count_of(data)
    lines << "Events: #{count}" if count

    rule = string_or_nil(data["triggered_rule"])
    lines << "Rule: #{rule}" if rule

    link = link_of(event)
    lines << "Link: #{link}" if link

    lines.join("\n")
  end

  # Backwards-friendly alias: some callers/docs say `.format`. Same pure behavior.
  def format(payload)
    build(payload)
  end

  # The project name for the headline. Sentry puts it top-level on some payloads
  # and under `data` on others; prefer the top-level slug, then a top-level
  # `project`, then `data.project`. Defaults to "(unknown project)" — never blank.
  # Internal helper.
  def project(payload, data)
    string_or_nil(payload["project_slug"]) ||
      string_or_nil(payload["project"]) ||
      string_or_nil(data["project_slug"]) ||
      string_or_nil(data["project"]) ||
      "(unknown project)"
  end
  private_class_method :project

  # Severity, upcased (ERROR/FATAL/WARNING/...). Missing/blank => "UNKNOWN" so the
  # line never reads as a blank severity. Internal helper.
  def level(event)
    (string_or_nil(event["level"]) || "unknown").upcase
  end
  private_class_method :level

  # The issue title: prefer the flat `title`; else build "Type: value" (or just
  # "Type") from `metadata`; else "(no title)". Never blank/nil. Internal helper.
  def title(event)
    string_or_nil(event["title"]) || title_from_metadata(event) || "(no title)"
  end
  private_class_method :title

  # "Type: value" / "Type" from a (possibly non-Hash / partial) `metadata`, or nil
  # if neither type nor value is a usable String. Internal helper.
  def title_from_metadata(event)
    meta  = hash_at(event, "metadata")
    type  = string_or_nil(meta["type"])
    value = string_or_nil(meta["value"])
    return nil if type.nil? && value.nil?
    return type if value.nil?
    return value if type.nil?

    "#{type}: #{value}"
  end
  private_class_method :title_from_metadata

  # The link a human follows: the browser `web_url`, else the API `issue_url`, else
  # nil (so the relay/build omits the link line). Internal helper.
  def link_of(event)
    string_or_nil(event["web_url"]) || string_or_nil(event["issue_url"])
  end
  private_class_method :link_of

  # An event/occurrence count for spike-style alerts, or nil when absent (so a lone
  # new issue shows no count). Accepts an Integer or a numeric String; anything else
  # => nil. Internal helper.
  def count_of(data)
    # Prefer event_count, but fall back to count when event_count is absent OR
    # present-but-nil (a nil event_count must not shadow a real count — matches the
    # documented "event_count or count" contract).
    raw = data["event_count"]
    raw = data["count"] if raw.nil?
    case raw
    when Integer then raw
    when String  then int_or_nil(raw)
    end
  end
  private_class_method :count_of

  # Fetch key from hash and return it only if it's itself a Hash; otherwise an
  # empty Hash. Lets callers index nested webhook keys without a nil/Array crash on
  # a malformed payload. Internal helper.
  def hash_at(hash, key)
    value = hash.is_a?(Hash) ? hash[key] : nil
    value.is_a?(Hash) ? value : {}
  end
  private_class_method :hash_at

  # A trimmed non-empty String, or nil (for blank/nil/non-String). Keeps the
  # message free of blank fields and guards against non-String webhook values.
  # Internal helper.
  def string_or_nil(value)
    return nil unless value.is_a?(String)

    s = value.strip
    s.empty? ? nil : s
  end
  private_class_method :string_or_nil

  # Version-agnostic strict integer parse (nil on non-integer). Avoids
  # Integer(_, exception: false) so the module stays portable across Ruby versions
  # / a stdlib-only dev box (the repo targets system Ruby 2.6). Internal helper.
  def int_or_nil(string)
    Integer(string)
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :int_or_nil
end
