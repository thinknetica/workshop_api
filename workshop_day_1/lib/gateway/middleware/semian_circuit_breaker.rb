# frozen_string_literal: true

require 'semian'
require 'semian/net_http'
require_relative 'curciut_breaker/counter'

module Gateway
  module Middleware
    class SemianCircuitBreaker
      CIRCUIT_CONFIG = {
        'users_service' => {
          error_threshold: 3,
          error_timeout: 10,
          tickets: 20
        },
        'orders_service' => {
          error_threshold: 5,
          error_timeout: 15,
          tickets: 10
        },
        'products_service' => {
          error_threshold: 3,
          error_timeout: 10,
          tickets: 15
        }
      }.freeze

      def initialize(app)
        @app = app
        @counter = Gateway::Middleware::CircuitBreaker::Counter.instance
        configure_semian_circuit_breaker
      end

      def call(env)
        @app.call(env)
      rescue Semian::OpenCircuitError, Net::OpenCircuitError => e
        # Circuit открыт — сервис недоступен
        handle_open_circuit(env, e)
      end

      private

      def configure_semian_circuit_breaker
        # Конфигурация Semian для Net::HTTP
        Semian::NetHTTP.semian_configuration = proc do |host, port|
          {
            name: circuit_name_for(host, port),
            circuit_breaker: true,
            success_threshold: 2, # Сколько успешных запросов для закрытия
            bulkhead: true
          }.merge(CIRCUIT_CONFIG[circuit_name_for(host, port)] || {})
        end

        Semian.subscribe do |event, resource, _scope, _adapter|
          case event
          when :success
            @counter[resource.name] ||= { success: 0 }
            @counter[resource.name][:success] += 1
          when :circuit_open
            @counter[resource.name] ||= { circuit_open: 0 }
            @counter[resource.name][:circuit_open] += 1
          end
        end
      end

      def circuit_name_for(host, port)
        {
          'localhost:3001' => 'users_service',
          'localhost:3011' => 'users_service',
          'localhost:3002' => 'orders_service',
          'localhost:3003' => 'products_service',
          'localhost:3013' => 'products_service'
        }["#{host}:#{port}"]
      end

      def handle_open_circuit(_env, error)
        [
          503, { 'content-type' => 'application/json' },
          {
            error: 'service_unavailable',
            message: 'Service is temporarily unavailable',
            details: "Circuit breaker is open for #{error.circuit_name}"
          }.to_json
        ]
      end
    end
  end
end
