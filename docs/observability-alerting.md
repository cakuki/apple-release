# Observability — alerting (Sentry → Telegram, email fallback)

This is the runbook for **EPIC-06 slice 3**: wiring Sentry so a new crash, a
regression, or a spike **surfaces fast**. Crash reporting itself is already shipped
(the template's `CrashReporting` Sentry wrapper, and automated dSYM upload in the
`beta` lane — see [Crash-report symbolication](../README.md#crash-report-symbolication-dsym-upload-to-sentry)).
This slice adds the **alert routing** on top.

**Routing (owner decision, [cakuki/atelier#122](https://github.com/cakuki/atelier/issues/122)):**

- **Telegram is PRIMARY** — alerts go straight to your phone via the same private
  `notify-telegram` bot the platform already uses for off-terminal pings. A small
  reference relay ([`scripts/sentry_relay.rb`](../scripts/sentry_relay.rb)) receives
  Sentry's webhook and forwards it.
- **Email is the FALLBACK** — Sentry's built-in issue-owner email on the same rule,
  zero code. So even if the relay is down (or before you host it), you still get the
  alert.

You can do **email-only today** (Section 3 alone, no hosting) and add the Telegram
relay whenever you want the faster push channel.

---

## 1. Create the Sentry alert rules

In your Sentry project: **Alerts → Create Alert → Issues**. Create rules for the
three regression signals (each can be its own rule, or combined):

| Rule | "When" condition (Sentry's wording) | Why |
| --- | --- | --- |
| **New issue** | *A new issue is created* | A crash type never seen before. |
| **Regression** | *The issue changes state from resolved to unresolved* | Something you fixed came back. |
| **High-frequency / spike** | *The issue is seen more than `N` times in `1h`* (or *Number of events in an issue is more than `N`*) | A spike — one bug hitting many users fast. |

Set the **environment** filter to `production` (and/or your TestFlight env) so local
noise doesn't page you. Keep the action interval modest (e.g. at most once per
issue per hour) to avoid alert storms.

Each rule gets **two actions** (Sections 2 and 3) so Telegram is primary and email
is the fallback **on the same rule**.

## 2. Add the Telegram webhook action (PRIMARY)

Telegram delivery is a Sentry **Internal Integration** (the webhook-signing kind),
plus the reference relay that translates Sentry's webhook into a Telegram message.

### 2a. Create the Sentry Internal Integration (gives you the signing secret)

1. **Settings → Developer Settings → New Internal Integration.**
2. Name it e.g. `telegram-alert-relay`. Set the **Webhook URL** to where you'll host
   the relay (Section 4), e.g. `https://relay.example.com/`.
3. Enable **Alert Rule Action** so the integration shows up as an action on issue
   alert rules.
4. Under **Webhooks**, subscribe to the **issue alert** events.
5. Copy the integration's **Client Secret** — this is the `SENTRY_WEBHOOK_SECRET`
   the relay verifies every request against (HMAC-SHA256 over the raw body, sent in
   the `Sentry-Hook-Signature` header). **Treat it like a password.**

### 2b. Point the alert rule at it

On each rule from Section 1, add the action **"Send a notification via
`telegram-alert-relay`"**. Sentry will now POST the issue-alert payload to your
relay URL, signed with the client secret.

### 2c. What the relay does

[`scripts/sentry_relay.rb`](../scripts/sentry_relay.rb) is a self-contained,
stdlib-only Ruby service (no bundler). On each POST it:

1. reads the raw body,
2. **verifies** `Sentry-Hook-Signature` (HMAC-SHA256 of the body under
   `SENTRY_WEBHOOK_SECRET`, **constant-time** compare) and **rejects** a mismatch
   with `401` — so a forged webhook (wrong/missing signature) is dropped. (HMAC
   alone does not prevent a verbatim **replay** of a genuine request; that would
   need an extra nonce/timestamp check, which Sentry's hook doesn't provide here.)
3. parses the JSON,
4. formats a concise message with the **pure, unit-tested** core
   [`fastlane/sentry_alert.rb`](../fastlane/sentry_alert.rb)
   (`SentryAlert.build`) — project, level, issue title, culprit, optional event
   count, the triggered rule, and a link to the issue, and
5. POSTs it to the Telegram Bot API `sendMessage` for your chat.

The signature check and message-building are unit-tested in
[`test/sentry_relay_test.rb`](../test/sentry_relay_test.rb) and
[`test/sentry_alert_test.rb`](../test/sentry_alert_test.rb); the HTTP serving and the
live Telegram POST are thin, un-unit-tested I/O (the same class as the dSYM
upload). A malformed payload still produces a best-effort message rather than
crashing the relay.

## 3. Enable email (FALLBACK — zero code)

On the **same** alert rules, add Sentry's built-in email action:

- Add the action **"Send a notification to Issue Owners"** (or
  **"Send a notification to a Member / Team"** and pick yourself).
- Make sure your Sentry account's notification settings allow alert emails.

That's it — no hosting, no secret. If the relay is down or unhosted, email still
arrives. This is the reliable backstop behind the faster Telegram push.

## 4. Deploy / run the relay

The relay is one stdlib Ruby file; host it anywhere Ruby runs (a small VM, a
container, Fly/Render, etc.). It listens on `$PORT` (default `8080`) and handles the
webhook `POST` on `/`.

```sh
TELEGRAM_BOT_TOKEN=123456:ABC... \
TELEGRAM_CHAT_ID=987654321 \
SENTRY_WEBHOOK_SECRET=<client secret from the Sentry internal integration> \
PORT=8080 \
ruby scripts/sentry_relay.rb
```

Put it behind HTTPS (Sentry only POSTs to `https://`) and set the integration's
Webhook URL (Section 2a) to that public URL.

### Environment / secrets it needs

| Env var | Required | What | Where it comes from |
| --- | --- | --- | --- |
| `TELEGRAM_BOT_TOKEN` | yes | Bot API token for the `notify-telegram` bot | the same private bot the platform already uses (from `@BotFather`) |
| `TELEGRAM_CHAT_ID` | yes | Chat id to deliver alerts to | your private chat with that bot |
| `SENTRY_WEBHOOK_SECRET` | yes | Client secret of the Sentry internal integration | Section 2a |
| `PORT` | no (default `8080`) | port to listen on | your host |

**Secret hygiene:** all three are read from the environment and are **never
logged**. The relay fails fast with a clear message if any is missing. The bot token
is required on the Telegram API URL path, but that URL is never logged; only
token-free status lines are printed. Keep these out of the repo (host-level
secrets), consistent with the rest of Atelier's secret handling.

> **Reuse, not a new bot:** this is the **same** `notify-telegram` bot/chat the
> platform already uses for off-terminal pings — no new account, no new channel.

## Verify the wiring

- In Sentry, open a rule and use **"Send Test Notification"** (or trigger a test
  event) — a message should arrive in Telegram within seconds, and an email as the
  fallback.
- Point the integration's Webhook URL at a wrong/stale relay and confirm a
  **bad-signature** request is rejected (the relay logs `signature verification
  failed` and returns `401`) — a forged webhook never reaches Telegram.
