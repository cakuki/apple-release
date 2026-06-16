# Pure, testable semver bump + xcodegen project.yml MARKETING_VERSION rewriter.
#
# EPIC-02, Task 4. Maps Conventional Commit subjects to a SemVer release level,
# folds a batch of subjects to the highest level, bumps a "x.y.z" string, and
# rewrites the `MARKETING_VERSION:` value in a project.yml otherwise byte-for-
# byte. Pure core only; the git/IO wiring into cog+Fastfile is Task 5.
module VersionBumper
  module_function

  # One conventional-commit subject -> :major | :minor | :patch | nil. Pure.
  def commit_level(subject)
    m = subject.match(/\A(\w+)(?:\([^)]*\))?(!)?:/)
    return nil unless m

    type = m[1]
    breaking = m[2]
    return :major if breaking
    return :minor if type == "feat"
    return :patch if %w[fix perf].include?(type)

    nil
  end

  PRECEDENCE = [:major, :minor, :patch].freeze

  # Array of subjects -> highest release level (major > minor > patch), or nil. Pure.
  def level_for(subjects)
    levels = subjects.map { |s| commit_level(s) }.compact
    PRECEDENCE.find { |level| levels.include?(level) }
  end

  # "x.y.z" + level -> next semver string; nil level is a no-op. Pure.
  def bump(version, level)
    return version if level.nil?

    major, minor, patch = version.split(".").map(&:to_i)
    case level
    when :major then "#{major + 1}.0.0"
    when :minor then "#{major}.#{minor + 1}.0"
    when :patch then "#{major}.#{minor}.#{patch + 1}"
    end
  end

  # project.yml text -> same text with the MARKETING_VERSION value set to
  # `version` (emitted quoted), everything else byte-for-byte preserved. Pure.
  def set_marketing_version(project_yml, version)
    project_yml.gsub(/^(\s*MARKETING_VERSION:[ \t]*).*$/) do
      "#{Regexp.last_match(1)}\"#{version}\""
    end
  end
end
