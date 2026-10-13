require "edgeway/test"
require "test_helper"

class HealthTest < Edgeway::IntegrationTest
  def test_health
    get "/health"
    assert_response 200
    assert_equal "ok", json["status"]
  end

  def test_root_is_the_health_check
    get "/"
    assert_response 200
    assert_equal "ok", json["status"]
  end
end
