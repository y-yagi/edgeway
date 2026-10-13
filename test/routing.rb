require "edgeway"

r = Edgeway::Routing::RouteSet.new
r.draw do |m|
  m.resources :todos, only: [:index, :show, :create, :update, :destroy] do |t|
    t.resources :comments, only: [:index, :create, :destroy]
  end
  m.namespace :admin do |a|
    a.resources :todos, only: [:index]
    a.get "/stats", to: "stats#show"
  end
  m.get "/health", to: "health#show"
  m.root to: "health#show"
end
r.list.each { |x| puts "#{x.verb} #{x.pattern} #{x.controller_class_name}##{x.action}" }
route, found = r.recognize("GET", "/todos/5/comments")
puts "#{route.controller_class_name} #{route.action} #{found["todo_id"]}"
route, found = r.recognize("DELETE", "/todos/5/comments/9")
puts "#{route.action} #{found["todo_id"]} #{found["id"]}"
route, _ = r.recognize("GET", "/admin/stats")
puts route.controller_class_name
route, _ = r.recognize("GET", "/")
puts route.pattern
begin
  r.recognize("DELETE", "/health")
rescue Edgeway::RoutingError => e
  puts e.message
end

# a namespace around nested resources keeps its path prefix, at any depth
n = Edgeway::Routing::RouteSet.new
n.draw do |m|
  m.namespace :admin do |a|
    a.resources :todos, only: [:index, :show] do |t|
      t.resources :comments, only: [:index] do |c|
        c.resources :replies, only: [:show]
      end
    end
  end
  m.resources :posts, except: [:destroy, :update] do |po|
    po.resources :tags, only: [:index]
  end
  m.resources :categories, only: [:index] do |c|
    c.resources :items, only: [:index]
  end
end
n.list.each { |x| puts "#{x.verb} #{x.pattern} #{x.controller_class_name}##{x.action}" }
route, found = n.recognize("GET", "/admin/todos/5/comments/6/replies/7")
puts "#{route.controller_class_name} #{found["todo_id"]} #{found["comment_id"]} #{found["id"]}"
route, found = n.recognize("GET", "/categories/2/items")
puts "#{route.controller_class_name} #{found["category_id"]}"

# only: and except: take the five actions; others are an error
begin
  n.draw { |m| m.resources :pages, only: [:new] }
rescue ArgumentError => e
  puts e.message
end
begin
  n.draw { |m| m.resources :pages, except: [:edit] }
rescue ArgumentError => e
  puts e.message
end

# HEAD is answered by a GET route, and only by one
route, _ = r.recognize("HEAD", "/health")
puts "HEAD #{route.verb} #{route.action}"
begin
  r.recognize("HEAD", "/todos/5/comments/9")
  puts "HEAD matched a DELETE route"
rescue Edgeway::RoutingError => e
  puts e.message
end
