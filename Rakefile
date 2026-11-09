# frozen_string_literal: true

require "bundler/gem_tasks"
require "fileutils"
require "open3"
require "spinel_test/unit/cli"
require "spinel_test/unit/toolchain"
require_relative "lib/edgeway/cli/toolchain"

# The tests are spinel_test-unit classes (xUnit style, named failures) in
# test/*_test.rb, each leg one run: `spinel_test-unit --ruby` under CRuby, one
# Spinel native build for the lot. Two directories keep the shape of Spinel's own
# tests instead: the script prints its results and the .expected file next to it
# is what it must print (stdout only):
#
#   test/cli/*.rb      the edgeway command, under CRuby
#   test/spinel/*.rb   Spinel only: they cannot run under CRuby (SQLiteAdapter's
#                      ffi_lib), so each is its own Spinel build
#
#   rake test                  both legs (the Spinel leg is skipped when
#                              there is no compiler), then test:cli and test:js
#   rake test:cruby            the unit tests under CRuby only
#   rake test:spinel           the unit tests and test/spinel/*.rb as Spinel builds
#   rake test:cli              the edgeway command: test/cli/*.rb (under CRuby;
#                              test_command.rb also runs edgeway test with Spinel)
#   rake test:js               test/js/*_test.mjs with plain node (skipped without node)
#   rake test:update           rewrite test/cli/*.expected from CRuby's output
#   SPINEL=/path/to/spinel     the compiler (default: spinel on PATH, then
#                              `mise which spinel`; see Edgeway::CLI::Toolchain)
#   JOBS=N                     how many test/spinel/*.rb tests build at once
#                              (default: the CPU count, honouring cgroup limits;
#                              each cc peaks around 350MB); when set, also how many
#                              units the one spinel_test-unit build is compiled
#                              as (otherwise its own default)
UNIT_TESTS = Dir["test/*_test.rb"].sort
CLI_TESTS = Dir["test/cli/*.rb"].sort
# Spinel only (ffi_lib / ffi_source can't be read by CRuby, like d1.rb).
SPINEL_ONLY_TESTS = Dir["test/spinel/*.rb"].sort

# Returns [passed, text] without printing, so it can run on a worker thread.
def check_test(name, cmd, expected)
  out, _err, status = Open3.capture3(*cmd, stdin_data: "")
  if status.success? && out == File.read(expected)
    [true, "ok   #{name}\n"]
  else
    actual = "tmp/#{File.basename(name)}.actual"
    File.write(actual, out)
    diff, _s = Open3.capture2("diff", expected, actual)
    [false, "FAIL #{name}\n#{diff.lines.first(20).join}"]
  end
end

def run_test(name, cmd, expected)
  passed, text = check_test(name, cmd, expected)
  puts text
  passed
end

def check_spinel_test(spinel, test)
  bin = "tmp/spinel/#{File.basename(test, ".rb")}"
  compile_and_check(spinel, test, bin)
rescue SystemCallError => e
  [false, "FAIL spinel #{test} (#{e.class}: #{e.message})\n"]
end

def compile_and_check(spinel, test, bin)
  _o, err, status = Open3.capture3(spinel, "-I", "lib", test, "-o", bin)
  if status.success?
    check_test("spinel #{test}", [bin], test.sub(/\.rb\z/, ".expected"))
  else
    [false, "FAIL spinel #{test} (compile)\n#{err.lines.first(8).join}"]
  end
end

def run_unit_tests(*options)
  SpinelTest::Unit::CLI.start([*options, "-I", "lib", *UNIT_TESTS]).zero?
end

def with_env(variables)
  previous = variables.to_h { |name, _value| [name, ENV[name]] }
  variables.each { |name, value| ENV[name] = value }
  yield
ensure
  previous.each { |name, value| ENV[name] = value }
end

def spinel_jobs
  jobs = ENV.fetch("JOBS", SpinelTest::Unit::Toolchain.cpus).to_i
  jobs.positive? ? jobs : 1
end

def unit_test_jobs
  ENV["JOBS"] ? spinel_jobs.to_s : ENV["SPINEL_TEST_UNIT_JOBS"]
end

def check_spinel_tests(spinel, tests)
  queue = Queue.new
  tests.each_index { |index| queue << index }
  queue.close
  results = Array.new(tests.size)
  workers = Array.new([spinel_jobs, tests.size].min) do
    Thread.new do
      while (index = queue.pop)
        results[index] = check_spinel_test(spinel, tests[index])
      end
    end
  end
  workers.each(&:join)
  results
end

namespace :test do
  desc "Run test/*_test.rb under CRuby"
  task :cruby do
    abort "CRuby leg failed" unless run_unit_tests("--ruby")
  end

  desc "Run test/spinel/*.rb and test/*_test.rb as Spinel native builds"
  task :spinel do
    spinel = Edgeway::CLI::Toolchain.spinel
    unless spinel
      puts "skip spinel leg: no Spinel compiler (set SPINEL=...)"
      next
    end
    FileUtils.mkdir_p("tmp/spinel")
    results = check_spinel_tests(spinel, SPINEL_ONLY_TESTS)
    results.each { |_passed, text| puts text }
    unit_passed = with_env("SPINEL" => spinel, "SPINEL_TEST_UNIT_JOBS" => unit_test_jobs) { run_unit_tests }
    abort "Spinel leg failed" unless [*results.map(&:first), unit_passed].all?
  end

  desc "Rewrite test/cli/*.expected from CRuby's output"
  task :update do
    CLI_TESTS.each do |t|
      out, _err, status = Open3.capture3("ruby", "-I", "lib", t, stdin_data: "")
      abort "#{t} failed" unless status.success?
      File.write(t.sub(/\.rb\z/, ".expected"), out)
    end
  end
end

desc "Test the edgeway command: build's main.rb, new, routes, test (under CRuby)"
task "test:cli" do
  FileUtils.mkdir_p("tmp")
  results = CLI_TESTS.map { |t| run_test("cruby #{t}", ["ruby", "-I", "lib", t], t.sub(/\.rb\z/, ".expected")) }
  abort "CLI tests failed" unless results.all?

  require "tmpdir"
  Dir.mktmpdir do |dir|
    exe = File.expand_path("exe/edgeway")
    lib = File.expand_path("lib")
    sh "ruby", "-I", lib, exe, "new", File.join(dir, "demo")
    %w[setup build deploy].each do |bin|
      abort "bin/#{bin} is not executable" unless File.executable?(File.join(dir, "demo/bin/#{bin}"))
    end
    out, _err, _status = Open3.capture3("ruby", "-I", lib, exe, "routes", chdir: File.join(dir, "demo"))
    abort "routes printed #{out.inspect}" unless out.include?("health#show")
    puts "ok   cli new, routes"
  end
end

desc "Test test/js/*_test.mjs with plain node (skipped when node is missing)"
task "test:js" do
  node = Edgeway::CLI::Toolchain.find_on_path("node")
  if node
    Dir["test/js/*_test.mjs"].sort.each { |t| sh node, t }
  else
    puts "skip test:js: no node"
  end
end

desc "Run the tests under CRuby and Spinel, then test:cli and test:js"
task test: ["test:cruby", "test:spinel", "test:cli", "test:js"]

task default: :test
