# frozen_string_literal: true

class JWKStore
  # Thread-safe, single-value in-memory cache with automatic refresh.
  #
  # Designed for caching expensive-to-fetch data (like JWK keys from remote URLs)
  # that needs periodic refresh but should never block readers during refresh.
  #
  #   ┌─────────────────────────────────────────────────────────────────────┐
  #   │                         Application                                 │
  #   │                             │                                       │
  #   │                             ▼                                       │
  #   │   ┌─────────────────────────────────────────────────────────────┐   │
  #   │   │                  L1Cache (this class)                       │   │
  #   │   │   • In-memory, single-value                                 │   │
  #   │   │   • Fast reads (no I/O)                                     │   │
  #   │   │   • Auto-refresh on expiration                              │   │
  #   │   └─────────────────────────────────────────────────────────────┘   │
  #   │                             │                                       │
  #   │                             ▼ (on cache miss or refresh)            │
  #   │   ┌─────────────────────────────────────────────────────────────┐   │
  #   │   │               Refresher (caller-provided)                   │   │
  #   │   │   • Could be L2 cache (Redis, Memcached)                    │   │
  #   │   │   • Could be direct network fetch                           │   │
  #   │   │   • Could be file system read                               │   │
  #   │   └─────────────────────────────────────────────────────────────┘   │
  #   └─────────────────────────────────────────────────────────────────────┘
  #
  # == Refresh Strategies
  #
  # The cache uses two distinct refresh strategies to balance freshness with availability:
  #
  # === Hard Refresh (blocking)
  #
  # Used when: first fetch, or forced refresh (e.g., signature verification failed)
  #
  #   Thread A                         Thread B
  #      │                                │
  #      ├─► fetch(force: true)           │
  #      │   ├─► acquire mutex            │
  #      │   │   ├─► call refresher ──────┼──► (blocked, waiting for mutex)
  #      │   │   └─► update @value        │
  #      │   └─► release mutex ───────────┼──► acquire mutex
  #      │                                │   └─► skip refresh (already done)
  #      ▼                                ▼
  #   returns new value              returns new value
  #
  # === Soft Refresh (non-blocking, stale-while-revalidate)
  #
  # Used when: cache expired during normal operation
  #
  # Implements the "stale-while-revalidate" pattern: instead of blocking all
  # readers while refreshing, the first thread to notice expiration performs
  # the refresh in the background while other threads immediately receive the
  # stale (but still usable) cached value. This trades temporary staleness for
  # consistent low-latency responses.
  #
  #   Thread A                         Thread B
  #      │                                │
  #      ├─► fetch() [cache expired]      │
  #      │   ├─► try_lock mutex ──────────┤
  #      │   │   └─► (got lock)           ├─► fetch() [cache expired]
  #      │   │       └─► refreshing...    │   ├─► try_lock mutex
  #      │   │                            │   │   └─► (lock busy, skip)
  #      │   │                            │   └─► return stale @value ◄── instant!
  #      │   └─► release mutex            │
  #      ▼                                ▼
  #   returns new value              returned stale value (fast)
  #
  # == DoS Protection
  #
  # Forced refreshes are rate-limited by `failed_refresh_cooldown` to prevent
  # malicious or buggy callers from hammering the upstream data source:
  #
  #   Time ──────────────────────────────────────────────────────────────►
  #        │                                                              │
  #        ├─► fetch(force:true) ✓  (refreshes)                           │
  #        │                                                              │
  #        │◄─── failed_refresh_cooldown ───►│                            │
  #        │                                 │                            │
  #        ├─► fetch(force:true) ✗  (ignored, within cooldown)            │
  #        ├─► fetch(force:true) ✗  (ignored)                             │
  #        │                                 │                            │
  #        │                                 ├─► fetch(force:true) ✓      │
  #        │                                                              │
  #
  # == Error Handling
  #
  # When refresh fails:
  # 1. The exception is re-raised to the caller
  # 2. The previous cached value is preserved (if any)
  # 3. Next refresh is scheduled after `failed_refresh_cooldown` (not full interval)
  #
  #   ┌──────────────────────────────────────────────────────────────────────┐
  #   │ Time: 0        100        110        120        160        260       │
  #   │       │         │          │          │          │          │        │
  #   │       ▼         ▼          ▼          ▼          ▼          ▼        │
  #   │    fetch()   expired    fetch()    fetch()    fetch()    fetch()     │
  #   │    success   (stale)    ERROR!     (stale)    success    (stale)     │
  #   │       │                    │          │          │                   │
  #   │       └── interval=100 ───►│          │          │                   │
  #   │                            └─ cool=50─┼─────────►│                   │
  #   │                               (short) │          └── interval=100 ─► │
  #   │                                       │                              │
  #   │                              returns old value                       │
  #   └──────────────────────────────────────────────────────────────────────┘
  #
  # @example Basic usage with a network fetcher
  #   cache = L1Cache.new(
  #     refresher: ->(**) {
  #       JWT::JWK::KeySet.new(
  #         HTTP.get("https://www.googleapis.com/oauth2/v3/certs").parse(:json)
  #       )
  #     },
  #     refresh_interval: 3600,        # refresh every hour
  #     failed_refresh_cooldown: 30    # retry after 30s on failure
  #   )
  #
  #   jwks = cache.fetch           # first call fetches from network
  #   jwks = cache.fetch           # subsequent calls return cached value
  #   jwks = cache.fetch(force: true)  # force refresh (e.g., key not found)
  #
  # @example With an L2 cache layer
  #   cache = L1Cache.new(
  #     refresher: ->(force:) {
  #       jwks = Rails.cache.fetch("my-jwks", force:) do
  #         HTTP.get("https://www.googleapis.com/oauth2/v3/certs").parse(:json)
  #       end
  #
  #       JWT::JWK::KeySet.new(jwks)
  #     }
  #   )
  class L1Cache
    DEFAULT_CLOCK                   = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_second) }
    DEFAULT_REFRESH_INTERVAL        = 3600
    DEFAULT_FAILED_REFRESH_COOLDOWN = 10

    # How often (in seconds) the cached value must be refreshed.
    #
    # @return [Numeric]
    attr_reader :refresh_interval

    # If last refresh failed, don't wait for the whole `refresh_interval` to
    # try again.
    #
    # @return [Numeric]
    attr_reader :failed_refresh_cooldown

    # Latest refreshed value.
    #
    # @return [T?]
    attr_reader :value

    # @param refresher [#call] Callable that responds to `#call(force: Boolean) -> T?`
    # @param clock [#call] Callable that responds current time as Float
    # @param refresh_interval [Numeric]
    # @param failed_refresh_cooldown [Numeric]
    def initialize( # rubocop:disable Metrics/MethodLength
      refresher:,
      clock:                   DEFAULT_CLOCK,
      refresh_interval:        DEFAULT_REFRESH_INTERVAL,
      failed_refresh_cooldown: DEFAULT_FAILED_REFRESH_COOLDOWN
    )
      raise ArgumentError, "refresher must be callable"      unless refresher.respond_to?(:call)
      raise ArgumentError, "clock must be callable"          unless clock.respond_to?(:call)
      raise ArgumentError, "invalid refresh_interval"        unless valid_interval?(refresh_interval)
      raise ArgumentError, "invalid failed_refresh_cooldown" unless valid_interval?(failed_refresh_cooldown)

      @refresher               = refresher
      @clock                   = clock
      @refresh_interval        = refresh_interval
      @failed_refresh_cooldown = failed_refresh_cooldown
      @value                   = nil
      @no_value                = true
      @refresh_after           = 0.0
      @refresh_attempted_at    = 0.0
      @mutex                   = Mutex.new
    end

    # @return [T?]
    def fetch(force: false)
      hard_refresh(force:) || soft_refresh(force:)

      value
    end

    private

    def current_time = @clock.call
    def expired?     = @refresh_after < current_time

    # Very first, or explicitly force cache refresh
    def hard_refresh(force:) # rubocop:disable Metrics/CyclomaticComplexity
      return false unless force || @no_value

      requested_at = current_time

      @mutex.synchronize do
        # DoS Protection: If a forced refresh is requested, but we JUST attempted
        # a network call within the cooldown window, don't use the force, Luke!
        force = false if force && (requested_at - @refresh_attempted_at) < failed_refresh_cooldown

        # Don't double-refresh in case of multiple threads called us at the same time.
        refresh(force:) if force || @no_value || expired?

        true
      end
    end

    # Regular lazy refresh of stale data
    def soft_refresh(force:)
      return false unless expired? && @mutex.try_lock

      begin
        refresh(force:)
        true
      ensure
        @mutex.unlock
      end
    end

    def refresh(force:)
      # Update last attempt *BEFORE* actual heavy-lift calls, to ensure
      # DoS cooldown is correctly handled in the event of network failure.
      @refresh_attempted_at = current_time

      @value             = @refresher.call(force:)
      @no_value          = false
      @refresh_after     = @refresh_attempted_at + refresh_interval
    rescue StandardError
      @refresh_after = current_time + failed_refresh_cooldown

      raise
    end

    def valid_interval?(value)
      value.is_a?(Numeric) && value >= 0
    end
  end
end
