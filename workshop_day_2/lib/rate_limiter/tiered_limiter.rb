require 'connection_pool'

module RateLimiter
  class TieredLimiter
    # Тарифные планы
    TIERS = {
      free: {
        requests_per_minute: 10,
        burst_capacity: 20,
        daily_quota: 1_000,
        concurrent_requests: 1
      },
      startup: {
        requests_per_minute: 100,
        burst_capacity: 150,
        daily_quota: 50_000,
        concurrent_requests: 5
      },
      business: {
        requests_per_minute: 500,
        burst_capacity: 1000,
        daily_quota: 500_000,
        concurrent_requests: 20
      },
      enterprise: {
        requests_per_minute: 2000,
        burst_capacity: 5000,
        daily_quota: nil,  # Безлимитно
        concurrent_requests: 100
      }
    }.freeze

    def initialize(redis_pool:)
      @redis_pool = redis_pool
    end

    # Проверка всех лимитов
    def check_all_limits(client)
      tier = client.tier&.to_sym || :free
      config = TIERS[tier]

      results = {
        allowed: true,
        tier: tier,
        checks: {}
      }

      # 1. Rate limit (запросов в минуту)
      rate_result = check_rate_limit(client, config)
      results[:checks][:rate_limit] = rate_result
      unless rate_result[:allowed]
        results[:allowed] = false
        results[:reason] = 'rate_limit_exceeded'
        return results
      end

      # 2. Daily quota (если есть лимит)
      if config[:daily_quota]
        quota_result = check_daily_quota(client, config)
        results[:checks][:daily_quota] = quota_result
        unless quota_result[:allowed]
          results[:allowed] = false
          results[:reason] = 'daily_quota_exceeded'
          return results
        end
      else
        results[:checks][:daily_quota] = { allowed: true, unlimited: true }
      end

      # 3. Concurrent requests
      concurrent_result = check_concurrent_limit(client, config)
      results[:checks][:concurrent] = concurrent_result
      unless concurrent_result[:allowed]
        results[:allowed] = false
        results[:reason] = 'concurrent_limit_exceeded'
        return results
      end

      results
    end

    # Освобождение concurrent slot после завершения запроса
    def release_concurrent(client)
      key = "concurrent:#{client.id}"
      @redis_pool.with { |redis| redis.decr(key) }
    end

    # Получение headers для ответа
    def build_headers(results, config)
      headers = {}

      # Rate limit headers
      if results[:checks][:rate_limit]
        headers['X-RateLimit-Limit'] = config[:requests_per_minute].to_s
        headers['X-RateLimit-Remaining'] = results[:checks][:rate_limit][:remaining].to_s
        headers['X-RateLimit-Reset'] = (Time.now.to_i + 60).to_s
      end

      # Daily quota headers
      if config[:daily_quota]
        headers['X-DailyQuota-Limit'] = config[:daily_quota].to_s
        headers['X-DailyQuota-Remaining'] = results[:checks][:daily_quota][:remaining].to_s
        headers['X-DailyQuota-Reset'] = tomorrow_timestamp.to_s
      else
        headers['X-DailyQuota-Limit'] = 'unlimited'
        headers['X-DailyQuota-Remaining'] = 'unlimited'
      end

      # Concurrent headers
      if results[:checks][:concurrent]
        headers['X-Concurrent-Limit'] = config[:concurrent_requests].to_s
        headers['X-Concurrent-Current'] = results[:checks][:concurrent][:current].to_s
      end

      headers
    end

    private

    # Проверка rate limit (запросов в минуту)
    def check_rate_limit(client, config)
      key = "rate_limit:#{client.id}"
      window = 60  # секунд

      @redis_pool.with do |redis|
        current = redis.incr(key)
        redis.expire(key, window) if current == 1

        remaining = config[:requests_per_minute] - current

        {
          allowed: remaining >= 0,
          current: current,
          limit: config[:requests_per_minute],
          remaining: [remaining, 0].max,
          resets_in: redis.ttl(key)
        }
      end
    end

    # Проверка дневной квоты
    def check_daily_quota(client, config)
      today = Time.now.strftime('%Y-%m-%d')
      key = "daily_quota:#{client.id}:#{today}"

      @redis_pool.with do |redis|
        current = redis.incr(key)
        redis.expireat(key, tomorrow_timestamp) if current == 1

        remaining = config[:daily_quota] - current

        {
          allowed: remaining >= 0,
          used: current,
          limit: config[:daily_quota],
          remaining: [remaining, 0].max,
          resets_at: tomorrow_timestamp
        }
      end
    end

    # Проверка одновременных запросов
    def check_concurrent_limit(client, config)
      key = "concurrent:#{client.id}"

      @redis_pool.with do |redis|
        current = redis.incr(key)
        redis.expire(key, 60)  # TTL как защита от утечек

        if current > config[:concurrent_requests]
          redis.decr(key)  # Откатываем увеличение
          return {
            allowed: false,
            current: current - 1,
            limit: config[:concurrent_requests]
          }
        end

        {
          allowed: true,
          current: current,
          limit: config[:concurrent_requests]
        }
      end
    end

    def tomorrow_timestamp
      (Time.now + 86400).beginning_of_day.to_i
    end
  end
end

# Хелпер для Time если его нет
class Time
  def beginning_of_day
    Time.new(year, month, day, 0, 0, 0)
  end
end
