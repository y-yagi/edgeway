# frozen_string_literal: true

module Edgeway
  module CLI
    # The JavaScript package manager of an app made by `edgeway new`: the one
    # place that names it. The templates (bin/*, README, mise.toml,
    # wrangler.toml) ask it for the commands, so supporting another is a
    # change here (and a way to choose it in New).
    module PackageManager
      NAME = "pnpm"

      def self.name = NAME

      # Installs package.json's dependencies (wrangler).
      def self.install = "#{NAME} install"

      # Runs a binary of the app's node_modules: `#{exec} wrangler dev`.
      def self.exec = "#{NAME} exec"
    end
  end
end
