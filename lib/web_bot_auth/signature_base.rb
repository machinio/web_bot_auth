# frozen_string_literal: true

module WebBotAuth
  module SignatureBase
    module_function

    def build(components:, params:, request:)
      lines = components.map { |component| "#{identifier(component)}: #{component_value(component, request)}" }
      lines << %("@signature-params": #{signature_params(components, params)})
      lines.join("\n")
    end

    def signature_params(components, params)
      inner = components.map { |component| identifier(component) }.join(" ")
      serialized = "(#{inner})"
      params.each { |key, value| serialized += ";#{key}=#{serialize_param(value)}" }
      serialized
    end

    def identifier(component)
      name, *flags = component.split(";")
      [%("#{name}"), *flags].join(";")
    end

    def component_value(component, request)
      name = component.split(";").first
      case name
      when "@authority"
        request.fetch(:authority).to_s.downcase
      when "@method"
        request.fetch(:method).to_s.upcase
      when "@path"
        path = request.fetch(:path).to_s
        path.empty? ? "/" : path
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
