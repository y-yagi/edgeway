module Edgeway
  module HTTP
    class Parameters
      # permitted: whether the values may be mass-assigned to a model. Only
      # what permit returns is; the request's params are not.
      def initialize(values = {}, permitted = false)
        @values = values
        @permitted = permitted
      end

      def permitted? = @permitted

      def [](key) = @values[key.to_s]
      def []=(key, value)
        @values[key.to_s] = value
      end
      def key?(key) = @values.key?(key.to_s)
      def fetch(key, default) = @values.key?(key.to_s) ? @values[key.to_s] : default
      def empty? = @values.empty?
      def to_h = @values

      def require(scope)
        prefix = "#{scope}["
        found = {}
        @values.each do |k, v|
          found[k[prefix.length...-1]] = v if k.start_with?(prefix) && k.end_with?("]")
        end
        raise ParameterMissing, "param is missing or the value is empty: #{scope}" if found.empty?
        Parameters.new(found)
      end

      def permit(*keys)
        found = {}
        keys.each do |key|
          name = key.to_s
          found[name] = @values[name] if @values.key?(name)
        end
        Parameters.new(found, true)
      end
    end
  end
end
