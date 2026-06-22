require "minitest/autorun"
require_relative "../fastlane/review_digest"

# Behavior of the pure App Store customer-reviews digest (EPIC-10 market-tracking,
# cakuki/atelier#125).
#
# ReviewDigest.build(reviews, options) turns the already-parsed ASC
# `customerReviews` data (an array of attribute hashes — rating/title/body/
# reviewerNickname/createdDate/territory) into a small digest structure: total
# count, new-since count, average rating + per-star breakdown, and the low-rating
# reviews flagged at/below a threshold so a rating drop surfaces early.
# ReviewDigest.format(digest) renders that structure to plain text for the lane to
# print. Keeping the whole thing pure (no fastlane, no network, no ASC) means the
# digest contract is asserted here WITHOUT any HTTP/JWT — the lane owns only the
# I/O fetch, mirroring how DeliverOptions / SentryDsymOptions / BuildProcessingStatus
# stay fastlane-free and how their dSYM/upload I/O lives in the lane, not the module.
#
# The fetch (a raw ASC GET with the JWT) is I/O and is NOT exercised here; this
# locks the digest math + text so the tested surface is the decision logic.
class ReviewDigestTest < Minitest::Test
  # --- fixture review data (ASC `data[].attributes` shape) ---

  # A small, hand-built set spanning all five star values and several dates so the
  # average, per-star breakdown, new-since filtering, and low-rating flag all have
  # something to bite on. Dates are ISO8601 (the ASC `createdDate` format).
  def review(rating:, created:, title: "t", body: "b", nick: "n", territory: "USA")
    {
      "rating"           => rating,
      "title"            => title,
      "body"             => body,
      "reviewerNickname" => nick,
      "createdDate"      => created,
      "territory"        => territory,
    }
  end

  def reviews
    [
      review(rating: 5, created: "2026-06-01T10:00:00-07:00", title: "Love it"),
      review(rating: 4, created: "2026-06-05T10:00:00-07:00"),
      review(rating: 1, created: "2026-06-10T10:00:00-07:00", title: "Crashes"),
      review(rating: 2, created: "2026-06-12T10:00:00-07:00", title: "Meh"),
      review(rating: 3, created: "2026-06-15T10:00:00-07:00"),
    ]
  end

  # --- total count ---

  def test_total_counts_all_reviews
    assert_equal 5, ReviewDigest.build(reviews)[:total]
  end

  # --- average rating (decided: rounded to 2 decimals) ---

  def test_average_is_mean_rounded_to_two_decimals
    # (5 + 4 + 1 + 2 + 3) / 5 = 15 / 5 = 3.0 exactly.
    assert_equal 3.0, ReviewDigest.build(reviews)[:average]
  end

  def test_average_rounds_to_two_decimals
    # (5 + 4 + 4) / 3 = 13 / 3 = 4.333... => 4.33 (round half-up at 2dp).
    rs = [
      review(rating: 5, created: "2026-06-01T10:00:00Z"),
      review(rating: 4, created: "2026-06-02T10:00:00Z"),
      review(rating: 4, created: "2026-06-03T10:00:00Z"),
    ]
    assert_equal 4.33, ReviewDigest.build(rs)[:average]
  end

  def test_average_rounds_half_up
    # (5 + 4) / 2 = 4.5 -> stays 4.5; (5 + 5 + 4) / 3 = 4.666... -> 4.67.
    assert_equal 4.5, ReviewDigest.build([
      review(rating: 5, created: "2026-06-01T10:00:00Z"),
      review(rating: 4, created: "2026-06-02T10:00:00Z"),
    ])[:average]
    assert_equal 4.67, ReviewDigest.build([
      review(rating: 5, created: "2026-06-01T10:00:00Z"),
      review(rating: 5, created: "2026-06-02T10:00:00Z"),
      review(rating: 4, created: "2026-06-03T10:00:00Z"),
    ])[:average]
  end

  # --- per-star breakdown (decided: Hash 1..5, every star present, zeros filled) ---

  def test_per_star_breakdown_counts_each_star
    breakdown = ReviewDigest.build(reviews)[:breakdown]
    assert_equal({ 5 => 1, 4 => 1, 3 => 1, 2 => 1, 1 => 1 }, breakdown)
  end

  def test_per_star_breakdown_always_has_all_five_keys_with_zeros
    # Only 5-star reviews => the other stars are present as 0, never missing —
    # so a consumer can index breakdown[1] without a nil-guard.
    rs = [
      review(rating: 5, created: "2026-06-01T10:00:00Z"),
      review(rating: 5, created: "2026-06-02T10:00:00Z"),
    ]
    assert_equal({ 5 => 2, 4 => 0, 3 => 0, 2 => 0, 1 => 0 },
                 ReviewDigest.build(rs)[:breakdown])
  end

  def test_breakdown_sums_to_total
    digest = ReviewDigest.build(reviews)
    assert_equal digest[:total], digest[:breakdown].values.sum
  end

  # --- new-since-date filtering ---

  def test_new_since_counts_reviews_strictly_after_the_date
    # since 2026-06-10 (start of day): the 06-10/06-12/06-15 reviews are after it,
    # the 06-01/06-05 ones are not. createdDate is compared as a real timestamp.
    digest = ReviewDigest.build(reviews, since: "2026-06-10T00:00:00Z")
    assert_equal 3, digest[:new_since]
  end

  def test_new_since_is_strictly_after_not_inclusive
    # A review whose createdDate == `since` is NOT "new since" (strictly after).
    rs = [review(rating: 5, created: "2026-06-10T00:00:00Z")]
    assert_equal 0, ReviewDigest.build(rs, since: "2026-06-10T00:00:00Z")[:new_since]
    assert_equal 1, ReviewDigest.build(rs, since: "2026-06-09T23:59:59Z")[:new_since]
  end

  def test_new_since_nil_when_no_since_option
    # No `since:` => new_since is nil (the lane prints "n/a"), NOT a count.
    assert_nil ReviewDigest.build(reviews)[:new_since]
  end

  def test_new_since_handles_mixed_timezones
    # createdDate carries an offset; comparison is on the absolute instant, so a
    # -07:00 review at 23:00 on 06-09 is actually 06-10T06:00Z — after a UTC since.
    rs = [review(rating: 5, created: "2026-06-09T23:00:00-07:00")]
    assert_equal 1, ReviewDigest.build(rs, since: "2026-06-10T00:00:00Z")[:new_since]
  end

  # --- low-rating flag (decided: ratings <= threshold, default 2) ---

  def test_flagged_defaults_to_threshold_two
    # Default threshold 2 => the 1- and 2-star reviews are flagged; 3/4/5 are not.
    flagged = ReviewDigest.build(reviews)[:flagged]
    assert_equal [1, 2], flagged.map { |r| r["rating"] }.sort
  end

  def test_flagged_respects_custom_threshold
    # threshold 1 => only the 1-star; threshold 3 => 1/2/3-star.
    assert_equal [1],
                 ReviewDigest.build(reviews, low_rating_threshold: 1)[:flagged].map { |r| r["rating"] }.sort
    assert_equal [1, 2, 3],
                 ReviewDigest.build(reviews, low_rating_threshold: 3)[:flagged].map { |r| r["rating"] }.sort
  end

  def test_flagged_preserves_full_review_hashes
    # Flagged entries are the original review hashes (so the lane can print
    # title/body/territory), not just ratings.
    flagged = ReviewDigest.build(reviews, low_rating_threshold: 1)[:flagged]
    assert_equal 1, flagged.length
    assert_equal "Crashes", flagged.first["title"]
    assert_equal "USA",     flagged.first["territory"]
  end

  def test_flagged_count_is_exposed
    assert_equal 2, ReviewDigest.build(reviews)[:flagged_count]
  end

  # --- empty input: a clean "no reviews" digest, never a crash ---

  def test_empty_reviews_is_a_clean_digest
    digest = ReviewDigest.build([])
    assert_equal 0, digest[:total]
    assert_nil   digest[:average], "no reviews => average is nil (not 0, not NaN)"
    assert_equal({ 5 => 0, 4 => 0, 3 => 0, 2 => 0, 1 => 0 }, digest[:breakdown])
    assert_equal [], digest[:flagged]
    assert_equal 0,  digest[:flagged_count]
    assert_nil   digest[:new_since], "no since option => nil even when empty"
  end

  def test_empty_reviews_with_since_has_zero_new
    assert_equal 0, ReviewDigest.build([], since: "2026-06-10T00:00:00Z")[:new_since]
  end

  def test_nil_reviews_treated_as_empty
    # Defensive: a nil from a fetch that returned no `data` must not crash.
    digest = ReviewDigest.build(nil)
    assert_equal 0, digest[:total]
    assert_nil digest[:average]
  end

  # --- build is pure: returns data, prints nothing ---

  def test_build_prints_nothing
    assert_output("", "") { ReviewDigest.build(reviews) }
    assert_output("", "") { ReviewDigest.build([]) }
  end

  # --- format: plain-text rendering for the lane to puts/UI.message ---

  def test_format_includes_headline_numbers
    text = ReviewDigest.format(ReviewDigest.build(reviews))
    assert_includes text, "Total reviews: 5"
    assert_includes text, "Average rating: 3.0"
    # Per-star breakdown lines (5 down to 1).
    assert_includes text, "5★: 1"
    assert_includes text, "1★: 1"
  end

  def test_format_shows_new_since_when_present
    text = ReviewDigest.format(ReviewDigest.build(reviews, since: "2026-06-10T00:00:00Z"))
    assert_includes text, "New since 2026-06-10T00:00:00Z: 3"
  end

  def test_format_omits_new_since_when_absent
    text = ReviewDigest.format(ReviewDigest.build(reviews))
    refute_includes text, "New since"
  end

  def test_format_lists_flagged_low_ratings
    text = ReviewDigest.format(ReviewDigest.build(reviews))
    assert_includes text, "Flagged low ratings (<= 2): 2"
    # The flagged section names the offending reviews so a drop is actionable.
    assert_includes text, "Crashes"
    assert_includes text, "Meh"
  end

  def test_format_empty_is_a_clean_no_reviews_message
    text = ReviewDigest.format(ReviewDigest.build([]))
    assert_includes text, "No reviews"
    # Never an "Average rating:" line for empty (nil average must not render as a number).
    refute_includes text, "Average rating:"
  end

  def test_format_returns_a_string
    assert_kind_of String, ReviewDigest.format(ReviewDigest.build(reviews))
    assert_kind_of String, ReviewDigest.format(ReviewDigest.build([]))
  end
end
