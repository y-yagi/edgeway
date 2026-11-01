require "edgeway"

class Lines
  attr_reader :lines

  def initialize
    @lines = []
  end

  def puts(line)
    @lines << line
  end
end

def logged(level)
  ENV["LOG_LEVEL"] = level
  out = Lines.new
  logger = Edgeway::Logger.new(out)
  logger.debug("d")
  logger.info("i", "status" => 401)
  logger.warn("w", ratio: 0.5, ok: true)
  logger.error("e")
  puts "#{level}: #{out.lines.length}"
  puts out.lines
end

ENV["LOG_LEVEL"] = "info"
clash = Lines.new
Edgeway::Logger.new(clash).info("real", level: "error", "message" => "fake", other: 1)
puts clash.lines

logged("debug")
logged("info")
logged("warn")
logged("error")
logged("verbose")
logged("")
