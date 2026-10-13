module Edgeway
  def self.env
    ENV["EDGEWAY_ENV"] || "development"
  end

  def self.config(name, default = "")
    ENV[name] || default
  end
end
