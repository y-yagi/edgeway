require_relative "test_helper"

class ModelValidationTest < DatabaseTestCase
  class ApplicationModel < Edgeway::Model::Base
    extend Edgeway::Model::Macros
  end

  class Measure < ApplicationModel
    attribute :amount, :float
    attribute :qty, :integer
    attribute :ratio, :float
    attribute :code, :string
    validates :amount, numericality: { greater_than: 0 }
    validates :qty, numericality: { only_integer: true, less_than_or_equal_to: 100 }
    validates :ratio, numericality: true
    validates :code, length: { in: 2..4 }
  end

  class Pin < ApplicationModel
    attribute :code, :string
    validates :code, length: { is: 3 }
  end

  class Project < ApplicationModel
    attribute :owner_id, :string
    attribute :name, :string
    validates :name, presence: true, uniqueness: { scope: :owner_id }
  end

  class Tag < ApplicationModel
    attribute :name, :string
    attribute :a, :string
    attribute :b, :string
    validates :name, uniqueness: true
    validates :a, uniqueness: { scope: [:b, :name] }
  end

  class Odd < ApplicationModel
    attribute :name, :string
    validates :name, uniqueness: { scope: :nope }
  end

  TAKEN = "name has already been taken"
  BLANK_NAME = "name can't be blank"
  NOT_NUMBERS = ["amount is not a number", "qty is not a number", "ratio is not a number"]

  FIND_WORK = "SELECT id, owner_id, name FROM projects WHERE name = ? AND owner_id = ? LIMIT 1 | [\"work\",\"u1\"]"
  FIND_HOME = "SELECT id, owner_id, name FROM projects WHERE name = ? AND owner_id = ? LIMIT 1 | [\"home\",\"u1\"]"
  FIND_BLANK_NAME = "SELECT id, owner_id, name FROM projects WHERE name = ? LIMIT 1 | [\"\"]"
  SCOPED_FIND_WORK = "SELECT id, owner_id, name FROM projects WHERE owner_id = ? AND name = ? LIMIT 1 | [\"u1\",\"work\"]"
  SCOPED_FIND_DEFAULT = "SELECT id, owner_id, name FROM projects WHERE owner_id = ? AND name = ? LIMIT 1 | [\"u1\",\"default\"]"
  CHECK_DEFAULT = "SELECT id, owner_id, name FROM projects WHERE name = ? AND owner_id = ? LIMIT 1 | [\"default\",\"u1\"]"
  INSERT_DEFAULT = "INSERT INTO projects (owner_id, name) VALUES (?, ?) RETURNING id, owner_id, name | [\"u1\",\"default\"]"
  SCOPED_FIND_RACE = "SELECT id, owner_id, name FROM projects WHERE owner_id = ? AND name = ? LIMIT 1 | [\"u1\",\"race\"]"
  CHECK_RACE = "SELECT id, owner_id, name FROM projects WHERE name = ? AND owner_id = ? LIMIT 1 | [\"race\",\"u1\"]"
  INSERT_RACE = "INSERT INTO projects (owner_id, name) VALUES (?, ?) RETURNING id, owner_id, name | [\"u1\",\"race\"]"
  FIND_GHOST = "SELECT id, owner_id, name FROM projects WHERE name = ? LIMIT 1 | [\"ghost\"]"
  CHECK_GHOST = "SELECT id, owner_id, name FROM projects WHERE name = ? AND owner_id IS NULL LIMIT 1 | [\"ghost\"]"
  INSERT_GHOST = "INSERT INTO projects (name) VALUES (?) RETURNING id, owner_id, name | [\"ghost\"]"
  UNIQUENESS_CHECK_U9_X = "SELECT id, owner_id, name FROM projects WHERE name = ? AND owner_id = ? LIMIT 1 | [\"x\",\"u9\"]"
  INSERT_U9_X = "INSERT INTO projects (owner_id, name) VALUES (?, ?) RETURNING id, owner_id, name | [\"u9\",\"x\"]"

  UNIQUE_FAILED = "D1_ERROR: UNIQUE constraint failed: tags.name: SQLITE_CONSTRAINT"
  NO_SUCH_TABLE = "D1_ERROR: no such table: tags: SQLITE_ERROR"

  def project_row
    { "id" => 2, "owner_id" => "u1", "name" => "work" }
  end

  def errors_of(attributes)
    measure = Measure.new(attributes)
    measure.valid?
    measure.errors
  end

  def assert_insert_fails_as(klass, message)
    @database.fail_next(message)
    error = assert_raise(klass) { @database.execute("INSERT", []) }
    assert_equal false, error.is_a?(Edgeway::RecordNotUnique)
    assert_equal ["INSERT | []"], @database.log
  end

  def assert_error_result(klass, message, json)
    error = assert_raise(klass) { @database.raise_error_result(JSON.parse(json), "d1: ") }
    assert_equal message, error.message
    assert_equal [], @database.log
  end

  def test_numericality_rejects_text_that_is_not_a_number
    assert_equal NOT_NUMBERS, errors_of(amount: "abc", qty: "x", ratio: "y", code: "abc")
  end

  def test_only_integer_rejects_a_decimal_string
    assert_equal ["qty must be an integer"], errors_of(amount: "1.5", qty: "1.9", ratio: "2", code: "abc")
  end

  def test_exponent_strings_are_numbers_but_not_integers
    assert_equal ["qty must be an integer"], errors_of(amount: "1e3", qty: "1e3", ratio: "-1.5E-3", code: "abc")
  end

  def test_a_small_float_is_a_number
    assert_equal [], errors_of(amount: 0.00001, qty: 5, ratio: 1.5e-7, code: "abc")
  end

  def test_a_float_that_prints_with_an_exponent_is_a_number
    # Set through the writers: a big integral Float in a Hash literal fails in Spinel.
    measure = Measure.new(qty: 5, code: "abc")
    measure.amount = 1.0e20
    measure.ratio = 0.00001
    measure.valid?
    assert_equal [], measure.errors
    assert_equal "1.0e+20", measure.amount.inspect
  end

  def test_bounds_and_length_are_checked_alongside_numericality
    errors = errors_of(amount: "0.00001", qty: "101", ratio: "", code: "a")
    assert_equal ["qty must be less than or equal to 100", "ratio is not a number", "code is too short (minimum is 2 characters)"], errors
  end

  def test_blank_and_nil_numbers_are_not_numbers
    errors = errors_of(amount: "  ", qty: nil, ratio: nil, code: "abcde")
    assert_equal ["amount is not a number", "code is too long (maximum is 4 characters)"], errors
  end

  def test_infinity_hex_and_underscored_digits_are_not_numbers
    assert_equal NOT_NUMBERS, errors_of(amount: "Infinity", qty: "0x10", ratio: "1_000", code: "abc")
  end

  def test_numbers_within_the_bounds_are_valid
    assert_equal [], errors_of(amount: 2, qty: 100, ratio: 3, code: "abcd")
  end

  def test_a_value_of_the_minimum_length_is_valid
    assert_equal [], errors_of(amount: 1, qty: 1, ratio: 1, code: "ab")
  end

  def test_a_number_equal_to_the_greater_than_bound_is_rejected
    assert_equal ["amount must be greater than 0"], errors_of(amount: 0, qty: 1, ratio: 1, code: "abc")
  end

  def test_a_changed_value_is_validated_again
    measure = Measure.new(amount: "2", qty: "3", ratio: "4", code: "abc")
    measure.qty = "z"
    assert_equal false, measure.valid?
    assert_equal ["qty is not a number"], measure.errors
    measure.qty = 7
    assert_equal true, measure.valid?
    assert_equal "7", measure.qty.inspect
  end

  def test_length_is_rejects_a_shorter_value
    pin = Pin.new(code: "ab")
    pin.valid?
    assert_equal ["code is the wrong length (should be 3 characters)"], pin.errors
  end

  def test_length_is_accepts_the_exact_length
    pin = Pin.new(code: "abc")
    pin.valid?
    assert_equal [], pin.errors
  end

  def test_uniqueness_rejects_a_value_another_row_has
    @database.queue([project_row])
    duplicate = Project.new(owner_id: "u1", name: "work")
    assert_equal false, duplicate.valid?
    assert_equal [TAKEN], duplicate.errors
    assert_equal [FIND_WORK], @database.log
  end

  def test_uniqueness_accepts_a_value_no_row_has
    @database.queue([])
    fresh = Project.new(owner_id: "u1", name: "home")
    assert_equal true, fresh.valid?
    assert_equal [FIND_HOME], @database.log
  end

  def test_a_saved_record_is_not_a_duplicate_of_itself
    @database.queue([project_row])
    same = Project.instantiate(project_row)
    assert_equal true, same.valid?
    assert_equal [FIND_WORK], @database.log
  end

  def test_a_saved_record_is_a_duplicate_of_another_row_with_the_value
    @database.queue([{ "id" => 3, "owner_id" => "u1", "name" => "work" }])
    same = Project.instantiate(project_row)
    assert_equal false, same.valid?
    assert_equal [TAKEN], same.errors
    assert_equal [FIND_WORK], @database.log
  end

  def test_an_invalid_record_does_not_query
    project = Project.new(owner_id: "u1", name: " ")
    assert_equal false, project.valid?
    assert_equal [BLANK_NAME], project.errors
    assert_equal [], @database.log
  end

  def test_a_nil_value_is_not_checked_and_a_nil_scope_is_null
    assert_equal true, Tag.new(a: "x").valid?
    assert_equal ["SELECT id, name, a, b FROM tags WHERE a = ? AND b IS NULL AND name IS NULL LIMIT 1 | [\"x\"]"], @database.log
  end

  def test_every_unique_column_is_queried
    @database.queue([])
    @database.queue([])
    assert_equal true, Tag.new(name: "l", a: "x").valid?
    expected = [
      "SELECT id, name, a, b FROM tags WHERE name = ? LIMIT 1 | [\"l\"]",
      "SELECT id, name, a, b FROM tags WHERE a = ? AND b IS NULL AND name = ? LIMIT 1 | [\"x\",\"l\"]",
    ]
    assert_equal expected, @database.log
  end

  def test_a_scope_column_that_does_not_exist_is_an_unknown_column
    error = assert_raise(Edgeway::UnknownColumn) { Odd.new(name: "n").valid? }
    assert_equal "unknown column: nope", error.message
    assert_equal [], @database.log
  end

  def test_find_or_create_by_returns_the_row_it_finds_without_inserting
    @database.queue([project_row])
    found = Project.where(owner_id: "u1").find_or_create_by(name: "work")
    assert_equal "2", found.id.inspect
    assert_equal [SCOPED_FIND_WORK], @database.log
  end

  def test_find_or_create_by_inserts_with_the_conditions_of_the_relation
    @database.queue([])
    @database.queue([])
    @database.queue([{ "id" => 4, "owner_id" => "u1", "name" => "default" }])
    made = Project.where(owner_id: "u1").find_or_create_by(name: "default")
    assert_equal "[4, \"u1\", true]", [made.id, made.owner_id, made.persisted?].inspect
    assert_equal [SCOPED_FIND_DEFAULT, CHECK_DEFAULT, INSERT_DEFAULT], @database.log
  end

  def test_find_or_create_by_answers_the_unsaved_record_when_validation_fails
    @database.queue([])
    unsaved = Project.find_or_create_by(name: "")
    assert_equal false, unsaved.persisted?
    assert_equal [BLANK_NAME], unsaved.errors
    assert_equal [FIND_BLANK_NAME], @database.log
  end

  def test_find_or_create_by_with_a_bang_raises_when_validation_fails
    error = assert_raise(Edgeway::RecordInvalid) { Project.find_or_create_by!(name: "") }
    assert_equal "validation failed: #{BLANK_NAME}", error.message
    assert_equal [FIND_BLANK_NAME], @database.log
  end

  def test_find_or_create_by_rejects_an_unknown_column_without_querying
    error = assert_raise(Edgeway::UnknownColumn) { Project.find_or_create_by(nope: 1) }
    assert_equal "unknown column: nope", error.message
    assert_equal [], @database.log
  end

  def test_find_or_create_by_finds_the_row_a_racing_insert_created
    @database.queue([])
    @database.queue([])
    @database.fail_next("D1_ERROR: UNIQUE constraint failed: projects.owner_id, projects.name: SQLITE_CONSTRAINT", "INSERT")
    @database.queue([{ "id" => 5, "owner_id" => "u1", "name" => "race" }])
    raced = Project.where(owner_id: "u1").find_or_create_by!(name: "race")
    assert_equal "5", raced.id.inspect
    assert_equal [SCOPED_FIND_RACE, CHECK_RACE, INSERT_RACE, SCOPED_FIND_RACE], @database.log
  end

  def test_find_or_create_by_raises_when_the_row_is_still_missing_after_a_unique_error
    @database.queue([])
    @database.queue([])
    @database.fail_next("D1_ERROR: UNIQUE constraint failed: projects.id: SQLITE_CONSTRAINT", "INSERT")
    @database.queue([])
    error = assert_raise(Edgeway::RecordNotUnique) { Project.find_or_create_by(name: "ghost") }
    assert_equal "D1_ERROR: UNIQUE constraint failed: projects.id: SQLITE_CONSTRAINT", error.message
    assert_equal [FIND_GHOST, CHECK_GHOST, INSERT_GHOST, FIND_GHOST], @database.log
  end

  def test_a_unique_constraint_message_is_record_not_unique
    @database.fail_next(UNIQUE_FAILED)
    error = assert_raise(Edgeway::RecordNotUnique) { @database.execute("INSERT", []) }
    assert_equal UNIQUE_FAILED, error.message
    assert_equal true, error.is_a?(Edgeway::DatabaseError)
    assert_equal ["INSERT | []"], @database.log
  end

  def test_another_database_message_is_not_record_not_unique
    @database.fail_next(NO_SUCH_TABLE)
    error = assert_raise(Edgeway::DatabaseError) { @database.select_all("SELECT", []) }
    assert_equal false, error.is_a?(Edgeway::RecordNotUnique)
    assert_equal NO_SUCH_TABLE, error.message
    assert_equal ["SELECT | []"], @database.log
  end

  def test_a_not_null_constraint_message_is_a_not_null_violation
    assert_insert_fails_as Edgeway::NotNullViolation, "D1_ERROR: NOT NULL constraint failed: tags.name: SQLITE_CONSTRAINT"
  end

  def test_a_foreign_key_constraint_message_is_an_invalid_foreign_key
    assert_insert_fails_as Edgeway::InvalidForeignKey, "D1_ERROR: FOREIGN KEY constraint failed: SQLITE_CONSTRAINT"
  end

  def test_a_check_constraint_message_is_a_check_violation
    assert_insert_fails_as Edgeway::CheckViolation, "D1_ERROR: CHECK constraint failed: stars: SQLITE_CONSTRAINT"
  end

  def test_an_unrecognised_message_is_a_database_error
    assert_insert_fails_as Edgeway::DatabaseError, NO_SUCH_TABLE
  end

  def test_an_error_result_flagged_unavailable_is_database_unavailable
    assert_error_result Edgeway::DatabaseUnavailable, "d1: D1_ERROR: Network connection lost.",
      '{"error":"D1_ERROR: Network connection lost.","unavailable":true}'
  end

  def test_an_error_result_with_a_unique_message_is_record_not_unique
    assert_error_result Edgeway::RecordNotUnique, "d1: #{UNIQUE_FAILED}",
      '{"error":"D1_ERROR: UNIQUE constraint failed: tags.name: SQLITE_CONSTRAINT"}'
  end

  def test_an_error_result_with_another_message_is_a_database_error
    assert_error_result Edgeway::DatabaseError, "d1: D1_ERROR: exceeded CPU time limit",
      '{"error":"D1_ERROR: exceeded CPU time limit"}'
  end

  def test_insert_returning_maps_a_unique_message_to_record_not_unique
    @database.queue([])
    @database.fail_next("UNIQUE constraint failed: projects.id", "RETURNING")
    error = assert_raise(Edgeway::RecordNotUnique) { Project.create(owner_id: "u9", name: "x") }
    assert_equal "UNIQUE constraint failed: projects.id", error.message
    assert_equal [UNIQUENESS_CHECK_U9_X, INSERT_U9_X], @database.log
  end
end
