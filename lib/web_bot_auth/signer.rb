# frozen_string_literal: true

require "base64"

module WebBotAuth
  class Signer
    DEFAULT_COMPONENTS = ["@authority", "signature-agent"].freeze
    DEFAULT_TAG = "web-bot-auth"
    DEFAULT_ALG = "ed25519"
    DEFAULT_TTL = 300
    DEFAULT_LABEL = "sig1"

    def initialize(key:, signature_agent:, tag: DEFAULT_TAG, label: DEFAULT_LABEL)
      @key = key
      @signature_agent = signature_agent
      @tag = tag
      @label = label
    end

    def sign(method:, authority:, path:, headers: {}, components: DEFAULT_COMPONENTS, created: nil, expires: nil, ttl: DEFAULT_TTL)
      created ||= Time.now.to_i
      expires ||= created + ttl
      agent_header = %("#{@signature_agent}")

      params = {
        created: created,
        expires: expires,
        keyid: @key.keyid,
        alg: DEFAULT_ALG,
        tag: @tag
      }

      request = {
        method: method,
        authority: authority,
        path: path,
        headers: headers.merge("signature-agent" => agent_header)
      }

      base = SignatureBase.build(components: components, params: params, request: request)
      signature = @key.sign(base)

      {
        "Signature-Agent" => agent_header,
        "Signature-Input" => "#{@label}=#{SignatureBase.signature_params(components, params)}",
        "Signature" => "#{@label}=:#{Base64.strict_encode64(signature)}:"
      }
    end
  end
end
