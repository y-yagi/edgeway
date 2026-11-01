module Edgeway
  class Logger
    LEVELS = ["debug", "info", "warn", "error"]

    def initialize(output = STDERR)
      @output = output
    end

    def debug(message, fields = {})
      write("debug", message, fields)
    end

    def info(message, fields = {})
      write("info", message, fields)
    end

    def warn(message, fields = {})
      write("warn", message, fields)
    end

    def error(message, fields = {})
      write("error", message, fields)
    end

    private

    def write(level, message, fields)
      return if LEVELS.index(level) < threshold
      entry = {}
      fields.each { |name, value| entry[name.to_s] = value }
      entry["level"] = level
      entry["message"] = message
      @output.puts JSON.generate(entry)
    end

    def threshold
      LEVELS.index(Edgeway.config("LOG_LEVEL", "info")) || LEVELS.index("info")
    end
  end

  def self.logger
    @logger ||= Logger.new
  end

  # For tests that want to see what is logged.
  def self.logger=(logger)
    @logger = logger
  end
end
