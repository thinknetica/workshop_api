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
        user = User.find(payload['user_id'])
        scopes = payload['scopes']
        required_scope = map_request_to_scope(path, request.method)
        @jwt_service.check_token_scopes(scopes: scopes, required_scope: required_scope, user: user)

        # Добавляем данные пользователя в env
        env['api.user_id'] = payload['user_id']
        env['api.scopes'] = scopes || []

        @app.call(env)
      rescue Auth::JwtService::ExpiredTokenError
        unauthorized('Token has expired', error_code: 'token_expired')
      rescue Auth::JwtService::InvalidTokenError => e
        unauthorized(e.message, error_code: 'invalid_token')
      rescue Auth::JwtService::InvalidTokenScopesError
        forbidden(error_code: 'insufficient_scope', user_scopes: scopes, required_scope: required_scope)
      end
    end

    private

    def map_request_to_scope(path, method)
      scope = %w[post put patch].include?(method) ? 'write' : 'read'
      resource = path[/\/api\/([^\/]+)/, 1]
      "#{scope}:#{resource}"
    end

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

    def forbidden(error_code: 'insufficient_scope', user_scopes:, required_scope:)
      [
        403,
        {
          'Content-Type' => 'application/json'
        },
        [{ error: error_code, required: required_scope, your_scopes: user_scopes}.to_json]
      ]
    end
  end
end
