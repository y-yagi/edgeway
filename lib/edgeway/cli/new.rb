# frozen_string_literal: true

require "erb"

module Edgeway
  module CLI
    class New
      TEMPLATES = File.expand_path("../generators/app/templates", __dir__)

      def self.run(args)
        name = args.first
        raise Error, "Usage: edgeway new APP" if name.nil? || name.start_with?("-")
        raise Error, "#{name} already exists" if File.exist?(name)

        new(name).run
      end

      def initialize(dir)
        @dir = dir
        @name = File.basename(File.expand_path(dir)).gsub(/[^A-Za-z0-9_-]/, "-")
        @version = Edgeway::VERSION
      end

      def run
        Dir.glob("**/*", File::FNM_DOTMATCH, base: TEMPLATES).sort.each do |rel|
          src = File.join(TEMPLATES, rel)
          next if File.directory?(src) || File.basename(rel) == "."

          dest = File.join(@dir, rel.delete_suffix(".tt"))
          FileUtils.mkdir_p(File.dirname(dest))
          if rel.end_with?(".tt")
            File.write(dest, ERB.new(File.read(src), trim_mode: "-").result(binding))
          else
            FileUtils.cp(src, dest)
          end
          FileUtils.chmod(0o755, dest) if File.executable?(src)
          puts "  create  #{dest}"
        end
        puts "\nNext: cd #{@dir} && bin/setup && bundle exec edgeway test && bin/build"
      end
    end
  end
end
