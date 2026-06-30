# frozen_string_literal: true

require_relative "test_helper"

class VerifierTest < Minitest::Test
  def setup
    @key = WebBotAuth::Key.from_jwk(Fixtures::TEST_JWK)
    @signer = WebBotAuth::Signer.new(key: @key, signature_agent: "https://www.machinio.com")
    @request = { method: "GET", authority: "crawltest.com", path: "/cdn-cgi/web-bot-auth" }
    @headers = @signer.sign(**@request, created: 1735689600, expires: 1735693200)
  end

  def test_round_trip
    assert WebBotAuth::Verifier.new(key: @key).verify(**@request, headers: @headers)
  end

  def test_round_trip_with_generated_key
    key = WebBotAuth::Key.generate
    headers = WebBotAuth::Signer.new(key: key, signature_agent: "https://www.machinio.com").sign(**@request)
    assert WebBotAuth::Verifier.new(key: key).verify(**@request, headers: headers)
  end

  def test_wrong_key_fails
    refute WebBotAuth::Verifier.new(key: WebBotAuth::Key.generate).verify(**@request, headers: @headers)
  end

  def test_tampered_authority_fails
    refute WebBotAuth::Verifier.new(key: @key).verify(**@request.merge(authority: "evil.com"), headers: @headers)
  end

  def test_accepts_case_insensitive_header_keys
    upcased = @headers.transform_keys(&:upcase)
    assert WebBotAuth::Verifier.new(key: @key).verify(**@request, headers: upcased)
  end
end
