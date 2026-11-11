require "spinel_test/unit"
require "edgeway"
require "edgeway/db/memory"

class DatabaseTestCase < SpinelTest::Unit::TestCase
  def setup
    @database = Edgeway::DB::MemoryAdapter.new
    Edgeway::Model.connection = @database
  end

  def teardown
    Edgeway::Model.disconnect(Edgeway::Model::PRIMARY)
  end
end
