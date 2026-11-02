require_relative "cache/store"
require_relative "cache/null_store"
require_relative "cache/memory_store"

module Edgeway
  @cache = Cache::NullStore.new

  def self.cache = @cache

  def self.cache=(store)
    @cache = store
  end
end
