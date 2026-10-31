module Edgeway
  module View
    ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;" }

    class SafeHTML
      def initialize(text)
        @text = text.to_s.dup
      end

      def to_s = @text
    end

    def self.escape(obj)
      return "" if obj.nil?
      return obj.to_s if obj.is_a?(SafeHTML)
      s = obj.to_s
      s.gsub(/[&<>"']/, ESCAPES)
    end
  end
end

class String
  def html_safe = Edgeway::View::SafeHTML.new(self)
end
