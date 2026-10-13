Edgeway.application.routes.draw do |r|
  r.resources :todos, only: [:index, :show, :create, :update, :destroy] do |t|
    t.resources :comments, only: [:index, :create, :destroy]   # /todos/:todo_id/comments
  end
  r.resources :tags, only: [:show, :create, :destroy]
  r.put "/tags/find_or_create", to: "tags#find_or_create"
  r.patch "/tags/rename_pair", to: "tags#rename_pair"
  r.get "/health", to: "health#show"
  r.get "/me", to: "me#show"               # needs a JWT (see check.sh)
  r.get "/boom", to: "health#boom"         # fails on purpose (see check.sh)
  r.root to: "health#show"
end
