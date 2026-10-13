module Edgeway
  # The environment name: EDGEWAY_ENV, "development" when it is not set.
  def self.env
    ENV["EDGEWAY_ENV"] || "development"
  end

  # A setting from the Worker's variables, which the runtime passes as CGI
  # environment variables; the default when it is not set.
  def self.config(name, default = "")
    ENV[name] || default
  end
end
