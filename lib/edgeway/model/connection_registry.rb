module Edgeway
  module Model
    class ConnectionRegistry
      def initialize
        @adapters = {}
      end

      def connect(name, adapter)
        @adapters[name.to_s] = adapter
      end

      def disconnect(name)
        @adapters.delete(name.to_s)
      end

      def connected?(name) = @adapters.key?(name.to_s)

      def names = @adapters.keys

      def fetch(name)
        @adapters[name.to_s] || raise(ConfigurationError, "no database #{name}: it is not under databases: of this environment in config/database.yml")
      end
    end
  end
end
