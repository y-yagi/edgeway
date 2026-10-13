# edgeway test's -lsqlite3 pre-flight check, with $CC standing in for the
# compiler (no Spinel needed). CRuby only.
require "tmpdir"
require_relative "../../lib/edgeway/cli"

def check
  Edgeway::CLI::Precheck.sqlite!
  puts "ok"
rescue Edgeway::CLI::Error => e
  puts e.message.gsub(/`.*? -lsqlite3`/, "`CC -lsqlite3`")
end

ENV.delete("EDGEWAY_SKIP_PRECHECK")
ENV["CC"] = "true"
puts "CC=true:"
check
ENV["CC"] = "false"
puts "CC=false:"
check
ENV["EDGEWAY_SKIP_PRECHECK"] = "1"
puts "skipped:"
check
ENV.delete("EDGEWAY_SKIP_PRECHECK")
ENV["CC"] = "no-such-compiler-xyz"
Dir.mktmpdir { |d| ENV["PATH"] = d } # no compiler anywhere: skipped silently
puts "no compiler:"
check
