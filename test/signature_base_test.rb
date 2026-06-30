# frozen_string_literal: true

require_relative "test_helper"

class SignatureBaseTest < Minitest::Test
  def setup
    @components = ["@authority", "signature-agent"]
    @params = {
      created: 1735689600,
      expires: 1735693200,
      keyid: Fixtures::TEST_KEYID,
      alg: "ed25519",
      tag: "web-bot-auth"
    }
    @request = {
      method: "GET",
      authority: "crawltest.com",
      path: "/cdn-cgi/web-bot-auth",
      headers: { "signature-agent" => %("https://www.machinio.com") }
    }
  end

  def test_exact_base_bytes
    expected = <<~BASE.chomp
      "@authority": crawltest.com
      "signature-agent": "https://www.machinio.com"
      "@signature-params": ("@authority" "signature-agent");created=1735689600;expires=1735693200;keyid="poqkLGiymh_W0uP6PZFw-dvez3QJT5SolqXBCW38r0U";alg="ed25519";tag="web-bot-auth"
    BASE

    base = WebBotAuth::SignatureBase.build(components: @components, params: @params, request: @request)
    assert_equal expected, base
  end

  def test_signature_params_serialization
    expected = %(("@authority" "signature-agent");created=1735689600;expires=1735693200;keyid="poqkLGiymh_W0uP6PZFw-dvez3QJT5SolqXBCW38r0U";alg="ed25519";tag="web-bot-auth")
    assert_equal expected, WebBotAuth::SignatureBase.signature_params(@components, @params)
  end

  def test_signature_agent_value_keeps_quotes
    base = WebBotAuth::SignatureBase.build(components: @components, params: @params, request: @request)
    assert_includes base, %("signature-agent": "https://www.machinio.com")
  end

  def test_authority_is_lowercased
    request = @request.merge(authority: "CrawlTest.COM")
    base = WebBotAuth::SignatureBase.build(components: @components, params: @params, request: request)
    assert_includes base, %("@authority": crawltest.com)
  end

  def test_missing_covered_header_raises
    assert_raises(WebBotAuth::Error) do
      WebBotAuth::SignatureBase.build(components: @components, params: @params, request: @request.merge(headers: {}))
    end
  end
end
