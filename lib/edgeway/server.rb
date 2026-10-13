module Edgeway
  # Runs the app for one request, CGI style: the request comes in as CGI
  # environment variables and STDIN (HTTP::Request.from_env), and the response
  # goes out on stdout as CGI output (Status and the headers, a blank line,
  # the body), which js/runtime.js turns into the Response.
  module Server
    def self.run
      response = Edgeway.application.call(HTTP::Request.from_env)
      print response.to_cgi
    end
  end
end
