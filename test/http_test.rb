require "spinel_test/unit"
require "edgeway"

class HTTPTest < SpinelTest::Unit::TestCase
  JSON_BODY = '{"todo":{"title":"t","done":true,"tags":["a"],"deep":{"x":1}},"top":5,"nothing":null}'

  def json_request
    request = Edgeway::HTTP::Request.new("POST", "/todos", "q=a%20b&x=1", "application/json", JSON_BODY)
    request.read_body
    request.add_path_params({ "id" => "7" })
    request
  end

  def test_query_string_is_decoded
    assert_equal "a b", json_request.params["q"]
  end

  def test_json_object_is_flattened_to_bracketed_keys
    params = json_request.params
    assert_equal "t", params["todo[title]"]
    assert_equal "true", params["todo[done]"]
  end

  def test_json_arrays_and_nested_objects_are_not_flattened
    params = json_request.params
    assert_nil params["todo[tags]"]
    assert_nil params["todo[deep]"]
  end

  def test_json_number_becomes_a_string
    assert_equal "5", json_request.params["top"]
  end

  def test_json_null_becomes_an_empty_string
    assert_equal "", json_request.params["nothing"]
  end

  def test_path_params_are_merged
    assert_equal "7", json_request.params["id"]
  end

  def test_missing_param_is_absent
    assert_equal false, json_request.params.key?("zzz")
  end

  def test_require_returns_the_nested_params
    todo = json_request.params.require(:todo)
    assert_equal [["title", "t"], ["done", "true"]], todo.to_h.to_a
  end

  def test_permit_keeps_only_the_listed_keys
    todo = json_request.params.require(:todo)
    assert_equal [["title", "t"], ["done", "true"]], todo.permit(:title, :done, :priority).to_h.to_a
    assert_equal [["title", "t"]], todo.permit(:title).to_h.to_a
  end

  def test_require_raises_when_the_param_is_missing
    error = assert_raise(Edgeway::ParameterMissing) { json_request.params.require(:comment) }
    assert_equal "param is missing or the value is empty: comment", error.message
  end

  def test_form_body_is_decoded
    form = Edgeway::HTTP::Request.new("POST", "/", "", "application/x-www-form-urlencoded", "todo%5Btitle%5D=a+b&todo%5Bdone%5D=1")
    form.read_body
    assert_equal [["title", "a b"], ["done", "1"]], form.params.require(:todo).to_h.to_a
  end

  def test_invalid_json_body_is_a_bad_request
    request = Edgeway::HTTP::Request.new("POST", "/", "", "application/json", "{bad")
    assert_raise(Edgeway::BadRequest) { request.read_body }
  end

  def test_response_is_serialized_as_cgi
    response = Edgeway::HTTP::Response.new(201, "{}\n")
    response.headers["Content-Type"] = "application/json"
    assert_equal "Status: 201\nContent-Type: application/json\n\n{}\n", response.to_cgi
  end

  def test_params_are_permitted_only_after_permit
    todo = json_request.params.require(:todo)
    assert_equal false, json_request.params.permitted?
    assert_equal true, todo.permit(:title).permitted?
    assert_equal false, todo.permitted?
  end
end
