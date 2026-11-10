require "spinel_test/unit"
require "edgeway"
require "edgeway/db/memory"

class ModelQueryTest < SpinelTest::Unit::TestCase
  class ApplicationModel < Edgeway::Model::Base
    extend Edgeway::Model::Macros
  end

  class Todo < ApplicationModel
    attribute :title, :string
    attribute :done, :boolean, default: false
    attribute :priority, :string, default: "normal"
    attribute :position, :integer
    timestamps
    has_many :comments
    validates :position, numericality: { only_integer: true }
  end

  class Comment < ApplicationModel
    attribute :body, :string
    belongs_to :todo
  end

  class Basket < ApplicationModel
    attribute :name, :string
    has_many :categories
  end

  class Category < ApplicationModel
    attribute :basket_id, :integer
  end

  SELECT_TODOS = "SELECT id, title, done, priority, position, created_at, updated_at FROM todos"
  COUNT_SUBSELECT = "SELECT COUNT(*) AS n FROM (SELECT 1 FROM todos"
  BIND_LIMIT_MESSAGE = "too many bind parameters: 101 (at most 100)"

  SINGULAR_AND_PLURAL_FORMS = [
    "status statuses status status",
    "class classes class class",
    "box boxes box box",
    "wish wishes wish wish",
    "match matches match match",
    "address addresses address address",
    "bus buses bus bus",
    "post posts post post",
    "category categories category category",
    "day days day day",
    "case cases case case",
    "base bases base base",
    "database databases database database",
    "type types type type",
    "house houses house house",
    "todo todos todo todo",
    "comment comments comment comment",
  ]

  PLURAL_ROUND_TRIPS = [
    "statuses status true",
    "classes class true",
    "addresses address true",
    "boxes box true",
    "wishes wish true",
    "matches match true",
    "cases case true",
    "bases base true",
    "databases database true",
    "types type true",
    "houses house true",
    "todos todo true",
    "comments comment true",
  ]

  def setup
    @database = Edgeway::DB::MemoryAdapter.new
    Edgeway::Model.connection = @database
  end

  def teardown
    Edgeway::Model.disconnect(Edgeway::Model::PRIMARY)
  end

  def inflections(word)
    plural = Edgeway::Inflector.pluralize(word)
    "#{word} #{plural} #{Edgeway::Inflector.singularize(plural)} #{Edgeway::Inflector.singularize(word)}"
  end

  def round_trip(plural)
    singular = Edgeway::Inflector.singularize(plural)
    "#{plural} #{singular} #{Edgeway::Inflector.pluralize(singular) == plural}"
  end

  def placeholders(count)
    (1..count).map { "?" }.join(", ")
  end

  def numbers_as_json(count)
    "[#{(1..count).to_a.join(",")}]"
  end

  def test_where_order_limit_and_offset_make_one_select
    Todo.where(done: false).order(:title, :desc).limit(5).offset(10).to_a
    assert_equal ["#{SELECT_TODOS} WHERE done = ? ORDER BY title DESC LIMIT 5 OFFSET 10 | [0]"], @database.log
  end

  def test_count_wraps_the_conditions_in_a_subselect
    @database.queue([{ "n" => 4 }])
    assert_equal "4", Todo.where("priority" => "high").count.inspect
    assert_equal ["#{COUNT_SUBSELECT} WHERE priority = ?) | [\"high\"]"], @database.log
  end

  def test_find_selects_by_id_and_casts_the_row
    @database.queue([{ "id" => 3, "title" => "a", "done" => 1, "priority" => "low", "position" => 2, "created_at" => "t", "updated_at" => "t" }])
    todo = Todo.find(3)
    assert_equal '{"id" => 3, "title" => "a", "done" => true, "priority" => "low", "position" => 2, "created_at" => "t", "updated_at" => "t"}', todo.as_json.inspect
    assert_equal ["#{SELECT_TODOS} WHERE id = ? LIMIT 1 | [3]"], @database.log
    assert_equal "true", todo.done.inspect
  end

  def test_find_of_a_missing_row_is_a_record_not_found
    @database.queue([])
    error = assert_raise(Edgeway::RecordNotFound) { Todo.find(4) }
    assert_equal "todos 4 not found", error.message
    assert_equal ["#{SELECT_TODOS} WHERE id = ? LIMIT 1 | [4]"], @database.log
  end

  def test_order_refuses_a_column_that_is_not_an_attribute_before_any_sql
    error = assert_raise(Edgeway::UnknownColumn) { Todo.order("title;DROP TABLE todos") }
    assert_equal "unknown column: title;DROP TABLE todos", error.message
    assert_equal [], @database.log
  end

  def test_where_refuses_a_column_that_is_not_an_attribute_before_any_sql
    error = assert_raise(Edgeway::UnknownColumn) { Todo.where(nope: 1) }
    assert_equal "unknown column: nope", error.message
    assert_equal "Edgeway::UnknownColumn", error.class.name
    assert_equal [], @database.log
  end

  def test_pluck_selects_only_the_column
    @database.queue([{ "title" => "x" }, { "title" => "y" }])
    assert_equal '["x", "y"]', Todo.pluck(:title).inspect
    assert_equal ["SELECT title FROM todos | []"], @database.log
  end

  def test_where_nil_is_is_null_with_no_bind
    Todo.where(position: nil).to_a
    assert_equal ["#{SELECT_TODOS} WHERE position IS NULL | []"], @database.log
  end

  def test_where_nil_combines_with_other_conditions_in_order
    Todo.where(position: nil, done: true).where(title: "x").to_a
    assert_equal ["#{SELECT_TODOS} WHERE position IS NULL AND done = ? AND title = ? | [1,\"x\"]"], @database.log
  end

  def test_building_from_a_where_nil_leaves_the_attribute_nil
    assert_equal "nil", Todo.where(position: nil).build(title: "b").position.inspect
  end

  def test_exists_asks_for_one_row
    @database.queue([{ "n" => 1 }])
    assert_equal "true", Todo.exists?.inspect
    assert_equal ["#{COUNT_SUBSELECT} LIMIT 1) | []"], @database.log
  end

  def test_exists_with_conditions_is_false_for_a_count_of_zero
    @database.queue([{ "n" => 0 }])
    assert_equal "false", Todo.exists?(title: "none").inspect
    assert_equal ["#{COUNT_SUBSELECT} WHERE title = ? LIMIT 1) | [\"none\"]"], @database.log
  end

  def test_count_keeps_the_limit_in_the_subselect
    @database.queue([{ "n" => 2 }])
    assert_equal "2", Todo.limit(2).count.inspect
    assert_equal ["#{COUNT_SUBSELECT} LIMIT 2) | []"], @database.log
  end

  def test_an_offset_alone_needs_limit_minus_one
    Todo.offset(3).to_a
    assert_equal ["#{SELECT_TODOS} LIMIT -1 OFFSET 3 | []"], @database.log
  end

  def test_empty_is_true_for_a_count_of_zero
    @database.queue([{ "n" => 0 }])
    assert_equal "true", Todo.where(done: true).empty?.inspect
    assert_equal ["#{COUNT_SUBSELECT} WHERE done = ? LIMIT 1) | [1]"], @database.log
  end

  def test_first_orders_by_id_unless_ordered
    Todo.first
    Todo.order(:title).first
    expected = [
      "#{SELECT_TODOS} ORDER BY id ASC LIMIT 1 | []",
      "#{SELECT_TODOS} ORDER BY title ASC LIMIT 1 | []",
    ]
    assert_equal expected, @database.log
  end

  def test_find_by_ignores_an_offset
    assert_equal "nil", Todo.offset(5).find_by(title: "z").inspect
    assert_equal ["#{SELECT_TODOS} WHERE title = ? LIMIT 1 | [\"z\"]"], @database.log
  end

  def test_find_by_ignores_an_offset_and_a_limit_but_keeps_the_conditions
    assert_equal "nil", Todo.where(done: true).offset(5).limit(3).find_by(title: "z").inspect
    assert_equal ["#{SELECT_TODOS} WHERE done = ? AND title = ? LIMIT 1 | [1,\"z\"]"], @database.log
  end

  def test_an_integer_id_beyond_32_bits_finds_nothing
    error = assert_raise(Edgeway::RecordNotFound) { Todo.find(4294967297) }
    assert_equal "todos 4294967297 not found", error.message
    assert_equal ["#{SELECT_TODOS} WHERE id = ? LIMIT 1 | [\"4294967297\"]"], @database.log
  end

  def test_a_string_id_beyond_32_bits_finds_nothing
    error = assert_raise(Edgeway::RecordNotFound) { Todo.find("99999999999999999999") }
    assert_equal "todos 99999999999999999999 not found", error.message
    assert_equal ["#{SELECT_TODOS} WHERE id = ? LIMIT 1 | [\"99999999999999999999\"]"], @database.log
  end

  def test_a_string_limit_beyond_32_bits_is_a_bad_request
    error = assert_raise(Edgeway::BadRequest) { Todo.limit("99999999999") }
    assert_equal "bad limit: 99999999999", error.message
    assert_equal "Edgeway::BadRequest", error.class.name
    assert_equal [], @database.log
  end

  def test_a_negative_string_limit_is_a_bad_request
    error = assert_raise(Edgeway::BadRequest) { Todo.limit("-1") }
    assert_equal "bad limit: -1", error.message
    assert_equal "Edgeway::BadRequest", error.class.name
    assert_equal [], @database.log
  end

  def test_an_integer_limit_beyond_32_bits_is_a_bad_request
    error = assert_raise(Edgeway::BadRequest) { Todo.limit(2147483648) }
    assert_equal "bad limit: 2147483648", error.message
    assert_equal "Edgeway::BadRequest", error.class.name
    assert_equal [], @database.log
  end

  def test_an_offset_beyond_32_bits_is_a_bad_request
    error = assert_raise(Edgeway::BadRequest) { Todo.offset("4294967297") }
    assert_equal "bad offset: 4294967297", error.message
    assert_equal "Edgeway::BadRequest", error.class.name
    assert_equal [], @database.log
  end

  def test_the_largest_32_bit_limit_is_accepted
    assert_equal "0", Todo.limit("2147483647").offset(0).to_a.size.inspect
    assert_equal ["#{SELECT_TODOS} LIMIT 2147483647 OFFSET 0 | []"], @database.log
  end

  def test_an_integer_attribute_beyond_32_bits_is_out_of_range
    todo = Todo.new(title: "t", position: "4294967297")
    assert_equal "false", todo.valid?.inspect
    assert_equal '["position is out of range"]', todo.errors.inspect
  end

  def test_integer_casting_keeps_the_32_bit_bounds
    assert_equal "2147483647", Edgeway::Model.cast(:integer, "2147483647").inspect
    assert_equal "-2147483648", Edgeway::Model.cast(:integer, "-2147483648").inspect
    assert_equal "nil", Edgeway::Model.cast(:integer, "2147483648").inspect
  end

  def test_table_names_are_the_plural_of_the_class_name
    assert_equal "todos", Todo.table_name
    assert_equal "comments", Comment.table_name
    assert_equal "categories", Category.table_name
    assert_equal "baskets", Basket.table_name
  end

  def test_pluralize_and_singularize_turn_y_into_ies_and_back
    assert_equal "days", Edgeway::Inflector.pluralize("day")
    assert_equal "categories", Edgeway::Inflector.pluralize("category")
    assert_equal "category", Edgeway::Inflector.singularize("categories")
    assert_equal "todo", Edgeway::Inflector.singularize("todos")
  end

  def test_singular_and_plural_forms_of_common_words
    forms = SINGULAR_AND_PLURAL_FORMS.map { |line| inflections(line.split(" ")[0]) }
    assert_equal SINGULAR_AND_PLURAL_FORMS, forms
  end

  def test_a_plural_singularizes_and_pluralizes_back_to_itself
    round_trips = PLURAL_ROUND_TRIPS.map { |line| round_trip(line.split(" ")[0]) }
    assert_equal PLURAL_ROUND_TRIPS, round_trips
  end

  def test_has_many_reads_the_plural_table_of_the_association
    basket = Basket.instantiate({ "id" => 4, "name" => "n" })
    basket.categories.to_a
    assert_equal ["SELECT id, basket_id FROM categories WHERE basket_id = ? | [4]"], @database.log
  end

  def test_order_adds_terms_in_the_order_given
    Todo.order(:updated_at, :desc).order(:id, :desc).to_a
    assert_equal ["#{SELECT_TODOS} ORDER BY updated_at DESC, id DESC | []"], @database.log
  end

  def test_order_accepts_strings_and_keeps_a_limit
    Todo.order(:title).order("position", "DESC").limit(2).to_a
    assert_equal ["#{SELECT_TODOS} ORDER BY title ASC, position DESC LIMIT 2 | []"], @database.log
  end

  def test_reorder_replaces_every_earlier_term
    Todo.order(:title).order(:id).reorder(:position).to_a
    assert_equal ["#{SELECT_TODOS} ORDER BY position ASC | []"], @database.log
  end

  def test_reorder_alone_sets_the_direction
    Todo.reorder(:title, :desc).to_a
    assert_equal ["#{SELECT_TODOS} ORDER BY title DESC | []"], @database.log
  end

  def test_first_after_a_reorder_uses_the_new_order_with_the_conditions
    Todo.where(done: true).order(:title).reorder(:id, :desc).first
    assert_equal ["#{SELECT_TODOS} WHERE done = ? ORDER BY id DESC LIMIT 1 | [1]"], @database.log
  end

  def test_first_after_several_orders_does_not_add_an_id_order
    Todo.order(:title).order(:id, :desc).first
    assert_equal ["#{SELECT_TODOS} ORDER BY title ASC, id DESC LIMIT 1 | []"], @database.log
  end

  def test_count_drops_the_order
    @database.queue([{ "n" => 1 }])
    Todo.order(:title).order(:id).count
    assert_equal ["#{COUNT_SUBSELECT}) | []"], @database.log
  end

  def test_a_later_order_refuses_an_unknown_column
    error = assert_raise(Edgeway::UnknownColumn) { Todo.order(:title).order(:nope) }
    assert_equal "unknown column: nope", error.message
    assert_equal [], @database.log
  end

  def test_a_later_order_refuses_an_unknown_direction
    error = assert_raise(Edgeway::BadRequest) { Todo.order(:title).order(:id, :sideways) }
    assert_equal "bad order direction: sideways", error.message
    assert_equal "Edgeway::BadRequest", error.class.name
    assert_equal [], @database.log
  end

  def test_reorder_refuses_an_unknown_direction
    error = assert_raise(Edgeway::BadRequest) { Todo.order(:title).reorder(:id, :up) }
    assert_equal "bad order direction: up", error.message
    assert_equal "Edgeway::BadRequest", error.class.name
    assert_equal [], @database.log
  end

  def test_reorder_refuses_an_unknown_column
    error = assert_raise(Edgeway::UnknownColumn) { Todo.order(:title).reorder("id;DROP") }
    assert_equal "unknown column: id;DROP", error.message
    assert_equal [], @database.log
  end

  def test_where_with_an_array_is_an_in_list
    Todo.where(id: [1, "2"]).to_a
    Todo.where(done: [true, false]).to_a
    expected = [
      "#{SELECT_TODOS} WHERE id IN (?, ?) | [1,2]",
      "#{SELECT_TODOS} WHERE done IN (?, ?) | [1,0]",
    ]
    assert_equal expected, @database.log
  end

  def test_where_with_an_empty_array_matches_nothing_without_a_bind
    Todo.where(id: []).to_a
    assert_equal ["#{SELECT_TODOS} WHERE 1 = 0 | []"], @database.log
  end

  def test_where_with_an_array_holding_nil_adds_is_null
    Todo.where(position: [1, nil]).to_a
    Todo.where(position: [nil]).to_a
    expected = [
      "#{SELECT_TODOS} WHERE (position IN (?) OR position IS NULL) | [1]",
      "#{SELECT_TODOS} WHERE position IS NULL | []",
    ]
    assert_equal expected, @database.log
  end

  def test_where_with_a_range_is_a_pair_of_comparisons
    Todo.where(position: 1..5).to_a
    Todo.where(position: 1...5).to_a
    expected = [
      "#{SELECT_TODOS} WHERE position >= ? AND position <= ? | [1,5]",
      "#{SELECT_TODOS} WHERE position >= ? AND position < ? | [1,5]",
    ]
    assert_equal expected, @database.log
  end

  def test_where_with_an_endless_or_beginless_range_is_one_comparison
    Todo.where(position: (2..)).to_a
    Todo.where(position: (..5)).to_a
    Todo.where(position: (...5)).to_a
    expected = [
      "#{SELECT_TODOS} WHERE position >= ? | [2]",
      "#{SELECT_TODOS} WHERE position <= ? | [5]",
      "#{SELECT_TODOS} WHERE position < ? | [5]",
    ]
    assert_equal expected, @database.log
  end

  def test_where_with_a_sql_fragment_is_parenthesised
    Todo.where("title LIKE ?", "%x%").to_a
    Todo.where("done = 1").to_a
    expected = [
      "#{SELECT_TODOS} WHERE (title LIKE ?) | [\"%x%\"]",
      "#{SELECT_TODOS} WHERE (done = 1) | []",
    ]
    assert_equal expected, @database.log
  end

  def test_a_sql_fragment_with_several_binds_joins_other_conditions_with_and
    Todo.where("title LIKE ? OR priority = ?", "%x%", "low").where(done: true).to_a
    Todo.where("done = ?", true).to_a
    expected = [
      "#{SELECT_TODOS} WHERE (title LIKE ? OR priority = ?) AND done = ? | [\"%x%\",\"low\",1]",
      "#{SELECT_TODOS} WHERE (done = ?) | [1]",
    ]
    assert_equal expected, @database.log
  end

  def test_every_kind_of_condition_chains_in_order_with_binds_in_order
    Todo.where(id: [1, 2]).where(position: 3..4).where("title <> ?", "z").where(done: false).order(:id).limit(5).offset(2).to_a
    expected = "#{SELECT_TODOS} WHERE id IN (?, ?) AND position >= ? AND position <= ? AND (title <> ?) AND done = ? ORDER BY id ASC LIMIT 5 OFFSET 2 | [1,2,3,4,\"z\",0]"
    assert_equal [expected], @database.log
  end

  def test_count_of_a_chain_keeps_the_conditions_and_a_limit_of_one
    @database.queue([{ "n" => 2 }])
    assert_equal "2", Todo.where(id: [1, 2]).where("title <> ?", "z").limit(1).count.inspect
    assert_equal ["#{COUNT_SUBSELECT} WHERE id IN (?, ?) AND (title <> ?) LIMIT 1) | [1,2,\"z\"]"], @database.log
  end

  def test_exists_with_a_range
    @database.queue([{ "n" => 1 }])
    assert_equal "true", Todo.where(position: 1..3).exists?.inspect
    assert_equal ["#{COUNT_SUBSELECT} WHERE position >= ? AND position <= ? LIMIT 1) | [1,3]"], @database.log
  end

  def test_pluck_first_and_find_by_keep_array_range_and_fragment_conditions
    Todo.where(id: [1, 2]).pluck(:title)
    Todo.where(position: 1..3).first
    Todo.where(id: [3, 4]).find_by(title: "z")
    Todo.where("title LIKE ?", "a%").find_by(id: 7)
    expected = [
      "SELECT title FROM todos WHERE id IN (?, ?) | [1,2]",
      "#{SELECT_TODOS} WHERE position >= ? AND position <= ? ORDER BY id ASC LIMIT 1 | [1,3]",
      "#{SELECT_TODOS} WHERE id IN (?, ?) AND title = ? LIMIT 1 | [3,4,\"z\"]",
      "#{SELECT_TODOS} WHERE (title LIKE ?) AND id = ? LIMIT 1 | [\"a%\",7]",
    ]
    assert_equal expected, @database.log
  end

  def test_delete_all_keeps_array_range_and_fragment_conditions
    Todo.where(id: [1, 2]).delete_all
    Todo.where(position: 1...3).where("title = ?", "z").where(done: true).delete_all
    Todo.where(id: []).delete_all
    expected = [
      "DELETE FROM todos WHERE id IN (?, ?) | [1,2]",
      "DELETE FROM todos WHERE position >= ? AND position < ? AND (title = ?) AND done = ? | [1,3,\"z\",1]",
      "DELETE FROM todos WHERE 1 = 0 | []",
    ]
    assert_equal expected, @database.log
  end

  def test_destroy_all_keeps_array_and_fragment_conditions
    @database.queue([{ "id" => 1, "title" => "a" }, { "id" => 2, "title" => "b" }])
    assert_equal "2", Todo.where(id: [1, 2]).where("title <> ?", "z").destroy_all.size.inspect
    expected = [
      "#{SELECT_TODOS} WHERE id IN (?, ?) AND (title <> ?) | [1,2,\"z\"]",
      "DELETE FROM todos WHERE id = ? | [1]",
      "DELETE FROM todos WHERE id = ? | [2]",
    ]
    assert_equal expected, @database.log
  end

  def test_eager_load_keeps_array_and_fragment_conditions_inside_the_subselect
    Todo.where(id: [1, 2]).eager_load(:comments).where("title <> ?", "z").limit(3).to_a
    expected = "SELECT todos.id AS p_id, todos.title AS p_title, todos.done AS p_done, todos.priority AS p_priority, todos.position AS p_position, todos.created_at AS p_created_at, todos.updated_at AS p_updated_at, eager_comments.id AS c0_id, eager_comments.body AS c0_body, eager_comments.todo_id AS c0_todo_id FROM (#{SELECT_TODOS} WHERE id IN (?, ?) AND (title <> ?) LIMIT 3) AS todos LEFT JOIN comments AS eager_comments ON eager_comments.todo_id = todos.id ORDER BY todos.id, eager_comments.id | [1,2,\"z\"]"
    assert_equal [expected], @database.log
  end

  def test_an_association_scope_accepts_array_and_fragment_conditions
    todo = Todo.instantiate({ "id" => 5, "title" => "x" })
    todo.comments.where(body: ["a", "b"]).where("body <> ?", "c").to_a
    assert_equal ["SELECT id, body, todo_id FROM comments WHERE todo_id = ? AND body IN (?, ?) AND (body <> ?) | [5,\"a\",\"b\",\"c\"]"], @database.log
  end

  def test_where_refuses_an_unknown_column_given_an_array
    error = assert_raise(Edgeway::UnknownColumn) { Todo.where(nope: [1]).to_a }
    assert_equal "unknown column: nope", error.message
    assert_equal [], @database.log
  end

  def test_where_refuses_an_unknown_column_given_a_range
    error = assert_raise(Edgeway::UnknownColumn) { Todo.where(nope: 1..2).to_a }
    assert_equal "unknown column: nope", error.message
    assert_equal [], @database.log
  end

  def test_times_are_bound_as_utc_strings_with_milliseconds
    time = Time.utc(2026, 10, 28, 5, 0, 0)
    Todo.where(created_at: time).to_a
    Todo.where(created_at: [time, time + 3600]).where("updated_at > ?", time).to_a
    Edgeway::Model.select_all("SELECT 1 WHERE ? < ?", [time, true])
    expected = [
      "#{SELECT_TODOS} WHERE created_at = ? | [\"2026-10-28T05:00:00.000Z\"]",
      "#{SELECT_TODOS} WHERE created_at IN (?, ?) AND (updated_at > ?) | [\"2026-10-28T05:00:00.000Z\",\"2026-10-28T06:00:00.000Z\",\"2026-10-28T05:00:00.000Z\"]",
      "SELECT 1 WHERE ? < ? | [\"2026-10-28T05:00:00.000Z\",1]",
    ]
    assert_equal expected, @database.log
  end

  def test_an_array_bind_in_a_sql_fragment_is_refused
    error = assert_raise(ArgumentError) { Todo.where("id IN (?)", [1, 2]) }
    assert_equal "an Array bind in a SQL fragment isn't expanded; use where(column: [...])", error.message
    assert_equal [], @database.log
  end

  def test_where_with_a_hash_takes_no_binds
    error = assert_raise(ArgumentError) { Todo.where({ id: 1 }, 2) }
    assert_equal "where(Hash) takes no binds", error.message
    assert_equal [], @database.log
  end

  def test_find_by_sql_binds_and_builds_persisted_records
    @database.queue([{ "id" => 4, "title" => "raw", "done" => 1, "priority" => "low", "position" => 2 }])
    todos = Todo.find_by_sql("SELECT * FROM todos WHERE done = ? AND title LIKE ?", [true, "r%"])
    assert_equal '[[4, "raw", true, true]]', todos.map { |todo| [todo.id, todo.title, todo.done, todo.persisted?] }.inspect
    assert_equal ["SELECT * FROM todos WHERE done = ? AND title LIKE ? | [1,\"r%\"]"], @database.log
  end

  def test_find_by_sql_without_rows_is_empty
    assert_equal "0", Todo.find_by_sql("SELECT * FROM todos").size.inspect
    assert_equal ["SELECT * FROM todos | []"], @database.log
  end

  def test_select_all_answers_the_rows
    @database.queue([{ "n" => 3 }])
    rows = Edgeway::Model.select_all("SELECT COUNT(*) AS n FROM todos WHERE done = ?", [false])
    assert_equal '[{"n" => 3}]', rows.inspect
    assert_equal ["SELECT COUNT(*) AS n FROM todos WHERE done = ? | [0]"], @database.log
  end

  def test_execute_answers_the_changes_and_the_last_insert_id
    update = Edgeway::Model.execute("UPDATE todos SET done = ? WHERE id = ?", [true, 1])
    delete = Edgeway::Model.execute("DELETE FROM todos")
    assert_equal '{"changes" => 1, "last_insert_id" => 1}', update.inspect
    assert_equal '{"changes" => 1, "last_insert_id" => 2}', delete.inspect
    assert_equal ["UPDATE todos SET done = ? WHERE id = ? | [1,1]", "DELETE FROM todos | []"], @database.log
  end

  def test_execute_inside_a_batch_is_queued_and_answers_a_placeholder
    queued_answer = ""
    log_size_in_block = -1
    results = Edgeway::Model.batch do
      queued_answer = Edgeway::Model.execute("UPDATE todos SET done = ? WHERE id = ?", [true, 1]).inspect
      Edgeway::Model.execute("DELETE FROM comments WHERE todo_id = ?", [1])
      log_size_in_block = @database.log.size
    end
    assert_equal '{"changes" => 0, "last_insert_id" => 0}', queued_answer
    assert_equal 0, log_size_in_block
    assert_equal '[{"changes" => 1, "last_insert_id" => 1}, {"changes" => 1, "last_insert_id" => 2}]', results.inspect
    assert_equal ["BATCH 2", "UPDATE todos SET done = ? WHERE id = ? | [1,1]", "DELETE FROM comments WHERE todo_id = ? | [1]"], @database.log
  end

  def test_a_query_may_bind_one_hundred_values
    Todo.where(id: (1..100).to_a).to_a
    assert_equal ["#{SELECT_TODOS} WHERE id IN (#{placeholders(100)}) | #{numbers_as_json(100)}"], @database.log
  end

  def test_a_query_with_one_hundred_and_one_binds_is_refused_before_any_sql
    error = assert_raise(ArgumentError) { Todo.where(id: (1..101).to_a).to_a }
    assert_equal BIND_LIMIT_MESSAGE, error.message
    assert_equal [], @database.log
  end

  def test_a_limit_and_offset_follow_the_in_list
    Todo.where(id: (1..100).to_a).limit(1).offset(2).to_a
    assert_equal ["#{SELECT_TODOS} WHERE id IN (#{placeholders(100)}) LIMIT 1 OFFSET 2 | #{numbers_as_json(100)}"], @database.log
  end

  def test_execute_with_one_hundred_and_one_binds_is_refused_before_any_sql
    sql = "DELETE FROM todos WHERE id IN (#{placeholders(101)})"
    error = assert_raise(ArgumentError) { Edgeway::Model.execute(sql, (1..101).to_a) }
    assert_equal BIND_LIMIT_MESSAGE, error.message
    assert_equal [], @database.log
  end

  def test_a_batch_with_a_statement_of_one_hundred_and_one_binds_sends_nothing
    sql = "DELETE FROM todos WHERE id IN (#{placeholders(101)})"
    error = assert_raise(ArgumentError) do
      Edgeway::Model.batch do
        Edgeway::Model.execute("DELETE FROM todos WHERE id = ?", [1])
        Edgeway::Model.execute(sql, (1..101).to_a)
      end
    end
    assert_equal BIND_LIMIT_MESSAGE, error.message
    assert_equal [], @database.log
  end
end
