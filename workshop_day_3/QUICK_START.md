# Quick Start Guide

## Быстрый запуск за 5 минут

### 1. Запустите Redis

```bash
docker-compose up -d
```

Проверьте что Redis работает:
```bash
docker-compose ps
redis-cli ping  # Должен вернуть PONG
```

### 2. Установите зависимости

```bash
# опционально
rvm use 3.2.2@api_gateway_workshop_day3

bundle install
```

### 3. Запустите сервер

```bash
bundle exec rackup -p 4000
```

Сервер запустится на http://localhost:4000

### 4. Проверьте работоспособность

```bash
curl http://localhost:4000/health
```

Должен вернуть:
```json
{"status":"ok"}
```

### 5. Запустите демо

В другом терминале:

```bash
# Интерактивное меню
ruby scripts/demo.rb

# Или все демо подряд
ruby scripts/demo.rb all

# Или по отдельности
ruby scripts/demo.rb 1  # Multi-layer Cache
ruby scripts/demo.rb 2  # Tag-based Invalidation
ruby scripts/demo.rb 3  # Correlation IDs
ruby scripts/demo.rb 4  # Structured Logging
ruby scripts/demo.rb 5  # Metrics Collection
ruby scripts/demo.rb 6  # Full Request Flow
```

## Быстрые примеры

### Multi-layer Cache

```bash
# Первый запрос — cache MISS (смотрите консоль сервера)
curl http://localhost:4000/api/users/1

# Второй запрос — cache HIT (нет лога "Fetching...")
curl http://localhost:4000/api/users/1

# Статистика кэша
curl http://localhost:4000/cache/stats | jq
```

### Correlation IDs

```bash
# Смотрим заголовки в ответе
curl -v http://localhost:4000/api/users/1 2>&1 | grep -i "x-trace\|x-request"

# Передаём свой trace_id
curl -H "X-Trace-Id: my-trace-123" http://localhost:4000/api/orders
```

### Metrics

```bash
# Генерируем нагрузку
for i in {1..20}; do curl -s http://localhost:4000/api/users/$i > /dev/null; done

# Prometheus формат
curl http://localhost:4000/metrics

# JSON формат
curl -H "Accept: application/json" http://localhost:4000/metrics | jq
```

## Endpoints

| URL | Описание |
|-----|----------|
| `/health` | Health check |
| `/metrics` | Prometheus метрики |
| `/cache/stats` | Статистика кэша |
| `/api/users` | Список пользователей |
| `/api/users/:id` | Пользователь по ID |
| `/api/orders` | Список заказов |

## Troubleshooting

### Redis не подключается

```bash
docker-compose restart redis
redis-cli ping
```

### Порт 4000 занят

```bash
kill -9 $(lsof -ti:4000)
# или
bundle exec rackup -p 4001
```

## Структура для вебинара

1. **Multi-layer Cache** (`lib/cache/multi_layer.rb`)
   - L1 (memory) + L2 (Redis)
   - Stampede protection с locks
   - Cache warming

2. **Tagged Cache** (`lib/cache/tagged_cache.rb`)
   - Версионирование тегов
   - O(1) инвалидация
   - Middleware интеграция

3. **Correlation** (`lib/observability/correlation.rb`)
   - trace_id, request_id, span_id
   - RequestStore для per-request storage
   - Header propagation

4. **Structured Logger** (`lib/observability/structured_logger.rb`)
   - JSON формат
   - Автоматический correlation context
   - RequestLoggerMiddleware

5. **Metrics** (`lib/observability/metrics.rb`)
   - Counters, Gauges, Histograms
   - Percentiles (p50, p95, p99)
   - Prometheus endpoint

Enjoy!
