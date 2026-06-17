# Pure, testable release-planning glue (EPIC-02, Task 5).
#
# Wires the changelog regen + version bump + tag-trigger flow together without
# touching git or the filesystem. Given the last release tag (or none) and the
# Conventional-Commit subjects since it, it decides:
#   - the `cog changelog` range (`<lastTag>..HEAD`, or `HEAD` for full history),
#   - the current semver baseline (last tag minus its `v`, or 0.0.0),
#   - the next semver (delegated to the already-tested VersionBumper),
#   - the `v<semver>` git tag to create.
#
# The git/IO orchestration (resolving the last tag, running `cog changelog`,
# rewriting MARKETING_VERSION, creating + pushing the tag) lives in the
# `prepare_release` lane / release workflow. The tag push then triggers `beta`,
# which consumes the regenerated CHANGELOG.md for its TestFlight notes. Build
# number (CURRENT_PROJECT_VERSION = TestFlight latest + 1, set via xcargs) is
# deliberately untouched here, so it stays decoupled from this semver.
require_relative "version_bumper"

module ReleasePlan
  module_function

  HEAD = "HEAD".freeze
  INITIAL_VERSION = "0.0.0".freeze
  TAG_PREFIX = "v".freeze

  # last tag -> `cog changelog` range. A present tag yields `<tag>..HEAD`; a
  # blank/missing tag (first release) yields `HEAD` so cog walks full history.
  def changelog_range(last_tag)
    tag = last_tag.to_s.strip
    return HEAD if tag.empty?

    "#{tag}..#{HEAD}"
  end

  # last tag -> current semver baseline. Strips a single leading `v`; a
  # blank/missing tag means nothing has shipped yet, so baseline is 0.0.0.
  def current_version(last_tag)
    tag = last_tag.to_s.strip
    return INITIAL_VERSION if tag.empty?

    tag.sub(/\A#{TAG_PREFIX}/, "")
  end

  # last tag + commit subjects -> next semver, or nil when no releasing commit
  # is present (only housekeeping types / empty). Reuses VersionBumper for the
  # commit->level mapping and the actual bump; never re-implements them.
  def next_version(last_tag, subjects)
    level = VersionBumper.level_for(subjects)
    return nil if level.nil?

    VersionBumper.bump(current_version(last_tag), level)
  end

  # semver (or already-prefixed tag) -> `v<semver>` tag name, idempotently.
  def tag_name(version)
    v = version.to_s.strip
    v.start_with?(TAG_PREFIX) ? v : "#{TAG_PREFIX}#{v}"
  end

  # The whole release decision in one hash. `release?` is false when there's
  # nothing to ship (next_version nil); the range is still returned so a
  # changelog regen can run as a safe no-op. Pure.
  def plan(last_tag:, subjects:)
    nxt = next_version(last_tag, subjects)
    {
      range: changelog_range(last_tag),
      current_version: current_version(last_tag),
      next_version: nxt,
      tag: nxt && tag_name(nxt),
      release?: !nxt.nil?,
    }
  end
end

# CLI entry: emit the release decision as shell-eval-able `key=value` lines so a
# workflow can capture them without a YAML/JSON parser, mirroring commit_range.rb.
# Inputs arrive via env: LAST_TAG (latest `v*` tag, may be empty) and SUBJECTS (the
# commit subjects since it, one per line). Guarded so requiring this file from
# tests/Fastfile stays side-effect free.
if $PROGRAM_NAME == __FILE__
  subjects = ENV["SUBJECTS"].to_s.split("\n").map(&:strip).reject(&:empty?)
  plan = ReleasePlan.plan(last_tag: ENV["LAST_TAG"], subjects: subjects)
  puts "release=#{plan[:release?]}"
  puts "range=#{plan[:range]}"
  puts "current_version=#{plan[:current_version]}"
  puts "next_version=#{plan[:next_version]}"
  puts "tag=#{plan[:tag]}"
end
