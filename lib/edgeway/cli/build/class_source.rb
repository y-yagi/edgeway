# frozen_string_literal: true

module Edgeway
  module CLI
    class Build
      module ClassSource
        def self.wrap(class_name, body)
          *modules, name = class_name.split("::")
          depth = modules.size
          lines = [""]
          modules.each_with_index { |module_name, index| lines << "#{"  " * index}module #{module_name}" }
          lines << "#{"  " * depth}class #{name}"
          body.each { |line| lines << (line.empty? ? "" : "#{"  " * (depth + 1)}#{line}") }
          lines << "#{"  " * depth}end"
          depth.times { |index| lines << "#{"  " * (depth - 1 - index)}end" }
          lines
        end
      end
    end
  end
end
