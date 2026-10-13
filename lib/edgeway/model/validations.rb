module Edgeway
  module Model
    # The instance side of validates: valid? fills errors.
    module Validations
      def errors = @errors

      def valid?
        @errors = []
        # A value the cast refused (an integer outside 32 bits) is nil now.
        @raw.each do |col, raw|
          @errors << "#{col} is out of range" if !raw.nil? && @attributes[col].nil?
        end
        self.class.rules.each do |rule|
          col = rule.column
          # A number is checked as it was set: the cast makes "abc" 0 and "1.9" 1.
          value = rule.kind == "numericality" && @raw.key?(col) ? @raw[col] : @attributes[col]
          msg = rule.message(value)
          @errors << msg unless msg.nil?
        end
        # One query per association; last, so a record already invalid skips it.
        if @errors.empty?
          self.class.belongs_to_list.each do |b|
            fk = @attributes[b.foreign_key]
            @errors << "#{b.name} must exist" if fk.nil? || Base.model_named(b.name, self.class.name).find_by({ b.primary_key => fk }).nil?
          end
        end
        # Uniqueness is a query too, so also last. It is racy (two requests can
        # both pass): the table's UNIQUE constraint is what guarantees it, and
        # its violation is a RecordNotUnique (409).
        if @errors.empty?
          self.class.rules.each do |rule|
            next unless rule.kind == "uniqueness"
            @errors << "#{rule.column} has already been taken" if taken?(rule)
          end
        end
        @errors.empty?
      end

      private

      # Whether another row has this rule's value (within its scope). A nil
      # value is not checked; a new record collides with any row, a saved one
      # only with a row that has another id.
      def taken?(rule)
        value = @attributes[rule.column]
        return false if value.nil?
        found = self.class.where({ rule.column => value })
        rule.scope.each { |c| found = found.where({ c => @attributes[self.class.column(c)] }) }
        other = found.limit(1).to_a.first
        !other.nil? && (new_record? || other.id != id)
      end
    end

    # One validation of one attribute. kind is "presence", "length",
    # "inclusion", "numericality", "format" or "uniqueness"; bounds holds the options that
    # are numbers (minimum, maximum, only_integer as 1, greater_than, ...).
    class Rule
      attr_reader :column, :kind

      # The scope columns of a uniqueness rule: uniqueness: true has none,
      # { scope: :user_id } or { scope: [:a, :b] } has those.
      def self.scope_columns(options)
        return [] if options == true
        scope = options[:scope]
        return [] if scope.nil?
        scope.is_a?(Array) ? scope.map(&:to_s) : [scope.to_s]
      end

      # The options of length: / numericality: ({ maximum: 200 }) with String
      # keys; true (only_integer: true) becomes 1. in: (a Range) becomes
      # minimum and maximum. numericality: true is no options at all.
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
        @column = attribute
        @kind = kind
        @bounds = bounds
        @list = list
        @pattern = pattern
      end

      # The error message for the value, or nil when it passes. A nil value
      # passes every rule but presence (presence is what rejects it).
      def message(v)
        # Uniqueness needs a query: Validations#taken? does it.
        return nil if @kind == "uniqueness"
        if @kind == "presence"
          return "#{@column} can't be blank" if v.nil? || v.to_s.strip.empty?
          return nil
        end
        return nil if v.nil?
        case @kind
        when "length" then length_message(v.to_s.length)
        when "inclusion" then @list.include?(v.to_s) ? nil : "#{@column} is not included in the list"
        when "format" then @pattern.match?(v.to_s) ? nil : "#{@column} is invalid"
        when "numericality" then numericality_message(v)
        end
      end

      def scope = @list

      private

      def length_message(n)
        if @bounds.key?("minimum") && n < @bounds["minimum"]
          return "#{@column} is too short (minimum is #{@bounds["minimum"]} characters)"
        end
        if @bounds.key?("maximum") && n > @bounds["maximum"]
          return "#{@column} is too long (maximum is #{@bounds["maximum"]} characters)"
        end
        if @bounds.key?("is") && n != @bounds["is"]
          return "#{@column} is the wrong length (should be #{@bounds["is"]} characters)"
        end
        nil
      end

      def numericality_message(v)
        text = v.to_s
        integer = text.match?(/\A[+-]?\d+\z/)
        # Decimals and exponents too: Float#to_s writes 1.0e+20 and 1.0e-05.
        return "#{@column} is not a number" unless integer || text.match?(/\A[+-]?\d+(\.\d+)?([eE][+-]?\d+)?\z/)
        return "#{@column} must be an integer" if @bounds.key?("only_integer") && !integer
        n = text.to_f
        if @bounds.key?("greater_than") && !(n > @bounds["greater_than"])
          return "#{@column} must be greater than #{@bounds["greater_than"]}"
        end
        if @bounds.key?("greater_than_or_equal_to") && !(n >= @bounds["greater_than_or_equal_to"])
          return "#{@column} must be greater than or equal to #{@bounds["greater_than_or_equal_to"]}"
        end
        if @bounds.key?("less_than") && !(n < @bounds["less_than"])
          return "#{@column} must be less than #{@bounds["less_than"]}"
        end
        if @bounds.key?("less_than_or_equal_to") && !(n <= @bounds["less_than_or_equal_to"])
          return "#{@column} must be less than or equal to #{@bounds["less_than_or_equal_to"]}"
        end
        nil
      end
    end
  end
end
