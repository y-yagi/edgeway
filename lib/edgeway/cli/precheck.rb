# frozen_string_literal: true

require "tmpdir"
require "shellwords"

module Edgeway
  module CLI
    # Verifies that -lsqlite3 links (SQLiteAdapter needs it at link time), so a
    # missing dev library fails fast with a fix instead of a bare `ld` error.
    # Uses $CC if set, else cc/gcc/clang from PATH; with no compiler the check
    # is skipped (Spinel fails on its own). EDGEWAY_SKIP_PRECHECK=1 disables it.
    module Precheck
      def self.sqlite!
        return if ENV["EDGEWAY_SKIP_PRECHECK"] == "1"

        cc = compiler
        return if cc.nil? || sqlite_links?(cc)

        raise Error, <<~MSG.chomp
          libsqlite3 cannot be linked (`#{cc.join(" ")} -lsqlite3` failed); `edgeway test` needs the SQLite development library.
            Debian/Ubuntu: sudo apt install libsqlite3-dev
            Fedora:        sudo dnf install sqlite-devel
            macOS:         brew install sqlite
          If it is installed somewhere else, set LIBRARY_PATH to a directory holding libsqlite3.so.
          Set EDGEWAY_SKIP_PRECHECK=1 to skip this check.
        MSG
      end

      # The compiler command as an argv array, or nil when there is none.
      def self.compiler
        env = ENV["CC"].to_s.strip
        unless env.empty?
          argv = Shellwords.split(env)
          return argv if !argv.empty? && (argv[0].include?("/") ? File.executable?(argv[0]) : Toolchain.find_on_path(argv[0]))
        end
        %w[cc gcc clang].each { |n| return [n] if Toolchain.find_on_path(n) }
        nil
      end

      def self.sqlite_links?(cc)
        Dir.mktmpdir("edgeway-precheck") do |dir|
          src = File.join(dir, "t.c")
          File.write(src, "int main(){return 0;}\n")
          system(*cc, src, "-o", File.join(dir, "t"), "-lsqlite3", out: File::NULL, err: File::NULL) ? true : false
        end
      end
    end
  end
end
