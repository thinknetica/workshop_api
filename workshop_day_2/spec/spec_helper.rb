ENV['RACK_ENV'] = 'test'
ENV['JWT_ACCESS_SECRET'] = 'test_access_secret'
ENV['JWT_REFRESH_SECRET'] = 'test_refresh_secret'
ENV['REDIS_URL'] = 'redis://localhost:6379/15'  # Используем отдельную БД для тестов

require 'rack/test'
require 'rspec'
require 'mock_redis'

# Отключаем Rack::Attack в тестах
require 'rack/attack'
Rack::Attack.enabled = false

RSpec.configure do |config|
  config.include Rack::Test::Methods

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Очищаем данные между тестами
  config.before(:each) do
    # Очищаем модели
    User.class_variable_set(:@@users, {})
    Client.class_variable_set(:@@clients, {})
    ApiKey.class_variable_set(:@@api_keys, [])

    # Очищаем Redis (если используем реальный в тестах)
    if defined?($redis) && $redis
      $redis.flushdb rescue nil
    end
  end
end
