#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'uri'

BASE_URL = 'http://localhost:9292'

class ApiClient
  def initialize(base_url)
    @base_url = base_url
  end

  def get(path, headers: {})
    uri = URI("#{@base_url}#{path}")
    request = Net::HTTP::Get.new(uri)
    headers.each { |k, v| request[k] = v }

    response = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(request)
    end

    body = begin
      JSON.parse(response.body)
    rescue
      response.body
    end

    {
      status: response.code.to_i,
      headers: response.to_hash,
      body: body
    }
  end

  def post(path, body: {}, headers: {})
    uri = URI("#{@base_url}#{path}")
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    headers.each { |k, v| request[k] = v }
    request.body = body.to_json

    response = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(request)
    end

    body = begin
      JSON.parse(response.body)
    rescue
      response.body
    end

    {
      status: response.code.to_i,
      headers: response.to_hash,
      body: body
    }
  end
end

def print_response(title, response)
  puts "\n" + "=" * 80
  puts "  #{title}"
  puts "=" * 80
  puts "Status: #{response[:status]}"

  # Печатаем rate limit headers если есть
  rate_headers = response[:headers].select { |k, _| k.downcase.start_with?('x-ratelimit', 'x-dailyquota', 'x-concurrent') }
  unless rate_headers.empty?
    puts "\nRate Limit Headers:"
    rate_headers.each { |k, v| puts "  #{k}: #{v.first}" }
  end

  puts "\nBody:"
  puts JSON.pretty_generate(response[:body]) rescue response[:body]
  puts "=" * 80
end

def demo_jwt_auth
  puts "\n\n"
  puts "╔" + "═" * 78 + "╗"
  puts "║" + "  ДЕМО 1: JWT Authentication & Refresh Token Rotation".ljust(78) + "║"
  puts "╚" + "═" * 78 + "╝"

  client = ApiClient.new(BASE_URL)

  # 1. Login
  response = client.post('/api/auth/login', body: {
    email: 'business@example.com',
    password: 'password'
  })
  print_response("1. Login (получаем access & refresh токены)", response)

  tokens = response[:body]['tokens']
  access_token = tokens['access_token']
  refresh_token = tokens['refresh_token']

  sleep 1

  # 2. Refresh token (первый раз)
  response = client.post('/api/auth/refresh', body: {
    refresh_token: refresh_token
  })
  print_response("2. Refresh tokens (первый раз - успех)", response)

  new_tokens = response[:body]['tokens']
  new_refresh_token = new_tokens['refresh_token']

  sleep 1

  # 3. Пытаемся использовать старый refresh token
  response = client.post('/api/auth/refresh', body: {
    refresh_token: refresh_token  # Старый токен!
  })
  print_response("3. Попытка использовать старый refresh token (ОТКЛОНЕНО)", response)

  sleep 1

  # 4. Используем новый refresh token
  response = client.post('/api/auth/refresh', body: {
    refresh_token: new_refresh_token
  })
  print_response("4. Используем новый refresh token (успех)", response)
end

def demo_api_key_rotation
  puts "\n\n"
  puts "╔" + "═" * 78 + "╗"
  puts "║" + "  ДЕМО 2: API Key Generation & Rotation with Grace Period".ljust(78) + "║"
  puts "╚" + "═" * 78 + "╝"

  client = ApiClient.new(BASE_URL)

  # 1. Генерируем первый ключ
  response = client.post('/api/keys/generate', body: { client_id: 3 })
  print_response("1. Генерация первого API ключа", response)

  first_key = response[:body]['api_key']['raw_key']

  sleep 1

  # 2. Тестируем первый ключ
  response = client.get('/api/orders', headers: { 'X-API-Key' => first_key })
  print_response("2. Тест первого ключа (работает)", response)

  sleep 1

  # 3. Ротация ключа
  response = client.post('/api/keys/rotate/3')
  print_response("3. Ротация ключа (grace period начался)", response)

  second_key = response[:body]['rotation']['new_key']['raw_key']

  sleep 1

  # 4. Старый ключ всё ещё работает (grace period)
  response = client.get('/api/orders', headers: { 'X-API-Key' => first_key })
  print_response("4. Старый ключ работает (grace period)", response)

  sleep 1

  # 5. Новый ключ тоже работает
  response = client.get('/api/orders', headers: { 'X-API-Key' => second_key })
  print_response("5. Новый ключ работает", response)

  sleep 1

  # 6. Список всех ключей клиента
  response = client.get('/api/keys/list/3')
  print_response("6. Список ключей клиента (оба активны)", response)
end

def demo_rate_limiting
  puts "\n\n"
  puts "╔" + "═" * 78 + "╗"
  puts "║" + "  ДЕМО 3: Tiered Rate Limiting (Free vs Business tier)".ljust(78) + "║"
  puts "╚" + "═" * 78 + "╝"

  client = ApiClient.new(BASE_URL)

  # Генерируем ключи для free и business тиров
  free_response = client.post('/api/keys/generate', body: { client_id: 1 })
  free_key = free_response[:body]['api_key']['raw_key']

  business_response = client.post('/api/keys/generate', body: { client_id: 3 })
  business_key = business_response[:body]['api_key']['raw_key']

  puts "\n--- FREE TIER (10 req/min) ---"

  # Делаем 12 запросов с free ключом
  12.times do |i|
    response = client.get('/api/demo/rate-limit-test', headers: { 'X-API-Key' => free_key })

    remaining = response[:headers]['x-ratelimit-remaining']&.first
    status_icon = response[:status] == 200 ? "✅" : "❌"

    puts "#{status_icon} Request #{i + 1}/12: Status #{response[:status]} | Remaining: #{remaining || 'N/A'}"
  end

  sleep 2

  puts "\n--- BUSINESS TIER (500 req/min) ---"

  # Делаем 12 запросов с business ключом
  12.times do |i|
    response = client.get('/api/demo/rate-limit-test', headers: { 'X-API-Key' => business_key })

    remaining = response[:headers]['x-ratelimit-remaining']&.first
    status_icon = response[:status] == 200 ? "✅" : "❌"

    puts "#{status_icon} Request #{i + 1}/12: Status #{response[:status]} | Remaining: #{remaining || 'N/A'}"
  end
end

def demo_rack_attack
  puts "\n\n"
  puts "╔" + "═" * 78 + "╗"
  puts "║" + "  ДЕМО 4: Rack::Attack - Login Brute Force Protection".ljust(78) + "║"
  puts "╚" + "═" * 78 + "╝"

  client = ApiClient.new(BASE_URL)

  puts "\nПопытки входа с неверным паролем (лимит: 5 попыток за 20 секунд):"

  7.times do |i|
    response = client.post('/api/auth/login', body: {
      email: 'business@example.com',
      password: 'wrong_password'
    })

    status_icon = response[:status] == 401 ? "🔒" : (response[:status] == 429 ? "🚫" : "❌")
    puts "#{status_icon} Attempt #{i + 1}/7: Status #{response[:status]} - #{response[:body]['error'] || response[:body]['message']}"

    sleep 0.5
  end
end

# Проверка, что сервер запущен
begin
  client = ApiClient.new(BASE_URL)
  response = client.get('/health')

  unless response[:status] == 200
    puts "❌ Сервер не запущен на #{BASE_URL}"
    puts "   Запустите: bundle exec rackup -p 9292"
    exit 1
  end

  puts "✅ Сервер запущен и готов"
rescue => e
  puts "❌ Не удалось подключиться к серверу: #{e.message}"
  puts "   Запустите: bundle exec rackup -p 9292"
  exit 1
end

# Запуск демо
if ARGV.empty?
  puts "\nВыберите демо:"
  puts "  1 - JWT Authentication & Refresh"
  puts "  2 - API Key Rotation"
  puts "  3 - Tiered Rate Limiting"
  puts "  4 - Rack::Attack Brute Force Protection"
  puts "  all - Все демо подряд"
  print "\nВведите номер: "
  choice = gets.chomp
else
  choice = ARGV[0]
end

case choice
when '1'
  demo_jwt_auth
when '2'
  demo_api_key_rotation
when '3'
  demo_rate_limiting
when '4'
  demo_rack_attack
when 'all'
  demo_jwt_auth
  demo_api_key_rotation
  demo_rate_limiting
  demo_rack_attack
else
  puts "❌ Неверный выбор"
  exit 1
end

puts "\n\n✅ Демонстрация завершена!"
