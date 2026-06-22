require "minitest/autorun"
require "openssl"
require_relative "../scripts/sentry_relay"

# Behavior of the testable core of the Sentry->Telegram relay (EPIC-06 slice 3 —
# alerting, cakuki/atelier#6).
#
# The relay is the thin reference service that makes "Telegram primary" (owner
# decision, cakuki/atelier#122) actually work once hosted: it receives Sentry's
# webhook POST, VERIFIES the `Sentry-Hook-Signature` (HMAC-SHA256 of the raw body
# with the integration's client secret), parses the JSON, formats via SentryAlert,
# and POSTs to the Telegram Bot API. The HTTP serving + the live Telegram POST are
# I/O and are NOT exercised here (they're the same kind of untested live I/O as the
# dSYM upload / ASC fetch). What IS pure and asserted here:
#
#   * verify_signature — a CONSTANT-TIME HMAC-SHA256 hex compare; the security gate
#     that rejects forged webhooks (wrong/missing signature). The single most
#     important thing to get right, and fully testable without a socket.
#   * build_telegram_payload — assembling the Bot API `sendMessage` body (chat_id +
#     text) from the formatted message, so a malformed Sentry payload still yields a
#     well-formed Telegram request rather than a crash.
#
# SECRET HYGIENE: none of these helpers log; the bot token/secret only ever flow
# through as data. The serving layer (untested) is documented to never log them.
class SentryRelayTest < Minitest::Test
  SECRET = "client_secret_example".freeze
  BODY   = '{"action":"triggered","data":{"event":{"title":"Boom"}}}'.freeze

  # The reference HMAC-SHA256 hex digest of BODY under SECRET — computed the same
  # way Sentry does, so verify_signature must accept exactly this.
  def valid_sig
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), SECRET, BODY)
  end

  # --- verify_signature: accept the genuine signature ---

  def test_accepts_the_correct_signature
    assert SentryRelay.verify_signature(BODY, valid_sig, SECRET),
           "the genuine HMAC-SHA256 hex of the body must be accepted"
  end

  # --- verify_signature: reject everything else ---

  def test_rejects_a_wrong_signature
    refute SentryRelay.verify_signature(BODY, "deadbeef", SECRET)
  end

  def test_rejects_a_non_64_hex_signature_shape
    # Wrong length or non-hex chars are rejected on shape before any compare.
    refute SentryRelay.verify_signature(BODY, "z" * 64, SECRET), "non-hex chars"
    refute SentryRelay.verify_signature(BODY, valid_sig + "0", SECRET), "too long"
    refute SentryRelay.verify_signature(BODY, valid_sig.upcase, SECRET), "uppercase hex"
  end

  def test_accepts_a_whitespace_padded_signature
    # Surrounding whitespace is trimmed before validation/compare.
    assert SentryRelay.verify_signature(BODY, "  #{valid_sig}\n", SECRET)
  end

  def test_rejects_a_signature_for_a_different_body
    other = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), SECRET, "tampered")
    refute SentryRelay.verify_signature(BODY, other, SECRET),
           "a signature over a DIFFERENT body must be rejected (tamper detection)"
  end

  def test_rejects_a_signature_under_a_different_secret
    wrong = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), "other_secret", BODY)
    refute SentryRelay.verify_signature(BODY, wrong, SECRET)
  end

  def test_rejects_nil_signature
    refute SentryRelay.verify_signature(BODY, nil, SECRET)
  end

  def test_rejects_empty_signature
    refute SentryRelay.verify_signature(BODY, "", SECRET)
  end

  def test_rejects_when_secret_is_nil_or_blank
    # No configured secret => can't verify anything => reject (fail closed, never
    # accept an unsigned webhook just because the relay is misconfigured).
    refute SentryRelay.verify_signature(BODY, valid_sig, nil)
    refute SentryRelay.verify_signature(BODY, valid_sig, "")
  end

  def test_signature_compare_is_case_sensitive
    # Sentry sends lowercase hex; an upper-cased digest is not byte-equal => reject.
    refute SentryRelay.verify_signature(BODY, valid_sig.upcase, SECRET)
  end

  def test_verify_does_not_raise_on_odd_types
    # Defensive: a non-String signature/body must reject, not crash the handler.
    [nil, 123, [], {}].each do |odd|
      refute SentryRelay.verify_signature(odd, valid_sig, SECRET)
      refute SentryRelay.verify_signature(BODY, odd, SECRET)
    end
  end

  # --- build_telegram_payload: a well-formed sendMessage body ---

  def test_build_telegram_payload_has_chat_id_and_text
    out = SentryRelay.build_telegram_payload(
      { "data" => { "event" => { "title" => "Boom", "level" => "error" } } },
      "123456",
    )
    assert_equal "123456", out[:chat_id]
    assert_includes out[:text], "Boom"
    assert_includes out[:text], "ERROR"
  end

  def test_build_telegram_payload_survives_malformed_payload
    # A malformed Sentry payload still yields a valid sendMessage body (best-effort
    # text from SentryAlert), so the relay alerts rather than crashing.
    out = SentryRelay.build_telegram_payload({}, "123456")
    assert_equal "123456", out[:chat_id]
    assert_includes out[:text], "Sentry"
  end

  # --- parse_port: blank => default, valid range, fail fast on garbage ---

  def test_parse_port_defaults_when_blank
    assert_equal 8080, SentryRelay.parse_port(nil)
    assert_equal 8080, SentryRelay.parse_port("")
    assert_equal 8080, SentryRelay.parse_port("   ")
  end

  def test_parse_port_accepts_a_valid_port
    assert_equal 3000, SentryRelay.parse_port("3000")
    assert_equal 3000, SentryRelay.parse_port("  3000\n")
    assert_equal 1, SentryRelay.parse_port("1")
    assert_equal 65_535, SentryRelay.parse_port("65535")
  end

  def test_parse_port_rejects_non_numeric_with_clear_message
    # Non-numeric PORT must raise a purpose-built message, not a bare Integer()
    # ArgumentError stack trace.
    err = assert_raises(RuntimeError) { SentryRelay.parse_port("eighty-eighty") }
    assert_includes err.message, "PORT must be an integer"
  end

  def test_parse_port_rejects_out_of_range
    assert_raises(RuntimeError) { SentryRelay.parse_port("0") }
    assert_raises(RuntimeError) { SentryRelay.parse_port("65536") }
    assert_raises(RuntimeError) { SentryRelay.parse_port("-1") }
  end

  # --- purity: the testable helpers log nothing (no secret/token leak) ---

  def test_helpers_print_nothing
    assert_output("", "") { SentryRelay.verify_signature(BODY, valid_sig, SECRET) }
    assert_output("", "") do
      SentryRelay.build_telegram_payload({ "data" => {} }, "123456")
    end
  end
end
