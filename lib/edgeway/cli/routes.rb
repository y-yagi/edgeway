# frozen_string_literal: true

module Edgeway
  module CLI
    class Routes
      def self.run(_args)
        path = File.join(Dir.pwd, "config/routes.rb")
        raise Error, "no config/routes.rb in #{Dir.pwd}" unless File.exist?(path)

        $LOAD_PATH.unshift(File.join(CLI.gem_dir, "lib"))
        require "edgeway"
        load path
        list = Edgeway.application.routes.list
        verb_w = list.map { |r| r.verb.size }.max.to_i
        path_w = list.map { |r| r.pattern.size }.max.to_i
        list.each do |r|
          puts "#{r.verb.ljust(verb_w)}  #{r.pattern.ljust(path_w)}  #{r.controller_path}##{r.action}"
        end
      end
    end
  end
end
