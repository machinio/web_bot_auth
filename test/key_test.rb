# frozen_string_literal: true

require_relative "test_helper"

class KeyTest < Minitest::Test
  def test_thumbprint_known_answer
    key = WebBotAuth::Key.from_jwk(Fixtures::TEST_JWK)
    assert_equal Fixtures::TEST_KEYID, key.keyid
  end

  def test_public_jwk_fields
    jwk = WebBotAuth::Key.from_jwk(Fixtures::TEST_JWK).public_jwk
    assert_equal "OKP", jwk["kty"]
    assert_equal "Ed25519", jwk["crv"]
    assert_equal Fixtures::TEST_JWK["x"], jwk["x"]
    assert_equal Fixtures::TEST_KEYID, jwk["kid"]
    assert_equal "sig", jwk["use"]
  end

  def test_generate_produces_private_key
    key = WebBotAuth::Key.generate
    assert key.private?
    assert_equal 43, key.keyid.length
  end

  def test_pem_round_trip
    key = WebBotAuth::Key.generate
    loaded = WebBotAuth::Key.from_pem(key.to_pem)
    assert_equal key.keyid, loaded.keyid
    assert loaded.private?
  end

  def test_public_only_key_is_not_private
    public_only = WebBotAuth::Key.from_jwk(WebBotAuth::Key.from_jwk(Fixtures::TEST_JWK).public_jwk)
    refute public_only.private?
    assert_equal Fixtures::TEST_KEYID, public_only.keyid
  end

  def test_rejects_non_okp_key
    assert_raises(WebBotAuth::Error) do
      WebBotAuth::Key.from_jwk("kty" => "RSA", "crv" => "Ed25519")
    end
  end
end
