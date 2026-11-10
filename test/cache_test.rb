require "spinel_test/unit"
require "edgeway"
require "edgeway/db/memory"
require "edgeway/service/cloudflare/kv_store"

class CacheTest < SpinelTest::Unit::TestCase
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

  module Clock
    @now = 0

    def self.now = @now

    def self.now=(seconds)
      @now = seconds
    end
  end

  class ClockedMemoryStore < Edgeway::Cache::MemoryStore
    def current_time = Clock.now
  end

  class ClockedKVStore < Edgeway::Cloudflare::KVStore
    def current_time = Clock.now
  end

  class LogCollector < Edgeway::Logger
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

  class SharedMemoryStore < Edgeway::Cache::MemoryStore
    def initialize(texts, namespace: nil)
      super(namespace: namespace)
      @texts = texts
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
    attr_reader :keys, :seconds

    def initialize(namespace: nil, expires_in: nil)
      super(namespace: namespace, expires_in: expires_in)
      @keys = []
      @seconds = []
    end

    def write_text(key, text, expires_in_seconds)
      @keys << key
      @seconds << expires_in_seconds
      super(key, text, expires_in_seconds)
    end

    def text_of(key) = read_text(key)
  end

  NOTE_UPDATED_AT = "2026-11-01T09:05:03.123Z"
  NOTE_KEY = "notes/5-#{NOTE_UPDATED_AT}"

  EXPIRES_IN_MESSAGE = "expires_in must be a whole number of seconds, 1 to 31536000"
  TEXT_MESSAGE = "a String to cache must be valid UTF-8 (a binary String is not)"
  NOT_CACHEABLE_SUFFIX = "can't be cached (String, Integer, Float, true, false, nil, Array and Hash can)"
  KEY_UTF8_MESSAGE = "cache key must be valid UTF-8"
  KEY_NUL_MESSAGE = "cache key can't contain a NUL byte"
  KEY_BLANK_MESSAGE = "cache key can't be blank"
  KEY_DOT_MESSAGE = "cache key can't be . or .."

  READ_FAILED_LOG = "read failed (binding CACHE) {}"
  WRITE_FAILED_LOG = "write failed (binding CACHE) {}"
  DELETE_FAILED_LOG = "delete failed (binding CACHE) {}"
  KV_GET_FAILED_LOG = "cache operation failed {\"operation\":\"get\",\"binding\":\"CACHE\",\"error\":\"KV GET failed: 500\"}"
  KV_PUT_FAILED_LOG = "cache operation failed {\"operation\":\"put\",\"binding\":\"CACHE\",\"error\":\"KV PUT failed: 429 Too Many Requests\"}"
  KV_DELETE_FAILED_LOG = "cache operation failed {\"operation\":\"delete\",\"binding\":\"CACHE\",\"error\":\"KV DELETE failed: 500\"}"

  KV_OK_ANSWER = "{\"ok\":true}"

  def setup
    @original_cache = Edgeway.cache
    @original_logger = Edgeway.logger
    Clock.now = 1000
    @log = LogCollector.new
    Edgeway.logger = @log
    @store = ClockedMemoryStore.new
  end

  def teardown
    Edgeway.cache = @original_cache
    Edgeway.logger = @original_logger
  end

  def note_at(id, updated_at)
    Note.instantiate({ "id" => id, "title" => "t", "created_at" => "2026-01-01T00:00:00.000Z", "updated_at" => updated_at })
  end

  def hash_key_message(class_name)
    "a Hash to cache needs String or Symbol keys (got #{class_name})"
  end

  def key_type_message(class_name)
    "a cache key is a String, Symbol, Integer, model or an Array of them (got #{class_name})"
  end

  def assert_argument_error(message, &block)
    error = assert_raise(ArgumentError, &block)
    assert_equal message, error.message
  end

  def assert_value_rejected(message, &block)
    assert_argument_error(message, &block)
    assert_equal false, @store.exist?("bad")
  end

  def assert_expires_in_rejected(&block)
    assert_argument_error(EXPIRES_IN_MESSAGE, &block)
  end

  def kv_transport(get_answer)
    FakeTransport.new({ "get" => get_answer, "put" => KV_OK_ANSWER, "delete" => KV_OK_ANSWER })
  end

  def hit_transport = kv_transport("{\"value\":\"{\\\"v\\\":[1,2]}\"}")

  def miss_transport = kv_transport("{\"value\":null}")

  def broken_transport
    FakeTransport.new({
      "get" => "{\"error\":\"KV GET failed: 500\"}",
      "put" => "{\"error\":\"KV PUT failed: 429 Too Many Requests\"}",
      "delete" => "{\"error\":\"KV DELETE failed: 500\"}"
    })
  end

  def kv_store(transport, namespace: nil, expires_in: nil)
    ClockedKVStore.new(binding: "CACHE", namespace: namespace, expires_in: expires_in, transport: transport)
  end

  def test_a_missing_key_reads_as_nil
    assert_nil @store.read("missing")
  end

  def test_a_missing_key_does_not_exist
    assert_equal false, @store.exist?("missing")
  end

  def test_write_returns_true
    assert_equal true, @store.write("greeting", "hello")
  end

  def test_a_written_string_reads_back_and_exists
    @store.write("greeting", "hello")
    assert_equal "hello", @store.read("greeting")
    assert_equal true, @store.exist?("greeting")
  end

  def test_delete_removes_the_entry_and_returns_true
    @store.write("greeting", "hello")
    assert_equal true, @store.delete("greeting")
    assert_nil @store.read("greeting")
  end

  def test_deleting_a_missing_key_returns_true
    @store.write("greeting", "hello")
    @store.delete("greeting")
    assert_equal true, @store.delete("greeting")
  end

  def test_an_integer_reads_back_as_an_integer
    @store.write("integer", 42)
    assert_equal "43", (@store.read("integer") + 1).inspect
  end

  def test_a_float_reads_back_as_a_float
    @store.write("float", 2.5)
    assert_equal 2.5, @store.read("float")
  end

  def test_true_reads_back_as_true
    @store.write("true", true)
    assert_equal true, @store.read("true")
  end

  def test_false_reads_back_as_false
    @store.write("false", false)
    assert_equal false, @store.read("false")
  end

  def test_nil_reads_back_as_nil
    @store.write("nil", nil)
    assert_nil @store.read("nil")
  end

  def test_a_multibyte_string_reads_back
    @store.write("text", "café 日本")
    assert_equal "café 日本", @store.read("text")
  end

  def test_an_array_reads_back_with_the_type_of_every_item
    @store.write("array", [1, "two", 3.5, nil, true, [4]])
    assert_equal "[1, \"two\", 3.5, nil, true, [4]]", @store.read("array").inspect
  end

  def test_a_hash_reads_back_in_its_key_order
    @store.write("hash", { "name" => "a", "list" => [1, 2], "nested" => { "k" => nil } })
    assert_equal "{\"name\" => \"a\", \"list\" => [1, 2], \"nested\" => {\"k\" => nil}}", @store.read("hash").inspect
  end

  def test_a_hash_with_symbol_keys_reads_back_with_string_keys
    @store.write("symbol keys", { name: "a", count: 2 })
    assert_equal "{\"name\" => \"a\", \"count\" => 2}", @store.read("symbol keys").inspect
  end

  def test_a_stored_nil_exists
    @store.write("nil", nil)
    assert_equal true, @store.exist?("nil")
  end

  def test_a_stored_false_exists
    @store.write("false", false)
    assert_equal true, @store.exist?("false")
  end

  def test_an_invalid_utf8_string_is_rejected
    assert_value_rejected(TEXT_MESSAGE) { @store.write("bad", "caf\xC3") }
  end

  def test_an_invalid_utf8_string_inside_a_structure_is_rejected
    assert_value_rejected(TEXT_MESSAGE) { @store.write("bad", ["ok", { "k" => "\xFF" }]) }
  end

  def test_a_binary_string_is_rejected
    assert_value_rejected(TEXT_MESSAGE) { @store.write("bad", "caf\xC3".b) }
  end

  def test_a_binary_string_inside_a_structure_is_rejected
    assert_value_rejected(TEXT_MESSAGE) { @store.write("bad", { "k" => ["\xFF".b] }) }
  end

  def test_a_binary_string_that_is_ascii_reads_back
    @store.write("ascii binary", "plain".b)
    assert_equal "plain", @store.read("ascii binary")
  end

  def test_a_hash_with_an_integer_key_is_rejected
    assert_value_rejected(hash_key_message("Integer")) { @store.write("bad", { 1 => 2 }) }
  end

  def test_a_hash_with_a_nil_key_is_rejected
    assert_value_rejected(hash_key_message("NilClass")) { @store.write("bad", { nil => 3 }) }
  end

  def test_a_hash_with_the_same_key_as_a_string_and_a_symbol_is_rejected
    message = "a Hash to cache has the same key twice (as a String and a Symbol)"
    assert_value_rejected(message) { @store.write("bad", { "a" => 1, :a => 2 }) }
  end

  def test_an_object_is_rejected
    assert_value_rejected("Object #{NOT_CACHEABLE_SUFFIX}") { @store.write("bad", Object.new) }
  end

  def test_a_model_is_rejected
    assert_value_rejected("CacheTest::Note #{NOT_CACHEABLE_SUFFIX}") { @store.write("bad", Note.new(title: "a")) }
  end

  def test_nan_is_rejected
    assert_value_rejected("a Float to cache must be finite") { @store.write("bad", 0.0 / 0.0) }
  end

  def test_infinity_inside_an_array_is_rejected
    assert_value_rejected("a Float to cache must be finite") { @store.write("bad", [1.0 / 0.0]) }
  end

  def test_a_plain_write_stores_the_value_without_an_expiry
    spy = SpyStore.new
    spy.write("plain", { "a" => 1 })
    assert_equal "{\"v\":{\"a\":1}}", spy.text_of("plain")
    assert_equal [0], spy.seconds
  end

  def test_a_write_with_expires_in_stores_the_expiry_time
    spy = SpyStore.new
    spy.write("timed", "x", expires_in: 90)
    assert_equal "{\"v\":\"x\",\"e\":1090}", spy.text_of("timed")
    assert_equal [90], spy.seconds
  end

  def test_a_written_nil_is_stored_in_the_envelope
    spy = SpyStore.new
    spy.write("nil", nil)
    assert_equal "{\"v\":null}", spy.text_of("nil")
    assert_equal ["nil"], spy.keys
  end

  def test_an_entry_is_readable_one_second_before_it_expires
    @store.write("short", "x", expires_in: 10)
    assert_equal "x", @store.read("short")
    Clock.now = 1009
    assert_equal "x", @store.read("short")
  end

  def test_an_entry_is_gone_at_the_second_it_expires
    @store.write("short", "x", expires_in: 10)
    Clock.now = 1010
    assert_nil @store.read("short")
    assert_equal false, @store.exist?("short")
  end

  def test_reading_an_expired_entry_does_not_remove_it
    @store.write("short", "x", expires_in: 10)
    Clock.now = 1010
    assert_nil @store.read("short")
    Clock.now = 1000
    assert_equal "x", @store.read("short")
  end

  def test_an_entry_without_expires_in_outlives_an_expiring_one
    @store.write("short", "x", expires_in: 10)
    @store.write("forever", "y")
    Clock.now = 1010
    assert_nil @store.read("short")
    assert_equal "y", @store.read("forever")
  end

  def test_an_entry_without_expires_in_is_still_there_a_year_later
    @store.write("forever", "y")
    Clock.now = 1000 + 31_536_000
    assert_equal "y", @store.read("forever")
  end

  def test_an_entry_written_at_time_zero_is_readable_one_second_before_it_expires
    Clock.now = 0
    @store.write("at zero", "x", expires_in: 5)
    Clock.now = 4
    assert_equal "x", @store.read("at zero")
  end

  def test_an_entry_written_at_time_zero_is_gone_at_the_second_it_expires
    Clock.now = 0
    @store.write("at zero", "x", expires_in: 5)
    Clock.now = 5
    assert_nil @store.read("at zero")
  end

  def test_expires_in_of_zero_is_rejected
    assert_expires_in_rejected { @store.write("bad", "x", expires_in: 0) }
  end

  def test_a_negative_expires_in_is_rejected
    assert_expires_in_rejected { @store.write("bad", "x", expires_in: -5) }
  end

  def test_a_float_expires_in_is_rejected
    assert_expires_in_rejected { @store.write("bad", "x", expires_in: 1.5) }
  end

  def test_a_string_expires_in_is_rejected
    assert_expires_in_rejected { @store.write("bad", "x", expires_in: "60") }
  end

  def test_an_expires_in_over_a_year_is_rejected
    assert_expires_in_rejected { @store.write("bad", "x", expires_in: 31_536_001) }
  end

  def test_a_default_expires_in_of_zero_is_rejected
    assert_expires_in_rejected { Edgeway::Cache::MemoryStore.new(expires_in: 0) }
  end

  def test_an_expires_in_of_exactly_a_year_is_accepted
    assert_equal true, @store.write("edge", "x", expires_in: 31_536_000)
  end

  def test_the_default_expires_in_applies_to_a_write
    timed = SpyStore.new(expires_in: 30)
    timed.write("a", 1)
    assert_equal [30], timed.seconds
    assert_equal "{\"v\":1,\"e\":1030}", timed.text_of("a")
  end

  def test_the_default_expiry_keeps_the_entry_one_second_before_it_passes
    timed = SpyStore.new(expires_in: 30)
    timed.write("a", 1)
    Clock.now = 1029
    assert_equal "1", timed.read("a").inspect
  end

  def test_the_default_expiry_passes_at_its_second
    timed = SpyStore.new(expires_in: 30)
    timed.write("a", 1)
    Clock.now = 1030
    assert_nil timed.read("a")
  end

  def test_an_expires_in_of_a_write_replaces_the_default
    timed = SpyStore.new(expires_in: 30)
    timed.write("b", 2, expires_in: 5)
    assert_equal [5], timed.seconds
  end

  def test_the_default_expiry_entry_outlives_a_shorter_one_written_with_its_own_expires_in
    timed = SpyStore.new(expires_in: 30)
    timed.write("a", 1)
    timed.write("b", 2, expires_in: 5)
    Clock.now = 1006
    assert_equal "1", timed.read("a").inspect
    assert_nil timed.read("b")
  end

  def test_a_write_with_its_own_expires_in_is_readable_one_second_before_it_expires
    timed = SpyStore.new(expires_in: 30)
    timed.write("b", 2, expires_in: 5)
    Clock.now = 1004
    assert_equal "2", timed.read("b").inspect
  end

  def test_a_write_with_its_own_expires_in_is_gone_at_its_second
    timed = SpyStore.new(expires_in: 30)
    timed.write("b", 2, expires_in: 5)
    Clock.now = 1005
    assert_nil timed.read("b")
  end

  def test_a_write_with_its_own_expires_in_is_gone_after_its_second
    timed = SpyStore.new(expires_in: 30)
    timed.write("b", 2, expires_in: 5)
    Clock.now = 1006
    assert_nil timed.read("b")
  end

  def test_fetch_runs_the_block_once_and_returns_the_cached_value_after
    spy = SpyStore.new
    runs = 0
    first = spy.fetch("fetched") { runs += 1; "computed" }
    second = spy.fetch("fetched") { runs += 1; "again" }
    assert_equal "computed", first
    assert_equal "computed", second
    assert_equal 1, runs
    assert_equal ["fetched"], spy.keys
  end

  def test_fetch_with_force_runs_the_block_and_replaces_the_entry
    runs = 0
    @store.fetch("fetched") { runs += 1; "computed" }
    assert_equal "forced", @store.fetch("fetched", force: true) { runs += 1; "forced" }
    assert_equal "forced", @store.read("fetched")
    assert_equal 2, runs
  end

  def test_fetch_returns_the_block_value_as_its_own_type
    runs = 0
    assert_equal "42", (@store.fetch("count") { runs += 1; 41 } + 1).inspect
    assert_equal 1, runs
  end

  def test_fetch_of_a_hash_returns_the_block_value_and_then_the_cached_hash
    runs = 0
    first = @store.fetch("fetched hash") { runs += 1; { "n" => 1, "list" => [1, 2.5, "x", nil, true] } }
    second = @store.fetch("fetched hash") { runs += 1; { "n" => 2 } }
    assert_equal "{\"n\" => 1, \"list\" => [1, 2.5, \"x\", nil, true]}", first.inspect
    assert_equal "1", second["n"].inspect
    assert_equal 1, runs
  end

  def test_fetch_keeps_the_cached_value_one_second_before_it_expires
    runs = 0
    @store.fetch("expiring", expires_in: 5) { runs += 1; "v" }
    Clock.now = 1004
    assert_equal "v", @store.fetch("expiring", expires_in: 5) { runs += 1; "v2" }
    assert_equal 1, runs
  end

  def test_fetch_runs_the_block_again_once_the_entry_has_expired
    runs = 0
    @store.fetch("expiring", expires_in: 5) { runs += 1; "v" }
    Clock.now = 1005
    assert_equal "v2", @store.fetch("expiring", expires_in: 5) { runs += 1; "v2" }
    assert_equal 2, runs
  end

  def test_fetch_without_a_block_reads_the_entry
    @store.write("fetched", "forced")
    assert_equal "forced", @store.fetch("fetched")
  end

  def test_fetch_without_a_block_of_a_missing_key_is_nil
    assert_nil @store.fetch("never stored")
  end

  def test_fetch_with_force_and_no_block_raises_and_keeps_the_entry
    @store.write("fetched", "forced")
    assert_argument_error("missing block") { @store.fetch("fetched", force: true) }
    assert_equal "forced", @store.read("fetched")
  end

  def test_fetch_caches_a_nil_result
    runs = 0
    assert_nil @store.fetch("cached nil") { runs += 1; nil }
    assert_nil @store.fetch("cached nil") { runs += 1; "other" }
    assert_equal 1, runs
    assert_equal true, @store.exist?("cached nil")
  end

  def test_fetch_with_skip_nil_does_not_store_a_nil_result
    runs = 0
    assert_nil @store.fetch("skipped nil", skip_nil: true) { runs += 1; nil }
    assert_equal 1, runs
    assert_equal false, @store.exist?("skipped nil")
  end

  def test_fetch_computes_again_after_a_skipped_nil
    runs = 0
    @store.fetch("skipped nil", skip_nil: true) { runs += 1; nil }
    assert_equal "now", @store.fetch("skipped nil", skip_nil: true) { runs += 1; "now" }
    assert_equal "now", @store.read("skipped nil")
    assert_equal 2, runs
  end

  def test_fetch_caches_a_false_result
    runs = 0
    assert_equal false, @store.fetch("false value") { runs += 1; false }
    assert_equal false, @store.fetch("false value") { runs += 1; true }
    assert_equal 1, runs
  end

  def test_a_string_key_is_used_as_it_is
    keyed = SpyStore.new
    keyed.write("string", 1)
    assert_equal ["string"], keyed.keys
  end

  def test_a_symbol_key_is_used_by_name
    keyed = SpyStore.new
    keyed.write(:symbol, 1)
    assert_equal ["symbol"], keyed.keys
  end

  def test_an_integer_key_is_used_as_text
    keyed = SpyStore.new
    keyed.write(7, 1)
    assert_equal ["7"], keyed.keys
  end

  def test_an_array_key_is_joined_with_slashes
    keyed = SpyStore.new
    keyed.write(["users", 7, :posts], 1)
    assert_equal ["users/7/posts"], keyed.keys
  end

  def test_a_nested_array_key_is_flattened_with_slashes
    keyed = SpyStore.new
    keyed.write(["a", ["b", "c"]], 1)
    assert_equal ["a/b/c"], keyed.keys
  end

  def test_an_array_key_and_its_joined_string_are_the_same_entry
    keyed = SpyStore.new
    keyed.write(["users", 7, :posts], 1)
    assert_equal "1", keyed.read(["users", 7, :posts]).inspect
    assert_equal "1", keyed.read("users/7/posts").inspect
  end

  def test_a_model_key_has_its_table_id_and_updated_at
    keyed = SpyStore.new
    keyed.write(note_at(5, NOTE_UPDATED_AT), 1)
    assert_equal [NOTE_KEY], keyed.keys
  end

  def test_a_model_inside_an_array_key_is_joined_like_any_part
    keyed = SpyStore.new
    keyed.write(["feed", note_at(5, NOTE_UPDATED_AT)], 1)
    assert_equal ["feed/#{NOTE_KEY}"], keyed.keys
  end

  def test_a_model_with_the_same_updated_at_finds_the_entry
    keyed = SpyStore.new
    keyed.write(note_at(5, NOTE_UPDATED_AT), 1)
    assert_equal true, keyed.exist?(note_at(5, NOTE_UPDATED_AT))
  end

  def test_a_model_with_another_updated_at_does_not_find_the_entry
    keyed = SpyStore.new
    keyed.write(note_at(5, NOTE_UPDATED_AT), 1)
    assert_equal false, keyed.exist?(note_at(5, "2026-11-02T00:00:00.000Z"))
  end

  def test_a_model_without_updated_at_is_rejected_as_a_key
    assert_argument_error("CacheTest::Plain has no updated_at (add timestamps)") { @store.write(Plain.new(title: "a"), 1) }
  end

  def test_an_invalid_utf8_key_is_rejected
    assert_argument_error(KEY_UTF8_MESSAGE) { @store.write("k\xFF", 1) }
  end

  def test_a_binary_key_inside_an_array_is_rejected
    assert_argument_error(KEY_UTF8_MESSAGE) { @store.write(["a", "\xFF".b], 1) }
  end

  def test_a_binary_key_that_is_valid_utf8_is_shortened_to_a_valid_key
    binary_key = "a" + ("日" * 300).b
    spy = SpyStore.new
    spy.write(binary_key, 1)
    assert_equal true, spy.keys[0].bytesize <= 512
    assert_equal true, spy.keys[0].valid_encoding?
    assert_equal "1", spy.read(binary_key).inspect
  end

  def test_a_binary_key_is_the_same_entry_as_its_text_key_under_a_namespace
    accented = SpyStore.new(namespace: "café")
    accented.write("日本".b, 1)
    assert_equal ["café:日本"], accented.keys
    assert_equal "1", accented.read("日本").inspect
  end

  def test_a_key_with_a_nul_byte_is_rejected
    assert_argument_error(KEY_NUL_MESSAGE) { @store.write("a\0b", 1) }
  end

  def test_a_nul_byte_inside_an_array_key_is_rejected
    assert_argument_error(KEY_NUL_MESSAGE) { @store.read(["a", "b\0"]) }
  end

  def test_a_namespace_with_a_nul_byte_is_rejected
    assert_argument_error(KEY_NUL_MESSAGE) { SpyStore.new(namespace: "a\0").write("b", 1) }
  end

  def test_a_float_key_is_rejected
    assert_argument_error(key_type_message("Float")) { @store.write(1.5, 1) }
  end

  def test_a_nil_key_is_rejected
    assert_argument_error(key_type_message("NilClass")) { @store.write(nil, 1) }
  end

  def test_a_hash_key_is_rejected
    assert_argument_error(key_type_message("Hash")) { @store.write({ "a" => 1 }, 1) }
  end

  def test_a_float_inside_an_array_key_is_rejected
    assert_argument_error(key_type_message("Float")) { @store.write(["a", 1.5], 1) }
  end

  def test_a_blank_key_is_rejected
    assert_argument_error(KEY_BLANK_MESSAGE) { @store.write("", 1) }
  end

  def test_an_empty_array_key_is_rejected
    assert_argument_error(KEY_BLANK_MESSAGE) { @store.read([]) }
  end

  def test_a_namespace_prefixes_a_string_key
    spaced = SpyStore.new(namespace: "v1")
    spaced.write("key", 1)
    assert_equal ["v1:key"], spaced.keys
  end

  def test_a_namespace_prefixes_an_array_key
    spaced = SpyStore.new(namespace: "v1")
    spaced.write(["a", "b"], 1)
    assert_equal ["v1:a/b"], spaced.keys
  end

  def test_a_namespaced_entry_reads_and_exists
    spaced = SpyStore.new(namespace: "v1")
    spaced.write("key", 1)
    assert_equal "1", spaced.read("key").inspect
    assert_equal true, spaced.exist?("key")
  end

  def test_deleting_a_namespaced_entry_removes_it
    spaced = SpyStore.new(namespace: "v1")
    spaced.write("key", 1)
    assert_equal true, spaced.delete("key")
    assert_equal false, spaced.exist?("key")
  end

  def test_another_namespace_over_the_same_backing_does_not_see_the_entries
    texts = {}
    SharedMemoryStore.new(texts, namespace: "v1").write(["a", "b"], 1)
    assert_equal "1", SharedMemoryStore.new(texts, namespace: "v1").read("a/b").inspect
    assert_nil SharedMemoryStore.new(texts, namespace: "v2").read("a/b")
  end

  def test_a_key_of_the_maximum_length_is_kept
    long = SpyStore.new
    exact = "k" * 512
    long.write(exact, 1)
    assert_equal [exact], long.keys
  end

  def test_a_key_over_the_maximum_length_is_cut_and_ends_with_a_digest_of_the_whole_key
    long = SpyStore.new
    long.write("k" * 513, 1)
    assert_equal 512, long.keys[0].bytesize
    assert_equal "#{"k" * 447}:45a7c7ef95c3417e800362f5672aba16da807261fe7121f3a81b0a0fb6b9a05c", long.keys[0]
  end

  def test_long_keys_with_the_same_start_are_stored_under_different_keys
    long = SpyStore.new
    long.write("same-start-" + "a" * 600, 1)
    long.write("same-start-" + "a" * 599 + "b", 2)
    assert_equal [512, 512], long.keys.map { |key| key.bytesize }
    assert_equal 2, long.keys.uniq.length
  end

  def test_long_keys_with_the_same_start_read_back_their_own_values
    long = SpyStore.new
    first_key = "same-start-" + "a" * 600
    second_key = "same-start-" + "a" * 599 + "b"
    long.write(first_key, 1)
    long.write(second_key, 2)
    assert_equal "1", long.read(first_key).inspect
    assert_equal "2", long.read(second_key).inspect
  end

  def test_a_long_multibyte_key_is_cut_to_a_valid_key
    long = SpyStore.new
    multibyte = "日" * 300
    long.write(multibyte, 1)
    assert_equal true, long.keys[0].bytesize <= 512
    assert_equal true, long.keys[0].valid_encoding?
    assert_equal "1", long.read(multibyte).inspect
  end

  def test_a_long_key_under_a_long_namespace_keeps_the_namespace_in_its_start
    long_spaced = SpyStore.new(namespace: "n" * 100)
    long_spaced.write("x" * 500, 1)
    assert_equal 512, long_spaced.keys[0].bytesize
    assert_equal true, long_spaced.keys[0].start_with?("n" * 100 + ":x")
  end

  def test_a_text_that_is_not_json_reads_as_nil_and_does_not_exist
    damaged = SpyStore.new
    damaged.write_text("not json", "{oops", 0)
    assert_nil damaged.read("not json")
    assert_equal false, damaged.exist?("not json")
  end

  def test_a_text_without_an_envelope_does_not_exist
    damaged = SpyStore.new
    damaged.write_text("no envelope", "[1,2]", 0)
    assert_equal false, damaged.exist?("no envelope")
  end

  def test_a_text_without_a_value_does_not_exist
    damaged = SpyStore.new
    damaged.write_text("no value", "{\"e\":5000}", 0)
    assert_equal false, damaged.exist?("no value")
  end

  def test_an_expiry_that_is_not_an_integer_is_ignored
    damaged = SpyStore.new
    damaged.write_text("odd expiry", "{\"v\":1,\"e\":\"soon\"}", 0)
    assert_equal "1", damaged.read("odd expiry").inspect
  end

  def test_a_null_store_write_returns_true_and_stores_nothing
    null_store = Edgeway::Cache::NullStore.new
    assert_equal true, null_store.write("a", 1)
    assert_nil null_store.read("a")
    assert_equal false, null_store.exist?("a")
  end

  def test_a_null_store_fetch_runs_the_block_every_time
    null_store = Edgeway::Cache::NullStore.new
    runs = 0
    assert_equal "x", null_store.fetch("a") { runs += 1; "x" }
    assert_equal "y", null_store.fetch("a") { runs += 1; "y" }
    assert_equal 2, runs
  end

  def test_a_null_store_delete_returns_true
    assert_equal true, Edgeway::Cache::NullStore.new.delete("a")
  end

  def test_a_null_store_rejects_an_invalid_value
    assert_argument_error("Object #{NOT_CACHEABLE_SUFFIX}") { Edgeway::Cache::NullStore.new.write("a", Object.new) }
  end

  def test_the_default_cache_is_a_null_store
    assert_equal "Edgeway::Cache::NullStore", @original_cache.class.name
  end

  def test_a_memory_store_assigned_to_the_cache_is_used
    Edgeway.cache = Edgeway::Cache::MemoryStore.new
    Edgeway.cache.write("shared", "yes")
    assert_equal "yes", Edgeway.cache.read("shared")
  end

  def test_assigning_the_cache_replaces_the_previous_store
    Edgeway.cache = Edgeway::Cache::MemoryStore.new
    Edgeway.cache.write("shared", "yes")
    Edgeway.cache = Edgeway::Cache::NullStore.new
    assert_nil Edgeway.cache.read("shared")
  end

  def test_a_failing_store_reads_as_nil_and_logs
    assert_nil FailingStore.new.read("key")
    assert_equal [READ_FAILED_LOG], @log.lines
  end

  def test_a_failing_store_does_not_have_the_entry_and_logs
    assert_equal false, FailingStore.new.exist?("key")
    assert_equal [READ_FAILED_LOG], @log.lines
  end

  def test_a_failing_store_write_returns_false_and_logs
    assert_equal false, FailingStore.new.write("key", "value")
    assert_equal [WRITE_FAILED_LOG], @log.lines
  end

  def test_a_failing_store_delete_returns_false_and_logs
    assert_equal false, FailingStore.new.delete("key")
    assert_equal [DELETE_FAILED_LOG], @log.lines
  end

  def test_fetch_on_a_failing_store_computes_every_time_and_logs_each_read_and_write
    failing = FailingStore.new
    runs = 0
    assert_equal "computed", failing.fetch("key") { runs += 1; "computed" }
    assert_equal "computed again", failing.fetch("key") { runs += 1; "computed again" }
    assert_equal 2, runs
    assert_equal [READ_FAILED_LOG, WRITE_FAILED_LOG, READ_FAILED_LOG, WRITE_FAILED_LOG], @log.lines
  end

  def test_fetch_with_force_and_skip_nil_stores_nothing_for_a_nil_result
    assert_nil @store.fetch("forced nil", force: true, skip_nil: true) { nil }
    assert_equal false, @store.exist?("forced nil")
  end

  def test_fetch_with_force_and_skip_nil_keeps_the_old_entry_for_a_nil_result
    @store.write("kept", "old")
    assert_nil @store.fetch("kept", force: true, skip_nil: true) { nil }
    assert_equal "old", @store.read("kept")
  end

  def test_fetch_with_force_and_skip_nil_replaces_the_old_entry_for_a_value
    @store.write("kept", "old")
    assert_equal "new", @store.fetch("kept", force: true, skip_nil: true) { "new" }
    assert_equal "new", @store.read("kept")
  end

  def test_a_write_expires_in_replaces_the_store_default
    defaulted = SpyStore.new(expires_in: 100)
    defaulted.write("a", 1, expires_in: 10)
    assert_equal "{\"v\":1,\"e\":1010}", defaulted.text_of("a")
  end

  def test_a_write_expires_in_is_readable_one_second_before_it_expires_over_the_store_default
    defaulted = SpyStore.new(expires_in: 100)
    defaulted.write("a", 1, expires_in: 10)
    Clock.now = 1009
    assert_equal "1", defaulted.read("a").inspect
  end

  def test_a_write_expires_in_is_gone_at_its_second_over_the_store_default
    defaulted = SpyStore.new(expires_in: 100)
    defaulted.write("a", 1, expires_in: 10)
    Clock.now = 1010
    assert_nil defaulted.read("a")
  end

  def test_a_fetch_expires_in_replaces_the_store_default
    defaulted = SpyStore.new(expires_in: 100)
    defaulted.fetch("b", expires_in: 20) { 2 }
    assert_equal "{\"v\":2,\"e\":1020}", defaulted.text_of("b")
  end

  def test_a_fetch_expires_in_is_readable_before_and_gone_at_its_second_over_the_store_default
    defaulted = SpyStore.new(expires_in: 100)
    defaulted.fetch("b", expires_in: 20) { 2 }
    Clock.now = 1015
    assert_equal "2", defaulted.read("b").inspect
    Clock.now = 1019
    assert_equal "2", defaulted.read("b").inspect
    Clock.now = 1020
    assert_nil defaulted.read("b")
  end

  def test_a_fetch_without_expires_in_uses_the_store_default
    defaulted = SpyStore.new(expires_in: 100)
    defaulted.fetch("c") { 3 }
    assert_equal "{\"v\":3,\"e\":1100}", defaulted.text_of("c")
  end

  def test_a_fetch_without_expires_in_is_readable_until_the_store_default_passes
    defaulted = SpyStore.new(expires_in: 100)
    defaulted.fetch("c") { 3 }
    Clock.now = 1015
    assert_equal "3", defaulted.read("c").inspect
    Clock.now = 1099
    assert_equal "3", defaulted.read("c").inspect
    Clock.now = 1100
    assert_nil defaulted.read("c")
  end

  def test_a_kv_store_rejects_a_dot_key_on_read
    transport = FakeTransport.new({})
    store = kv_store(transport)
    assert_argument_error(KEY_DOT_MESSAGE) { store.read(".") }
    assert_equal [], transport.calls
  end

  def test_a_kv_store_rejects_a_dot_dot_key_on_write
    transport = FakeTransport.new({})
    store = kv_store(transport)
    assert_argument_error(KEY_DOT_MESSAGE) { store.write("..", 1) }
    assert_equal [], transport.calls
  end

  def test_a_kv_store_rejects_a_dot_dot_key_on_delete
    transport = FakeTransport.new({})
    store = kv_store(transport)
    assert_argument_error(KEY_DOT_MESSAGE) { store.delete("..") }
    assert_equal [], transport.calls
  end

  def test_a_memory_store_accepts_a_dot_key
    assert_equal true, Edgeway::Cache::MemoryStore.new.write(".", 1)
  end

  def test_a_kv_store_read_returns_the_decoded_value_from_one_get
    transport = hit_transport
    store = kv_store(transport, namespace: "app")
    assert_equal "[1, 2]", store.read("key").inspect
    assert_equal ["get CACHE app:key"], transport.calls
    assert_equal [], @log.lines
  end

  def test_a_kv_store_exist_asks_with_one_get
    transport = hit_transport
    store = kv_store(transport, namespace: "app")
    assert_equal true, store.exist?("key")
    assert_equal ["get CACHE app:key"], transport.calls
    assert_equal [], @log.lines
  end

  def test_a_kv_store_write_puts_the_envelope_and_the_expiry_under_the_namespaced_key
    transport = hit_transport
    store = kv_store(transport, namespace: "app")
    assert_equal true, store.write("key", [1, 2], expires_in: 30)
    assert_equal ["put CACHE app:key {\"v\":[1,2],\"e\":1030} 30"], transport.calls
    assert_equal [], @log.lines
  end

  def test_a_kv_store_delete_deletes_the_namespaced_key
    transport = hit_transport
    store = kv_store(transport, namespace: "app")
    assert_equal true, store.delete("key")
    assert_equal ["delete CACHE app:key"], transport.calls
    assert_equal [], @log.lines
  end

  def test_a_kv_store_read_of_a_missing_value_is_nil
    transport = miss_transport
    store = kv_store(transport, expires_in: 90)
    assert_nil store.read("key")
    assert_equal ["get CACHE key"], transport.calls
    assert_equal [], @log.lines
  end

  def test_a_kv_store_exist_of_a_missing_value_is_false
    transport = miss_transport
    store = kv_store(transport, expires_in: 90)
    assert_equal false, store.exist?("key")
    assert_equal ["get CACHE key"], transport.calls
    assert_equal [], @log.lines
  end

  def test_a_kv_store_fetch_of_a_missing_value_gets_once_and_puts_with_the_default_expiry
    transport = miss_transport
    store = kv_store(transport, expires_in: 90)
    assert_equal "computed", store.fetch("key") { "computed" }
    assert_equal ["get CACHE key", "put CACHE key {\"v\":\"computed\",\"e\":1090} 90"], transport.calls
    assert_equal [], @log.lines
  end

  def test_a_kv_store_read_that_fails_is_nil_and_logs_without_the_key
    transport = broken_transport
    store = kv_store(transport)
    assert_nil store.read("secret-key")
    assert_equal [KV_GET_FAILED_LOG], @log.lines
  end

  def test_a_kv_store_exist_that_fails_is_false_and_logs_without_the_key
    transport = broken_transport
    store = kv_store(transport)
    assert_equal false, store.exist?("secret-key")
    assert_equal [KV_GET_FAILED_LOG], @log.lines
  end

  def test_a_kv_store_write_that_fails_is_false_and_logs_without_the_key
    transport = broken_transport
    store = kv_store(transport)
    assert_equal false, store.write("secret-key", "x")
    assert_equal [KV_PUT_FAILED_LOG], @log.lines
  end

  def test_a_kv_store_delete_that_fails_is_false_and_logs_without_the_key
    transport = broken_transport
    store = kv_store(transport)
    assert_equal false, store.delete("secret-key")
    assert_equal [KV_DELETE_FAILED_LOG], @log.lines
  end

  def test_a_kv_store_fetch_that_fails_still_computes_and_logs_the_read_and_write_without_the_key
    transport = broken_transport
    store = kv_store(transport)
    assert_equal "computed", store.fetch("secret-key") { "computed" }
    assert_equal [KV_GET_FAILED_LOG, KV_PUT_FAILED_LOG], @log.lines
  end
end
