# frozen_string_literal: true

require 'dotenv/load'
require 'rack/attack'
require_relative 'app'
require_relative 'config/initializers/rack_attack'
require_relative 'lib/middleware/jwt_auth'

# Middleware стэк
use Rack::Attack

# JWT Auth middleware (применяется только к защищённым эндпоинтам)
# Для Sinatra приложения аутентификация реализована через helpers
# Но можем добавить middleware для автоматической проверки токенов

use Middleware::JwtAuth, jwt_service: ApiGatewayApp.settings.jwt_service,
                         exclude_paths: ['/api/auth', '/health', '/api/keys']
use Rack::Logger
use Rack::CommonLogger

# Инициализация тестовых данных
ApiGatewayApp.seed_data!

run ApiGatewayApp
