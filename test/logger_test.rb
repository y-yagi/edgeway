require "spinel_test/unit"
require "edgeway"

class LoggerTest < SpinelTest::Unit::TestCase
  class Lines
    attr_reader :lines

    def initialize
      @lines = []
    end

    def puts(line)
      @lines << line
    end
  end

  DEBUG_LINE = '{"level":"debug","message":"d"}'
  INFO_LINE = '{"status":401,"level":"info","message":"i"}'
  WARN_LINE = '{"ratio":0.5,"ok":true,"level":"warn","message":"w"}'
  ERROR_LINE = '{"level":"error","message":"e"}'

  def setup
    @original_level = ENV["LOG_LEVEL"]
  end

  def teardown
    if @original_level.nil?
      ENV.delete("LOG_LEVEL")
    else
      ENV["LOG_LEVEL"] = @original_level
    end
  end

  def logged_lines(level)
    ENV["LOG_LEVEL"] = level
    out = Lines.new
    logger = Edgeway::Logger.new(out)
    logger.debug("d")
    logger.info("i", "status" => 401)
    logger.warn("w", ratio: 0.5, ok: true)
    logger.error("e")
    out.lines
  end

  def test_reserved_keys_in_fields_do_not_override_level_and_message
    ENV["LOG_LEVEL"] = "info"
    out = Lines.new
    Edgeway::Logger.new(out).info("real", level: "error", "message" => "fake", other: 1)
    assert_equal ['{"level":"info","message":"real","other":1}'], out.lines
  end

  def test_debug_level_logs_everything
    assert_equal [DEBUG_LINE, INFO_LINE, WARN_LINE, ERROR_LINE], logged_lines("debug")
  end

  def test_info_level_skips_debug
    assert_equal [INFO_LINE, WARN_LINE, ERROR_LINE], logged_lines("info")
  end

  def test_warn_level_skips_info_and_debug
    assert_equal [WARN_LINE, ERROR_LINE], logged_lines("warn")
  end

  def test_error_level_logs_only_errors
    assert_equal [ERROR_LINE], logged_lines("error")
  end

  def test_unknown_level_falls_back_to_info
    assert_equal [INFO_LINE, WARN_LINE, ERROR_LINE], logged_lines("verbose")
  end

  def test_empty_level_falls_back_to_info
    assert_equal [INFO_LINE, WARN_LINE, ERROR_LINE], logged_lines("")
  end
end
