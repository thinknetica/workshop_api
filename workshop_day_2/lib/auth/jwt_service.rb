require 'jwt'
require 'securerandom'

module Auth
  class JwtService
    class InvalidTokenError < StandardError; end
    class ExpiredTokenError < StandardError; end

    ACCESS_TOKEN_TTL = 15 * 60  # 15 минут
    REFRESH_TOKEN_TTL = 30 * 24 * 60 * 60  # 30 дней

    def initialize(redis:, access_secret:, refresh_secret:)
      @redis = redis
      @access_secret = access_secret
      @refresh_secret = refresh_secret
    end

    # Генерация пары токенов
    def generate_tokens(user)
      jti = SecureRandom.uuid

      access_token = JWT.encode({
        user_id: user.id,
        type: 'access',
        scopes: user.scopes,
        exp: Time.now.to_i + ACCESS_TOKEN_TTL,
        iat: Time.now.to_i
      }, @access_secret, 'HS256')

      refresh_token = JWT.encode({
        user_id: user.id,
        type: 'refresh',
        jti: jti,
        exp: Time.now.to_i + REFRESH_TOKEN_TTL,
        iat: Time.now.to_i
      }, @refresh_secret, 'HS256')

      # Сохраняем refresh token для возможности отзыва
      store_refresh_token(user.id, jti, REFRESH_TOKEN_TTL)

      {
        access_token: access_token,
        refresh_token: refresh_token,
        expires_in: ACCESS_TOKEN_TTL
      }
    end

    # Проверка access token
    def verify_access_token(token)
      payload = JWT.decode(token, @access_secret, true, { algorithm: 'HS256' })[0]

      raise InvalidTokenError, 'Not an access token' unless payload['type'] == 'access'

      payload
    rescue JWT::ExpiredSignature
      raise ExpiredTokenError, 'Access token has expired'
    rescue JWT::DecodeError => e
      raise InvalidTokenError, "Invalid token: #{e.message}"
    end

    # Обновление токенов через refresh token
    def refresh(refresh_token)
      payload = JWT.decode(refresh_token, @refresh_secret, true, { algorithm: 'HS256' })[0]

      raise InvalidTokenError, 'Not a refresh token' unless payload['type'] == 'refresh'

      jti = payload['jti']
      user_id = payload['user_id']

      # Проверяем, что токен не отозван
      unless valid_refresh_token?(user_id, jti)
        # Кто-то использует старый токен — возможно компрометация!
        revoke_all_refresh_tokens(user_id)
        raise InvalidTokenError, 'Token has been revoked. All tokens invalidated due to security concerns.'
      end

      # Ротация: инвалидируем старый, выдаём новый
      revoke_refresh_token(user_id, jti)

      user = User.find(user_id)
      raise InvalidTokenError, 'User not found' unless user

      generate_tokens(user)
    rescue JWT::ExpiredSignature
      raise ExpiredTokenError, 'Refresh token has expired'
    rescue JWT::DecodeError => e
      raise InvalidTokenError, "Invalid token: #{e.message}"
    end

    # Отзыв всех токенов пользователя
    def revoke_all_refresh_tokens(user_id)
      jtis = @redis.smembers("user_refresh_tokens:#{user_id}")
      jtis.each { |jti| @redis.del("refresh_token:#{user_id}:#{jti}") }
      @redis.del("user_refresh_tokens:#{user_id}")
    end

    private

    def store_refresh_token(user_id, jti, ttl)
      key = "refresh_token:#{user_id}:#{jti}"
      @redis.setex(key, ttl, Time.now.to_i)
      @redis.sadd("user_refresh_tokens:#{user_id}", jti)
      @redis.expire("user_refresh_tokens:#{user_id}", ttl)
    end

    def valid_refresh_token?(user_id, jti)
      result = @redis.exists?("refresh_token:#{user_id}:#{jti}")
      # MockRedis возвращает boolean, Redis >= 4.0 возвращает integer
      result.is_a?(Integer) ? result > 0 : result
    end

    def revoke_refresh_token(user_id, jti)
      @redis.del("refresh_token:#{user_id}:#{jti}")
      @redis.srem("user_refresh_tokens:#{user_id}", jti)
    end
  end
end
