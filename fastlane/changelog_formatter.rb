# Pure, testable changelog -> TestFlight/App Store notes formatter.
#
# Converges LoopApp's richer `format_changelog_for_testflight` into the central
# `changelog_from_md` (EPIC-02, Task 3): strip markdown sub-headers, convert
# bullets to UTF bullets, drop commit-hash/committer trailers, collapse blank
# runs, take only the latest "## " section, and fall back to "Automated build".
#
# Section delimiter is the generic `^## ` (NOT LoopApp's `## Build \d+`) so this
# stays decoupled from the versioning scheme (deferred to EPIC-02 task 4).
module ChangelogFormatter
  module_function

  FALLBACK = "Automated build".freeze

  # Clean a single changelog section body (string -> string). Pure.
  def clean(section)
    text = section.dup
    text = text.gsub(/^####\s+(.+)$/, '\1')                              # drop "#### Foo" -> "Foo"
    text = text.gsub(/^-\s+/, "• ")                                      # "- x" -> "• x"
    text = text.gsub(/\s+-\s+\([0-9a-f]+\)(\s+-\s+[\w\s]+)?$/, "")       # drop " - (hash) - Name"
    text.strip.gsub(/\n{3,}/, "\n\n")                                    # collapse blank runs
  end

  # Extract the top (latest) "## " section body, or nil if none matches. Pure.
  def top_section(changelog)
    m = changelog.match(/^## .*?\n\n(.*?)(?=\n##|\n# |\z)/m)
    m && m[1]
  end

  # Full changelog text -> notes string, with "Automated build" fallback. Pure.
  def notes(changelog)
    section = top_section(changelog)
    return FALLBACK if section.nil?

    cleaned = clean(section)
    cleaned.empty? ? FALLBACK : cleaned
  end

  # Read a CHANGELOG.md path -> notes, with "Automated build" fallback.
  def from_file(path)
    return FALLBACK unless File.exist?(path)

    notes(File.read(path))
  end
end
