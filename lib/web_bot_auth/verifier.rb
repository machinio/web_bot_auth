# frozen_string_literal: true

require "base64"

module WebBotAuth
  class Verifier
    def initialize(key:)
      @key = key
    end

    def verify(method:, authority:, path:, headers:)
      headers = headers.transform_keys { |k| k.to_s.downcase }
      input = headers.fetch("signature-input") { raise Error, "missing Signature-Input" }
      signature_field = headers.fetch("signature") { raise Error, "missing Signature" }

      _, params_value = split_label(input)
      _, signature_value = split_label(signature_field)

      components = parse_components(params_value)
      params = parse_params(params_value)

      base = SignatureBase.build(
        components: components,
        params: params,
        request: { method: method, authority: authority, path: path, headers: headers }
      )

      @key.verify(decode_signature(signature_value), base)
    end

    private

    def split_label(value)
      value.split("=", 2)
    end

    def parse_components(params_value)
      inner = params_value[/\A\(([^)]*)\)/, 1].to_s
      inner.split(" ").map { |item| item.delete('"') }
    end

    def parse_params(params_value)
      tail = params_value.sub(/\A\([^)]*\)/, "")
      tail.split(";").reject(&:empty?).each_with_object({}) do |pair, acc|
        key, raw = pair.split("=", 2)
        acc[key.to_sym] = parse_value(raw)
      end
    end

    def parse_value(raw)
      if raw.start_with?('"')
        raw.delete('"')
      else
        Integer(raw)
      end
    end

    def decode_signature(value)
      Base64.strict_decode64(value.delete(":"))
    end
  end
end
