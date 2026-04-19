# frozen_string_literal: true

class JWKStore
  class L1CacheTest < Minitest::Test
    class Refresher
      Result = Data.define(:force, :sequence)

      attr_reader :sequence

      def initialize(sleep: nil)
        @sequence = 0
        @sleep    = sleep
      end

      def call(force: false)
        sleep @sleep if @sleep

        Result.new(force:, sequence: next_sequence)
      end

      private

      def next_sequence
        @sequence += 1
      end
    end

    class Clock
      def initialize
        @current_time = 0.0
      end

      def advance(seconds)
        @current_time += seconds
      end

      def call
        @current_time
      end
    end

    def setup
      @refresher = Refresher.new
      @clock     = Clock.new
    end

    # --------------------------------------------------------------------------
    # #initialize
    # --------------------------------------------------------------------------

    def test_initializes_cache_with_defaults
      cache = L1Cache.new(refresher: @refresher)

      assert_equal 3600, cache.refresh_interval
      assert_equal 10,   cache.failed_refresh_cooldown

      assert_nil cache.value
    end

    def test_respects_given_overrides
      cache = L1Cache.new(
        refresher:               @refresher,
        refresh_interval:        4,
        failed_refresh_cooldown: 20
      )

      assert_equal 4,  cache.refresh_interval
      assert_equal 20, cache.failed_refresh_cooldown
    end

    def test_fails_on_negative_refresh_interval
      error = assert_raises(ArgumentError) do
        L1Cache.new(refresher: @refresher, refresh_interval: -1)
      end

      assert_match(%r{invalid refresh_interval}, error.message)
    end

    def test_fails_on_negative_failed_refresh_cooldown
      error = assert_raises(ArgumentError) do
        L1Cache.new(refresher: @refresher, failed_refresh_cooldown: -1)
      end

      assert_match(%r{invalid failed_refresh_cooldown}, error.message)
    end

    def test_fails_if_refresher_is_not_callable
      error = assert_raises(ArgumentError) do
        L1Cache.new(refresher: "not callable")
      end

      assert_match(%r{refresher must be callable}, error.message)
    end

    def test_fails_if_clock_is_not_callable
      error = assert_raises(ArgumentError) do
        L1Cache.new(refresher: @refresher, clock: "not callable")
      end

      assert_match(%r{clock must be callable}, error.message)
    end

    def test_accepts_zero_refresh_interval
      cache = L1Cache.new(refresher: @refresher, refresh_interval: 0)

      assert_equal 0, cache.refresh_interval
    end

    def test_accepts_zero_failed_refresh_cooldown
      cache = L1Cache.new(refresher: @refresher, failed_refresh_cooldown: 0)

      assert_equal 0, cache.failed_refresh_cooldown
    end

    def test_accepts_float_intervals
      cache = L1Cache.new(
        refresher:               @refresher,
        refresh_interval:        0.5,
        failed_refresh_cooldown: 0.1
      )

      assert_in_delta(0.5, cache.refresh_interval)
      assert_in_delta(0.1, cache.failed_refresh_cooldown)
    end

    def test_fails_on_non_numeric_refresh_interval
      error = assert_raises(ArgumentError) do
        L1Cache.new(refresher: @refresher, refresh_interval: "60")
      end

      assert_match(%r{invalid refresh_interval}, error.message)
    end

    def test_fails_on_non_numeric_failed_refresh_cooldown
      error = assert_raises(ArgumentError) do
        L1Cache.new(refresher: @refresher, failed_refresh_cooldown: "10")
      end

      assert_match(%r{invalid failed_refresh_cooldown}, error.message)
    end

    # --------------------------------------------------------------------------
    # #fetch
    # --------------------------------------------------------------------------

    def test_fetches_and_returns_data_on_first_call
      cache  = L1Cache.new(refresher: @refresher)
      result = cache.fetch

      assert_instance_of Refresher::Result, result
      assert_equal 1, result.sequence
      assert_equal result, cache.value
    end

    def test_returns_cached_data_without_calling_refresher_when_not_expired
      cache = L1Cache.new(refresher: @refresher, clock: @clock, refresh_interval: 100)

      first_result = cache.fetch

      @clock.advance(50)

      second_result = cache.fetch

      assert_equal 1, first_result.sequence
      assert_equal first_result, second_result
    end

    def test_refreshes_after_expiration
      cache = L1Cache.new(refresher: @refresher, clock: @clock, refresh_interval: 100)

      first_result = cache.fetch

      @clock.advance(101)

      second_result = cache.fetch

      assert_equal 1, first_result.sequence
      assert_equal 2, second_result.sequence
    end

    def test_forces_refresh_even_when_not_expired_after_cooldown
      cache = L1Cache.new(
        refresher:               @refresher,
        clock:                   @clock,
        refresh_interval:        3600,
        failed_refresh_cooldown: 10
      )

      cache.fetch

      @clock.advance(11)

      result = cache.fetch(force: true)

      assert_equal 2, result.sequence
      assert result.force
    end

    def test_propagates_error_on_first_call_and_leaves_value_nil
      refresher = proc { raise StandardError, "Network error" }
      cache     = L1Cache.new(refresher:)

      error = assert_raises(StandardError) { cache.fetch }

      assert_equal "Network error", error.message
      assert_nil cache.value
    end

    def test_raises_error_but_preserves_cached_value_on_refresh_failure
      call_count = 0
      refresher  = proc do
        call_count += 1

        raise StandardError, "Network failed" if call_count == 2

        "initial_data"
      end

      cache = L1Cache.new(refresher:, clock: @clock, refresh_interval: 3600)

      cache.fetch

      @clock.advance(20)

      assert_raises(StandardError) { cache.fetch(force: true) }
      assert_equal "initial_data", cache.value
    end

    def test_ignores_force_within_cooldown_dos_protection
      cache = L1Cache.new(refresher: @refresher, clock: @clock, failed_refresh_cooldown: 100)

      first_result = cache.fetch

      @clock.advance(50)

      second_result = cache.fetch(force: true)

      assert_equal 1, first_result.sequence
      assert_equal first_result, second_result
    end

    def test_schedules_retry_after_cooldown_on_error
      call_count = 0
      refresher  = proc do
        call_count += 1

        raise StandardError if call_count == 2

        "data-#{call_count}"
      end

      cache = L1Cache.new(
        refresher:               refresher,
        clock:                   @clock,
        refresh_interval:        100,
        failed_refresh_cooldown: 50
      )

      cache.fetch # Success (Call 1)

      @clock.advance(101)

      assert_raises(StandardError) { cache.fetch } # Fails (Call 2). Retry at 101 + 50 = 151

      @clock.advance(30) # Time 131. Inside cooldown window.

      assert_equal "data-1", cache.fetch
      assert_equal 2, call_count # Refresher not called again

      @clock.advance(30) # Time 161. Past cooldown.

      assert_equal "data-3", cache.fetch
      assert_equal 3, call_count
    end

    def test_returns_stale_data_while_soft_refresh_is_in_progress
      refresher = Refresher.new(sleep: 0.1)
      cache = L1Cache.new(refresher: refresher, clock: @clock, refresh_interval: 100)

      stale_value = cache.fetch # Warm cache at 0.0
      @clock.advance(101) # Expire cache

      # Background thread triggers soft_refresh and holds the mutex
      thread = Thread.new { cache.fetch }
      sleep 0.02 # Give the thread time to acquire the lock

      # Main thread should fail to get the lock and return the stale value immediately
      assert_equal stale_value, cache.fetch

      # Eventually, the background thread finishes and returns the new value
      assert_equal 2, thread.value.sequence
    end

    def test_does_not_double_refresh_when_multiple_threads_call_concurrently_on_empty
      refresher = Refresher.new(sleep: 0.05)
      cache     = L1Cache.new(refresher: refresher)

      # All threads demand data on an empty cache
      threads = Array.new(5) { Thread.new { cache.fetch } }
      threads.each(&:join)

      # Refresher should have only been called once due to hard_refresh mutex
      assert_equal 1, refresher.sequence
    end

    def test_returns_same_value_object_to_all_concurrent_callers
      refresher = Refresher.new(sleep: 0.05)
      cache     = L1Cache.new(refresher: refresher)

      threads = Array.new(5) { Thread.new { cache.fetch } }

      # Thread#value returns the result of cache.fetch for that thread
      results = threads.map(&:value)

      assert_equal 5, results.size

      # Every thread should have received the exact same Refresher::Result object
      assert_equal 1, results.uniq.size
    end

    def test_refreshes_exactly_at_expiration_boundary
      cache = L1Cache.new(refresher: @refresher, clock: @clock, refresh_interval: 100)

      first_result = cache.fetch

      @clock.advance(100) # Exactly at boundary (refresh_after < current_time is false)

      # At exactly 100, refresh_after (100) is NOT less than current_time (100)
      # So cache should NOT refresh yet
      second_result = cache.fetch

      assert_equal first_result, second_result
    end

    def test_refreshes_one_tick_past_expiration_boundary
      cache = L1Cache.new(refresher: @refresher, clock: @clock, refresh_interval: 100)

      cache.fetch

      @clock.advance(100.001) # Just past boundary

      result = cache.fetch

      assert_equal 2, result.sequence
    end

    def test_handles_refresher_returning_nil
      refresher = proc {}
      cache     = L1Cache.new(refresher:, clock: @clock, refresh_interval: 100)

      result = cache.fetch

      assert_nil result
      assert_nil cache.value

      # Should not trigger another refresh since nil is a valid cached value
      @clock.advance(50)

      cache.fetch

      # Value stays nil, no additional refresh needed (would error if called again)
    end

    def test_handles_refresher_returning_false
      call_count = 0
      refresher  = proc {
        call_count += 1
        false
      }
      cache = L1Cache.new(refresher:, clock: @clock, refresh_interval: 100)

      result = cache.fetch

      refute result
      refute cache.value

      assert_equal 1, call_count

      # Should use cached false value, not refresh again
      @clock.advance(50)

      cache.fetch

      assert_equal 1, call_count
    end

    def test_force_refresh_immediately_after_initial_fetch_is_ignored
      cache = L1Cache.new(
        refresher:               @refresher,
        clock:                   @clock,
        refresh_interval:        3600,
        failed_refresh_cooldown: 10
      )

      first = cache.fetch

      # Force immediately (within cooldown of initial fetch)
      second = cache.fetch(force: true)

      assert_equal first, second
      assert_equal 1, @refresher.sequence
    end

    def test_multiple_consecutive_force_refreshes_are_rate_limited
      cache = L1Cache.new(
        refresher:               @refresher,
        clock:                   @clock,
        refresh_interval:        3600,
        failed_refresh_cooldown: 10
      )

      cache.fetch
      @clock.advance(11)

      # First force succeeds
      cache.fetch(force: true)

      assert_equal 2, @refresher.sequence

      # Rapid successive forces are ignored
      cache.fetch(force: true)
      cache.fetch(force: true)
      cache.fetch(force: true)

      assert_equal 2, @refresher.sequence

      # Wait for cooldown, then force works again
      @clock.advance(11)

      cache.fetch(force: true)

      assert_equal 3, @refresher.sequence
    end

    def test_concurrent_force_refreshes_limited_by_cooldown
      refresher = Refresher.new(sleep: 0.05)
      cache     = L1Cache.new(
        refresher:,
        clock:                   @clock,
        refresh_interval:        3600,
        failed_refresh_cooldown: 100
      )

      cache.fetch # seq 1 at time 0

      @clock.advance(101) # Past cooldown, time is now 101

      # All threads capture requested_at = 101 before acquiring mutex
      # First thread: (101 - 0) < 100 is false, force allowed, refreshes
      # Other threads: (101 - 101) < 100 is true, force disabled
      threads = Array.new(5) { Thread.new { cache.fetch(force: true) } }
      threads.each(&:join)

      # Only 2 calls: initial + one force (others blocked by cooldown)
      assert_equal 2, refresher.sequence
    end

    def test_soft_refresh_skipped_when_hard_refresh_succeeds
      call_count = 0
      refresher  = proc {
        call_count += 1
        "data-#{call_count}"
      }
      cache = L1Cache.new(refresher:, clock: @clock, refresh_interval: 100)

      # Initial fetch (hard_refresh due to @no_value)
      cache.fetch

      assert_equal 1, call_count

      # Even if expired, force: true triggers hard_refresh which returns true,
      # so soft_refresh is not called
      @clock.advance(101)

      cache.fetch(force: true)

      assert_equal 2, call_count # Only one additional call, not two
    end

    def test_multiple_errors_reset_cooldown_each_time # rubocop:disable Minitest/MultipleAssertions
      call_count = 0
      refresher  = proc do
        call_count += 1
        raise StandardError, "Error #{call_count}" if call_count > 1

        "initial"
      end

      cache = L1Cache.new(
        refresher:               refresher,
        clock:                   @clock,
        refresh_interval:        100,
        failed_refresh_cooldown: 50
      )

      cache.fetch # Success at time 0

      @clock.advance(101) # Expired

      assert_raises(StandardError) { cache.fetch } # Error at 101, retry at 151

      @clock.advance(30) # Time 131, within cooldown

      assert_equal "initial", cache.fetch # Returns stale, no call
      assert_equal 2, call_count

      @clock.advance(30) # Time 161, past cooldown

      assert_raises(StandardError) { cache.fetch } # Error at 161, retry at 211
      assert_equal 3, call_count

      @clock.advance(30) # Time 191, within new cooldown

      assert_equal "initial", cache.fetch # Still returns stale
      assert_equal 3, call_count
    end

    def test_successful_refresh_after_error_restores_normal_interval
      call_count = 0
      refresher  = proc do
        call_count += 1

        raise StandardError if call_count == 2

        "data-#{call_count}"
      end

      cache = L1Cache.new(
        refresher:               refresher,
        clock:                   @clock,
        refresh_interval:        100,
        failed_refresh_cooldown: 10
      )

      cache.fetch # data-1 at 0, expires at 100

      @clock.advance(101)

      assert_raises(StandardError) { cache.fetch } # Error at 101, retry at 111

      @clock.advance(15) # Time 116, past error cooldown

      result = cache.fetch # data-3 at 116, expires at 216

      assert_equal "data-3", result

      @clock.advance(50) # Time 166, not yet expired

      assert_equal "data-3", cache.fetch
      assert_equal 3, call_count # No additional refresh
    end

    def test_zero_refresh_interval_expires_on_next_tick
      cache = L1Cache.new(refresher: @refresher, clock: @clock, refresh_interval: 0)

      cache.fetch # refresh_after = 0 + 0 = 0

      assert_equal 1, @refresher.sequence

      # At same time (0), expired? is (0 < 0) = false, so no refresh
      cache.fetch

      assert_equal 1, @refresher.sequence

      # Any time advance triggers expiration
      @clock.advance(0.001)

      cache.fetch

      assert_equal 2, @refresher.sequence
    end

    def test_zero_cooldown_allows_immediate_force_refresh
      cache = L1Cache.new(
        refresher:               @refresher,
        clock:                   @clock,
        refresh_interval:        3600,
        failed_refresh_cooldown: 0
      )

      cache.fetch

      # Force immediately with zero cooldown should work
      result = cache.fetch(force: true)

      assert_equal 2, result.sequence
      assert result.force
    end
  end
end
