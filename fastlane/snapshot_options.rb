# Pure option builder for the central `screenshots` lane (EPIC-07 Task 2,
# cakuki/atelier#123).
#
# SnapshotOptions.build(env) maps the process ENV to the exact kwargs hash the
# `screenshots` lane passes to fastlane's `capture_screenshots` (snapshot)
# action, and SnapshotOptions.frame?(env) answers the separate "should we also
# run `frame_screenshots` (frameit) afterwards?" question. Keeping both decisions
# pure (no fastlane, no IO, no simulator, no Xcode) means the whole
# screenshot-capture contract is unit-testable under stdlib minitest, the same
# way DeliverOptions / SentryDsymOptions / ExternalTestFlightOptions stay
# fastlane-free.
#
# NON-LIVE BY DESIGN: the lane only generates local screenshots into an output
# dir; it NEVER uploads (uploading screenshots rides the owner-gated `deliver`
# slice 4). So unlike DeliverOptions there is no "live" opt-in here — the safety
# property is simply that no kwarg this builder produces can reach App Store
# Connect (asserted by the test's no-upload-keys lock).
#
# frameit is OFF BY DEFAULT — device frames are heavy (extra assets) and
# opinionated (a specific marketing look), so we capture bare screenshots unless
# a caller explicitly opts in via SNAPSHOT_FRAMES=true (or the FRAMEIT=true
# alias). The toggle is a SEPARATE predicate, not a `capture_screenshots` kwarg,
# because framing is a distinct frameit pass over the captured images.
module SnapshotOptions
  module_function

  # Lanes run with CWD = `fastlane/`, so `./screenshots` resolves to
  # fastlane/screenshots — a local, git-ignorable artifact dir. Mirrors deliver's
  # `./metadata` default style.
  DEFAULT_OUTPUT_DIR = "./screenshots".freeze

  # A single representative device when SNAPSHOT_DEVICES is unset: a multi-device
  # matrix is slow and opinionated, so default narrow and let callers opt into
  # more. Plain "iPhone 16" (not the "Pro" variant) is the widely-preinstalled
  # simulator on CI images and matches the template's local-testing baseline
  # (ios-app-template docs/USING-THIS-TEMPLATE.md), so the default capture works
  # out of the box.
  # Element strings are frozen too (not just the array): `devices`/`languages`
  # return a `.dup` of these defaults, and a caller mutating an element in place
  # (e.g. `opts[:devices][0] << "x"`) would otherwise corrupt the constant for
  # every later call.
  DEFAULT_DEVICES = ["iPhone 16".freeze].freeze

  # Default a single language (US English) when SNAPSHOT_LANGUAGES is unset —
  # ASC's primary/default locale and the minimum a listing needs.
  DEFAULT_LANGUAGES = ["en-US".freeze].freeze

  # ENV -> kwargs for `capture_screenshots`. `scheme` is REQUIRED: a MISSING key
  # fails fast (KeyError, matching beta/deliver — there's nothing to capture
  # without a scheme) and a present-but-BLANK value also fails fast (ArgumentError)
  # rather than passing "   " through to capture_screenshots. `project` is attached
  # ONLY when XCODEPROJ is set (otherwise snapshot infers it from cwd). No
  # api_key/app_identifier/upload key is ever produced — the lane is NON-LIVE.
  def build(env)
    opts = {
      scheme:                     scheme(env),
      devices:                    devices(env),
      languages:                  languages(env),
      output_directory:           output_directory(env),
      # Wipe the output dir each run so captures are deterministic and never
      # mixed with stale images from a previous device/locale set.
      clear_previous_screenshots: true,
      # Leave snapshot's own HTML summary behavior to its CI/headless detection:
      # `skip_open_summary: false` does NOT force-open anything — snapshot still
      # only *opens* the summary on an interactive local run and stays quiet when
      # it detects CI/headless. We keep it false so a local `fastlane snapshot`
      # gets the convenience preview, while CI runs never pop a browser.
      skip_open_summary:          false,
    }
    # Only name the project when given — keeps the default build cwd-relative and
    # avoids passing an empty/placeholder path through to snapshot.
    project = env["XCODEPROJ"].to_s.strip
    opts[:project] = project unless project.empty?
    opts
  end

  # frameit opt-in: only an exact "true" (case-insensitive, whitespace-trimmed,
  # mirroring DeliverOptions' DELIVER_SUBMIT) on EITHER SNAPSHOT_FRAMES or the
  # FRAMEIT alias enables device framing. Anything else (unset, "false", "0",
  # "yes", ...) leaves frames OFF, so a heavy/opinionated frameit pass never runs
  # implicitly.
  def frame?(env)
    truthy(env["SNAPSHOT_FRAMES"]) || truthy(env["FRAMEIT"])
  end

  # Required scheme. A MISSING key raises KeyError (via fetch, like beta/deliver);
  # a present-but-blank value raises ArgumentError so we fail fast with a clear
  # message instead of handing "   " to capture_screenshots (which errors later,
  # less actionably).
  def scheme(env)
    value = env.fetch("SCHEME").strip
    raise ArgumentError, "SCHEME must not be blank" if value.empty?

    value
  end

  # SNAPSHOT_OUTPUT_DIR override, defaulting to `./screenshots`. Blank/whitespace
  # is treated as unset.
  def output_directory(env)
    dir = env["SNAPSHOT_OUTPUT_DIR"].to_s.strip
    dir.empty? ? DEFAULT_OUTPUT_DIR : dir
  end

  # SNAPSHOT_DEVICES -> list of device names, defaulting to a single device.
  # Robust parse: split on commas AND newlines (a YAML block-scalar input arrives
  # newline-separated), strip each, drop empties. Spaces WITHIN a name (e.g.
  # "iPhone 16 Pro") are preserved — we never split on spaces.
  def devices(env)
    names = split_list(env["SNAPSHOT_DEVICES"])
    names.empty? ? DEFAULT_DEVICES.dup : names
  end

  # SNAPSHOT_LANGUAGES -> list of language codes, defaulting to ["en-US"]. Same
  # robust comma/newline split as devices.
  def languages(env)
    codes = split_list(env["SNAPSHOT_LANGUAGES"])
    codes.empty? ? DEFAULT_LANGUAGES.dup : codes
  end

  # Split a raw ENV value on commas/newlines, strip each fragment, reject empties.
  # Returns [] for nil/blank. Internal helper shared by devices/languages.
  def split_list(raw)
    raw.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?)
  end
  private_class_method :split_list

  # Exact "true" (case-insensitive, whitespace-trimmed) => true; everything else
  # => false. Mirrors DeliverOptions' DELIVER_SUBMIT parse. Internal helper.
  def truthy(raw)
    raw.to_s.strip.downcase == "true"
  end
  private_class_method :truthy
end
