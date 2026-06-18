require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../fastlane/changelog_formatter"
require_relative "../fastlane/release_plan"

# REAL-cog integration test (cakuki/atelier#26). The canonical guard against
# tool-output DRIFT: every other test in this suite asserts against a *hand-
# written* idea of cog's output, proving only "code matches the test", never
# "the test matches the real tool". That gap shipped a `top_section` regex that
# never matched cog's actual `default`-template output (EPIC-02 Task 3, caught
# late in apple-release PR #2). This test closes it by running the REAL `cog`
# binary end-to-end:
#
#   build throwaway repo (conventional commits + tag)
#     -> real `cog changelog <range>`        (the actual tool, actual cog.toml)
#       -> ChangelogFormatter.notes          (TestFlight notes)
#       -> ReleasePlan.plan                  (derived v<semver> tag)
#
# and asserts BOTH the formatted notes and the derived tag are what we expect,
# failing if the cog<->formatter contract drifts.
#
# Gated on cog availability: if `cog` is not on PATH this test SKIPs (does not
# fail), so the fast pure-stdlib unit suite still passes on machines without cog
# (e.g. the system-ruby-2.6, no-bundler dev box). In CI the commit-lint workflow
# installs the pinned cog binary, so this actually runs there. Run locally with:
#   ruby test/all.rb        # skips this test cleanly if cog is absent
class ChangelogPipelineIntegrationTest < Minitest::Test
  # Use a tag-based `<rev>..HEAD` range — the exact shape ReleasePlan emits for
  # an already-tagged app. We deliberately avoid the bare `HEAD` form: cog 7.x
  # rejects `cog changelog HEAD` ("invalid commit range pattern"), and a range
  # is what the real release flow uses once the first tag exists.
  def setup
    @cog = which("cog")
    skip "cog binary not on PATH — install cog to run the real-tool integration test" if @cog.nil?
  end

  # End-to-end: real cog output -> formatter -> clean TestFlight notes.
  def test_real_cog_changelog_formats_to_clean_testflight_notes
    Dir.mktmpdir("atelier-cog-it") do |repo|
      init_repo(repo)
      commit(repo, "feat: shiny new feature")
      commit(repo, "fix: a small bug")
      git(repo, "tag", "v0.1.0")
      base = "v0.1.0"
      commit(repo, "feat: another shiny thing")
      commit(repo, "perf: make it snappier")
      # Omitted types must NOT reach the changelog (cog.toml omit_from_changelog).
      commit(repo, "chore: tidy up")

      changelog = cog_changelog(repo, "#{base}..HEAD")

      # Sanity: the RAW cog output really has the shape the formatter must cope
      # with — the regex bug that motivated this test lived exactly here.
      assert_match(/^#### /, changelog, "expected cog h4 type sub-headers in raw output")
      assert_match(/^- .+ - \([0-9a-f]+\) - /, changelog, "expected cog dash bullets with - (hash) - committer trailers")

      notes = ChangelogFormatter.notes(changelog)

      # The real contract: releasing commits appear as clean UTF bullets.
      assert_includes notes, "• another shiny thing"
      assert_includes notes, "• make it snappier"
      # Omitted/housekeeping commit must not surface.
      refute_includes notes, "tidy up"
      # No cog artifacts leak through.
      refute_match(/#+/, notes, "markdown headers leaked into notes")
      refute_match(/\([0-9a-f]{7,}\)/, notes, "commit hashes leaked into notes")
      refute_includes notes, "Unreleased"
      refute_equal ChangelogFormatter::FALLBACK, notes, "real notes degraded to the fallback"
    end
  end

  # End-to-end: real commit subjects -> ReleasePlan -> derived v<semver> tag.
  # The version half of the pipeline the issue calls out alongside the notes.
  def test_real_commit_subjects_derive_expected_semver_tag
    Dir.mktmpdir("atelier-cog-it") do |repo|
      init_repo(repo)
      commit(repo, "feat: base feature")
      git(repo, "tag", "v1.2.3")
      commit(repo, "fix: patch one")
      commit(repo, "feat: a new capability") # highest level = minor

      subjects = git(repo, "log", "v1.2.3..HEAD", "--format=%s").split("\n")
      plan = ReleasePlan.plan(last_tag: "v1.2.3", subjects: subjects)

      assert_equal "v1.2.3..HEAD", plan[:range]
      assert_equal "1.2.3", plan[:current_version]
      assert_equal "1.3.0", plan[:next_version], "feat over a fix must bump minor"
      assert_equal "v1.3.0", plan[:tag]
      assert plan[:release?]
    end
  end

  private

  # Locate an executable on PATH without shelling out (works on ruby 2.6 stdlib).
  def which(cmd)
    exts = ENV["PATHEXT"] ? ENV["PATHEXT"].split(";") : [""]
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
      exts.each do |ext|
        exe = File.join(dir, "#{cmd}#{ext}")
        return exe if File.executable?(exe) && !File.directory?(exe)
      end
    end
    nil
  end

  def init_repo(dir)
    git(dir, "init", "-q")
    git(dir, "config", "user.email", "ci@atelier.test")
    git(dir, "config", "user.name", "atelier-ci")
    git(dir, "config", "commit.gpgsign", "false")
    git(dir, "config", "tag.gpgsign", "false")
    # Use the canonical Atelier cog.toml so we exercise the real config apps
    # inherit (h4 type headers, omit_from_changelog), not cog's bare defaults.
    src = File.expand_path("../templates/cog.toml", __dir__)
    File.write(File.join(dir, "cog.toml"), File.read(src))
  end

  def commit(dir, subject)
    # Each commit needs a real change; name the file off a monotonic counter so
    # filenames are guaranteed unique (no `String#hash` collision flakiness).
    @seq = (@seq || 0) + 1
    fname = "f_#{@seq}.txt"
    File.write(File.join(dir, fname), subject)
    git(dir, "add", fname)
    git(dir, "commit", "-q", "-m", subject)
  end

  # Hermetic git environment for the throwaway repo. The test must NOT inherit
  # the developer/runner's GLOBAL or SYSTEM git config: a globally-enabled
  # `commit.gpgsign`/`tag.gpgsign` would make `git commit`/`git tag` fail (no
  # signing key) or hang on a GPG prompt, and an unset `user.name`/`user.email`
  # on a clean CI runner would abort the commit. We point both config files at
  # /dev/null (no global/system config at all) and force-disable signing in a
  # batch (non-interactive) GPG context. Local user.name/email are still set in
  # init_repo. This keeps the test hermetic on a signing-enabled dev machine and
  # on a bare CI runner alike.
  GIT_ENV = {
    "GIT_CONFIG_GLOBAL" => File::NULL,
    "GIT_CONFIG_SYSTEM" => File::NULL,
    "GIT_TERMINAL_PROMPT" => "0",
    "GPG_TTY" => nil
  }.freeze

  # Run git in `dir`, returning stdout; raise with stderr on failure. Runs in a
  # fully isolated git env (see GIT_ENV) with signing explicitly disabled so the
  # throwaway repo never reaches for the user's global config or a signing key.
  def git(dir, *args)
    cmd = ["git", "-C", dir,
           "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args]
    out, err, status = Open3.capture3(GIT_ENV, *cmd)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  # Run the REAL cog binary to generate the changelog for `range` in `dir`.
  # Same isolated git env so cog's internal git calls also ignore global config.
  def cog_changelog(dir, range)
    out, err, status = Open3.capture3(GIT_ENV, @cog, "changelog", range, chdir: dir)
    raise "cog changelog #{range} failed: #{err}" unless status.success?

    out
  end
end
