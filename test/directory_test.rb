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

  def test_response_headers_format
    key = WebBotAuth::Key.from_jwk(Fixtures::TEST_JWK)
    headers = WebBotAuth::Directory.new(keys: [key]).response_headers(
      authority: "www.machinio.com", created: 1735689600, expires: 1735776000
    )

    expected = %(sig1=("@authority";req);created=1735689600;expires=1735776000;keyid="#{Fixtures::TEST_KEYID}";alg="ed25519";tag="http-message-signatures-directory")
    assert_equal expected, headers["Signature-Input"]
    assert_match(%r{\Asig1=:[A-Za-z0-9+/]+=*:\z}, headers["Signature"])
  end

  def test_matches_cloudflare_directory_response_vector
    key = WebBotAuth::Key.from_jwk(Fixtures::TEST_JWK)
    base = WebBotAuth::SignatureBase.build(
      components: ["@authority;req", "content-digest"],
      params: { created: 1735689600, keyid: Fixtures::TEST_KEYID, alg: "ed25519", expires: 4889289600, tag: "http-message-signatures-directory" },
      request: {
        authority: "signature-agent.test",
        headers: { "content-digest" => "sha-256=:CADMT2aBdV/rqQr/NIru64ERQkCobVvllA4V0fLFDu0=:" }
      }
    )

    expected = <<~BASE.chomp
      "@authority";req: signature-agent.test
      "content-digest": sha-256=:CADMT2aBdV/rqQr/NIru64ERQkCobVvllA4V0fLFDu0=:
      "@signature-params": ("@authority";req "content-digest");created=1735689600;keyid="poqkLGiymh_W0uP6PZFw-dvez3QJT5SolqXBCW38r0U";alg="ed25519";expires=4889289600;tag="http-message-signatures-directory"
    BASE
    assert_equal expected, base
    assert_equal(
      "yiHq0TXrbpzbmlttAQMpYoAufitFJUWuNsakB7QQMoN0EHbo5o51bZRVR8az/ptTWCwllix9clrKXfGKwdPzBg==",
      Base64.strict_encode64(key.sign(base))
    )
  end

  def test_response_headers_round_trip
    key = WebBotAuth::Key.generate
    headers = WebBotAuth::Directory.new(keys: [key]).response_headers(authority: "www.machinio.com")

    assert WebBotAuth::Verifier.new(key: key).verify(
      method: "GET", authority: "www.machinio.com", path: "/.well-known/http-message-signatures-directory", headers: headers
    )
  end

  def test_response_headers_are_bound_to_authority
    key = WebBotAuth::Key.generate
    headers = WebBotAuth::Directory.new(keys: [key]).response_headers(authority: "www.machinio.com")

    refute WebBotAuth::Verifier.new(key: key).verify(
      method: "GET", authority: "evil.com", path: "/.well-known/http-message-signatures-directory", headers: headers
    )
  end

  def test_one_signature_per_key
    keys = [WebBotAuth::Key.generate, WebBotAuth::Key.generate]
    headers = WebBotAuth::Directory.new(keys: keys).response_headers(authority: "www.machinio.com")

    assert_equal 2, headers["Signature-Input"].scan(/(?:\A|, )sig\d=/).length
    assert_equal 2, headers["Signature"].scan(/(?:\A|, )sig\d=/).length
    keys.each_index { |index| assert_includes headers["Signature-Input"], %(sig#{index + 1}=("@authority";req)) }
    keys.each { |key| assert_includes headers["Signature-Input"], %(keyid="#{key.keyid}") }
  end

  def test_public_only_key_cannot_sign
    public_key = WebBotAuth::Key.from_jwk(WebBotAuth::Key.generate.public_jwk)

    assert_raises(WebBotAuth::Error) do
      WebBotAuth::Directory.new(keys: [public_key]).response_headers(authority: "www.machinio.com")
    end
  end
end
