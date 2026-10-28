module Edgeway
  module Model
    module Validations
      def errors = @errors

      def valid?
        @errors = []
        @raw.each do |col, raw|
          @errors << "#{col} #{bad_value_text(col)}" if !raw.nil? && @attributes[col].nil?
        end

        self.class.rules.each do |rule|
          col = rule.attribute
          value = rule.kind == "numericality" && @raw.key?(col) ? @raw[col] : @attributes[col]
          msg = rule.message(value, self.class.type_of(col))
          @errors << msg unless msg.nil?
        end

        if @errors.empty?
          self.class.belongs_to_list.each do |b|
            fk = @attributes[b.foreign_key]
            @errors << "#{b.name} must exist" if fk.nil? || Base.model_named(b.name, self.class.name).find_by(b.primary_key => fk).nil?
          end
        end

        if @errors.empty?
          self.class.rules.each do |rule|
            next unless rule.kind == "uniqueness"
            @errors << "#{rule.attribute} has already been taken" if taken?(rule)
          end
        end
        @errors.empty?
      end

      private

      def bad_value_text(column)
        self.class.type_of(column) == :integer ? "is out of range" : "is invalid"
      end

      def taken?(rule)
        value = @attributes[rule.attribute]
        return false if value.nil?
        found = self.class.where(rule.attribute => value)
        rule.scope.each { |c| found = found.where(c => @attributes[self.class.column(c)]) }
        other = found.limit(1).to_a.first
        !other.nil? && (new_record? || other.id != id)
      end
    end

    class Rule
      attr_reader :attribute, :kind

      def self.scope_columns(options)
        return [] if options == true
        scope = options[:scope]
        return [] if scope.nil?
        scope.is_a?(Array) ? scope.map(&:to_s) : [scope.to_s]
      end

      def self.bounds(options)
        h = {}
        return h if options == true
        options.each do |k, v|
          key = k.to_s
          if key == "in"
            h["minimum"] = v.min
            h["maximum"] = v.max
          else
            h[key] = v == true ? 1 : v
          end
        end
        h
      end

      def initialize(attribute, kind, bounds, list, pattern)
        @attribute = attribute
        @kind = kind
        @bounds = bounds
        @list = list
        @pattern = pattern
      end

      def message(v, type = nil)
        # Uniqueness needs a query: Validations#taken? does it.
        return nil if @kind == "uniqueness"
        if @kind == "presence"
          return "#{@attribute} can't be blank" if v.nil? || blank_text?(v.to_s, type)
          return nil
        end
        return nil if v.nil?
        case @kind
        when "length" then type == :binary ? length_message(v.to_s.bytesize, "bytes") : length_message(v.to_s.length, "characters")
        when "inclusion" then @list.include?(v.to_s) ? nil : "#{@attribute} is not included in the list"
        when "format" then @pattern.match?(v.to_s) ? nil : "#{@attribute} is invalid"
        when "numericality" then numericality_message(v)
        end
      end

      def scope = @list

      private

      def blank_text?(text, type) = type == :binary ? text.empty? : text.strip.empty?

      def length_message(n, unit)
        if @bounds.key?("minimum") && n < @bounds["minimum"]
          return "#{@attribute} is too short (minimum is #{@bounds["minimum"]} #{unit})"
        end
        if @bounds.key?("maximum") && n > @bounds["maximum"]
          return "#{@attribute} is too long (maximum is #{@bounds["maximum"]} #{unit})"
        end
        if @bounds.key?("is") && n != @bounds["is"]
          return "#{@attribute} is the wrong length (should be #{@bounds["is"]} #{unit})"
        end
        nil
      end

      def numericality_message(v)
        text = v.to_s
        integer = text.match?(/\A[+-]?\d+\z/)
        # Decimals and exponents too: Float#to_s writes 1.0e+20 and 1.0e-05.
        return "#{@attribute} is not a number" unless integer || text.match?(/\A[+-]?\d+(\.\d+)?([eE][+-]?\d+)?\z/)
        return "#{@attribute} must be an integer" if @bounds.key?("only_integer") && !integer
        n = text.to_f
        if @bounds.key?("greater_than") && !(n > @bounds["greater_than"])
          return "#{@attribute} must be greater than #{@bounds["greater_than"]}"
        end
        if @bounds.key?("greater_than_or_equal_to") && !(n >= @bounds["greater_than_or_equal_to"])
          return "#{@attribute} must be greater than or equal to #{@bounds["greater_than_or_equal_to"]}"
        end
        if @bounds.key?("less_than") && !(n < @bounds["less_than"])
          return "#{@attribute} must be less than #{@bounds["less_than"]}"
        end
        if @bounds.key?("less_than_or_equal_to") && !(n <= @bounds["less_than_or_equal_to"])
          return "#{@attribute} must be less than or equal to #{@bounds["less_than_or_equal_to"]}"
        end
        nil
      end
    end
  end
end
