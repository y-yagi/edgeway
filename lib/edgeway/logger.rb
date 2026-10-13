module Edgeway
  # Writes to stderr; the runtime sends it to console.error.
  class Logger
    def info(message)
      STDERR.puts "[edgeway] #{message}"
    end

    def error(message)
      STDERR.puts "[edgeway] ERROR #{message}"
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
