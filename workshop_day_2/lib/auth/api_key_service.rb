require 'securerandom'
require 'bcrypt'

module Auth
  class ApiKeyService
    KEY_PREFIX = 'sk_live_'  # Stripe-style prefix
    GRACE_PERIOD = 7 * 24 * 60 * 60  # 7 дней в секундах

    def initialize(redis:)
      @redis = redis
    end

    # Генерация нового API ключа
    def generate(client)
      # Генерируем безопасный ключ
      raw_key = "#{KEY_PREFIX}#{SecureRandom.urlsafe_base64(32)}"

      # Храним только хэш (как пароли)
      key_hash = BCrypt::Password.create(raw_key)

      api_key = ApiKey.create!(
        client_id: client.id,
        key_hash: key_hash,
        key_prefix: raw_key[0, 12],  # Для идентификации в UI
        status: 'active',
        created_at: Time.now
      )

      client.api_keys << api_key

      # Возвращаем сырой ключ ОДИН РАЗ
      {
        raw_key: raw_key,
        api_key_id: api_key.id,
        key_prefix: api_key.key_prefix,
        warning: 'Save this key securely. It will not be shown again.'
      }
    end

    # Ротация ключа с grace period
    def rotate(client)
      old_keys = client.api_keys.select { |k| k.status == 'active' }

      # 1. Создаём новый ключ
      new_key_info = generate(client)

      # 2. Старые ключи переводим в grace period
      old_keys.each do |key|
        key.update!(
          status: 'grace_period',
          grace_period_ends_at: Time.now + GRACE_PERIOD
        )
      end

      {
        new_key: new_key_info,
        old_keys_valid_until: Time.now + GRACE_PERIOD,
        grace_period_days: GRACE_PERIOD / 86400,
        action_required: "Update your integration to use the new key within #{GRACE_PERIOD / 86400} days"
      }
    end

    # Валидация API ключа
    def validate(raw_key)
      return nil unless raw_key&.start_with?(KEY_PREFIX)

      prefix = raw_key[0, 12]

      # Ищем по префиксу (быстро)
      candidates = ApiKey.where(key_prefix: prefix)
                         .select { |k| ['active', 'grace_period'].include?(k.status) }

      # Проверяем хэш (медленно, но только для кандидатов)
      valid_key = candidates.find do |api_key|
        begin
          BCrypt::Password.new(api_key.key_hash) == raw_key
        rescue BCrypt::Errors::InvalidHash
          false
        end
      end

      # Проверяем не истёк ли grace period
      if valid_key&.status == 'grace_period'
        if valid_key.grace_period_ends_at && Time.now > valid_key.grace_period_ends_at
          valid_key.update!(status: 'expired')
          return nil
        end
      end

      valid_key
    end

    # Отзыв ключа
    def revoke(api_key, reason:)
      api_key.update!(
        status: 'revoked',
        revoked_at: Time.now,
        revocation_reason: reason
      )

      log_audit_event(
        event: 'api_key_revoked',
        client_id: api_key.client_id,
        key_prefix: api_key.key_prefix,
        reason: reason
      )

      {
        success: true,
        message: "API key #{api_key.key_prefix}... has been revoked",
        reason: reason
      }
    end

    # Список активных ключей клиента
    def list_keys(client)
      client.api_keys.map do |key|
        {
          id: key.id,
          prefix: key.key_prefix,
          status: key.status,
          created_at: key.created_at,
          grace_period_ends_at: key.grace_period_ends_at,
          revoked_at: key.revoked_at,
          revocation_reason: key.revocation_reason
        }
      end
    end

    private

    def log_audit_event(event:, **details)
      @redis.lpush('audit_log', {
        event: event,
        timestamp: Time.now.to_i,
        details: details
      }.to_json)
      @redis.ltrim('audit_log', 0, 9999)  # Храним последние 10000 событий
    end
  end
end
