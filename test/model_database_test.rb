require "spinel_test/unit"
require "edgeway"
require "edgeway/db/memory"

class ModelDatabaseTest < SpinelTest::Unit::TestCase
  class ApplicationModel < Edgeway::Model::Base
    extend Edgeway::Model::Macros
  end

  class Todo < ApplicationModel
    attribute :title, :string
    attribute :done, :boolean, default: false
    attribute :priority, :string, default: "normal"
    attribute :position, :integer
    timestamps
  end

  class Event < ApplicationModel
    self.database = :analytics
    attribute :name, :string
  end

  class Impression < ApplicationModel
    self.database = :analytics
    attribute :note, :string
    belongs_to :todo
  end

  class ClickEvent < Event
  end

  class Venue < ApplicationModel
    attribute :name, :string
    has_many :guests, dependent: :destroy
  end

  class Stand < ApplicationModel
    attribute :name, :string
    has_many :passes, dependent: :delete_all
  end

  class Guest < ApplicationModel
    self.database = :analytics
    attribute :venue_id, :integer
  end

  class Pass < ApplicationModel
    self.database = :analytics
    attribute :stand_id, :integer
  end

  NO_ANALYTICS_MESSAGE = "no database analytics: it is not under databases: of this environment in config/database.yml"
  MULTI_STATEMENT_SQL = "CREATE TABLE a (id)\nINSERT INTO a VALUES (1)"
  IMPRESSION_SELECT_LOG = "SELECT id, note, todo_id FROM impressions ORDER BY id ASC LIMIT 1 | []"
  TODO_7_SELECT_LOG = "SELECT id, title, done, priority, position, created_at, updated_at FROM todos WHERE id = ? LIMIT 1 | [7]"

  def setup
    @primary = Edgeway::DB::MemoryAdapter.new
    Edgeway::Model.connection = @primary
  end

  def teardown
    Edgeway::Model.disconnect("analytics")
    Edgeway::Model.disconnect(Edgeway::Model::PRIMARY)
  end

  def connect_analytics
    @analytics = Edgeway::DB::MemoryAdapter.new
    Edgeway::Model.connect(:analytics, @analytics)
  end

  def record_meta(adapter, meta_json)
    adapter.record_meta(JSON.parse(meta_json))
  end

  def persisted_todo
    Todo.instantiate({ "id" => 1, "title" => "p", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" })
  end

  def persisted_event
    Event.instantiate({ "id" => 1, "name" => "signup" })
  end

  def assert_logs(primary_log, analytics_log)
    assert_equal primary_log, @primary.log
    assert_equal analytics_log, @analytics.log
  end

  def test_a_fresh_connection_has_no_query_stats
    assert_equal '{"queries":0,"rows_read":0,"rows_written":0,"db_ms":0.0}', JSON.generate(Edgeway::Model.query_stats.log_fields)
    assert_equal "0", Edgeway::Model.query_stats.queries.inspect
  end

  def test_query_stats_add_up_and_keep_the_latest_region_and_primary_flag
    record_meta(@primary, '{"rows_read":3,"rows_written":1,"duration":2,"served_by_region":"WEUR","served_by_primary":false}')
    record_meta(@primary, '{"rows_read":4,"rows_written":0,"duration":0.456,"served_by_region":"ENAM","served_by_primary":true}')
    stats = @primary.query_stats
    assert_equal '[2, 7, 1, 2.456, "ENAM", true]', [stats.queries, stats.rows_read, stats.rows_written, stats.duration_ms, stats.served_by_region, stats.served_by_primary].inspect
    assert_equal '{"queries":2,"rows_read":7,"rows_written":1,"db_ms":2.46}', JSON.generate(stats.log_fields)
  end

  def test_a_report_without_region_and_primary_fields_keeps_the_earlier_ones
    record_meta(@primary, '{"rows_read":3,"rows_written":1,"duration":2,"served_by_region":"WEUR","served_by_primary":false}')
    record_meta(@primary, '{"rows_read":4,"rows_written":0,"duration":0.456,"served_by_region":"ENAM","served_by_primary":true}')
    record_meta(@primary, '{"rows_read":0,"rows_written":0,"duration":0.5}')
    stats = @primary.query_stats
    assert_equal '[3, "ENAM", true]', [stats.queries, stats.served_by_region, stats.served_by_primary].inspect
  end

  def test_a_report_without_the_primary_flag_keeps_an_earlier_false
    record_meta(@primary, '{"rows_read":1,"rows_written":0,"duration":1,"served_by_region":"WEUR","served_by_primary":false}')
    record_meta(@primary, '{"rows_read":0,"rows_written":0,"duration":1}')
    assert_equal '["WEUR", false]', [@primary.query_stats.served_by_region, @primary.query_stats.served_by_primary].inspect
  end

  def test_a_report_with_an_empty_region_is_counted
    record_meta(@primary, '{"rows_read":30,"rows_written":3,"duration":1.5,"served_by_region":"","served_by_primary":true}')
    assert_equal '{"queries":1,"rows_read":30,"rows_written":3,"db_ms":1.5}', JSON.generate(@primary.query_stats.log_fields)
  end

  def test_a_report_with_an_empty_region_replaces_the_earlier_region
    record_meta(@primary, '{"rows_read":1,"rows_written":0,"duration":1,"served_by_region":"WEUR","served_by_primary":false}')
    record_meta(@primary, '{"rows_read":30,"rows_written":3,"duration":1.5,"served_by_region":"","served_by_primary":true}')
    assert_equal '["", true]', [@primary.query_stats.served_by_region, @primary.query_stats.served_by_primary].inspect
  end

  def test_a_row_count_sum_stops_at_the_32_bit_maximum
    record_meta(@primary, '{"rows_read":2147483647,"rows_written":5,"duration":1}')
    record_meta(@primary, '{"rows_read":10,"rows_written":5,"duration":1}')
    assert_equal '{"queries":2,"rows_read":2147483647,"rows_written":10,"db_ms":2.0}', JSON.generate(@primary.query_stats.log_fields)
  end

  def test_query_stats_of_another_database_are_its_own
    connect_analytics
    record_meta(@analytics, '{"rows_read":2,"rows_written":0,"duration":1,"served_by_region":"WEUR","served_by_primary":true}')
    assert_equal '{"queries":1,"rows_read":2,"rows_written":0,"db_ms":1.0}', JSON.generate(Edgeway::Model.query_stats(:analytics).log_fields)
    assert_equal '{"queries":0,"rows_read":0,"rows_written":0,"db_ms":0.0}', JSON.generate(Edgeway::Model.query_stats.log_fields)
  end

  def test_database_names_lists_the_connected_databases_as_strings
    assert_equal '["primary"]', Edgeway::Model.database_names.inspect
    connect_analytics
    assert_equal '["primary", "analytics"]', Edgeway::Model.database_names.inspect
  end

  def test_a_model_names_its_database_and_a_subclass_inherits_it
    assert_equal '["primary", "analytics", "analytics"]', [Todo.database, Event.database, ClickEvent.database].inspect
  end

  def test_a_model_on_an_unconnected_database_is_a_configuration_error
    error = assert_raise(Edgeway::ConfigurationError) { Event.count }
    assert_equal NO_ANALYTICS_MESSAGE, error.message
  end

  def test_models_use_the_connection_of_their_database
    connect_analytics
    assert_equal true, Edgeway::Model.connection_for("analytics").equal?(@analytics)
    assert_equal true, Edgeway::Model.connection_for(:analytics).equal?(@analytics)
    assert_equal true, Event.connection.equal?(@analytics)
    assert_equal true, ClickEvent.connection.equal?(@analytics)
    assert_equal true, Todo.connection.equal?(@primary)
  end

  def test_queries_on_another_database_leave_the_primary_alone
    connect_analytics
    @analytics.queue([{ "id" => 1, "name" => "signup" }])
    event = Event.create!(name: "signup")
    event.update!(name: "login")
    @analytics.queue([{ "n" => 1 }])
    ClickEvent.count
    @analytics.queue([{ "n" => 1 }])
    Event.where(name: "login").count
    Event.find_by_sql("SELECT * FROM events WHERE id = ?", [1])
    Edgeway::Model.select_all("SELECT 1", [], database: :analytics)
    Edgeway::Model.execute("DELETE FROM events", [], database: "analytics")
    event.destroy
    Event.delete_all
    expected = [
      "INSERT INTO events (name) VALUES (?) RETURNING id, name | [\"signup\"]",
      "UPDATE events SET name = ? WHERE id = ? | [\"login\",1]",
      "SELECT COUNT(*) AS n FROM (SELECT 1 FROM click_events) | []",
      "SELECT COUNT(*) AS n FROM (SELECT 1 FROM events WHERE name = ?) | [\"login\"]",
      "SELECT * FROM events WHERE id = ? | [1]",
      "SELECT 1 | []",
      "DELETE FROM events | []",
      "DELETE FROM events WHERE id = ? | [1]",
      "DELETE FROM events | []",
    ]
    assert_logs [], expected
  end

  def test_exec_sends_a_multi_statement_text_whole_to_the_primary_database
    connect_analytics
    assert_nil Edgeway::Model.exec(MULTI_STATEMENT_SQL)
    assert_logs ["#{MULTI_STATEMENT_SQL} | []"], []
  end

  def test_exec_can_name_another_database
    connect_analytics
    assert_nil Edgeway::Model.exec("DROP TABLE a", database: :analytics)
    assert_logs [], ["DROP TABLE a | []"]
  end

  def test_exec_is_refused_inside_a_batch
    connect_analytics
    error = assert_raise(ArgumentError) { Edgeway::Model.batch { Edgeway::Model.exec("DROP TABLE a") } }
    assert_equal "Model.exec can't run inside Model.batch", error.message
    assert_equal false, Edgeway::Model.batching?
    assert_logs [], []
  end

  def test_exec_maps_a_database_error
    @primary.fail_next("D1_EXEC_ERROR: syntax error")
    error = assert_raise(Edgeway::DatabaseError) { Edgeway::Model.exec("NOPE") }
    assert_equal "D1_EXEC_ERROR: syntax error", error.message
  end

  def test_exec_refuses_an_empty_sql
    connect_analytics
    error = assert_raise(ArgumentError) { Edgeway::Model.exec("") }
    assert_equal "Model.exec needs SQL text", error.message
    assert_logs [], []
  end

  def test_exec_refuses_a_blank_sql
    connect_analytics
    error = assert_raise(ArgumentError) { Edgeway::Model.exec("  \n") }
    assert_equal "Model.exec needs SQL text", error.message
    assert_logs [], []
  end

  def test_exec_refuses_a_nil_sql
    connect_analytics
    error = assert_raise(ArgumentError) { Edgeway::Model.exec(nil) }
    assert_equal "Model.exec needs SQL text", error.message
    assert_logs [], []
  end

  def test_a_belongs_to_loads_the_parent_from_the_other_database
    connect_analytics
    @analytics.queue([{ "id" => 1, "note" => "n", "todo_id" => 7 }])
    impression = Impression.first
    @primary.queue([{ "id" => 7, "title" => "p", "done" => 0, "priority" => "normal", "position" => 1, "created_at" => "c", "updated_at" => "u" }])
    assert_equal "p", impression.todo.title
    assert_logs [TODO_7_SELECT_LOG], [IMPRESSION_SELECT_LOG]
  end

  def test_a_batch_runs_on_the_database_of_its_models
    connect_analytics
    event = persisted_event
    Edgeway::Model.batch do
      event.update!(name: "one")
      Event.delete_all
    end
    assert_logs [], ["BATCH 2", "UPDATE events SET name = ? WHERE id = ? | [\"one\",1]", "DELETE FROM events | []"]
  end

  def test_a_batch_that_starts_on_the_analytics_database_cannot_add_a_primary_write
    connect_analytics
    event = persisted_event
    todo = persisted_todo
    error = assert_raise(ArgumentError) do
      Edgeway::Model.batch do
        event.update!(name: "two")
        todo.update!(title: "mixed")
      end
    end
    assert_equal "Model.batch spans databases (analytics and primary); a batch runs on one database", error.message
    assert_equal false, Edgeway::Model.batching?
    assert_logs [], []
  end

  def test_a_batch_that_starts_on_the_primary_database_cannot_add_an_analytics_write
    connect_analytics
    event = persisted_event
    todo = persisted_todo
    error = assert_raise(ArgumentError) do
      Edgeway::Model.batch do
        todo.update!(title: "mixed")
        event.update!(name: "two")
      end
    end
    assert_equal "Model.batch spans databases (primary and analytics); a batch runs on one database", error.message
    assert_equal false, Edgeway::Model.batching?
    assert_logs [], []
  end

  def test_eager_load_cannot_join_across_databases
    connect_analytics
    error = assert_raise(ArgumentError) { Impression.eager_load(:todo).to_a }
    assert_equal "eager_load :todo joins ModelDatabaseTest::Todo (database primary) to ModelDatabaseTest::Impression (database analytics); a JOIN can't cross databases", error.message
    assert_logs [], []
  end

  def test_destroy_refuses_dependent_destroy_on_another_database
    connect_analytics
    venue = Venue.instantiate({ "id" => 1, "name" => "hall" })
    error = assert_raise(ArgumentError) { venue.destroy }
    assert_equal "ModelDatabaseTest::Venue has_many :guests, dependent: :destroy, on database analytics; destroy can't delete across databases atomically", error.message
    assert_equal true, venue.persisted?
    assert_logs [], []
  end

  def test_destroy_refuses_dependent_delete_all_on_another_database
    connect_analytics
    stand = Stand.instantiate({ "id" => 1, "name" => "booth" })
    error = assert_raise(ArgumentError) { stand.destroy }
    assert_equal "ModelDatabaseTest::Stand has_many :passes, dependent: :delete_all, on database analytics; destroy can't delete across databases atomically", error.message
    assert_equal true, stand.persisted?
    assert_logs [], []
  end
end
