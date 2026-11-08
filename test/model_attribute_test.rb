require "spinel_test/unit"
require "edgeway"
require "edgeway/db/memory"

class ModelAttributeTest < SpinelTest::Unit::TestCase
  class ApplicationModel < Edgeway::Model::Base
    extend Edgeway::Model::Macros
  end

  class Attachment < ApplicationModel
    attribute :name, :string
    attribute :data, :binary
  end

  class Ledger < ApplicationModel
    attribute :id, :bigint
    attribute :total, :bigint
  end

  class Sized < ApplicationModel
    attribute :data, :binary
    validates :data, presence: true, length: { maximum: 3 }
  end

  class Reference < ApplicationModel
    attribute :ticket_id, :integer
    attribute :note, :string
  end

  BYTES = [0, 1, 255, 0, 128]
  BASE64 = "AAH/AIA="
  BLOB_SHAPE = '{"$blob" => "AAH/AIA="}'
  ATTACHMENT_ROW = { "id" => 1, "name" => "a", "data" => { "$blob" => BASE64 } }
  INSERT_ATTACHMENT = "INSERT INTO attachments (name, data) VALUES (?, ?) RETURNING id, name, data | [\"a\",{\"$blob\":\"AAH/AIA=\"}]"
  SELECT_ATTACHMENT_BY_DATA = "SELECT id, name, data FROM attachments WHERE data = ? ORDER BY id ASC LIMIT 1 | [{\"$blob\":\"AAH/AIA=\"}]"
  UPDATE_ATTACHMENT = "UPDATE attachments SET name = ?, data = ? WHERE id = ? | [\"a\",{\"$blob\":\"eA==\"},1]"
  SELECT_LEDGER = "SELECT id, total FROM ledgers WHERE id = ? LIMIT 1 | [\"3000000000\"]"
  UPDATE_LEDGER = "UPDATE ledgers SET total = ? WHERE id = ? | [\"12\",\"3000000000\"]"
  DELETE_LEDGER = "DELETE FROM ledgers WHERE id = ? | [\"3000000000\"]"
  SELECT_REFERENCE = "SELECT id, ticket_id, note FROM references ORDER BY id ASC LIMIT 1 | []"

  def setup
    @database = Edgeway::DB::MemoryAdapter.new
    Edgeway::Model.connection = @database
    @raw = BYTES.pack("C*")
  end

  def teardown
    Edgeway::Model.freeze_time(nil)
    Edgeway::Model.disconnect(Edgeway::Model::PRIMARY)
  end

  def bigint_cast_inspect(text)
    Edgeway::Model.cast(:bigint, text).inspect
  end

  def last_insert_id_inspect(id)
    @database.last_insert_id_of(id).inspect
  end

  def saved_attachment
    attachment = Attachment.new(name: "a", data: @raw)
    @database.queue([ATTACHMENT_ROW])
    attachment.save
    @database.log.clear
    attachment
  end

  def found_ledger
    @database.queue([{ "id" => 3000000000, "total" => 9007199254740991 }])
    ledger = Ledger.find("3000000000")
    @database.log.clear
    ledger
  end

  def attachment_from_params(data)
    Attachment.new(Edgeway::HTTP::Parameters.new({ "data" => data }, true))
  end

  def sized_errors(data)
    sized = Sized.new(data: data)
    sized.valid?
    sized.errors.inspect
  end

  def test_now_without_a_frozen_time_is_utc_with_three_digits_of_milliseconds
    # so the strings sort in time order
    Edgeway::Model.freeze_time(nil)
    assert_equal "true", Edgeway::Model.now.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/).inspect
  end

  def test_binary_cast_keeps_the_bytes_of_a_string
    assert_equal "[0, 1, 255, 0, 128]", Edgeway::Model.cast(:binary, @raw).bytes.inspect
  end

  def test_binary_cast_decodes_a_blob_hash
    assert_equal "[0, 1, 255, 0, 128]", Edgeway::Model.cast(:binary, { "$blob" => BASE64 }).bytes.inspect
  end

  def test_binary_cast_of_an_empty_blob_is_empty_bytes
    assert_equal 0, Edgeway::Model.cast(:binary, { "$blob" => "" }).bytesize
  end

  def test_binary_cast_of_a_hash_without_blob_is_nil
    assert_equal "nil", Edgeway::Model.cast(:binary, { "other" => 1 }).inspect
  end

  def test_binary_cast_of_invalid_base64_is_nil
    assert_equal "nil", Edgeway::Model.cast(:binary, { "$blob" => "!!" }).inspect
  end

  def test_binary_cast_of_nil_is_nil
    assert_equal "nil", Edgeway::Model.cast(:binary, nil).inspect
  end

  def test_blob_wraps_the_base64_of_the_bytes
    assert_equal BLOB_SHAPE, Edgeway::Model.blob(@raw).inspect
  end

  def test_database_value_of_a_binary_is_a_blob
    assert_equal BLOB_SHAPE, Edgeway::Model.database_value(@raw, :binary).inspect
  end

  def test_database_value_of_a_string_without_a_type_keeps_the_bytes
    assert_equal "[0, 1, 255, 0, 128]", Edgeway::Model.database_value(@raw).bytes.inspect
  end

  def test_database_value_of_a_nil_binary_is_nil
    assert_equal "nil", Edgeway::Model.database_value(nil, :binary).inspect
  end

  def test_bigint_cast_keeps_integral_strings_and_integers_as_strings
    assert_equal '"3000000000"', bigint_cast_inspect("3000000000")
    assert_equal '"3000000000"', Edgeway::Model.cast(:bigint, 3000000000).inspect
    assert_equal '"-5"', bigint_cast_inspect("-5")
    assert_equal '"7"', Edgeway::Model.cast(:bigint, 7).inspect
  end

  def test_bigint_cast_inspect_anything_not_integral_is_nil
    assert_equal "nil", bigint_cast_inspect("")
    assert_equal "nil", bigint_cast_inspect("1.5")
    assert_equal "nil", bigint_cast_inspect("12a")
    assert_equal "nil", bigint_cast_inspect(" 1")
    assert_equal "nil", Edgeway::Model.cast(:bigint, 1.5).inspect
    assert_equal "nil", Edgeway::Model.cast(:bigint, true).inspect
  end

  def test_bigint_cast_normalizes_leading_zeros_and_negative_zero
    assert_equal '"7"', bigint_cast_inspect("007")
    assert_equal '"0"', bigint_cast_inspect("-0")
    assert_equal '"-7"', bigint_cast_inspect("-007")
    assert_equal '"0"', bigint_cast_inspect("0")
    assert_equal '"1"', bigint_cast_inspect("00000000000000000000001")
  end

  def test_bigint_cast_is_bounded_by_the_signed_64_bit_range
    assert_equal '"9223372036854775807"', bigint_cast_inspect("9223372036854775807")
    assert_equal "nil", bigint_cast_inspect("9223372036854775808")
    assert_equal '"-9223372036854775808"', bigint_cast_inspect("-9223372036854775808")
    assert_equal "nil", bigint_cast_inspect("-9223372036854775809")
  end

  def test_database_value_of_a_bigint_string_stays_a_string
    assert_equal '"3000000000"', Edgeway::Model.database_value("3000000000", :bigint).inspect
  end

  def test_a_new_attachment_holds_the_bytes_and_serializes_them_as_base64
    attachment = Attachment.new(name: "a", data: @raw)
    assert_equal "[0, 1, 255, 0, 128]", attachment.data.bytes.inspect
    assert_equal '{"id" => nil, "name" => "a", "data" => "AAH/AIA="}', attachment.as_json.inspect
  end

  def test_saving_an_attachment_sends_the_data_as_a_blob
    attachment = Attachment.new(name: "a", data: @raw)
    @database.queue([ATTACHMENT_ROW])
    attachment.save
    assert_equal [INSERT_ATTACHMENT], @database.log
    assert_equal "[0, 1, 255, 0, 128]", attachment.data.bytes.inspect
  end

  def test_finding_by_binary_data_sends_a_blob_and_decodes_the_row
    @database.queue([ATTACHMENT_ROW])
    found = Attachment.where(data: @raw).first
    assert_equal '{"id" => 1, "name" => "a", "data" => "AAH/AIA="}', found.as_json.inspect
    assert_equal [SELECT_ATTACHMENT_BY_DATA], @database.log
  end

  def test_updating_an_attachment_sends_the_new_data_as_a_blob
    attachment = saved_attachment
    attachment.data = "x"
    attachment.save
    assert_equal [UPDATE_ATTACHMENT], @database.log
  end

  def test_finding_a_ledger_by_a_bigint_string_keeps_the_values_as_strings
    ledger = found_ledger
    assert_equal '"3000000000"', ledger.id.inspect
    assert_equal '"9007199254740991"', ledger.total.inspect
    assert_equal '{"id" => "3000000000", "total" => "9007199254740991"}', ledger.as_json.inspect
  end

  def test_finding_a_ledger_binds_the_bigint_id_as_a_string
    @database.queue([{ "id" => 3000000000, "total" => 9007199254740991 }])
    Ledger.find("3000000000")
    assert_equal [SELECT_LEDGER], @database.log
  end

  def test_updating_a_ledger_binds_the_bigints_as_strings
    ledger = found_ledger
    ledger.total = 12
    ledger.save
    assert_equal [UPDATE_LEDGER], @database.log
  end

  def test_destroying_a_ledger_binds_the_bigint_id_as_a_string
    ledger = found_ledger
    ledger.destroy
    assert_equal [DELETE_LEDGER], @database.log
  end

  def test_a_ledger_total_that_is_not_an_integer_is_nil_and_invalid
    ledger = Ledger.new(total: "12x")
    assert_equal "nil", ledger.total.inspect
    assert_equal "false", ledger.valid?.inspect
    assert_equal '["total is invalid"]', ledger.errors.inspect
  end

  def test_last_insert_id_stays_an_integer_within_32_bits
    assert_equal "5", last_insert_id_inspect(5)
    assert_equal "2147483647", last_insert_id_inspect(2147483647)
    assert_equal "-2147483648", last_insert_id_inspect(-2147483648)
  end

  def test_last_insert_id_beyond_32_bits_becomes_a_decimal_string
    assert_equal '"2147483648"', last_insert_id_inspect(2147483648)
    assert_equal '"-2147483649"', last_insert_id_inspect(-2147483649)
    assert_equal '"9007199254740991"', last_insert_id_inspect(9007199254740991)
  end

  def test_last_insert_id_of_nil_is_zero
    assert_equal "0", @database.last_insert_id_of(nil).inspect
  end

  def test_last_insert_id_of_a_parsed_json_number
    assert_equal '"3000000000"', @database.last_insert_id_of(JSON.parse('{"id":3000000000}')["id"]).inspect
  end

  def test_request_params_decode_a_base64_binary_attribute
    params = Edgeway::HTTP::Parameters.new({ "name" => "p", "data" => BASE64 }, true)
    assert_equal "[0, 1, 255, 0, 128]", Attachment.new(params).data.bytes.inspect
  end

  def test_request_params_with_empty_base64_are_empty_bytes
    assert_equal 0, attachment_from_params("").data.bytesize
  end

  def test_request_params_with_invalid_base64_are_nil_and_invalid
    attachment = attachment_from_params("!!")
    assert_equal "nil", attachment.data.inspect
    assert_equal "false", attachment.valid?.inspect
    assert_equal '["data is invalid"]', attachment.errors.inspect
  end

  def test_assigned_attributes_that_are_not_params_are_not_base64_decoded
    assert_equal "[65, 65, 72, 47]", Attachment.new(data: "AAH/").data.bytes.inspect
  end

  def test_binary_presence_accepts_zero_bytes
    assert_equal "true", Sized.new(data: [0, 0].pack("C*")).valid?.inspect
  end

  def test_binary_presence_rejects_empty_data
    assert_equal '["data can\'t be blank"]', sized_errors("")
  end

  def test_binary_length_is_counted_in_bytes
    assert_equal '["data is too long (maximum is 3 bytes)"]', sized_errors("abcd")
    assert_equal '["data is too long (maximum is 3 bytes)"]', sized_errors("\u00e9\u00e9")
  end

  def test_an_integer_attribute_reads_nil_for_a_stored_value_it_cannot_hold
    @database.queue([{ "id" => 1, "ticket_id" => 5000000000, "note" => "a" }])
    assert_equal "nil", Reference.first.ticket_id.inspect
  end

  def test_saving_a_record_with_an_out_of_range_integer_is_refused_and_sends_nothing
    @database.queue([{ "id" => 1, "ticket_id" => 5000000000, "note" => "a" }])
    reference = Reference.first
    assert_equal [SELECT_REFERENCE], @database.log
    @database.log.clear
    assert_equal "false", reference.update(note: "b").inspect
    assert_equal '["ticket_id is out of range"]', reference.errors.inspect
    assert_equal [], @database.log
  end
end
