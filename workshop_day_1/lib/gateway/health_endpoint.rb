# frozen_string_literal: true

require 'json'
require 'semian'

module Gateway
  class HealthEndpoint
    def initialize(app, health_checker:)
      @app = app
      @health_checker = health_checker
      @circuit_breaker_counter = Gateway::Middleware::CircuitBreaker::Counter.instance
    end

    def call(env)
      case env['PATH_INFO']
      when '/health'
        health_response
      when '/health/detailed'
        detailed_health_response
      when '/health/live'
        liveness_response
      when '/health/ready'
        readiness_response
      when '/health/circuits'
        semian_circuits_response
      else
        @app.call(env)
      end
    end

    private

    def semian_circuits_response
      circuits = {}

      # Получить информацию о всех circuit'ах из Semian

      %w[nethttp_users_service nethttp_prodcuts_service nethttp_orders_service].each do |name|
        resource = Semian[name]
        next unless (circuit_breaker_object = resource&.circuit_breaker)

        circuits[name] = {
          state: circuit_state_name(resource.circuit_breaker),
          success_count: @circuit_breaker_counter[name][:success],
          success_atom_count: circuit_breaker_object.instance_variable_get(:@successes).instance_variable_get(:@atom).value,
          error_count: circuit_breaker_object.instance_variable_get(:@errors).instance_variable_get(:@window).size,
          circuit_open_count: @circuit_breaker_counter[name][:circuit_open]
        }
      end

      [200, { 'content-type' => 'application/json' }, [circuits.to_json]]
    end

    def circuit_state_name(circuit)
      if circuit.open?
        'open'
      elsif circuit.half_open?
        'half_open'
      else
        'closed'
      end
    end

    # Базовая проверка — Gateway жив?
    def liveness_response
      [200, { 'content-type' => 'application/json' },
       [{ status: 'ok' }.to_json]]
    end

    # Готовность — есть ли хотя бы один здоровый backend?
    def readiness_response
      healthy_count = @health_checker.healthy_backends.size

      if healthy_count.positive?
        [200, { 'content-type' => 'application/json' },
         [{ status: 'ready', healthy_backends: healthy_count }.to_json]]
      else
        [503, { 'content-type' => 'application/json' },
         [{ status: 'not_ready', healthy_backends: 0 }.to_json]]
      end
    end

    # Общий health — сводная информация
    def health_response
      healthy_count = @health_checker.healthy_backends.size
      total_count = @health_checker.status.size

      status = if healthy_count == total_count
                 'ok'
               elsif healthy_count.positive?
                 'degraded'
               else
                 'unhealthy'
               end

      http_status = healthy_count.positive? ? 200 : 503

      [http_status, { 'content-type' => 'application/json' },
       [{
         status: status,
         healthy_backends: healthy_count,
         total_backends: total_count
       }.to_json]]
    end

    # Детальная информация о всех backends
    def detailed_health_response
      [200, { 'content-type' => 'application/json' },
       [{
         gateway: 'ok',
         uptime: process_uptime,
         backends: @health_checker.status,
         timestamp: Time.now.iso8601
       }.to_json]]
    end

    def process_uptime
      "#{(Time.now - $gateway_start_time).round}s" if defined?($gateway_start_time)
    end
  end
end
