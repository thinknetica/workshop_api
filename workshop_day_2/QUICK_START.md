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
bundle install
```

### 3. Запустите сервер

```bash
bundle exec rackup -p 9292
```

Сервер запустится на http://localhost:9292

### 4. Проверьте работоспособность

```bash
curl http://localhost:9292/health
```

Должен вернуть:
```json
{
  "status": "ok",
  "redis": "PONG"
}
```

### 5. Запустите демо

В другом терминале:

```bash
# Все демо подряд
ruby scripts/demo.rb all

# Или по отдельности
ruby scripts/demo.rb 1  # JWT Authentication
ruby scripts/demo.rb 2  # API Key Rotation
ruby scripts/demo.rb 3  # Tiered Rate Limiting
ruby scripts/demo.rb 4  # Rack::Attack Brute Force Protection
```

### 6. Запустите тесты

```bash
bundle exec rspec
```

## Готовые тестовые данные

При запуске сервера автоматически создаются:

### Пользователи (для JWT auth)

| Email | Password | Tier | Rate Limit |
|-------|----------|------|------------|
| free@example.com | password | free | 10/min |
| startup@example.com | password | startup | 100/min |
| business@example.com | password | business | 500/min |
| enterprise@example.com | password | enterprise | 2000/min |

### Клиенты (для API keys)

| ID | Name | Tier |
|----|------|------|
| 1 | Free Client | free |
| 2 | Startup Client | startup |
| 3 | Business Client | business |
| 4 | Enterprise Client | enterprise |

## Примеры запросов

### JWT Authentication

```bash
# Login
curl -X POST http://localhost:9292/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "business@example.com", "password": "password"}'
```

### API Key Management

```bash
# Сгенерировать ключ для Business клиента
curl -X POST http://localhost:9292/api/keys/generate \
  -H "Content-Type: application/json" \
  -d '{"client_id": 3}'

# Использовать ключ
curl http://localhost:9292/api/orders \
  -H "X-API-Key: sk_live_YOUR_KEY_HERE"
```

### Rate Limiting Test

```bash
# Сгенерировать ключ
API_KEY=$(curl -s -X POST http://localhost:9292/api/keys/generate \
  -H "Content-Type: application/json" \
  -d '{"client_id": 1}' | jq -r '.api_key.raw_key')

# Тест rate limiting (free tier: 10 req/min)
for i in {1..12}; do
  echo "Request $i:"
  curl -s -i http://localhost:9292/api/demo/rate-limit-test \
    -H "X-API-Key: $API_KEY" | grep -E "HTTP|X-RateLimit-Remaining"
done
```

## Troubleshooting

### Redis не подключается

```bash
# Проверить что контейнер запущен
docker-compose ps

# Рестарт Redis
docker-compose restart redis

# Логи Redis
docker-compose logs -f redis
```

### Порт 9292 занят

```bash
# Найти процесс
lsof -i :9292

# Убить процесс
kill -9 PID

# Или использовать другой порт
bundle exec rackup -p 9393
```

### Тесты падают

```bash
# Очистить Redis тестовую БД
redis-cli -n 15 FLUSHDB

# Рестарт Redis
docker-compose restart redis

# Запустить тесты заново
bundle exec rspec
```

## Полезные команды

```bash
# Очистить Redis
redis-cli FLUSHDB

# Остановить все
docker-compose down
pkill -f rackup

# Посмотреть все ключи в Redis
redis-cli KEYS "*"

# Мониторинг Redis
redis-cli MONITOR
```

## Структура для вебинара

1. **Rack::Attack** (config/initializers/rack_attack.rb)
   - Throttling по IP, API key, email
   - Safelist и Blocklist
   - Custom response headers

2. **Tiered Rate Limiting** (lib/rate_limiter/tiered_limiter.rb)
   - 4 тарифных плана
   - 3 типа лимитов: rate, quota, concurrent
   - Dynamic headers

3. **JWT Service** (lib/auth/jwt_service.rb)
   - Access & Refresh tokens
   - Token rotation
   - Reuse detection

4. **API Key Service** (lib/auth/api_key_service.rb)
   - Generation with bcrypt
   - Rotation with grace period
   - Revocation & audit

Enjoy! 🚀
