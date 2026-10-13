Edgeway.application.routes.draw do |r|
  r.get "/health", to: "health#show"
  r.root to: "health#show"
end
