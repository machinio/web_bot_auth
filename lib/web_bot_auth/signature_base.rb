# frozen_string_literal: true

module WebBotAuth
  module SignatureBase
    module_function

    def build(components:, params:, request:)
      lines = components.map { |name| %("#{name}": #{component_value(name, request)}) }
      lines << %("@signature-params": #{signature_params(components, params)})
      lines.join("\n")
    end

    def signature_params(components, params)
      inner = components.map { |name| %("#{name}") }.join(" ")
      serialized = "(#{inner})"
      params.each { |key, value| serialized += ";#{key}=#{serialize_param(value)}" }
      serialized
    end

    def component_value(name, request)
      case name
      when "@authority"
        request.fetch(:authority).to_s.downcase
      when "@method"
        request.fetch(:method).to_s.upcase
      when "@path"
        request.fetch(:path).to_s
      else
        field_value(name, request)
      end
    end

    def field_value(name, request)
      headers = request[:headers] || {}
      value = headers[name] || headers[name.downcase]
      raise Error, "missing covered header: #{name}" if value.nil?

      value.to_s.strip
    end

    def serialize_param(value)
      case value
      when Integer
        value.to_s
      when String, Symbol
        %("#{value}")
      else
        raise Error, "unsupported param type: #{value.class}"
      end
    end
  end
end
