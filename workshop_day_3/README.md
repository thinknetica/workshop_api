# API Gateway Workshop - День 3

Практический проект для вебинара по Caching, Observability и Metrics.

## Темы

1. **Multi-layer Cache** — L1 (in-memory) + L2 (Redis) с защитой от stampede
2. **Tag-based Invalidation** — O(1) инвалидация через версии тегов
3. **Correlation IDs** — trace_id, request_id, span_id для distributed tracing
4. **Structured Logging** — JSON логи с автоматическим correlation context
5. **Metrics Collection** — Counters, Gauges, Histograms в формате Prometheus

## Требования

- Ruby 3.2.2
- Redis 7+
- Docker & Docker Compose

## Установка

1. **Перейти в директорию:**
   ```bash
   cd workshop_day_3
   ```

2. **Настроить RVM (если используется):**
   ```bash
   rvm use 3.2.2
   # Gemset создастся автоматически из .ruby-gemset
   ```

3. **Запустить Redis:**
   ```bash
   docker-compose up -d
   # Проверить статус
   docker-compose ps
   ```

4. **Установить зависимости:**
   ```bash
   bundle install
   ```

## Запуск

### Запуск сервера

```bash
bundle exec rackup -p 4000
```

Сервер будет доступен на `http://localhost:4000`

### Проверка работоспособности

```bash
curl http://localhost:4000/health
```

Должен вернуть:
```json
{"status":"ok"}
```

### Запуск демо-скриптов

```bash
# Интерактивное меню
ruby scripts/demo.rb

# Все демо подряд
ruby scripts/demo.rb all

# Или по отдельности:
ruby scripts/demo.rb 1  # Multi-layer Cache
ruby scripts/demo.rb 2  # Tag-based Invalidation
ruby scripts/demo.rb 3  # Correlation IDs
ruby scripts/demo.rb 4  # Structured Logging
ruby scripts/demo.rb 5  # Metrics Collection
ruby scripts/demo.rb 6  # Full Request Flow
```

## Структура проекта

```
workshop_day_3/
├── config.ru                           # Точка входа, сборка middleware
├── Gemfile
├── lib/
│   ├── cache/
│   │   ├── multi_layer.rb              # L1 + L2 кэш со stampede protection
│   │   └── tagged_cache.rb             # Кэш с O(1) инвалидацией по тегам
│   └── observability/
│       ├── correlation.rb              # trace_id, request_id, span_id
│       ├── structured_logger.rb        # JSON логгер + RequestLoggerMiddleware
│       └── metrics.rb                  # Counters, Gauges, Histograms + Prometheus
└── scripts/
    └── demo.rb                         # Демонстрационный скрипт
```

## API Endpoints

### Системные

| Endpoint | Описание |
|----------|----------|
| `GET /health` | Health check |
| `GET /metrics` | Prometheus метрики (text/plain) |
| `GET /metrics` + `Accept: application/json` | Метрики в JSON |
| `GET /cache/stats` | Статистика кэша (L1/L2 hits, misses, hit rate) |

### Demo API

| Endpoint | Описание |
|----------|----------|
| `GET /api/users` | Список пользователей (кэшируется с тегом `users`) |
| `GET /api/users/:id` | Пользователь по ID (теги: `users`, `user:ID`) |
| `GET /api/orders` | Список заказов (multi-layer кэш) |

## Примеры использования

### Multi-layer Cache

```bash
# Первый запрос — cache miss, данные "из БД"
curl http://localhost:4000/api/users/1

# Второй запрос — cache hit (L1, мгновенно)
curl http://localhost:4000/api/users/1

# Статистика кэша
curl http://localhost:4000/cache/stats
```

### Correlation IDs

```bash
# Запрос без trace_id — генерируется новый
curl -v http://localhost:4000/api/users/1 2>&1 | grep -i x-trace

# Запрос с trace_id — используется переданный
curl -v -H "X-Trace-Id: my-custom-trace-123" \
  http://localhost:4000/api/orders 2>&1 | grep -i x-trace
```

### Metrics

```bash
# Генерируем нагрузку
for i in {1..50}; do curl -s http://localhost:4000/api/users/$i > /dev/null; done

# Смотрим метрики (Prometheus формат)
curl http://localhost:4000/metrics

# Метрики в JSON
curl -H "Accept: application/json" http://localhost:4000/metrics | jq
```

## Архитектура

### Middleware Stack (порядок важен!)

```
Request →
  1. RequestStore::Middleware      # Per-request storage
  2. MetricsEndpoint               # /metrics endpoint (до сбора метрик!)
  3. CorrelationMiddleware         # Генерация trace_id, span_id
  4. MetricsMiddleware             # Сбор метрик запроса
  5. RequestLoggerMiddleware       # JSON логирование
  6. Application                   # Бизнес-логика + кэширование
← Response
```

### Multi-layer Cache

```
Request → L1 (Memory) → L2 (Redis) → Database
            ↓ hit         ↓ hit         ↓ miss
         Return        Promote       Generate
                       to L1         & Store
```

### Tag-based Invalidation

```
Write: user:123 → {value: {...}, tag_versions: {users: "5", user:123: "2"}}

Read:  1. Get current tag versions from Redis
       2. Compare with stored versions
       3. If mismatch → cache is stale → return nil

Invalidate: INCR tag_version:users  → O(1)!
```

## Ключевые концепции

### Зачем два слоя кэша?

- **L1 (Memory)**: ~0.001ms, но per-process (не shared)
- **L2 (Redis)**: ~0.5-2ms, shared между процессами

L1 разгружает Redis и даёт мгновенный ответ для hot keys.

### Зачем Stampede Protection?

При expire популярного ключа 100 процессов одновременно пойдут в БД.
Lock гарантирует, что только 1 процесс генерирует данные, остальные ждут.

### Зачем Tag-based Invalidation?

При обновлении пользователя нужно инвалидировать:
- `/api/users` (список)
- `/api/users/123` (конкретный)
- `/api/orders?user_id=123` (заказы пользователя)

Без тегов: нужно знать все ключи и удалять их (O(N)).
С тегами: `INCR tag_version:user:123` — одна команда (O(1)).

### Зачем Correlation IDs?

Запрос проходит через 5 микросервисов. Как найти все логи одного запроса?
По `trace_id`! Он передаётся в headers и добавляется во все логи.

### Зачем Structured Logging?

Текстовые логи: `[2024-01-26 10:30:15] INFO: User created id=123`
JSON логи: `{"timestamp":"...","level":"INFO","event":"user_created","user_id":123}`

JSON можно:
- Фильтровать: `level=ERROR AND user_id=123`
- Агрегировать: `COUNT(*) GROUP BY path`
- Алертить: `COUNT(status>=500) > 10 per minute`

## Полезные команды

```bash
# Запуск сервера
bundle exec rackup -p 4000

# Очистить Redis
redis-cli FLUSHDB

# Мониторинг Redis
redis-cli MONITOR

# Остановить Redis
docker-compose down

# Логи Redis
docker-compose logs -f redis
```

## Troubleshooting

### Redis не подключается

```bash
# Проверить что контейнер запущен
docker-compose ps

# Рестарт Redis
docker-compose restart redis

# Проверить подключение
redis-cli ping
```

### Порт 4000 занят

```bash
# Найти процесс
lsof -i :4000

# Убить
kill -9 $(lsof -ti:4000)

# Или использовать другой порт
bundle exec rackup -p 4001
```

## Для вебинара

### Порядок демонстрации

1. **Multi-layer Cache** (20 мин)
   - Показать `lib/cache/multi_layer.rb`
   - Демо: первый запрос (miss) vs повторный (hit)
   - Показать `/cache/stats`
   - Объяснить L1 vs L2, promotion, eviction

2. **Tag-based Invalidation** (20 мин)
   - Показать `lib/cache/tagged_cache.rb`
   - Объяснить версионирование тегов
   - Демо: запись → чтение → инвалидация → чтение

3. **Correlation & Logging** (20 мин)
   - Показать `lib/observability/correlation.rb`
   - Показать `lib/observability/structured_logger.rb`
   - Демо: запросы с разными trace_id
   - Показать JSON логи в консоли сервера

4. **Metrics** (20 мин)
   - Показать `lib/observability/metrics.rb`
   - Демо: нагрузка → `/metrics`
   - Объяснить counters, gauges, histograms
   - Показать percentiles (p50, p95, p99)

### Ключевые файлы для показа

| Файл | Что показать |
|------|--------------|
| `lib/cache/multi_layer.rb:55-84` | Метод `fetch` — логика L1 → L2 → generate |
| `lib/cache/multi_layer.rb:180-208` | `StampedeSafeMultiLayer.fetch` — lock protection |
| `lib/cache/tagged_cache.rb:28-46` | Метод `write` — сохранение с версиями тегов |
| `lib/cache/tagged_cache.rb:48-74` | Метод `read` — проверка версий |
| `lib/observability/correlation.rb:49-76` | `CorrelationMiddleware.call` |
| `lib/observability/metrics.rb:143-171` | `MetricsMiddleware.call` |
| `config.ru:26-39` | Порядок middleware |

## Ресурсы

**Гемы:**
- [connection_pool](https://github.com/mperham/connection_pool)
- [oj](https://github.com/ohler55/oj)
- [request_store](https://github.com/steveklabnik/request_store)
- [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby)

**Документация:**
- [Redis Caching](https://redis.io/solutions/caching/)
- [OpenTelemetry Ruby](https://opentelemetry.io/docs/instrumentation/ruby/)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/)

## Лицензия

MIT
