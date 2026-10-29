module Edgeway
  # Runs the app for one request, CGI style: the request comes in as CGI
  # environment variables and STDIN (HTTP::Request.from_env), and the response
  # goes out on stdout as CGI output (Status and the headers, a blank line,
  # the body), which js/runtime.js turns into the Response.
  module Server
    def self.run
      response = Edgeway.application.call(HTTP::Request.from_env)
      print response.to_cgi
      log_query_stats
    end

    def self.log_query_stats
      Model.database_names.each { |name| log_database_stats(name) }
    end

    def self.log_database_stats(name)
      stats = Model.query_stats(name)
      return unless stats.queries > 0
      prefix = name == Model::PRIMARY ? "" : "database=#{name} "
      Edgeway.logger.info(prefix + stats.log_text)
    end
  end
end
