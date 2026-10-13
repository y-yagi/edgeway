# edgeway new: the files it creates (test scaffolding included) and the hint
# it prints, without invoking Spinel. CRuby only.
require "tmpdir"
require "stringio"
require_relative "../../lib/edgeway/cli"

Dir.mktmpdir do |dir|
  app = File.join(dir, "my_app")
  out = StringIO.new
  $stdout = out
  begin
    Edgeway::CLI::New.run([app])
  ensure
    $stdout = STDOUT
  end
  files = Dir.glob("**/*", File::FNM_DOTMATCH, base: app).select { |f| File.file?(File.join(app, f)) }.sort
  puts files
  puts "--"
  puts File.read(File.join(app, "test/test_helper.rb"))
  puts File.read(File.join(app, "test/controllers/health_test.rb")).lines.grep(/class|require/)
  puts File.read(File.join(app, "Gemfile")).lines.grep(/spinel_test-unit/).last
  %w[setup build deploy].each { |b| puts "bin/#{b} executable: #{File.executable?(File.join(app, "bin/#{b}"))}" }
  # pnpm everywhere, npm/npx nowhere
  puts "package.json: #{File.read(File.join(app, "package.json"))[/"packageManager"/].inspect}"
  puts "mise.toml: #{File.read(File.join(app, "mise.toml")).lines.grep(/^(node|pnpm) =/).join.gsub("\n", "; ")}"
  puts File.read(File.join(app, "bin/deploy")).lines.last(2)
  npm = files.select { |f| File.read(File.join(app, f)).match?(/\bnpm\b|\bnpx\b/) }
  puts "mentions npm/npx: #{npm.inspect}"
  puts out.string.lines.last.sub(app, "APP")
end
