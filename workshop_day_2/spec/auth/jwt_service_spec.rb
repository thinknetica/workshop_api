# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/models'
require_relative '../../lib/auth/jwt_service'
require 'mock_redis'

RSpec.describe Auth::JwtService do
  let(:redis) { MockRedis.new }
  let(:access_secret) { 'test_access_secret' }
  let(:refresh_secret) { 'test_refresh_secret' }
  let(:service) { described_class.new(redis: redis, access_secret: access_secret, refresh_secret: refresh_secret) }

  let(:user) do
    User.create!(
      email: 'test@example.com',
      password_hash: 'hash',
      scopes: %w[read write],
      tier: 'free'
    )
  end

  describe '#generate_tokens' do
    it 'генерирует access и refresh токены' do
      result = service.generate_tokens(user)

      expect(result).to have_key(:access_token)
      expect(result).to have_key(:refresh_token)
      expect(result).to have_key(:expires_in)
    end

    it 'access token содержит правильные данные' do
      result = service.generate_tokens(user)
      payload = JWT.decode(result[:access_token], access_secret, true, { algorithm: 'HS256' })[0]

      expect(payload['user_id']).to eq(user.id)
      expect(payload['type']).to eq('access')
      expect(payload['scopes']).to eq(%w[read write])
    end

    it 'refresh token содержит jti' do
      result = service.generate_tokens(user)
      payload = JWT.decode(result[:refresh_token], refresh_secret, true, { algorithm: 'HS256' })[0]

      expect(payload['type']).to eq('refresh')
      expect(payload['jti']).to be_a(String)
      expect(payload['jti'].length).to be > 0
    end

    it 'сохраняет refresh token в Redis' do
      result = service.generate_tokens(user)
      payload = JWT.decode(result[:refresh_token], refresh_secret, true, { algorithm: 'HS256' })[0]
      jti = payload['jti']

      expect(redis.exists?("refresh_token:#{user.id}:#{jti}")).to be_truthy
      expect(redis.sismember("user_refresh_tokens:#{user.id}", jti)).to be true
    end
  end

  describe '#verify_access_token' do
    it 'успешно верифицирует валидный токен' do
      tokens = service.generate_tokens(user)
      payload = service.verify_access_token(tokens[:access_token])

      expect(payload['user_id']).to eq(user.id)
      expect(payload['scopes']).to eq(%w[read write])
    end

    it 'выбрасывает ошибку для невалидного токена' do
      expect do
        service.verify_access_token('invalid_token')
      end.to raise_error(Auth::JwtService::InvalidTokenError)
    end

    it 'выбрасывает ошибку для истёкшего токена' do
      # Создаём токен с exp в прошлом
      expired_token = JWT.encode({
                                   user_id: user.id,
                                   type: 'access',
                                   exp: Time.now.to_i - 3600
                                 }, access_secret, 'HS256')

      expect do
        service.verify_access_token(expired_token)
      end.to raise_error(Auth::JwtService::ExpiredTokenError)
    end

    it 'отклоняет refresh token' do
      tokens = service.generate_tokens(user)

      # Refresh token подписан другим секретом, поэтому будет ошибка декодирования
      # Это корректное поведение - разные секреты для разных типов токенов
      expect do
        service.verify_access_token(tokens[:refresh_token])
      end.to raise_error(Auth::JwtService::InvalidTokenError)
    end
  end

  describe '#refresh' do
    it 'выдаёт новую пару токенов' do
      tokens = service.generate_tokens(user)
      sleep 1 # Чтобы timestamp отличался
      new_tokens = service.refresh(tokens[:refresh_token])

      # Проверяем что это действительно новые токены
      expect(new_tokens[:access_token]).not_to eq(tokens[:access_token])
      expect(new_tokens[:refresh_token]).not_to eq(tokens[:refresh_token])

      # Проверяем что jti разные
      old_jti = JWT.decode(tokens[:refresh_token], refresh_secret, false)[0]['jti']
      new_jti = JWT.decode(new_tokens[:refresh_token], refresh_secret, false)[0]['jti']
      expect(new_jti).not_to eq(old_jti)
    end

    it 'инвалидирует старый refresh token (Token Rotation)' do
      tokens = service.generate_tokens(user)
      old_refresh = tokens[:refresh_token]

      # Используем refresh token первый раз
      service.refresh(old_refresh)

      # Пытаемся использовать второй раз
      expect do
        service.refresh(old_refresh)
      end.to raise_error(Auth::JwtService::InvalidTokenError, /revoked/)
    end

    it 'отзывает все токены при попытке reuse старого токена' do
      tokens = service.generate_tokens(user)
      old_refresh = tokens[:refresh_token]

      # Первый refresh - успешно
      new_tokens = service.refresh(old_refresh)

      # Пытаемся использовать старый токен - должен отозвать ВСЕ
      expect do
        service.refresh(old_refresh)
      end.to raise_error(Auth::JwtService::InvalidTokenError)

      # Новый токен тоже должен быть инвалидирован
      expect do
        service.refresh(new_tokens[:refresh_token])
      end.to raise_error(Auth::JwtService::InvalidTokenError)
    end

    it 'выбрасывает ошибку для access token' do
      tokens = service.generate_tokens(user)

      # Access token подписан другим секретом, поэтому будет ошибка декодирования
      # Это корректное поведение - разные секреты для разных типов токенов
      expect do
        service.refresh(tokens[:access_token])
      end.to raise_error(Auth::JwtService::InvalidTokenError)
    end
  end

  describe '#revoke_all_refresh_tokens' do
    it 'удаляет все refresh токены пользователя' do
      # Создаём несколько токенов (симулируем несколько устройств)
      tokens1 = service.generate_tokens(user)
      tokens2 = service.generate_tokens(user)
      tokens3 = service.generate_tokens(user)

      # Проверяем что все три токена работают
      expect { JWT.decode(tokens1[:refresh_token], refresh_secret, true, { algorithm: 'HS256' }) }.not_to raise_error
      expect { JWT.decode(tokens2[:refresh_token], refresh_secret, true, { algorithm: 'HS256' }) }.not_to raise_error
      expect { JWT.decode(tokens3[:refresh_token], refresh_secret, true, { algorithm: 'HS256' }) }.not_to raise_error

      # Проверяем что все токены есть в Redis
      jti1 = JWT.decode(tokens1[:refresh_token], refresh_secret, false)[0]['jti']
      jti2 = JWT.decode(tokens2[:refresh_token], refresh_secret, false)[0]['jti']
      jti3 = JWT.decode(tokens3[:refresh_token], refresh_secret, false)[0]['jti']

      expect(redis.sismember("user_refresh_tokens:#{user.id}", jti1)).to be true
      expect(redis.sismember("user_refresh_tokens:#{user.id}", jti2)).to be true
      expect(redis.sismember("user_refresh_tokens:#{user.id}", jti3)).to be true

      # Отзываем все
      service.revoke_all_refresh_tokens(user.id)

      # Проверяем что все токены удалены из Redis
      expect(redis.sismember("user_refresh_tokens:#{user.id}", jti1)).to be false
      expect(redis.sismember("user_refresh_tokens:#{user.id}", jti2)).to be false
      expect(redis.sismember("user_refresh_tokens:#{user.id}", jti3)).to be false

      # Попытка использовать отозванные токены должна провалиться
      expect do
        service.refresh(tokens1[:refresh_token])
      end.to raise_error(Auth::JwtService::InvalidTokenError, /revoked/)

      # Генерируем новый токен после отзыва - он должен работать
      tokens_new = service.generate_tokens(user)
      expect { service.refresh(tokens_new[:refresh_token]) }.not_to raise_error
    end
  end

  describe '#check_token_scopes' do
    it 'успешно проходит, если required scope присутствует в scopes' do
      expect do
        service.check_token_scopes(required_scope: 'read', scopes: %w[read write], user: user)
      end.not_to raise_error
    end

    it 'успешно проходит для любого из доступных scopes' do
      expect do
        service.check_token_scopes(required_scope: 'write', scopes: %w[read write], user: user)
      end.not_to raise_error
    end

    it 'выбрасывает InvalidTokenError, если user равен nil' do
      expect do
        service.check_token_scopes(required_scope: 'read', scopes: %w[read write], user: nil)
      end.to raise_error(Auth::JwtService::InvalidTokenError, 'User not found')
    end

    it 'выбрасывает InvalidTokenScopesError, если required scope отсутствует в scopes' do
      expect do
        service.check_token_scopes(required_scope: 'admin', scopes: %w[read write], user: user)
      end.to raise_error(Auth::JwtService::InvalidTokenScopesError)
    end

    it 'выбрасывает InvalidTokenScopesError, если scopes пустой массив' do
      expect do
        service.check_token_scopes(required_scope: 'read', scopes: [], user: user)
      end.to raise_error(Auth::JwtService::InvalidTokenScopesError)
    end

    context 'с токеном пользователя' do
      it 'проверяет scopes из сгенерированного токена' do
        tokens = service.generate_tokens(user)
        payload = service.verify_access_token(tokens[:access_token])

        expect do
          service.check_token_scopes(required_scope: 'read', scopes: payload['scopes'], user: user)
        end.not_to raise_error
      end

      it 'отклоняет scope, которого нет у пользователя' do
        tokens = service.generate_tokens(user)
        payload = service.verify_access_token(tokens[:access_token])

        expect do
          service.check_token_scopes(required_scope: 'delete', scopes: payload['scopes'], user: user)
        end.to raise_error(Auth::JwtService::InvalidTokenScopesError)
      end
    end
  end
end
