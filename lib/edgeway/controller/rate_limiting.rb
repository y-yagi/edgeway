module Edgeway
  module Controller
    @rate_limiter = RateLimit::NullLimiter.new

    def self.rate_limiter = @rate_limiter

    def self.rate_limiter=(limiter)
      @rate_limiter = limiter
    end

    # Rate limiting through a limiter binding:
    #
    #   class PostsController < ApplicationController
    #     rate_limit "WRITE_LIMITER", only: [:create], retry_after: 10
    #   end
    #
    # It is a before_action. Over the limit it raises TooManyRequests (429).
    # The limit and the period are set on the binding, not here. A by: method is
    # never a route's action (Base.rate_limit adds it to the non-actions).
    module RateLimiting
      class Rule < Callback
        attr_reader :binding_name, :by, :scope_name, :retry_after

        def self.build(binding_name, by, name, retry_after, only, except)
          raise ArgumentError, "the limiter binding name must be a non-empty String" unless binding_name.is_a?(String) && !binding_name.empty?
          raise ArgumentError, "by: must be a Symbol" unless by.nil? || by.is_a?(Symbol)
          raise ArgumentError, "name: must be a String" unless name.nil? || name.is_a?(String)
          raise ArgumentError, "retry_after: must be a positive Integer" unless retry_after.nil? || RateLimiting.positive_integer?(retry_after)
          new(binding_name, by, name, retry_after.nil? ? 0 : retry_after, only.map(&:to_s), except.map(&:to_s))
        end

        def initialize(binding_name, by, name, retry_after, only, except)
          super("rate_limit", only, except)
          @binding_name = binding_name
          @by = by
          @scope_name = name
          @retry_after = retry_after
        end

        def run(controller)
          controller.send(:enforce_rate_limit, self)
        end
      end

      IPV6_GROUPS = 8
      IPV6_PREFIX_GROUPS = 4
      IPV4_OCTETS = 4
      IPV4_MAPPED_ZERO_GROUPS = 5
      IPV4_MAPPED_MARKER_GROUP = 5
      IPV4_HIGH_GROUP = 6
      IPV4_LOW_GROUP = 7
      HEX_DIGITS = "0123456789abcdef"

      # An IPv6 client usually has a whole /64, so its address is keyed by
      # that prefix; an IPv4 address (or one that does not parse) is kept.
      def self.address_key(address)
        return address unless address.include?(":")

        text = address.downcase.split("%")[0].to_s
        groups = ipv6_groups(embedded_ipv4_as_hex(text))
        return address if groups.nil?

        ipv4_mapped?(groups) ? ipv4_from_groups(groups) : groups[0, IPV6_PREFIX_GROUPS].join(":") + "::/64"
      end

      # "::ffff:192.0.2.1" -> "::ffff:c000:201", so the dotted tail parses as two groups.
      def self.embedded_ipv4_as_hex(text)
        colon = text.rindex(":").to_i
        octets = text[colon + 1, text.length].to_s.split(".", -1)
        return text unless octets.length == IPV4_OCTETS && octets.all? { |octet| decimal_octet?(octet) }

        values = octets.map { |octet| octet.to_i }
        high = (values[0] * 256 + values[1]).to_s(16)
        low = (values[2] * 256 + values[3]).to_s(16)
        text[0, colon + 1].to_s + high + ":" + low
      end

      def self.decimal_octet?(octet)
        octet.length >= 1 && octet.length <= 3 && octet.each_char.all? { |digit| "0123456789".include?(digit) } && octet.to_i <= 255
      end

      def self.ipv4_mapped?(groups)
        groups[0, IPV4_MAPPED_ZERO_GROUPS].all? { |group| group == "0" } && groups[IPV4_MAPPED_MARKER_GROUP] == "ffff"
      end

      def self.ipv4_from_groups(groups)
        high = groups[IPV4_HIGH_GROUP].to_i(16)
        low = groups[IPV4_LOW_GROUP].to_i(16)
        [high / 256, high % 256, low / 256, low % 256].join(".")
      end

      def self.ipv6_groups(text)
        halves = text.split("::", -1)
        return nil if halves.empty? || halves.length > 2

        head = group_list(halves[0])
        tail = halves.length == 2 ? group_list(halves[1]) : []
        return nil if head.nil? || tail.nil?

        filler = IPV6_GROUPS - head.length - tail.length
        return nil if halves.length == 1 ? filler != 0 : filler < 1

        head + Array.new(filler, "0") + tail
      end

      def self.group_list(text)
        return [] if text.empty?

        groups = text.split(":", -1).map { |group| normalized_group(group) }
        groups.include?("") ? nil : groups
      end

      def self.normalized_group(group)
        return "" if group.empty? || group.length > 4 || !group.each_char.all? { |digit| HEX_DIGITS.include?(digit) }

        group.to_i(16).to_s(16)
      end

      # Integer() gives Spinel a type for a parameter no call site types.
      def self.positive_integer?(value)
        value.is_a?(Integer) && Integer(value) > 0
      end

      private

      def enforce_rate_limit(rule)
        return unless Edgeway::Controller.rate_limiter.exceeded?(rule.binding_name, rate_limit_key_for(rule))

        raise TooManyRequests.new("rate limit exceeded (#{rule.binding_name})", rule.retry_after)
      end

      def rate_limit_key_for(rule)
        scope = rule.scope_name.nil? ? self.class.name : rule.scope_name
        "#{scope}:#{rule.by.nil? ? default_rate_limit_key : send(rule.by).to_s}"
      end

      def default_rate_limit_key
        subject = authenticated? ? current_claims["sub"].to_s : ""
        return "user:#{subject}" unless subject.empty?

        "ip:#{RateLimiting.address_key(request.remote_addr)}"
      end
    end
  end
end
