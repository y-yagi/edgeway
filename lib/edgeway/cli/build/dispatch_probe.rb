# frozen_string_literal: true

require "json"
require "edgeway"

module Edgeway
  module DispatchProbe
    ACTION_NAME = /\A[a-z_][a-zA-Z0-9_]*[!?]?\z/

    def self.route_problem(route)
      where = "#{route.verb} #{route.pattern} (#{route.controller_path}##{route.action})"
      name = route.controller_class_name
      return "#{where}: #{name} is not defined (app/controllers/#{route.controller_path}_controller.rb)" unless Object.const_defined?(name)

      controller_class = Object.const_get(name)
      return "#{where}: #{name} is a #{controller_class.class.name.downcase}, not a class" unless controller_class.is_a?(Class)
      return "#{where}: #{name} is not an Edgeway::Controller::Base" unless controller_class < Edgeway::Controller::Base
      return "#{where}: #{route.action.inspect} is not a valid action name" unless ACTION_NAME.match?(route.action)
      return nil if controller_class.allocate.action?(route.action)

      "#{where}: #{name} has no action #{route.action} (a public method that is not one of Edgeway::Controller::Base's)"
    end

    def self.actions_by_controller(routes)
      routes.each_with_object({}) do |route, grouped|
        actions = (grouped[route.controller_class_name] ||= [])
        actions << route.action unless actions.include?(route.action)
      end
    end

    def self.load_library(lines)
      lines.each_line do |line|
        TOPLEVEL_BINDING.eval(line)
      rescue NoMethodError => error
        raise unless error.name.to_s.start_with?("ffi_")
      end
    end

    def self.run(result_path, root, library_lines, files)
      load_library(library_lines)
      files.each { |file| require File.join(root, file) }
      load File.join(root, "config/routes.rb")
      routes = Edgeway.application.routes.list
      problems = routes.map { |route| route_problem(route) }.compact
      result = problems.empty? ? { "controllers" => actions_by_controller(routes) } : { "problems" => problems }
      File.write(result_path, JSON.generate(result))
    end
  end
end

result_path, root, library_lines, *files = ARGV
Edgeway::DispatchProbe.run(result_path, root, library_lines, files)
