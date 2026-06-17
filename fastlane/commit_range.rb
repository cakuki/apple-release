# Pure, testable base..HEAD commit-range resolver for the commit-lint CI check.
#
# EPIC-02, Task 2. On a pull request, `cog check` must lint exactly the commits
# the PR introduces — the range `<base>..<head>`. A shallow clone breaks range
# resolution, so the workflow checks out with `fetch-depth: 0`; this module is
# the pure piece that turns the runner's base/head refs (from env) into the
# `base..head` string `cog check` consumes. No git/IO here — that wiring lives
# in the workflow.
module CommitRange
  module_function

  DEFAULT_HEAD = "HEAD".freeze

  # base + head -> "base..head". `head` defaults to HEAD when blank/missing;
  # a blank/missing `base` is an ArgumentError (a range needs a base). Pure.
  def resolve(base:, head: nil)
    base = base.to_s.strip
    raise ArgumentError, "base ref is required to resolve a commit range" if base.empty?

    head = head.to_s.strip
    head = DEFAULT_HEAD if head.empty?

    "#{base}..#{head}"
  end

  # GitHub Actions PR env -> range string. The base branch arrives as a bare
  # name in GITHUB_BASE_REF, so we prefix `origin/` to point at the fetched
  # remote-tracking ref (idempotent if already prefixed). The head is the PR
  # tip SHA (GITHUB_HEAD_SHA, else GITHUB_SHA), falling back to HEAD. Pure.
  def from_env(env)
    base = env["GITHUB_BASE_REF"].to_s.strip
    raise ArgumentError, "GITHUB_BASE_REF is empty; not a pull_request event?" if base.empty?

    base = "origin/#{base}" unless base.start_with?("origin/")
    head = env["GITHUB_HEAD_SHA"].to_s.strip
    head = env["GITHUB_SHA"].to_s.strip if head.empty?

    resolve(base: base, head: head)
  end
end

# CLI entry: print the resolved range from the GitHub Actions env so the
# commit-lint workflow can capture it (`RANGE="$(ruby fastlane/commit_range.rb)"`).
# Guarded so requiring this file from tests/Fastfile stays side-effect free.
if $PROGRAM_NAME == __FILE__
  puts CommitRange.from_env(ENV)
end
