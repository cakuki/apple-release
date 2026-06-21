require_relative "changelog_formatter"

# Pure release-notes wiring for the central `deliver` (metadata-only) lane
# (EPIC-07 slice 2, cakuki/atelier#7).
#
# Slice 1's `deliver` lane uploads localized App Store metadata, with release
# notes coming from each locale's hand-written `release_notes.txt`. Slice 2 lets
# the lane instead source the DEFAULT locale's "what's new" from the top section
# of the generated `CHANGELOG.md` — the same source `beta` uses for its TestFlight
# changelog (EPIC-02) — so notes aren't maintained in two places. The actual
# changelog parsing is NOT reimplemented here: it reuses the already-pure,
# already-tested `ChangelogFormatter` (latest `## ` section, cleaned, with an
# "Automated build" fallback).
#
# SAFETY: this is **opt-in and OFF by default**. The lane only overwrites
# `release_notes.txt` when a caller explicitly sets
# `RELEASE_NOTES_FROM_CHANGELOG=true`; otherwise hand-written store copy stays the
# source of truth and is never silently clobbered. The decision logic here —
# `enabled?`, `default_locale`, the extracted `notes`, and the `target_path` — is
# fastlane-free so the whole contract is unit-testable without fastlane, a
# simulator, or any network/ASC call (mirroring DeliverOptions/ChangelogFormatter).
# (`from_file` is the one exception — it reads `CHANGELOG.md` from disk.) The lane
# owns the single File.write; this module owns the WHAT and WHERE.
module DeliverReleaseNotes
  module_function

  # App Store's default/primary locale. `deliver` lays metadata out as
  # `<metadata>/<locale>/release_notes.txt`; we write only the default locale's
  # notes from the changelog (other locales keep their hand-written copy).
  DEFAULT_LOCALE = "en-US".freeze

  # Opt-in: only an exact "true" (case-insensitive, whitespace-trimmed) sources
  # release notes from the changelog. Anything else (unset, "false", "0", ...)
  # leaves hand-written `release_notes.txt` untouched — mirrors DeliverOptions'
  # DELIVER_SUBMIT parse so the two flags behave identically.
  def enabled?(env)
    env["RELEASE_NOTES_FROM_CHANGELOG"].to_s.strip.downcase == "true"
  end

  # An App Store locale: letters + an optional region (e.g. en-US, de-DE, zh-Hans).
  # Deliberately strict so the value — which becomes a path segment in target_path,
  # then mkdir_p'd and written — can never contain `..` or a path separator and
  # escape the metadata dir.
  LOCALE_PATTERN = /\A[A-Za-z]{2,8}(-[A-Za-z]{2,8})?\z/

  # Default locale to write changelog notes into, overridable via
  # DELIVER_DEFAULT_LOCALE; a blank/unset value falls back to en-US. Validated
  # (LOCALE_PATTERN) before use — a bad value fails fast rather than writing
  # outside the metadata directory.
  def default_locale(env)
    locale = env["DELIVER_DEFAULT_LOCALE"].to_s.strip
    return DEFAULT_LOCALE if locale.empty?
    unless locale.match?(LOCALE_PATTERN)
      raise ArgumentError,
            "DELIVER_DEFAULT_LOCALE #{locale.inspect} is not a valid App Store locale " \
            "(letters with an optional region, e.g. en-US)"
    end
    locale
  end

  # Full changelog text -> notes string (reuses ChangelogFormatter; "Automated
  # build" fallback on empty/missing section). Pure.
  def notes(changelog)
    ChangelogFormatter.notes(changelog)
  end

  # Read a CHANGELOG.md path -> notes, with the same safe fallback when the file
  # is missing. Delegates to ChangelogFormatter.from_file, which reads the file
  # from disk (the one IO call in this module).
  def from_file(path)
    ChangelogFormatter.from_file(path)
  end

  # Where the default locale's release notes live under the metadata dir, per
  # `deliver`'s layout. Pure string join (no IO) so it's assertable.
  def target_path(metadata_path, locale)
    File.join(metadata_path, locale, "release_notes.txt")
  end
end
