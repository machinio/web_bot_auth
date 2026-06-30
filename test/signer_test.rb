# frozen_string_literal: true

require_relative "test_helper"

class SignerTest < Minitest::Test
  def setup
    @key = WebBotAuth::Key.from_jwk(Fixtures::TEST_JWK)
    @signer = WebBotAuth::Signer.new(key: @key, signature_agent: "https://www.machinio.com")
  end

  def test_produces_three_headers
    headers = @signer.sign(method: "GET", authority: "crawltest.com", path: "/")
    assert_equal %w[Signature Signature-Agent Signature-Input].sort, headers.keys.sort
  end

  def test_signature_agent_is_quoted
    headers = @signer.sign(method: "GET", authority: "crawltest.com", path: "/")
    assert_equal %("https://www.machinio.com"), headers["Signature-Agent"]
  end

  def test_signature_input_format
    headers = @signer.sign(method: "GET", authority: "crawltest.com", path: "/", created: 1735689600, expires: 1735693200)
    expected = %(sig1=("@authority" "signature-agent");created=1735689600;expires=1735693200;keyid="#{Fixtures::TEST_KEYID}";alg="ed25519";tag="web-bot-auth")
    assert_equal expected, headers["Signature-Input"]
  end

  def test_signature_is_byte_sequence
    headers = @signer.sign(method: "GET", authority: "crawltest.com", path: "/")
    assert_match(%r{\Asig1=:[A-Za-z0-9+/]+=*:\z}, headers["Signature"])
  end

  def test_signature_is_deterministic
    args = { method: "GET", authority: "crawltest.com", path: "/", created: 1735689600, expires: 1735693200 }
    assert_equal @signer.sign(**args)["Signature"], @signer.sign(**args)["Signature"]
  end

  def test_default_expiry_uses_ttl
    headers = @signer.sign(method: "GET", authority: "crawltest.com", path: "/", created: 1000, ttl: 60)
    assert_includes headers["Signature-Input"], "created=1000;expires=1060"
  end
end
