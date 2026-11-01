module Edgeway
  module TestDatabases
    # Called before each test.
    def self.reset
    end

    def self.open(name)
      migrations = name == Edgeway::Model::PRIMARY ? "db/migrations" : "db/#{name}/migrations"
      directory = File.join(Edgeway::TEST_APP_ROOT, migrations)
      if name != Edgeway::Model::PRIMARY && !File.directory?(directory)
        raise Edgeway::ConfigurationError, "database #{name} (config/database.yml) has no #{migrations} directory"
      end
      database = Edgeway::DB::SQLiteAdapter.new(":memory:")
      database.apply_migrations(directory)
      database
    end
  end
end
