require 'dotenv/load'
require 'rack/attack'
require_relative 'app'
require_relative 'config/initializers/rack_attack'

# Middleware стэк
use Rack::Attack

# JWT Auth middleware (применяется только к защищённым эндпоинтам)
# Для Sinatra приложения аутентификация реализована через helpers
# Но можем добавить middleware для автоматической проверки токенов

use Rack::Logger
use Rack::CommonLogger

# Инициализация тестовых данных
ApiGatewayApp.seed_data!

run ApiGatewayApp
