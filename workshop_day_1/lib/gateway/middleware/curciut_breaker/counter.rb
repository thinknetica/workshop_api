module Gateway
  module Middleware
    module CircuitBreaker
      class Counter
        class << self
          def instance
            @instance ||= Concurrent::Hash.new { |h, k| h[k] = { success: 0, circuit_open: 0 } }
          end

          def increment(name, event)
            @instance[name] |= { event => 0 }
            @instance[name][event] += 1
          end

          def decrement(name, event)
            @instance[name] |= { event => 0 }
            @instance[name][event] -= 1
          end

          def get(name, event)
            @instance[name][event]
          end
        end
      end
    end
  end
end
