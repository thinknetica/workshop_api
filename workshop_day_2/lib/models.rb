# Упрощенные модели для демонстрации (без реальной БД)
# В продакшене используйте ActiveRecord или Sequel

class User
  attr_accessor :id, :email, :password_hash, :scopes, :tier

  def initialize(id:, email:, password_hash:, scopes: [], tier: 'free')
    @id = id
    @email = email
    @password_hash = password_hash
    @scopes = scopes
    @tier = tier
  end

  def self.find(id)
    # Заглушка для демо
    @@users ||= {}
    @@users[id]
  end

  def self.find_by_email(email)
    @@users ||= {}
    @@users.values.find { |u| u.email == email }
  end

  def self.create!(params)
    @@users ||= {}
    id = @@users.keys.max.to_i + 1
    user = new(**params.merge(id: id))
    @@users[id] = user
    user
  end

  def self.all
    @@users ||= {}
    @@users.values
  end
end

class Client
  attr_accessor :id, :name, :tier, :api_keys

  def initialize(id:, name:, tier: 'free')
    @id = id
    @name = name
    @tier = tier
    @api_keys = []
  end

  def self.find(id)
    @@clients ||= {}
    @@clients[id]
  end

  def self.create!(params)
    @@clients ||= {}
    id = @@clients.keys.max.to_i + 1
    client = new(**params.merge(id: id))
    @@clients[id] = client
    client
  end

  def self.all
    @@clients ||= {}
    @@clients.values
  end
end

class ApiKey
  attr_accessor :id, :client_id, :key_hash, :key_prefix, :status, :created_at,
                :grace_period_ends_at, :revoked_at, :revocation_reason

  def initialize(params)
    params.each { |k, v| instance_variable_set("@#{k}", v) }
  end

  def self.where(conditions)
    @@api_keys ||= []
    result = @@api_keys.select do |key|
      conditions.all? { |k, v| v.is_a?(Array) ? v.include?(key.send(k)) : key.send(k) == v }
    end
    result
  end

  def self.create!(params)
    @@api_keys ||= []
    id = @@api_keys.map(&:id).max.to_i + 1
    api_key = new(params.merge(id: id, created_at: Time.now))
    @@api_keys << api_key
    api_key
  end

  def update!(params)
    params.each { |k, v| instance_variable_set("@#{k}", v) }
  end

  def client
    Client.find(client_id)
  end
end
