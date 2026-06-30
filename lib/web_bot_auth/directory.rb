# frozen_string_literal: true

require "json"

module WebBotAuth
  class Directory
    CONTENT_TYPE = "application/http-message-signatures-directory+json"

    def initialize(keys:)
      @keys = Array(keys)
    end

    def to_h
      { "keys" => @keys.map(&:public_jwk) }
    end

    def to_json(*args)
      JSON.generate(to_h, *args)
    end
  end
end
