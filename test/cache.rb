require "edgeway"
require "edgeway/db/memory"
require "edgeway/service/cloudflare/kv_store"

class ApplicationModel < Edgeway::Model::Base
  extend Edgeway::Model::Macros
end

class Note < ApplicationModel
  attribute :title, :string
  timestamps
end

class Plain < ApplicationModel
  attribute :title, :string
end

module TestClock
  @now = 1000

  def self.now = @now

  def self.now=(seconds)
    @now = seconds
  end
end

class ClockedMemoryStore < Edgeway::Cache::MemoryStore
  def current_time = TestClock.now
end

class ClockedKVStore < Edgeway::Cloudflare::KVStore
  def current_time = TestClock.now
end

class RecordingLogger < Edgeway::Logger
  attr_reader :lines

  def initialize
    @lines = []
  end

  def warn(message, fields = {})
    @lines << "#{message} #{JSON.generate(fields)}"
  end
end

class FailingStore < Edgeway::Cache::Store
  def read_text(key)
    Edgeway.logger.warn("read failed (binding CACHE)", {})
    nil
  end

  def write_text(key, text, expires_in_seconds)
    Edgeway.logger.warn("write failed (binding CACHE)", {})
    false
  end

  def delete_text(key)
    Edgeway.logger.warn("delete failed (binding CACHE)", {})
    false
  end
end

class FakeTransport < Edgeway::Cloudflare::KVTransport
  attr_reader :calls

  def initialize(answers)
    @answers = answers
    @calls = []
  end

  def get(binding_name, key) = answer("get #{binding_name}", key)

  def put(binding_name, key, text, expires_in_seconds)
    @calls << "put #{binding_name} #{key} #{text} #{expires_in_seconds}"
    @answers["put"]
  end

  def delete(binding_name, key) = answer("delete #{binding_name}", key)

  private

  def answer(label, key)
    @calls << "#{label} #{key}"
    @answers[label.split(" ")[0]]
  end
end

class SpyStore < ClockedMemoryStore
  attr_reader :last_key, :last_seconds

  def write_text(key, text, expires_in_seconds)
    @last_key = key
    @last_seconds = expires_in_seconds
    super(key, text, expires_in_seconds)
  end

  def text_of(key) = read_text(key)
end

def note_at(id, updated_at)
  Note.instantiate({ "id" => id, "title" => "t", "created_at" => "2026-01-01T00:00:00.000Z", "updated_at" => updated_at })
end

def report_error(label)
  yield
  puts "#{label}: no error"
rescue ArgumentError => e
  puts "#{label}: #{e.class}: #{e.message}"
end

Edgeway::Model.connection = Edgeway::DB::MemoryAdapter.new

store = ClockedMemoryStore.new
p store.read("missing")
p store.exist?("missing")
p store.write("greeting", "hello")
p store.read("greeting")
p store.exist?("greeting")
p store.delete("greeting")
p store.read("greeting")
p store.delete("greeting")

puts "-- values"
store.write("integer", 42)
store.write("float", 2.5)
store.write("true", true)
store.write("false", false)
store.write("nil", nil)
store.write("text", "café 日本")
store.write("array", [1, "two", 3.5, nil, true, [4]])
store.write("hash", { "name" => "a", "list" => [1, 2], "nested" => { "k" => nil } })
store.write("symbol keys", { name: "a", count: 2 })
p store.read("integer") + 1
p store.read("float")
p store.read("true")
p store.read("false")
p store.read("nil")
p store.read("text")
p store.read("array")
p store.read("hash")
p store.read("symbol keys")
p store.exist?("nil")
p store.exist?("false")

puts "-- invalid values"
report_error("invalid UTF-8") { store.write("bad", "caf\xC3") }
report_error("nested invalid UTF-8") { store.write("bad", ["ok", { "k" => "\xFF" }]) }
report_error("binary") { store.write("bad", "caf\xC3".b) }
report_error("nested binary") { store.write("bad", { "k" => ["\xFF".b] }) }
store.write("ascii binary", "plain".b)
p store.read("ascii binary")
report_error("Hash with an Integer key") { store.write("bad", { 1 => 2 }) }
report_error("Hash with a nil key") { store.write("bad", { nil => 3 }) }
report_error("Hash with a key as String and Symbol") { store.write("bad", { "a" => 1, :a => 2 }) }
report_error("object") { store.write("bad", Object.new) }
report_error("model") { store.write("bad", Note.new(title: "a")) }
report_error("nan") { store.write("bad", 0.0 / 0.0) }
report_error("infinity") { store.write("bad", [1.0 / 0.0]) }
p store.exist?("bad")

puts "-- envelope"
spy = SpyStore.new
TestClock.now = 1000
spy.write("plain", { "a" => 1 })
puts spy.text_of("plain")
p spy.last_seconds
spy.write("timed", "x", expires_in: 90)
puts spy.text_of("timed")
p spy.last_seconds
spy.write("nil", nil)
puts spy.text_of("nil")
p spy.last_key

puts "-- expiry"
store.write("short", "x", expires_in: 10)
store.write("forever", "y")
p store.read("short")
TestClock.now = 1009
p store.read("short")
TestClock.now = 1010
p store.read("short")
p store.exist?("short")
p store.read("forever")
TestClock.now = 1000
p store.read("short")
TestClock.now = 1000 + 31_536_000
p store.read("forever")
TestClock.now = 0
store.write("at zero", "x", expires_in: 5)
TestClock.now = 4
p store.read("at zero")
TestClock.now = 5
p store.read("at zero")
TestClock.now = 1000

puts "-- expires_in checks"
[0, -5, 1.5, "60", 31_536_001].each do |bad|
  report_error("expires_in #{bad.inspect}") { store.write("bad", "x", expires_in: bad) }
end
report_error("default expires_in") { Edgeway::Cache::MemoryStore.new(expires_in: 0) }
p store.write("edge", "x", expires_in: 31_536_000)

puts "-- default expires_in"
timed = SpyStore.new(expires_in: 30)
timed.write("a", 1)
p timed.last_seconds
puts timed.text_of("a")
timed.write("b", 2, expires_in: 5)
p timed.last_seconds
TestClock.now = 1006
p timed.read("a")
p timed.read("b")
TestClock.now = 1030
p timed.read("a")
TestClock.now = 1000

puts "-- fetch"
calls = 0
first = store.fetch("fetched") { calls += 1; "computed" }
second = store.fetch("fetched") { calls += 1; "again" }
p first, second, calls
p store.fetch("fetched", force: true) { calls += 1; "forced" }
p store.read("fetched")
p calls
p store.fetch("count") { calls += 1; 41 } + 1
p store.fetch("fetched hash") { { "n" => 1, "list" => [1, 2.5, "x", nil, true] } }
p store.fetch("fetched hash") { { "n" => 2 } }["n"]
p store.fetch("fetched")
p store.fetch("not fetched")
store.fetch("expiring", expires_in: 5) { calls += 1; "v" }
TestClock.now = 1005
p store.fetch("expiring", expires_in: 5) { calls += 1; "v2" }
p calls
TestClock.now = 1000

puts "-- nil"
nil_calls = 0
p store.fetch("cached nil") { nil_calls += 1; nil }
p store.fetch("cached nil") { nil_calls += 1; "other" }
p nil_calls
p store.exist?("cached nil")
p store.fetch("skipped nil", skip_nil: true) { nil_calls += 1; nil }
p store.exist?("skipped nil")
p store.fetch("skipped nil", skip_nil: true) { nil_calls += 1; "now" }
p store.read("skipped nil")
p nil_calls
p store.fetch("false value") { false }
p store.fetch("false value") { true }

puts "-- keys"
keyed = SpyStore.new
keyed.write("string", 1)
p keyed.last_key
keyed.write(:symbol, 1)
p keyed.last_key
keyed.write(7, 1)
p keyed.last_key
keyed.write(["users", 7, :posts], 1)
p keyed.last_key
keyed.write(["a", ["b", "c"]], 1)
p keyed.last_key
p keyed.read(["users", 7, :posts])
p keyed.read("users/7/posts")
keyed.write(note_at(5, "2026-11-01T09:05:03.123Z"), 1)
p keyed.last_key
keyed.write(["feed", note_at(5, "2026-11-01T09:05:03.123Z")], 1)
p keyed.last_key
p keyed.exist?(note_at(5, "2026-11-01T09:05:03.123Z"))
p keyed.exist?(note_at(5, "2026-11-02T00:00:00.000Z"))
report_error("model without updated_at") { keyed.write(Plain.new(title: "a"), 1) }
report_error("invalid UTF-8 key") { keyed.write("k\xFF", 1) }
report_error("binary key") { keyed.write(["a", "\xFF".b], 1) }
binary_key = "a" + ("日" * 300).b
binary_spy = SpyStore.new
binary_spy.write(binary_key, 1)
p binary_spy.last_key.bytesize <= 512
p binary_spy.last_key.valid_encoding?
p binary_spy.read(binary_key)
accented = SpyStore.new(namespace: "café")
accented.write("日本".b, 1)
p accented.last_key
p accented.read("日本")
report_error("NUL key") { keyed.write("a\0b", 1) }
report_error("NUL in an Array key") { keyed.read(["a", "b\0"]) }
report_error("namespace with NUL") { SpyStore.new(namespace: "a\0").write("b", 1) }
report_error("Float key") { keyed.write(1.5, 1) }
report_error("nil key") { keyed.write(nil, 1) }
report_error("Hash key") { keyed.write({ "a" => 1 }, 1) }
report_error("Array with a Float") { keyed.write(["a", 1.5], 1) }
report_error("blank key") { keyed.write("", 1) }
report_error("blank array key") { keyed.read([]) }

puts "-- namespace"
spaced = SpyStore.new(namespace: "v1")
spaced.write("key", 1)
p spaced.last_key
spaced.write(["a", "b"], 1)
p spaced.last_key
p spaced.read("key")
p spaced.exist?("key")
p spaced.delete("key")
p spaced.exist?("key")
other = SpyStore.new(namespace: "v2")
p other.read("a/b")

puts "-- long keys"
long = SpyStore.new
exact = "k" * 512
long.write(exact, 1)
p long.last_key == exact
over = "k" * 513
long.write(over, 1)
p long.last_key.bytesize
p long.last_key == "#{"k" * 447}:#{Digest::SHA256.hexdigest(over)}"
first_key = "same-start-" + "a" * 600
second_key = "same-start-" + "a" * 599 + "b"
long.write(first_key, 1)
shortened = long.last_key
long.write(second_key, 2)
p shortened == long.last_key
p long.read(first_key)
p long.read(second_key)
multibyte = "日" * 300
long.write(multibyte, 1)
p long.last_key.bytesize <= 512
p long.last_key.valid_encoding?
p long.read(multibyte)
long_spaced = SpyStore.new(namespace: "n" * 100)
long_spaced.write("x" * 500, 1)
p long_spaced.last_key.bytesize
p long_spaced.last_key.start_with?("n" * 100 + ":x")

puts "-- foreign and damaged texts"
damaged = SpyStore.new
damaged.write_text("not json", "{oops", 0)
damaged.write_text("no envelope", "[1,2]", 0)
damaged.write_text("no value", "{\"e\":5}", 0)
damaged.write_text("odd expiry", "{\"v\":1,\"e\":\"soon\"}", 0)
p damaged.read("not json")
p damaged.exist?("not json")
p damaged.exist?("no envelope")
p damaged.exist?("no value")
p damaged.read("odd expiry")

puts "-- NullStore"
null_store = Edgeway::Cache::NullStore.new
p null_store.write("a", 1)
p null_store.read("a")
p null_store.exist?("a")
null_calls = 0
p null_store.fetch("a") { null_calls += 1; "x" }
p null_store.fetch("a") { null_calls += 1; "y" }
p null_calls
p null_store.delete("a")
report_error("NullStore invalid value") { null_store.write("a", Object.new) }

puts "-- Edgeway.cache"
p Edgeway.cache.class.name
Edgeway.cache = Edgeway::Cache::MemoryStore.new
Edgeway.cache.write("shared", "yes")
p Edgeway.cache.read("shared")
Edgeway.cache = Edgeway::Cache::NullStore.new
p Edgeway.cache.read("shared")

puts "-- failures"
logger = RecordingLogger.new
Edgeway.logger = logger
failing = FailingStore.new
p failing.read("key")
p failing.exist?("key")
p failing.write("key", "value")
p failing.delete("key")
runs = 0
p failing.fetch("key") { runs += 1; "computed" }
p failing.fetch("key") { runs += 1; "computed again" }
p runs
puts logger.lines

puts "-- fetch without a block"
p store.fetch("fetched")
p store.fetch("never stored")
report_error("force without a block") { store.fetch("fetched", force: true) }
p store.read("fetched")

puts "-- force and skip_nil"
forced_nil = store.fetch("forced nil", force: true, skip_nil: true) { nil }
p forced_nil
p store.exist?("forced nil")
store.write("kept", "old")
p store.fetch("kept", force: true, skip_nil: true) { nil }
p store.read("kept")
p store.fetch("kept", force: true, skip_nil: true) { "new" }
p store.read("kept")

puts "-- a call's expires_in over the store's default"
defaulted = SpyStore.new(expires_in: 100)
defaulted.write("a", 1, expires_in: 10)
puts defaulted.text_of("a")
defaulted.fetch("b", expires_in: 20) { 2 }
puts defaulted.text_of("b")
defaulted.fetch("c") { 3 }
puts defaulted.text_of("c")
TestClock.now = 1015
p defaulted.read("a")
p defaulted.read("b")
p defaulted.read("c")
TestClock.now = 1000

puts "-- KVStore over a transport"
report_error("dot key") { Edgeway::Cloudflare::KVStore.new(binding: "CACHE", transport: FakeTransport.new({})).read(".") }
report_error("dot dot key") { Edgeway::Cloudflare::KVStore.new(binding: "CACHE", transport: FakeTransport.new({})).write("..", 1) }
report_error("dot dot delete") { Edgeway::Cloudflare::KVStore.new(binding: "CACHE", transport: FakeTransport.new({})).delete("..") }
p Edgeway::Cache::MemoryStore.new.write(".", 1)
logger = RecordingLogger.new
Edgeway.logger = logger
hit_calls = FakeTransport.new({ "get" => "{\"value\":\"{\\\"v\\\":[1,2]}\"}", "put" => "{\"ok\":true}", "delete" => "{\"ok\":true}" })
hit = ClockedKVStore.new(binding: "CACHE", namespace: "app", transport: hit_calls)
p hit.read("key")
p hit.exist?("key")
p hit.write("key", [1, 2], expires_in: 30)
p hit.delete("key")
puts hit_calls.calls
hit_transport = FakeTransport.new({ "get" => "{\"value\":null}", "put" => "{\"ok\":true}", "delete" => "{\"ok\":true}" })
miss = ClockedKVStore.new(binding: "CACHE", expires_in: 90, transport: hit_transport)
p miss.read("key")
p miss.exist?("key")
p miss.fetch("key") { "computed" }
puts hit_transport.calls
p logger.lines.size

broken_transport = FakeTransport.new({
  "get" => "{\"error\":\"KV GET failed: 500\"}",
  "put" => "{\"error\":\"KV PUT failed: 429 Too Many Requests\"}",
  "delete" => "{\"error\":\"KV DELETE failed: 500\"}"
})
broken = Edgeway::Cloudflare::KVStore.new(binding: "CACHE", transport: broken_transport)
p broken.read("secret-key")
p broken.exist?("secret-key")
p broken.write("secret-key", "x")
p broken.delete("secret-key")
p broken.fetch("secret-key") { "computed" }
puts logger.lines
p logger.lines.any? { |line| line.include?("secret-key") }
