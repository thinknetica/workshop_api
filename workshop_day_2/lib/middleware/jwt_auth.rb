module Middleware
  class JwtAuth
    def initialize(app, jwt_service:, exclude_paths: [])
      @app = app
      @jwt_service = jwt_service
      @exclude_paths = exclude_paths
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path

      # Пропускаем публичные endpoints
      return @app.call(env) if excluded?(path)

      token = extract_token(env)
      return unauthorized('Missing authorization header') unless token

      begin
        payload = @jwt_service.verify_access_token(token)

        # Добавляем данные пользователя в env
        env['api.user_id'] = payload['user_id']
        env['api.scopes'] = payload['scopes'] || []

        @app.call(env)
      rescue Auth::JwtService::ExpiredTokenError
        unauthorized('Token has expired', error_code: 'token_expired')
      rescue Auth::JwtService::InvalidTokenError => e
        unauthorized(e.message, error_code: 'invalid_token')
      end
    end

    private

    def excluded?(path)
      @exclude_paths.any? { |pattern| path.start_with?(pattern) }
    end

    def extract_token(env)
      auth_header = env['HTTP_AUTHORIZATION']
      return nil unless auth_header

      # Поддержка формата "Bearer TOKEN"
      if auth_header.start_with?('Bearer ')
        auth_header.sub('Bearer ', '')
      else
        auth_header
      end
    end

    def unauthorized(message, error_code: 'unauthorized')
      [
        401,
        {
          'Content-Type' => 'application/json',
          'WWW-Authenticate' => 'Bearer realm="API"'
        },
        [{ error: error_code, message: message }.to_json]
      ]
    end
  end
end
