# frozen_string_literal: true

require "openssl"
require "digest"
require "base64"

module WebBotAuth
  class Key
    CURVE = "Ed25519"
    KTY = "OKP"

    def self.generate
      new(OpenSSL::PKey.generate_key(CURVE))
    end

    def self.from_pem(pem)
      new(OpenSSL::PKey.read(pem))
    end

    def self.from_jwk(jwk)
      jwk = jwk.transform_keys(&:to_sym)
      raise Error, "unsupported kty: #{jwk[:kty]}" unless jwk[:kty] == KTY
      raise Error, "unsupported crv: #{jwk[:crv]}" unless jwk[:crv] == CURVE

      if jwk[:d]
        new(OpenSSL::PKey.new_raw_private_key(CURVE, b64url_decode(jwk[:d])))
      elsif jwk[:x]
        new(OpenSSL::PKey.new_raw_public_key(CURVE, b64url_decode(jwk[:x])))
      else
        raise Error, "jwk missing both d and x"
      end
    end

    def self.b64url(bytes)
      Base64.urlsafe_encode64(bytes, padding: false)
    end

    def self.b64url_decode(str)
      str += "=" * ((4 - (str.length % 4)) % 4)
      Base64.urlsafe_decode64(str)
    end

    def initialize(pkey)
      @pkey = pkey
    end

    attr_reader :pkey

    def private?
      @pkey.raw_private_key
      true
    rescue OpenSSL::PKey::PKeyError
      false
    end

    def sign(data)
      @pkey.sign(nil, data)
    end

    def verify(signature, data)
      @pkey.verify(nil, signature, data)
    end

    def keyid
      self.class.b64url(Digest::SHA256.digest(thumbprint_json))
    end

    def public_jwk
      {
        "kty" => KTY,
        "crv" => CURVE,
        "x" => x,
        "kid" => keyid,
        "use" => "sig"
      }
    end

    def to_pem
      @pkey.private_to_pem
    end

    def public_to_pem
      @pkey.public_to_pem
    end

    private

    def x
      self.class.b64url(@pkey.raw_public_key)
    end

    def thumbprint_json
      %({"crv":"#{CURVE}","kty":"#{KTY}","x":"#{x}"})
    end
  end
end
