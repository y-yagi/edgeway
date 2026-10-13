require "edgeway"

include Edgeway::HTTP

req = Request.new("POST", "/todos", "q=a%20b&x=1", "application/json",
                  '{"todo":{"title":"t","done":true,"tags":["a"],"deep":{"x":1}},"top":5,"nothing":null}')
req.read_body
req.add_path_params({ "id" => "7" })
p req.params["q"]
p req.params["todo[title]"]
p req.params["todo[done]"]
p req.params["todo[tags]"]
p req.params["todo[deep]"]
p req.params["top"]
p req.params["nothing"]
p req.params["id"]
p req.params.key?("zzz")

todo = req.params.require(:todo)
p todo.to_h
p todo.permit(:title, :done, :priority).to_h

begin
  req.params.require(:comment)
rescue Edgeway::ParameterMissing => e
  puts "ParameterMissing: #{e.message}"
end

form = Request.new("POST", "/", "", "application/x-www-form-urlencoded", "todo%5Btitle%5D=a+b&todo%5Bdone%5D=1")
form.read_body
p form.params.require(:todo).to_h

bad = Request.new("POST", "/", "", "application/json", "{bad")
begin
  bad.read_body
rescue Edgeway::BadRequest => e
  puts "BadRequest"
end

res = Response.new(201, "{}\n")
res.headers["Content-Type"] = "application/json"
print res.to_cgi

p req.params.permitted?
p todo.permitted?
p todo.permit(:title).permitted?
