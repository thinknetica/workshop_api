# frozen_string_literal: true

require 'bundler/setup'
require 'request_store'
require 'connection_pool'
require 'redis'
require 'oj'

# Configure Oj for proper JSON output
Oj.default_options = { mode: :compat }

# Load all our modules
require_relative 'lib/cache/multi_layer'
require_relative 'lib/cache/tagged_cache'
require_relative 'lib/observability/correlation'
require_relative 'lib/observability/structured_logger'
require_relative 'lib/observability/metrics'

# Initialize components
REDIS_POOL = ConnectionPool.new(size: 10) { Redis.new }
LOGGER = Observability::StructuredLogger.new(output: $stdout, level: :info)
METRICS = Observability::MetricsCollector.new(prefix: 'api_gateway')
CACHE = Cache::StampedeSafeMultiLayer.new(REDIS_POOL, l1_max_size: 1000)
TAGGED_CACHE = Cache::TaggedCache.new(REDIS_POOL)

# Middleware stack (order matters!)
use RequestStore::Middleware

# Metrics endpoint (before other middleware to not affect metrics)
use Observability::MetricsEndpoint, metrics: METRICS, path: '/metrics'

# Correlation IDs
use Observability::CorrelationMiddleware

# Metrics collection
use Observability::MetricsMiddleware, metrics: METRICS

# Request logging
use Observability::RequestLoggerMiddleware, logger: LOGGER

# Health check
map '/health' do
  run proc { |env|
    [200, { 'content-type' => 'application/json' }, ['{"status":"ok"}']]
  }
end

# Demo API endpoints
map '/api/users' do
  run proc { |env|
    path = env['PATH_INFO']

    if match = path.match(%r{^/(\d+)$})
      user_id = match[1]

      # Используем кэш с тегами
      user = TAGGED_CACHE.fetch("user:#{user_id}", tags: ['users', "user:#{user_id}"]) do
        LOGGER.info("Fetching user from database", user_id: user_id)
        { id: user_id.to_i, name: "User #{user_id}", email: "user#{user_id}@example.com" }
      end

      [200, { 'content-type' => 'application/json' }, [Oj.dump(user)]]
    else
      # Список пользователей
      users = TAGGED_CACHE.fetch("users:list", tags: ['users']) do
        LOGGER.info("Fetching users list from database")
        (1..10).map { |i| { id: i, name: "User #{i}" } }
      end

      [200, { 'content-type' => 'application/json' }, [Oj.dump(users)]]
    end
  }
end

map '/api/orders' do
  run proc { |env|
    orders = CACHE.fetch("orders:recent", expires_in: 60) do
      LOGGER.info("Fetching orders from database")
      [
        { id: 1, total: 99.99, status: 'completed' },
        { id: 2, total: 149.99, status: 'pending' }
      ]
    end

    [200, { 'content-type' => 'application/json' }, [Oj.dump(orders)]]
  }
end

# Cache stats endpoint
map '/cache/stats' do
  run proc { |env|
    stats = CACHE.stats
    [200, { 'content-type' => 'application/json' }, [Oj.dump(stats)]]
  }
end

# Default handler
run proc { |env|
  [200, { 'content-type' => 'application/json' }, ['{"message":"Hello from API Gateway Day 3"}']]
}
