module Edgeway
  module Model
    TRUE_STRINGS = ["true", "1", "t", "on"]

    # Integer is 32-bit in a wasm build: to_i raises RangeError beyond these.
    # to_int checks them too, so CRuby and a native build (64-bit) cast the
    # same values to nil as the wasm does.
    INT_MAX = 2147483647
    INT_MIN = -2147483648

    PRIMARY = "primary"

    def self.registry = (@registry ||= ConnectionRegistry.new)

    def self.connect(name, adapter) = registry.connect(name, adapter)

    def self.disconnect(name) = registry.disconnect(name)

    def self.connection=(adapter)
      connect(PRIMARY, adapter)
    end

    def self.connected? = registry.connected?(PRIMARY)

    def self.connection = connection_for(PRIMARY)

    def self.connection_for(name) = registry.fetch(name)

    def self.database_names = registry.names

    def self.query_stats(name = PRIMARY)
      connection_for(name).query_stats
    end

    # Runs the block with writes queued instead of executed, then sends them
    # all as one atomic batch (one SQL transaction, all or none).
    # A batch belongs to the database of its first write.
    def self.batch
      if @batch_queue
        yield
        return []
      end
      queue = []
      @batch_queue = queue
      @batch_database = nil
      begin
        yield
      rescue => e
        @batch_queue = nil
        raise e
      end
      database = @batch_database
      @batch_queue = nil
      queue.empty? ? [] : connection_for(database).batch(queue)
    end

    def self.batching? = !@batch_queue.nil?

    # Every model write but an INSERT goes through here: executed at once, or
    # queued inside batch. A queued write answers a placeholder result, as its
    # counts are not known until the batch is sent.
    def self.write(sql, binds, database: PRIMARY)
      name = database.to_s
      queue = @batch_queue
      if queue.nil?
        connection_for(name).execute(sql, binds)
      else
        join_batch(name)
        queue << [sql, binds]
        { "changes" => 0, "last_insert_id" => 0 }
      end
    end

    def self.join_batch(name)
      current = @batch_database
      if current.nil?
        @batch_database = name
      elsif current != name
        raise ArgumentError, "Model.batch spans databases (#{current} and #{name}); a batch runs on one database"
      end
    end

    def self.select_all(sql, binds = [], database: PRIMARY)
      connection_for(database).select_all(sql, binds.map { |b| database_value(b) })
    end

    def self.execute(sql, binds = [], database: PRIMARY)
      write(sql, binds.map { |b| database_value(b) }, database: database)
    end

    def self.exec(sql, database: PRIMARY)
      raise ArgumentError, "Model.exec can't run inside Model.batch" if batching?
      raise ArgumentError, "Model.exec needs SQL text" unless sql.is_a?(String) && !sql.strip.empty?
      connection_for(database).exec(sql)
      nil
    end

    def self.to_int(v)
      n = v.is_a?(Integer) ? v : v.to_s.to_i
      n > INT_MAX || n < INT_MIN ? nil : n
    rescue RangeError
      nil
    end

    def self.cast(type, v)
      return nil if v.nil?
      case type
      when :integer then to_int(v)
      when :float then v.is_a?(Float) ? v : v.to_s.to_f
      when :boolean then v == true || TRUE_STRINGS.include?(v.to_s)
      when :bigint then to_bigint(v)
      when :binary then to_binary(v)
      else v.to_s
      end
    end

    INT64_MAX_DIGITS = "9223372036854775807"
    INT64_MIN_DIGITS = "9223372036854775808"

    # A bigint is held as its decimal String, as a number beyond 32 bits can't
    # be an Integer in wasm.
    def self.to_bigint(value)
      text = value.to_s
      return nil unless text.match?(/\A-?[0-9]+\z/)
      negative = text.start_with?("-")
      digits = text.sub(/\A-?0*/, "")
      digits = "0" if digits.empty?
      return nil unless within_int64?(digits, negative)
      negative && digits != "0" ? "-#{digits}" : digits
    end

    def self.within_int64?(digits, negative)
      limit = negative ? INT64_MIN_DIGITS : INT64_MAX_DIGITS
      return digits.length < limit.length || (digits.length == limit.length && digits <= limit)
    end

    def self.to_binary(value)
      return value.to_s.b unless value.is_a?(Hash)
      return nil unless value.key?("$blob")
      value["$blob"].to_s.unpack1("m0").b
    rescue ArgumentError
      nil
    end

    def self.encode_base64(bytes) = [bytes].pack("m0")

    def self.blob(bytes)
      { "$blob" => encode_base64(bytes) }
    end

    def self.database_value(value, type = nil)
      return connection.quote_boolean(value) if value == true || value == false
      return value.getutc.iso8601(3) if value.is_a?(Time)
      return blob(value) if type == :binary && value.is_a?(String)
      value
    end

    def self.underscore(name)
      name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def self.now = @frozen_time || Time.now.utc.iso8601(3)

    def self.freeze_time(text)
      @frozen_time = text
    end
  end
end
