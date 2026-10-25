module Edgeway
  module View
    ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;" }

    def self.escape(obj)
      return "" if obj.nil?
      s = obj.to_s
      s.gsub(/[&<>"']/, ESCAPES)
    end
  end
end
