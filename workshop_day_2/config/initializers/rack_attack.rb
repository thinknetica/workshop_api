require 'rack/attack'
require 'active_support/notifications'

class Rack::Attack
  ### Конфигурация ###

  # Используем Redis для хранения счётчиков
  Rack::Attack.cache.store = Rack::Attack::StoreProxy::RedisStoreProxy.new($redis)

  ### Safelist ###

  # Пропускаем внутренние сервисы без лимитов
  safelist('allow-localhost') do |req|
    req.ip == '127.0.0.1' || req.ip == '::1'
  end

  # Пропускаем healthcheck endpoints
  safelist('allow-healthcheck') do |req|
    req.path == '/health' || req.path == '/ping'
  end

  ### Blocklist ###

  # Блокируем по IP из Redis (динамический blocklist)
  blocklist('block-banned-ips') do |req|
    $redis.sismember('banned_ips', req.ip)
  end

  ### Throttles ###

  # 1. Общий лимит по IP (защита от DDoS)
  throttle('req/ip', limit: 100, period: 60) do |req|  # 60 секунд = 1 минута
    req.ip unless req.path.start_with?('/assets', '/favicon')
  end

  # 2. Rate limit для API по API ключу
  throttle('api/key', limit: 1000, period: 3600) do |req|  # 3600 секунд = 1 час
    if req.path.start_with?('/api/')
      req.env['HTTP_X_API_KEY'] || req.get_header('HTTP_AUTHORIZATION')&.sub('Bearer ', '')
    end
  end

  # 3. Rate limit для login (защита от brute-force)
  throttle('logins/ip', limit: 5, period: 20) do |req|  # 20 секунд
    if req.path == '/api/auth/login' && req.post?
      req.ip
    end
  end

  # 4. Rate limit по email (защита от credential stuffing)
  throttle('logins/email', limit: 10, period: 600) do |req|  # 600 секунд = 10 минут
    if req.path == '/api/auth/login' && req.post?
      # Парсим email из body
      begin
        body = JSON.parse(req.body.read)
        req.body.rewind  # Важно! Иначе контроллер не получит body
        body['email']&.downcase
      rescue JSON::ParserError
        nil
      end
    end
  end

  # 5. Rate limit для регистрации по IP
  throttle('signups/ip', limit: 3, period: 3600) do |req|  # 3600 секунд = 1 час
    if req.path == '/api/auth/register' && req.post?
      req.ip
    end
  end

  ### Кастомные ответы ###

  # Ответ при превышении rate limit
  self.throttled_responder = lambda do |request|
    match_data = request.env['rack.attack.match_data']
    now = Time.now.to_i

    retry_after = match_data[:period] - (now % match_data[:period])

    headers = {
      'Content-Type' => 'application/json',
      'Retry-After' => retry_after.to_s,
      'X-RateLimit-Limit' => match_data[:limit].to_s,
      'X-RateLimit-Remaining' => '0',
      'X-RateLimit-Reset' => (now + retry_after).to_s
    }

    body = {
      error: 'rate_limit_exceeded',
      message: 'Too many requests. Please try again later.',
      retry_after: retry_after,
      limit: match_data[:limit],
      period: match_data[:period]
    }

    [429, headers, [body.to_json]]
  end

  # Ответ при блокировке
  self.blocklisted_responder = lambda do |_request|
    [
      403,
      { 'Content-Type' => 'application/json' },
      [{ error: 'forbidden', message: 'Your IP has been blocked' }.to_json]
    ]
  end

  ### Уведомления (для мониторинга) ###

  # Логирование при срабатывании throttle
  ActiveSupport::Notifications.subscribe('throttle.rack_attack') do |_name, _start, _finish, _id, payload|
    req = payload[:request]

    puts "[RATE LIMIT] #{req.env['rack.attack.matched']} | IP: #{req.ip} | Path: #{req.path}"

    # Можно добавить отправку метрик в StatsD, DataDog и т.д.
    # StatsD.increment('rate_limit.triggered', tags: ["throttle:#{req.env['rack.attack.matched']}"])
  end

  # Алерт при блокировке
  ActiveSupport::Notifications.subscribe('blocklist.rack_attack') do |_name, _start, _finish, _id, payload|
    req = payload[:request]

    puts "[BLOCKED] IP: #{req.ip} | Path: #{req.path} | User-Agent: #{req.user_agent}"

    # Можно добавить отправку в Slack, PagerDuty и т.д.
    # SlackNotifier.alert("Blocked request from #{req.ip} to #{req.path}")
  end
end

# Вспомогательные методы для управления блокировками
module RackAttackHelpers
  def self.ban_ip(ip, reason: nil, duration: 24 * 60 * 60)
    $redis.sadd('banned_ips', ip)
    $redis.setex("ban_reason:#{ip}", duration, reason || 'Manual ban')
    $redis.expire("banned_ips", duration)
    puts "[BAN] Added #{ip} to blocklist. Reason: #{reason}"
  end

  def self.unban_ip(ip)
    $redis.srem('banned_ips', ip)
    $redis.del("ban_reason:#{ip}")
    puts "[UNBAN] Removed #{ip} from blocklist"
  end

  def self.banned_ips
    $redis.smembers('banned_ips')
  end

  def self.reset_limit(discriminator)
    # Сбросить лимит для конкретного ключа
    # Например: RackAttackHelpers.reset_limit("req/ip:192.168.1.1")
    Rack::Attack.cache.delete(discriminator)
  end
end
