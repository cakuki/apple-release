# Pure App Store customer-reviews digest — the testable core of the central
# `reviews` lane (EPIC-10 market-tracking, cakuki/atelier#125).
#
# ReviewDigest.build(reviews, options) takes the already-parsed ASC
# `customerReviews` data — an array of `data[].attributes` hashes with the keys
# `rating` (Int 1–5), `title`, `body`, `reviewerNickname`, `createdDate`
# (ISO8601), `territory` — and returns a small digest structure:
#
#   {
#     total:         Int,            # how many reviews we have
#     new_since:     Int | nil,      # count created strictly after options[:since]
#     average:       Float | nil,    # mean rating, rounded to 2dp (nil if no reviews)
#     breakdown:     { 5=>Int, ..., 1=>Int },  # per-star counts, ALL stars present
#     flagged:       [review_hash, ...],        # reviews with rating <= threshold
#     flagged_count: Int,
#     threshold:     Int,            # the low-rating threshold that was applied
#     since:         String | nil,   # the since option echoed back (for format)
#   }
#
# ReviewDigest.format(digest) renders that structure to plain text for the lane to
# print via UI.message/puts. The lane is READ-ONLY: it fetches reviews from ASC and
# feeds them here; this module never writes to ASC and never does I/O.
#
# Keeping the digest pure (no fastlane, no IO, no network, no JWT) means the whole
# market-tracking contract is unit-testable under stdlib minitest — the same way
# DeliverOptions / SentryDsymOptions / BuildProcessingStatus stay fastlane-free, and
# the actual ASC GET lives in the lane (untested I/O) rather than here.
#
# TL DECISIONS (documented here + in the PR body):
#   * Average is rounded to 2 decimals (`round(2)`, Ruby's round-half-up). Two
#     decimals is enough to make a drop visible (4.50 -> 4.33) without noise; no
#     reviews => nil (NOT 0.0 / NaN), so "no data" never reads as a 0-star app.
#   * The per-star breakdown is a Hash with EVERY star 1..5 present (zeros filled),
#     so a consumer can index breakdown[1] without a nil-guard, and the values
#     always sum to total.
#   * Default low-rating threshold is 2: 1- and 2-star reviews are the early signal
#     of a rating drop. Overridable via options[:low_rating_threshold]; flagged
#     entries are the FULL review hashes so the lane can print title/body/territory.
#   * "New since" is parameterized as an ISO8601 string in options[:since]; a review
#     is "new" iff its createdDate is STRICTLY AFTER `since` (absolute instant, so
#     timezone offsets are honored). No since => new_since is nil (the lane prints
#     "n/a") rather than a misleading count.
#   * Empty / nil input is a clean digest (total 0, average nil, all-zero breakdown,
#     no flagged) — never a crash or a divide-by-zero.
require "time"

module ReviewDigest
  module_function

  # The full ASC star range, high to low — the canonical order for the breakdown
  # and the format output. Every key is always present in a breakdown (zeros filled).
  STARS = [5, 4, 3, 2, 1].freeze

  # Default low-rating threshold: ratings AT OR BELOW this are flagged so a drop
  # surfaces early. 2 catches the 1- and 2-star reviews. Overridable per call.
  DEFAULT_LOW_RATING_THRESHOLD = 2

  # reviews (Array of attribute hashes, or nil) + options -> digest Hash. Pure: no
  # fastlane, no IO, no network, no logging. nil/empty input yields a clean digest.
  #
  #   options[:since]                 ISO8601 String — count "new since" this instant
  #   options[:low_rating_threshold]  Int — flag ratings <= this (default 2)
  def build(reviews, options = {})
    reviews   = Array(reviews)
    since     = options[:since]
    threshold = (options[:low_rating_threshold] || DEFAULT_LOW_RATING_THRESHOLD).to_i

    ratings = reviews.map { |r| r["rating"].to_i }
    flagged = reviews.select { |r| r["rating"].to_i <= threshold }

    {
      total:         reviews.length,
      new_since:     new_since_count(reviews, since),
      average:       average(ratings),
      breakdown:     breakdown(ratings),
      flagged:       flagged,
      flagged_count: flagged.length,
      threshold:     threshold,
      since:         since,
    }
  end

  # Mean of the ratings, rounded to 2 decimals; nil when there are no reviews (so
  # "no data" is never rendered as a 0-star average). Internal helper.
  def average(ratings)
    return nil if ratings.empty?

    (ratings.sum.to_f / ratings.length).round(2)
  end
  private_class_method :average

  # Per-star counts as a Hash with EVERY star 1..5 present (zeros filled), in the
  # canonical high->low order, so the values always sum to total and consumers
  # never hit a missing key. Internal helper.
  def breakdown(ratings)
    counts = STARS.map { |star| [star, 0] }.to_h
    ratings.each { |r| counts[r] += 1 if counts.key?(r) }
    counts
  end
  private_class_method :breakdown

  # Count of reviews created STRICTLY AFTER `since` (an ISO8601 String), comparing
  # absolute instants so timezone offsets are honored. nil `since` => nil (the lane
  # prints "n/a", not a count). A review with an unparseable createdDate is treated
  # as NOT new (conservative: don't inflate the "new" count on bad data). Internal.
  def new_since_count(reviews, since)
    return nil if since.nil? || since.to_s.strip.empty?

    # Best-effort cutoff parse, same policy as createdDate: an unparseable `since`
    # yields nil (no count) rather than crashing the pure digest. The lane
    # validates REVIEWS_SINCE up front and fails fast with a clear message, so this
    # is the defensive backstop.
    cutoff = parse_time(since)
    return nil if cutoff.nil?

    reviews.count do |r|
      created = parse_time(r["createdDate"])
      created && created > cutoff
    end
  end
  private_class_method :new_since_count

  # Best-effort ISO8601 parse; nil on anything unparseable (so a bad createdDate
  # never crashes the digest and never counts as "new"). Internal helper.
  def parse_time(value)
    # Time.iso8601 (not the permissive Time.parse): both `createdDate` and the
    # `since` cutoff are documented ISO8601 instants, and iso8601 requires an
    # explicit offset so comparisons are always on absolute instants rather than
    # the runner's local zone. Anything non-ISO8601 => nil (best-effort).
    Time.iso8601(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :parse_time

  # digest Hash (from build) -> plain text for the lane to print. Pure string
  # assembly; no IO. Empty digest renders a clean "No reviews" message (and never
  # an "Average rating:" line, since the average is nil).
  def format(digest)
    return "App Store reviews digest\n  No reviews found." if digest[:total].zero?

    lines = ["App Store reviews digest"]
    lines << "  Total reviews: #{digest[:total]}"
    lines << "  Average rating: #{digest[:average]}"

    # Gate on the COUNT, not on :since — so a valid cutoff with 0 new reviews still
    # prints (0 is meaningful), while a nil/blank/unparseable cutoff (new_since nil)
    # prints nothing instead of a confusing line with an empty date or `nil` count.
    unless digest[:new_since].nil?
      lines << "  New since #{digest[:since]}: #{digest[:new_since]}"
    end

    lines << "  Breakdown:"
    STARS.each { |star| lines << "    #{star}★: #{digest[:breakdown][star]}" }

    lines << "  Flagged low ratings (<= #{digest[:threshold]}): #{digest[:flagged_count]}"
    digest[:flagged].each do |r|
      # One line per flagged review: rating, territory, title — enough to act on a
      # drop without dumping the whole body. (The body is available in the hash if
      # a caller wants more.)
      lines << "    - #{r['rating']}★ [#{r['territory']}] #{r['title']}"
    end

    lines.join("\n")
  end
end
