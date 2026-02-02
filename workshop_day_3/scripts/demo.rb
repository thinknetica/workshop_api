#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

BASE_URL = 'http://localhost:4000'

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

    resp_body = begin
      JSON.parse(response.body)
    rescue
      response.body
    end

    {
      status: response.code.to_i,
      headers: response.to_hash,
      body: resp_body
    }
  end
end

def print_header(title)
  puts "\n\n"
  puts "╔" + "═" * 78 + "╗"
  puts "║" + "  #{title}".ljust(78) + "║"
  puts "╚" + "═" * 78 + "╝"
end

def print_response(title, response, show_body: true)
  puts "\n" + "─" * 80
  puts "  #{title}"
  puts "─" * 80
  puts "Status: #{response[:status]}"

  # Correlation headers
  correlation_headers = %w[x-trace-id x-request-id]
  found_headers = response[:headers].select { |k, _| correlation_headers.include?(k.downcase) }
  unless found_headers.empty?
    puts "\nCorrelation Headers:"
    found_headers.each { |k, v| puts "  #{k}: #{v.first}" }
  end

  if show_body
    puts "\nBody:"
    if response[:body].is_a?(Hash) || response[:body].is_a?(Array)
      puts JSON.pretty_generate(response[:body])
    else
      puts response[:body]
    end
  end
end

def print_metrics(metrics_text)
  puts "\n" + "─" * 80
  puts "  Prometheus Metrics"
  puts "─" * 80

  lines = metrics_text.split("\n")

  # Группируем по типу метрик
  requests = lines.select { |l| l.include?('requests_total') }
  duration = lines.select { |l| l.include?('request_duration') }
  errors = lines.select { |l| l.include?('errors_total') }

  unless requests.empty?
    puts "\n📊 Request Counts:"
    requests.each { |l| puts "  #{l}" }
  end

  unless duration.empty?
    puts "\n⏱️  Latency (ms):"
    duration.each { |l| puts "  #{l}" }
  end

  unless errors.empty?
    puts "\n❌ Errors:"
    errors.each { |l| puts "  #{l}" }
  end

  puts "\n(Полный вывод: curl http://localhost:4000/metrics)"
end

# ═══════════════════════════════════════════════════════════════════════════════
# DEMO 1: Multi-layer Cache
# ═══════════════════════════════════════════════════════════════════════════════

def demo_multi_layer_cache
  print_header "ДЕМО 1: Multi-layer Cache (L1 Memory + L2 Redis)"

  client = ApiClient.new(BASE_URL)

  puts "\n📝 Объяснение:"
  puts "   L1 = In-memory кэш (быстрый, per-process)"
  puts "   L2 = Redis (shared между процессами)"
  puts "   При первом запросе: MISS → данные из 'БД' → сохраняем в L1 и L2"
  puts "   При повторном: HIT из L1 (мгновенно, без Redis)"

  # Очищаем кэш перед демо (делаем запрос к новому user id)
  random_id = rand(1000..9999)

  puts "\n" + "─" * 40
  puts "Запрос 1: GET /api/users/#{random_id} (первый раз — cache MISS)"
  puts "─" * 40

  response1 = client.get("/api/users/#{random_id}")
  print_response("Первый запрос (MISS)", response1)
  puts "\n💡 Смотрите консоль сервера — там будет лог 'Fetching user from database'"

  sleep 1

  puts "\n" + "─" * 40
  puts "Запрос 2: GET /api/users/#{random_id} (повторный — cache HIT)"
  puts "─" * 40

  response2 = client.get("/api/users/#{random_id}")
  print_response("Второй запрос (HIT)", response2)
  puts "\n💡 В консоли сервера НЕ будет лога 'Fetching...' — данные из кэша"

  sleep 1

  # Показываем статистику кэша
  puts "\n" + "─" * 40
  puts "Статистика кэша: GET /cache/stats"
  puts "─" * 40

  stats = client.get('/cache/stats')
  print_response("Cache Stats", stats)

  puts "\n📊 Интерпретация:"
  if stats[:body].is_a?(Hash)
    puts "   L1 hits: #{stats[:body]['l1_hits']} (из памяти процесса)"
    puts "   L2 hits: #{stats[:body]['l2_hits']} (из Redis)"
    puts "   Misses: #{stats[:body]['misses']} (пришлось идти в 'БД')"
    puts "   Hit rate: #{stats[:body]['hit_rate']}%"
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# DEMO 2: Tag-based Cache Invalidation
# ═══════════════════════════════════════════════════════════════════════════════

def demo_tagged_cache
  print_header "ДЕМО 2: Tag-based Cache Invalidation"

  client = ApiClient.new(BASE_URL)

  puts "\n📝 Объяснение:"
  puts "   Каждый закэшированный объект помечен тегами"
  puts "   user:123 помечен тегами ['users', 'user:123']"
  puts "   При инвалидации тега — все связанные записи становятся невалидными"
  puts "   Инвалидация = O(1), просто инкремент версии тега"

  puts "\n" + "─" * 40
  puts "Шаг 1: Загружаем список пользователей"
  puts "─" * 40

  response1 = client.get('/api/users')
  print_response("GET /api/users", response1, show_body: true)

  sleep 1

  puts "\n" + "─" * 40
  puts "Шаг 2: Загружаем конкретного пользователя"
  puts "─" * 40

  response2 = client.get('/api/users/5')
  print_response("GET /api/users/5", response2)

  sleep 1

  puts "\n" + "─" * 40
  puts "Шаг 3: Повторные запросы (из кэша)"
  puts "─" * 40

  start = Time.now
  5.times { client.get('/api/users/5') }
  elapsed = ((Time.now - start) * 1000).round(2)

  puts "✅ 5 запросов выполнено за #{elapsed}ms (из кэша)"
  puts "💡 Без кэша каждый запрос шёл бы в БД"

  stats = client.get('/cache/stats')
  puts "\n📊 Cache stats после запросов:"
  puts "   L1 hits: #{stats[:body]['l1_hits']}"
  puts "   Hit rate: #{stats[:body]['hit_rate']}%"
end

# ═══════════════════════════════════════════════════════════════════════════════
# DEMO 3: Correlation IDs & Distributed Tracing
# ═══════════════════════════════════════════════════════════════════════════════

def demo_correlation
  print_header "ДЕМО 3: Correlation IDs (Distributed Tracing)"

  client = ApiClient.new(BASE_URL)

  puts "\n📝 Объяснение:"
  puts "   trace_id — уникальный ID цепочки запросов (UUID)"
  puts "   request_id — ID конкретного запроса (hex)"
  puts "   span_id — ID текущего 'участка' обработки"
  puts "   Все логи содержат эти ID → можно найти все логи одного запроса"

  puts "\n" + "─" * 40
  puts "Запрос 1: Без передачи trace_id (генерируется новый)"
  puts "─" * 40

  response1 = client.get('/api/users/1')
  trace_id_1 = response1[:headers]['x-trace-id']&.first
  request_id_1 = response1[:headers]['x-request-id']&.first

  puts "Status: #{response1[:status]}"
  puts "\n🔍 Correlation IDs в ответе:"
  puts "   X-Trace-Id: #{trace_id_1}"
  puts "   X-Request-Id: #{request_id_1}"
  puts "\n💡 Эти ID есть во всех логах этого запроса (смотрите консоль сервера)"

  sleep 1

  puts "\n" + "─" * 40
  puts "Запрос 2: Передаём свой trace_id (как будто от другого сервиса)"
  puts "─" * 40

  my_trace_id = "my-custom-trace-#{rand(1000)}"
  response2 = client.get('/api/orders', headers: { 'X-Trace-Id' => my_trace_id })
  returned_trace_id = response2[:headers]['x-trace-id']&.first

  puts "Status: #{response2[:status]}"
  puts "\n🔍 Переданный trace_id: #{my_trace_id}"
  puts "   Возвращённый trace_id: #{returned_trace_id}"
  puts "   Совпадают: #{my_trace_id == returned_trace_id ? '✅ Да' : '❌ Нет'}"
  puts "\n💡 Trace propagation позволяет отследить запрос через все микросервисы"

  sleep 1

  puts "\n" + "─" * 40
  puts "Запрос 3: Несколько запросов — разные request_id, можно группировать по trace"
  puts "─" * 40

  common_trace = "batch-trace-#{rand(1000)}"
  request_ids = []

  3.times do |i|
    resp = client.get("/api/users/#{i + 1}", headers: { 'X-Trace-Id' => common_trace })
    request_ids << resp[:headers]['x-request-id']&.first
  end

  puts "Общий trace_id: #{common_trace}"
  puts "Request IDs:"
  request_ids.each_with_index { |id, i| puts "  #{i + 1}. #{id}" }
  puts "\n💡 В ELK/Datadog можно найти все 3 запроса по одному trace_id"
end

# ═══════════════════════════════════════════════════════════════════════════════
# DEMO 4: Structured Logging
# ═══════════════════════════════════════════════════════════════════════════════

def demo_structured_logging
  print_header "ДЕМО 4: Structured Logging (JSON)"

  client = ApiClient.new(BASE_URL)

  puts "\n📝 Объяснение:"
  puts "   Все логи в формате JSON (не текст)"
  puts "   Каждый лог содержит: timestamp, level, message, trace_id, ..."
  puts "   Легко парсить, фильтровать, агрегировать в ELK/Datadog/Splunk"

  puts "\n" + "─" * 40
  puts "Делаем несколько запросов разных типов..."
  puts "─" * 40

  # Успешный запрос
  client.get('/api/users/1')
  puts "✅ GET /api/users/1 — успешный запрос"

  # Ещё запросы для разнообразия логов
  client.get('/api/orders')
  puts "✅ GET /api/orders — успешный запрос"

  client.get('/health')
  puts "✅ GET /health — health check"

  puts "\n💡 Смотрите консоль сервера — там JSON логи вида:"
  puts '   {"timestamp":"2024-01-26T10:30:15.123Z","level":"INFO","message":"HTTP Request",'
  puts '    "trace_id":"abc-123","method":"GET","path":"/api/users/1","status":200,"duration_ms":12.34}'

  puts "\n📊 Преимущества JSON логов:"
  puts "   • Можно фильтровать: level=ERROR, status>=500"
  puts "   • Можно агрегировать: AVG(duration_ms) GROUP BY path"
  puts "   • Можно алертить: COUNT(status=500) > 10 за минуту"
end

# ═══════════════════════════════════════════════════════════════════════════════
# DEMO 5: Metrics Collection (Prometheus)
# ═══════════════════════════════════════════════════════════════════════════════

def demo_metrics
  print_header "ДЕМО 5: Metrics Collection (Prometheus format)"

  client = ApiClient.new(BASE_URL)

  puts "\n📝 Объяснение:"
  puts "   Три типа метрик: Counters, Gauges, Histograms"
  puts "   Counter — только растёт (requests_total)"
  puts "   Gauge — текущее значение (active_connections)"
  puts "   Histogram — распределение (request_duration_ms с percentiles)"

  puts "\n" + "─" * 40
  puts "Шаг 1: Генерируем нагрузку (20 запросов)"
  puts "─" * 40

  20.times do |i|
    path = ['/api/users/1', '/api/users/2', '/api/orders', '/health'].sample
    client.get(path)
    print "."
  end
  puts " Done!"

  sleep 1

  puts "\n" + "─" * 40
  puts "Шаг 2: Смотрим метрики GET /metrics"
  puts "─" * 40

  response = client.get('/metrics')

  if response[:status] == 200 && response[:body].is_a?(String)
    print_metrics(response[:body])
  else
    puts "Metrics response:"
    puts response[:body]
  end

  sleep 1

  puts "\n" + "─" * 40
  puts "Шаг 3: Метрики в JSON формате"
  puts "─" * 40

  response_json = client.get('/metrics', headers: { 'Accept' => 'application/json' })

  if response_json[:body].is_a?(Hash)
    puts "\nCounters:"
    response_json[:body]['counters']&.each do |key, value|
      puts "  #{key}: #{value}"
    end

    puts "\nHistograms (latency):"
    response_json[:body]['histograms']&.each do |key, stats|
      next unless key.include?('duration')
      puts "  #{key}:"
      puts "    count: #{stats['count']}, p50: #{stats['p50']}ms, p95: #{stats['p95']}ms, p99: #{stats['p99']}ms"
    end
  end

  puts "\n💡 Prometheus scraper запрашивает /metrics каждые 15-30 сек"
  puts "   Данные визуализируются в Grafana"
end

# ═══════════════════════════════════════════════════════════════════════════════
# DEMO 6: Full Request Flow
# ═══════════════════════════════════════════════════════════════════════════════

def demo_full_flow
  print_header "ДЕМО 6: Полный путь запроса через все middleware"

  client = ApiClient.new(BASE_URL)

  puts "\n📝 Порядок middleware (сверху вниз на входе, снизу вверх на выходе):"
  puts "   1. RequestStore::Middleware — инициализация per-request storage"
  puts "   2. MetricsEndpoint — перехват /metrics"
  puts "   3. CorrelationMiddleware — генерация trace_id, span_id"
  puts "   4. MetricsMiddleware — сбор метрик запроса"
  puts "   5. RequestLoggerMiddleware — JSON логирование"
  puts "   6. Application — бизнес-логика + кэширование"

  puts "\n" + "─" * 40
  puts "Один запрос проходит через всё:"
  puts "─" * 40

  trace_id = "demo-flow-#{Time.now.to_i}"
  response = client.get('/api/users/42', headers: { 'X-Trace-Id' => trace_id })

  puts "\n📥 Request:"
  puts "   GET /api/users/42"
  puts "   X-Trace-Id: #{trace_id}"

  puts "\n📤 Response:"
  puts "   Status: #{response[:status]}"
  puts "   X-Trace-Id: #{response[:headers]['x-trace-id']&.first}"
  puts "   X-Request-Id: #{response[:headers]['x-request-id']&.first}"
  puts "   Body: #{response[:body]}"

  puts "\n📊 Что произошло внутри:"
  puts "   1. CorrelationMiddleware сохранил trace_id в RequestStore"
  puts "   2. MetricsMiddleware засёк время начала"
  puts "   3. RequestLoggerMiddleware подготовил request_info"
  puts "   4. TaggedCache проверил кэш по ключу 'user:42'"
  puts "   5. При MISS — 'запрос в БД', результат в кэш"
  puts "   6. RequestLoggerMiddleware записал JSON лог"
  puts "   7. MetricsMiddleware записал метрики (counter, histogram)"
  puts "   8. CorrelationMiddleware добавил headers в response"

  puts "\n💡 Найдите этот запрос в консоли сервера по trace_id: #{trace_id}"
end

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

def check_server
  client = ApiClient.new(BASE_URL)
  response = client.get('/health')

  unless response[:status] == 200
    puts "❌ Сервер не запущен на #{BASE_URL}"
    puts "   Запустите: bundle exec rackup -p 4000"
    exit 1
  end

  puts "✅ Сервер запущен и готов (#{BASE_URL})"
rescue => e
  puts "❌ Не удалось подключиться к серверу: #{e.message}"
  puts "   Запустите: bundle exec rackup -p 4000"
  exit 1
end

def show_menu
  puts "\n" + "═" * 60
  puts "  Workshop Day 3: Caching, Observability, Metrics"
  puts "═" * 60
  puts "\nВыберите демо:"
  puts "  1 - Multi-layer Cache (L1 + L2)"
  puts "  2 - Tag-based Cache Invalidation"
  puts "  3 - Correlation IDs (Distributed Tracing)"
  puts "  4 - Structured Logging (JSON)"
  puts "  5 - Metrics Collection (Prometheus)"
  puts "  6 - Full Request Flow (все middleware)"
  puts "  all - Все демо подряд"
  puts "  q - Выход"
  print "\nВведите номер: "
end

# Entry point
check_server

if ARGV.empty?
  loop do
    show_menu
    choice = gets&.chomp

    case choice
    when '1' then demo_multi_layer_cache
    when '2' then demo_tagged_cache
    when '3' then demo_correlation
    when '4' then demo_structured_logging
    when '5' then demo_metrics
    when '6' then demo_full_flow
    when 'all'
      demo_multi_layer_cache
      demo_tagged_cache
      demo_correlation
      demo_structured_logging
      demo_metrics
      demo_full_flow
    when 'q', nil then break
    else puts "❌ Неверный выбор"
    end
  end
else
  case ARGV[0]
  when '1' then demo_multi_layer_cache
  when '2' then demo_tagged_cache
  when '3' then demo_correlation
  when '4' then demo_structured_logging
  when '5' then demo_metrics
  when '6' then demo_full_flow
  when 'all'
    demo_multi_layer_cache
    demo_tagged_cache
    demo_correlation
    demo_structured_logging
    demo_metrics
    demo_full_flow
  else
    puts "❌ Неверный выбор: #{ARGV[0]}"
    puts "   Допустимые: 1, 2, 3, 4, 5, 6, all"
    exit 1
  end
end

puts "\n\n✅ Демонстрация завершена!"
