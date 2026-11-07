# config/edgeway.yml: the platform edgeway build targets, and the check that
# the platform supports the app's database adapter and cache store.
# CRuby only (the CLI is not part of the wasm).
require "tmpdir"
require "fileutils"
require_relative "../../lib/edgeway/cli"

def write(root, path, text = "")
  full = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(full))
  File.write(full, text)
end

def platform_name_for(edgeway_yml)
  Dir.mktmpdir do |root|
    write(root, "config/edgeway.yml", edgeway_yml) if edgeway_yml
    Edgeway::CLI::Build::PlatformConfig.load(root).name
  rescue Edgeway::CLI::Error => e
    e.message
  end
end

puts platform_name_for(nil)
puts platform_name_for("platform: cloudflare\n")
puts platform_name_for("")
puts platform_name_for("platform: vercel\n")
puts platform_name_for("platform:\n")
puts platform_name_for("target: cloudflare\n")
puts platform_name_for("- cloudflare\n")

puts "--"
class FakePlatform
  def name = "fake"

  def adapters = %w[memory]

  def stores = %w[null]

  def service_lines = []

  def setup_lines = []

  def rate_limiter_lines = []

  def adapter_expression(_adapter, _binding_name) = "Edgeway::DB::MemoryAdapter.new"
end

def main_on_fake_platform(database_yml, cache_yml)
  Dir.mktmpdir do |root|
    write(root, "config/routes.rb")
    write(root, "config/database.yml", database_yml)
    write(root, "config/cache.yml", cache_yml)
    config = Edgeway::CLI::Build::AppConfig.load(root, "development")
    FileUtils.mkdir_p(File.join(root, "build"))
    Edgeway::CLI::Build.new(root, "development", platform: FakePlatform.new).send(:write_main, config)
    "built"
  rescue Edgeway::CLI::Error => e
    e.message
  end
end

puts main_on_fake_platform("development:\n  adapter: memory\n", "development:\n  store: null\n")
puts main_on_fake_platform("development:\n  adapter: d1\n", "development:\n  store: null\n")
puts main_on_fake_platform("development:\n  adapter: memory\n", "development:\n  store: memory\n")
puts main_on_fake_platform("development:\n  adapter: memory\n", "development:\n  store: kv\n  binding: CACHE\n")

puts "--"
Build = Edgeway::CLI::Build
class FakePlatform
  def js_paths(tests: false) = [File.join(Edgeway::CLI.gem_dir, "js/cors.js")]
end

def with_fake_platform
  Build::PlatformConfig::PLATFORMS["fake"] = FakePlatform
  yield
ensure
  Build::PlatformConfig::PLATFORMS.delete("fake")
end

def build_files_of_app_naming(platform_yml)
  Dir.mktmpdir do |root|
    write(root, "config/routes.rb")
    write(root, "config/database.yml", "development:\n  adapter: memory\n")
    write(root, "config/cache.yml", "development:\n  store: null\n")
    write(root, "config/edgeway.yml", platform_yml)
    config = Build::AppConfig.load(root, "development")
    FileUtils.mkdir_p(File.join(root, "build"))
    build = Build.new(root, "development")
    build.send(:write_main, config)
    build.send(:copy_js, config)
    Dir.children(File.join(root, "build/edgeway")).sort.inspect
  rescue Edgeway::CLI::Error => e
    e.message
  end
end

with_fake_platform { puts build_files_of_app_naming("platform: fake\n") }
puts build_files_of_app_naming("platform: 1\n")

puts "--"
def cloudflare_test_on(platform_yml)
  Dir.mktmpdir do |root|
    write(root, "config/edgeway.yml", platform_yml)
    Edgeway::CLI::CloudflareTest.new(root)
    "accepted"
  rescue Edgeway::CLI::Error => e
    e.message
  end
end

with_fake_platform { puts cloudflare_test_on("platform: fake\n") }

puts "--"
def cloudflare_js(tests)
  Build::PlatformConfig.platform_named("cloudflare").js_paths(tests:).map { |path| File.basename(path) }
end

def js_names(platform_name, tests, directory)
  Build::JsFiles.paths(platform_name, tests, directory:).map { |path| File.basename(path) }
end

Dir.mktmpdir do |js_dir|
  %w[fake.js fake-extra.js fake-test-runner.js neutral.js cloudflare.js cloudflare-kv.js cloudflare-test-runner.js].each do |name|
    File.write(File.join(js_dir, name), "")
  end
  with_fake_platform do
    puts js_names("cloudflare", true, js_dir).inspect
    puts js_names("fake", false, js_dir).inspect
    puts js_names("fake", true, js_dir).inspect
  end
end
puts cloudflare_js(false).grep(/\Afake/).inspect
puts (cloudflare_js(true) - cloudflare_js(false)).sort.inspect
puts cloudflare_js(false).grep(/-test/).inspect
