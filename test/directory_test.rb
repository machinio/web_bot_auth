# frozen_string_literal: true

require_relative "test_helper"
require "json"

class DirectoryTest < Minitest::Test
  def test_directory_structure
    key = WebBotAuth::Key.from_jwk(Fixtures::TEST_JWK)
    doc = JSON.parse(WebBotAuth::Directory.new(keys: [key]).to_json)
    assert_equal 1, doc["keys"].length

    jwk = doc["keys"].first
    assert_equal "OKP", jwk["kty"]
    assert_equal "Ed25519", jwk["crv"]
    assert_equal Fixtures::TEST_KEYID, jwk["kid"]
    assert_equal "sig", jwk["use"]
  end

  def test_content_type
    assert_equal "application/http-message-signatures-directory+json", WebBotAuth::Directory::CONTENT_TYPE
  end

  def test_accepts_single_key
    doc = WebBotAuth::Directory.new(keys: WebBotAuth::Key.generate).to_h
    assert_equal 1, doc["keys"].length
  end
end
