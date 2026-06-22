#!/usr/bin/env ruby
# frozen_string_literal: true

# sentry_relay.rb — the thin REFERENCE relay that makes "Telegram primary" actually
# work (EPIC-06 slice 3 — alerting; owner routing decision cakuki/atelier#122:
# Telegram is PRIMARY, email is FALLBACK; tracked under cakuki/atelier#6).
#
# Sentry's webhook integration POSTs an issue-alert here; this relay:
#   1. reads the raw POST body,
#   2. VERIFIES Sentry's `Sentry-Hook-Signature` (HMAC-SHA256 of the raw body with
#      the integration's client secret) with a constant-time compare — rejects on
#      mismatch (HTTP 401),
#   3. parses the JSON,
#   4. formats it via the pure `SentryAlert` core (shared with the unit tests), and
#   5. POSTs the message to the Telegram Bot API `sendMessage` — the SAME private
#      `notify-telegram` bot the platform already uses for off-terminal pings.
#
# Run it (self-contained, stdlib-only — no bundler):
#   TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... SENTRY_WEBHOOK_SECRET=... \
#     ruby scripts/sentry_relay.rb            # listens on $PORT (default 8080)
#
# TL DECISIONS (documented here + in docs/observability-alerting.md + the PR body):
#   * FORM: a single self-contained stdlib `WEBrick` HTTP handler — zero gems, runs
#     anywhere Ruby does (a tiny VM, a container, a Fly/Render box). The owner hosts
#     it; this repo ships the reference, not the infra. Heavier frameworks would add
#     dependencies for one endpoint.
#   * The SECURITY-CRITICAL bits (signature verify + sendMessage-body assembly) are
#     pulled out as PURE module methods (`verify_signature`, `build_telegram_payload`)
#     and unit-tested in test/sentry_relay_test.rb; the socket serving + the live
#     Telegram POST are thin untested I/O (same class as the dSYM upload / ASC fetch).
#   * FAIL CLOSED: a missing/blank secret, a missing/mismatched signature, or a body
#     that won't parse as JSON is REJECTED (4xx) — the relay never forwards an
#     unverified webhook.
#
# SECRET HYGIENE (critical): TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID and
# SENTRY_WEBHOOK_SECRET come from ENV and are NEVER logged. The bot token is placed
# on the Telegram API URL (Bot API requires it in the path) but that URL is NEVER
# logged; only token-free status lines are printed. The signature compare is
# constant-time (OpenSSL.secure_compare / a manual fallback) so a timing side-channel
# can't be used to forge a signature byte-by-byte.

require_relative "../fastlane/sentry_alert"

module SentryRelay
  module_function

  # ENV keys (documented in docs/observability-alerting.md). All three are required
  # to actually serve; the pure helpers below take their inputs explicitly so they
  # stay testable without ENV.
  BOT_TOKEN_ENV = "TELEGRAM_BOT_TOKEN".freeze
  CHAT_ID_ENV   = "TELEGRAM_CHAT_ID".freeze
  SECRET_ENV    = "SENTRY_WEBHOOK_SECRET".freeze

  # The header Sentry signs the body under (HMAC-SHA256 hex). WEBrick normalizes
  # header names to lowercase; this is the wire name for docs/clarity.
  SIGNATURE_HEADER = "Sentry-Hook-Signature".freeze

  # Verify Sentry's webhook signature: `signature` must equal the HMAC-SHA256 hex of
  # the raw request `body` under the integration's client `secret`. Constant-time
  # compare so a timing side-channel can't forge the digest. FAIL CLOSED: a
  # nil/blank/non-String body, signature, or secret => false (never accept an
  # unverifiable webhook). Pure: no IO, no logging. Used by the handler before any
  # parsing/forwarding.
  def verify_signature(body, signature, secret)
    require "openssl"

    return false unless body.is_a?(String)
    return false unless signature.is_a?(String) && !signature.empty?
    return false unless secret.is_a?(String) && !secret.empty?

    expected = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), secret, body)
    secure_compare(expected, signature)
  end

  # Constant-time string comparison. Prefers OpenSSL.secure_compare (stdlib, Ruby
  # 2.6+); falls back to a manual byte-XOR accumulation that also compares lengths
  # in constant time, so the relay works even on a build without the helper. Returns
  # false on a length mismatch without leaking WHERE it differs. Internal helper.
  def secure_compare(a, b)
    require "openssl"

    return OpenSSL.secure_compare(a, b) if OpenSSL.respond_to?(:secure_compare)

    return false unless a.bytesize == b.bytesize

    diff = 0
    a.bytes.zip(b.bytes) { |x, y| diff |= x ^ y }
    diff.zero?
  end
  private_class_method :secure_compare

  # Assemble the Telegram Bot API `sendMessage` body from a parsed Sentry `payload`
  # and the destination `chat_id`. The text comes from the pure SentryAlert core, so
  # even a malformed payload yields a well-formed request (best-effort text) rather
  # than a crash. parse_mode is deliberately omitted (plain text — see SentryAlert).
  # Pure: no IO, no logging.
  def build_telegram_payload(payload, chat_id)
    { chat_id: chat_id, text: SentryAlert.build(payload) }
  end

  # --- below here is thin, untested I/O (HTTP serving + live Telegram POST) ---

  # Read ENV, fail fast on any missing required secret, and start the WEBrick server.
  # I/O entry point; not unit-tested.
  def run(env = ENV, out = $stdout)
    secret    = required_env(env, SECRET_ENV)
    bot_token = required_env(env, BOT_TOKEN_ENV)
    chat_id   = required_env(env, CHAT_ID_ENV)
    port      = (env["PORT"].to_s.strip.empty? ? 8080 : Integer(env["PORT"]))

    serve(port: port, secret: secret, bot_token: bot_token, chat_id: chat_id, out: out)
  end

  # Fetch a required ENV value, trimmed; raise a clear error (NOT echoing the value)
  # if it's missing/blank so a misconfigured deploy fails fast. Internal I/O helper.
  def required_env(env, key)
    value = env[key].to_s.strip
    raise "#{key} is required (set it in the relay's environment)" if value.empty?

    value
  end
  private_class_method :required_env

  # Start a minimal WEBrick server that handles the webhook POST. Untested I/O: it's
  # a socket + a live outbound POST, the same class of live I/O as the dSYM upload.
  def serve(port:, secret:, bot_token:, chat_id:, out:)
    require "webrick"

    server = WEBrick::HTTPServer.new(Port: port, Logger: WEBrick::Log.new(nil, 0),
                                     AccessLog: [])
    server.mount_proc("/") do |req, res|
      handle_request(req, res, secret: secret, bot_token: bot_token,
                               chat_id: chat_id, out: out)
    end
    trap("INT") { server.shutdown }
    # Token-free startup line — never logs the secret/token.
    out.puts("sentry_relay listening on :#{port} (POST your Sentry webhook here)")
    server.start
  end
  private_class_method :serve

  # Handle one webhook request: POST only, verify signature, parse JSON, forward to
  # Telegram. Replies with a small status; never echoes secrets. Untested I/O.
  def handle_request(req, res, secret:, bot_token:, chat_id:, out:)
    if req.request_method != "POST"
      res.status = 405
      res.body = "method not allowed"
      return
    end

    body      = req.body.to_s
    signature = req.header[SIGNATURE_HEADER.downcase]&.first

    unless verify_signature(body, signature, secret)
      # Don't reveal whether it was the signature, secret, or body — just reject.
      res.status = 401
      res.body = "invalid signature"
      out.puts("rejected webhook: signature verification failed")
      return
    end

    payload = parse_json(body)
    if payload.nil?
      res.status = 400
      res.body = "invalid json"
      out.puts("rejected webhook: body was not valid JSON")
      return
    end

    send_to_telegram(build_telegram_payload(payload, chat_id), bot_token)
    res.status = 200
    res.body = "ok"
    out.puts("forwarded a Sentry alert to Telegram")
  rescue StandardError => e
    # Never let an exception leak a secret-bearing backtrace to the HTTP client.
    res.status = 500
    res.body = "relay error"
    out.puts("relay error: #{e.class}")
  end
  private_class_method :handle_request

  # Parse a JSON body to a Hash, or nil on anything unparseable / non-object (so the
  # handler can 400 cleanly). Internal I/O helper.
  def parse_json(body)
    require "json"

    parsed = JSON.parse(body)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end
  private_class_method :parse_json

  # POST the sendMessage body to the Telegram Bot API. The bot token goes on the URL
  # path (Bot API requires it there) but the URL is NEVER logged. Untested live I/O.
  def send_to_telegram(message, bot_token)
    require "net/http"
    require "json"
    require "uri"

    uri = URI("https://api.telegram.org/bot#{bot_token}/sendMessage")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
    request.body = JSON.generate(message)
    http.request(request)
  end
  private_class_method :send_to_telegram
end

# Only start serving when run as a script (not when required by the test suite).
SentryRelay.run if $PROGRAM_NAME == __FILE__
