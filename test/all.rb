# Atelier unit-test aggregator: run the whole stdlib-minitest suite with one
# command — `ruby test/all.rb`. Each file uses `minitest/autorun`, so requiring
# them here runs every test in a single process. CI (EPIC-02 Task 2) and local
# devs should invoke this rather than naming individual files; new `*_test.rb`
# files are discovered automatically, so the suite needs no edits to grow.
Dir[File.join(__dir__, "*_test.rb")].sort.each { |f| require_relative File.basename(f) }
