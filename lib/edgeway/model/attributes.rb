module Edgeway
  module Model
    TRUE_STRINGS = ["true", "1", "t", "on"]

    # Integer is 32-bit in a wasm build: to_i raises RangeError beyond these.
    # to_int checks them too, so CRuby and a native build (64-bit) cast the
    # same values to nil as the wasm does.
    INT_MAX = 2147483647
    INT_MIN = -2147483648

    def self.connection=(adapter)
      @connection = adapter
    end

    def self.connection
      @connection || raise(ConfigurationError, "Edgeway::Model.connection is not set")
    end

    # Runs the block with writes queued instead of executed, then sends them
    # all as one atomic batch (D1 batch(): one SQL transaction, all or none).
    def self.batch
      if @batch_queue
        yield
        return []
      end
      queue = []
      @batch_queue = queue
      begin
        yield
      rescue => e
        @batch_queue = nil
        raise e
      end
      @batch_queue = nil
      queue.empty? ? [] : connection.batch(queue)
    end

    def self.batching? = !@batch_queue.nil?

    # Every model write but an INSERT goes through here: executed at once, or
    # queued inside batch. A queued write answers a placeholder result, as its
    # counts are not known until the batch is sent.
    def self.write(sql, binds)
      queue = @batch_queue
      if queue.nil?
        connection.execute(sql, binds)
      else
        queue << [sql, binds]
        { "changes" => 0, "last_insert_id" => 0 }
      end
    end

    def self.select_all(sql, binds = [])
      connection.select_all(sql, binds.map { |b| to_db(b) })
    end

    def self.execute(sql, binds = [])
      write(sql, binds.map { |b| to_db(b) })
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
      else v.to_s
      end
    end

    def self.to_db(v)
      return connection.quote_boolean(v) if v == true || v == false
      return v.getutc.iso8601(3) if v.is_a?(Time)
      v
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
