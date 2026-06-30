# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "web_bot_auth"
require "net/http"
require "uri"

TEST_JWK = {
  "kty" => "OKP",
  "crv" => "Ed25519",
  "d" => "n4Ni-HpISpVObnQMW0wOhCKROaIKqKtW_2ZYb2p9KcU",
  "x" => "JrQLj5P_89iXES9-vFgrIy29clF9CC_oPPsw3c5D0bs"
}.freeze

URL = ENV.fetch("WEB_BOT_AUTH_URL", "https://crawltest.com/cdn-cgi/web-bot-auth")
SIGNATURE_AGENT = ENV.fetch("WEB_BOT_AUTH_SIGNATURE_AGENT", "https://www.machinio.com")

def load_key
  if (pem = ENV["WEB_BOT_AUTH_PRIVATE_KEY"])
    WebBotAuth::Key.from_pem(pem)
  elsif (path = ENV["WEB_BOT_AUTH_PRIVATE_KEY_PATH"])
    WebBotAuth::Key.from_pem(File.read(path))
  else
    WebBotAuth::Key.from_jwk(TEST_JWK)
  end
end

def explain(code)
  case code.to_i
  when 200 then "OK: key is known to Cloudflare and the signature verified"
  when 401 then "signature is valid but the key is unknown (register the directory, or sign with the shared test key)"
  when 400 then "malformed signed request"
  else "unexpected status"
  end
end

key = load_key
uri = URI(URL)

headers = WebBotAuth::Signer.new(key: key, signature_agent: SIGNATURE_AGENT).sign(
  method: "GET",
  authority: uri.host,
  path: uri.request_uri,
  headers: {}
)

puts "keyid:           #{key.keyid}"
puts "signature-agent: #{SIGNATURE_AGENT}"
puts "GET #{URL}"
puts
headers.each { |name, value| puts "#{name}: #{value}" }
puts

if ENV["DRY_RUN"]
  puts "DRY_RUN set, skipping the network request"
  exit 0
end

request = Net::HTTP::Get.new(uri.request_uri)
request["User-Agent"] = "web_bot_auth/#{WebBotAuth::VERSION}"
headers.each { |name, value| request[name] = value }

http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = uri.scheme == "https"
response = http.request(request)

puts "HTTP #{response.code} -> #{explain(response.code)}"
exit(response.code.to_i == 200 ? 0 : 1)
