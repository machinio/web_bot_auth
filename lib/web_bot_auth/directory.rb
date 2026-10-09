# frozen_string_literal: true

require "json"
require "base64"

module WebBotAuth
  class Directory
    CONTENT_TYPE = "application/http-message-signatures-directory+json"
    COMPONENTS = ["@authority;req"].freeze
    TAG = "http-message-signatures-directory"
    ALG = "ed25519"
    DEFAULT_TTL = 86_400

    def initialize(keys:)
      @keys = Array(keys)
    end

    def to_h
      { "keys" => @keys.map(&:public_jwk) }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end

    def response_headers(authority:, created: nil, expires: nil, ttl: DEFAULT_TTL)
      created ||= Time.now.to_i
      expires ||= created + ttl
      inputs = []
      signatures = []

      @keys.each_with_index do |key, index|
        raise Error, "signing the directory requires a private key" unless key.private?

        label = "sig#{index + 1}"
        params = { created: created, expires: expires, keyid: key.keyid, alg: ALG, tag: TAG }
        base = SignatureBase.build(components: COMPONENTS, params: params, request: { authority: authority })

        inputs << "#{label}=#{SignatureBase.signature_params(COMPONENTS, params)}"
        signatures << "#{label}=:#{Base64.strict_encode64(key.sign(base))}:"
      end

      {
        "Signature-Input" => inputs.join(", "),
        "Signature" => signatures.join(", ")
      }
    end
  end
end
