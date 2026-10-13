# frozen_string_literal: true

require "bundler/gem_tasks"
require "fileutils"
require "open3"
require_relative "lib/edgeway/cli/toolchain"

# Tests follow the shape of Spinel's own: test/NAME.rb prints its results and
# test/NAME.expected is what it must print. Each runs under CRuby and, when a
# Spinel compiler is found, as a Spinel native build; both must print exactly
# the .expected (stdout only).
#
#   rake test                  both legs (the Spinel leg is skipped when
#                              there is no compiler)
#   rake test:cruby            CRuby only (what CI runs)
#   rake test:spinel           Spinel only (also test/spinel/*.rb: the tests that
#                              cannot run under CRuby, e.g. SQLiteAdapter's ffi_lib)
#   rake test:cli              the edgeway command (CRuby only): test/cli/*.rb
#   rake test:js               js/*.js with plain node (skipped without node)
#   rake test:update           rewrite the .expected files from CRuby's output
#   SPINEL=/path/to/spinel     the compiler (default: spinel on PATH, then
#                              `mise which spinel`; see Edgeway::CLI::Toolchain)
TESTS = Dir["test/*.rb"].sort
CLI_TESTS = Dir["test/cli/*.rb"].sort
# Spinel only (ffi_lib / ffi_source can't be read by CRuby, like d1.rb).
SPINEL_ONLY_TESTS = Dir["test/spinel/*.rb"].sort

def run_test(name, cmd, expected)
  out, _err, status = Open3.capture3(*cmd, stdin_data: "")
  if status.success? && out == File.read(expected)
    puts "ok   #{name}"
    true
  else
    puts "FAIL #{name}"
    File.write("tmp/#{File.basename(name)}.actual", out)
    diff, _s = Open3.capture2("diff", expected, "tmp/#{File.basename(name)}.actual")
    puts diff.lines.first(20).join
    false
  end
end

namespace :test do
  desc "Run test/*.rb under CRuby"
  task :cruby do
    FileUtils.mkdir_p("tmp")
    results = TESTS.map do |t|
      run_test("cruby #{t}", ["ruby", "-I", "lib", t], t.sub(/\.rb\z/, ".expected"))
    end
    abort "CRuby leg failed" unless results.all?
  end

  desc "Run test/*.rb as Spinel native builds"
  task :spinel do
    spinel = Edgeway::CLI::Toolchain.spinel
    unless spinel
      puts "skip spinel leg: no Spinel compiler (set SPINEL=...)"
      next
    end
    FileUtils.mkdir_p("tmp/spinel")
    results = (TESTS + SPINEL_ONLY_TESTS).map do |t|
      bin = "tmp/spinel/#{File.basename(t, ".rb")}"
      _o, err, status = Open3.capture3(spinel, "-I", "lib", t, "-o", bin)
      if status.success?
        run_test("spinel #{t}", [bin], t.sub(/\.rb\z/, ".expected"))
      else
        puts "FAIL spinel #{t} (compile)\n#{err.lines.first(8).join}"
        false
      end
    end
    abort "Spinel leg failed" unless results.all?
  end

  desc "Rewrite test/*.expected from CRuby's output"
  task :update do
    (TESTS + CLI_TESTS).each do |t|
      out, _err, status = Open3.capture3("ruby", "-I", "lib", t, stdin_data: "")
      abort "#{t} failed" unless status.success?
      File.write(t.sub(/\.rb\z/, ".expected"), out)
    end
  end
end

desc "Test the edgeway command: build's main.rb, new, routes (CRuby only)"
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

desc "Test js/*.js with plain node (skipped when node is missing)"
task "test:js" do
  node = Edgeway::CLI::Toolchain.find_on_path("node")
  if node
    Dir["test/js/*_test.mjs"].sort.each { |t| sh node, t }
  else
    puts "skip test:js: no node"
  end
end

desc "Run the tests under CRuby and Spinel"
task test: ["test:cruby", "test:spinel", "test:cli", "test:js"]

task default: :test
