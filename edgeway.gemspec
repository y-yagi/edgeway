# frozen_string_literal: true

require_relative "lib/edgeway/version"

Gem::Specification.new do |spec|
  spec.name = "edgeway"
  spec.version = Edgeway::VERSION
  spec.authors = ["Yuji Yaginuma"]
  spec.email = ["yuuji.yaginuma@gmail.com"]

  spec.summary = "A library for Ruby compiled by Spinel to wasm on edge workers."
  spec.homepage = "https://github.com/y-yagi/edgeway"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ Rakefile mise.toml CODE_OF_CONDUCT.md])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
