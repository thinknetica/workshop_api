# API Gateway Workshop - День 2

Практический проект для вебинара по API Gateway patterns.

## Темы

1. **Rate Limiting с Rack::Attack** - Защита от DDoS и brute-force атак
2. **Business Tiers** - Многоуровневые тарифные планы с разными лимитами
3. **JWT с Refresh Tokens** - Безопасная аутентификация с Token Rotation
4. **API Key Management** - Генерация, ротация и отзыв API ключей с grace period

## Требования

- Ruby 3.2.2
- Redis 7+
- Docker & Docker Compose

## Установка

1. **Клонировать репозиторий и перейти в директорию:**
   ```bash
   cd workshop_day_2
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

5. **Создать .env файл:**
   ```bash
   cp .env.example .env
   # Или использовать существующий .env
   ```

## Запуск

### Запуск сервера

```bash
bundle exec rackup -p 9292
# Или через rake
rake server
```

Сервер будет доступен на `http://localhost:9292`

### Проверка работоспособности

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

### Запуск демо-скриптов

```bash
# Все демо подряд
ruby scripts/demo.rb all

# Или по отдельности:
ruby scripts/demo.rb 1  # JWT Authentication
ruby scripts/demo.rb 2  # API Key Rotation
ruby scripts/demo.rb 3  # Tiered Rate Limiting
ruby scripts/demo.rb 4  # Rack::Attack Brute Force
```

### Запуск тестов

```bash
bundle exec rspec
# Или
rake spec
```

## Структура проекта

```
workshop_day_2/
├── app.rb                           # Главное Sinatra приложение
├── config.ru                        # Rack конфигурация
├── config/
│   └── initializers/
│       └── rack_attack.rb          # Конфигурация Rack::Attack
├── lib/
│   ├── models.rb                   # Упрощённые модели (User, Client, ApiKey)
│   ├── auth/
│   │   ├── jwt_service.rb          # JWT генерация и верификация
│   │   └── api_key_service.rb      # API Key management
│   ├── rate_limiter/
│   │   └── tiered_limiter.rb       # Тарифные планы и лимиты
│   └── middleware/
│       └── jwt_auth.rb             # JWT middleware
├── spec/
│   ├── spec_helper.rb
│   └── auth/
│       └── jwt_service_spec.rb     # Тесты JWT сервиса
└── scripts/
    └── demo.rb                      # Демонстрационный скрипт
```

## Тестовые данные

При старте сервера автоматически создаются тестовые пользователи:

| Email | Password | Tier | Rate Limit | Daily Quota |
|-------|----------|------|------------|-------------|
| free@example.com | password | free | 10/min | 1,000 |
| startup@example.com | password | startup | 100/min | 50,000 |
| business@example.com | password | business | 500/min | 500,000 |
| enterprise@example.com | password | enterprise | 2000/min | Unlimited |

## API Endpoints

### Публичные

- `GET /` - Информация об API
- `GET /health` - Healthcheck

### Аутентификация (JWT)

- `POST /api/auth/login` - Вход (получение токенов)
- `POST /api/auth/refresh` - Обновление токенов
- `POST /api/auth/logout` - Выход (отзыв refresh токенов)

### API Key Management

- `POST /api/keys/generate` - Генерация нового ключа
- `POST /api/keys/rotate/:client_id` - Ротация ключа
- `POST /api/keys/revoke/:key_id` - Отзыв ключа
- `GET /api/keys/list/:client_id` - Список ключей клиента

### Protected API (требуется API ключ)

- `GET /api/orders` - Список заказов
- `POST /api/orders` - Создание заказа
- `GET /api/demo/rate-limit-test` - Тест rate limiting

## Примеры использования

### 1. JWT Authentication

```bash
# Login
curl -X POST http://localhost:9292/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "business@example.com", "password": "password"}'

# Response:
# {
#   "message": "Login successful",
#   "tokens": {
#     "access_token": "eyJhbGc...",
#     "refresh_token": "eyJhbGc...",
#     "expires_in": 900
#   }
# }

# Refresh tokens
curl -X POST http://localhost:9292/api/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"refresh_token": "eyJhbGc..."}'
```

### 2. API Key Management

```bash
# Генерация ключа
curl -X POST http://localhost:9292/api/keys/generate \
  -H "Content-Type: application/json" \
  -d '{"client_id": 3}'

# Response:
# {
#   "api_key": {
#     "raw_key": "sk_live_xxxxxxxxxxx",
#     "key_prefix": "sk_live_xxxx",
#     "warning": "Save this key securely. It will not be shown again."
#   }
# }

# Использование ключа
curl http://localhost:9292/api/orders \
  -H "AUTHORIZATION: Bearer eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjozLCJ0eXBlIjoiYWNjZXNzIiwic2NvcGVzIjpbInJlYWQiLCJ3cml0ZSIsImFkbWluIiwicmVhZDpvcmRlcnMiXSwiZXhwIjoxNzY5OTc1MjAwLCJpYXQiOjE3Njk5NzQzMDB9.iZi-C_EF4WGerMfrI_aRFmEfW1kfPq40keJ3oNGlwi4"
```

### 3. Rate Limiting

```bash
# Делаем много запросов и смотрим на headers
for i in {1..15}; do
  echo "Request $i:"
  curl -s -i http://localhost:9292/api/orders \
    -H "X-API-Key: sk_live_xxx" | grep -E "(HTTP|X-RateLimit|X-DailyQuota)"
  echo "---"
done
```

## Полезные команды

```bash
# Очистить Redis
rake redis_flush

# Остановить Redis
docker-compose down

# Логи Redis
docker-compose logs -f redis

# Проверить Redis напрямую
redis-cli -h localhost -p 6379 ping
redis-cli -h localhost -p 6379 keys "*"
```

## Архитектурные решения

### 1. Rack::Attack для базовой защиты

- Throttling по IP, API ключу, email
- Safelist для внутренних сервисов
- Динамический blocklist через Redis
- Кастомные ответы с rate limit headers

### 2. Tiered Rate Limiting

- 3 типа лимитов: rate (req/min), quota (daily), concurrent
- Разные тарифные планы
- Headers для информирования клиента
- TTL для защиты от утечек

### 3. JWT + Refresh Token Rotation

- Access token: 15 минут
- Refresh token: 30 дней
- Автоматическая ротация при refresh
- Детекция компрометации через reuse detection
- Отзыв всех токенов при подозрительной активности

### 4. API Key Management

- Хеширование ключей (bcrypt)
- Префиксы для идентификации
- Grace period при ротации (7 дней)
- Аудит логирование

## Для вебинара

### Порядок демонстрации

1. **Rack::Attack** (20 мин)
   - Показать конфигурацию
   - Демо brute-force protection
   - Объяснить throttle/safelist/blocklist

2. **Business Tiers** (20 мин)
   - Показать конфигурацию тарифов
   - Демо разных лимитов для free vs business
   - Объяснить concurrent limit и TTL

3. **JWT** (20 мин)
   - Показать генерацию токенов
   - Демо refresh token rotation
   - Показать детекцию reuse

4. **API Keys** (20 мин)
   - Показать генерацию и хеширование
   - Демо ротации с grace period
   - Показать список ключей

### Ключевые моменты для подчёркивания

- **Production-ready patterns** - используются в GitLab, Stripe, GitHub
- **Безопасность** - хеширование, rotation, аудит
- **Reliability** - TTL для защиты от утечек, grace period
- **Developer Experience** - headers, понятные ошибки, документация

## Troubleshooting

**Redis не запускается:**
```bash
# Проверить занят ли порт
lsof -i :6379
# Изменить порт в docker-compose.yml и .env
```

**Тесты падают:**
```bash
# Очистить тестовую БД Redis
redis-cli -n 15 FLUSHDB
```

**Gemset не переключается:**
```bash
rvm gemset list
rvm use 3.2.2@api_gateway_workshop_day2
```

## Лицензия

MIT
