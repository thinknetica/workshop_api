# frozen_string_literal: true

require 'securerandom'
require 'request_store'

module Observability
  class Correlation
    TRACE_HEADER = 'X-Trace-Id'.freeze
    REQUEST_HEADER = 'X-Request-Id'.freeze
    PARENT_SPAN_HEADER = 'X-Parent-Span-Id'.freeze

    class << self
      def trace_id
        RequestStore.store[:trace_id]
      end

      def request_id
        RequestStore.store[:request_id]
      end

      def span_id
        RequestStore.store[:span_id]
      end

      def parent_span_id
        RequestStore.store[:parent_span_id]
      end

      def context
        {
          trace_id: trace_id,
          request_id: request_id,
          span_id: span_id,
          parent_span_id: parent_span_id
        }
      end

      # Headers для пробрасывания в downstream сервисы
      def propagation_headers
        {
          TRACE_HEADER => trace_id,
          REQUEST_HEADER => request_id,
          PARENT_SPAN_HEADER => span_id
        }.compact
      end
    end
  end

  class CorrelationMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      # Извлекаем или генерируем IDs
      trace_id = extract_header(env, Correlation::TRACE_HEADER) || generate_trace_id
      request_id = extract_header(env, Correlation::REQUEST_HEADER) || generate_request_id
      parent_span_id = extract_header(env, Correlation::PARENT_SPAN_HEADER)
      span_id = generate_span_id

      # Сохраняем в RequestStore
      RequestStore.store[:trace_id] = trace_id
      RequestStore.store[:request_id] = request_id
      RequestStore.store[:span_id] = span_id
      RequestStore.store[:parent_span_id] = parent_span_id
      RequestStore.store[:request_start_time] = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Выполняем запрос
      status, headers, body = @app.call(env)

      # Добавляем correlation headers в response (Rack 3 requires lowercase)
      headers['x-trace-id'] = trace_id
      headers['x-request-id'] = request_id

      [status, headers, body]
    end

    private

    def extract_header(env, header_name)
      # HTTP headers приходят как HTTP_X_TRACE_ID
      key = "HTTP_#{header_name.upcase.tr('-', '_')}"
      env[key]
    end

    def generate_trace_id
      SecureRandom.uuid
    end

    def generate_request_id
      SecureRandom.hex(8)
    end

    def generate_span_id
      SecureRandom.hex(8)
    end
  end
end
