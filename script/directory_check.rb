# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "web_bot_auth"
require "net/http"
require "json"
require "uri"

URL = ENV.fetch("WEB_BOT_AUTH_DIRECTORY_URL", "https://www.machinio.com/.well-known/http-message-signatures-directory")
USER_AGENT = ENV.fetch("WEB_BOT_AUTH_USER_AGENT", "Cloudflare-Validator/1.0")
CONTENT_TYPE = WebBotAuth::Directory::CONTENT_TYPE
TAG = WebBotAuth::Directory::TAG
FAILED = []

def fetch(uri)
  request = Net::HTTP::Get.new(uri.request_uri)
  request["User-Agent"] = USER_AGENT
  request["Accept"] = CONTENT_TYPE

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.request(request)
end

def ed25519_keys(body)
  Array(JSON.parse(body)["keys"]).select { |jwk| jwk["kty"] == "OKP" && jwk["crv"] == "Ed25519" }
rescue JSON::ParserError, TypeError
  []
end

def members(field)
  field.to_s.split(/,\s*(?=[\w-]+=)/).to_h { |member| member.split("=", 2) }
end

def verified?(key, uri, label, input, signature)
  WebBotAuth::Verifier.new(key: key).verify(
    method: "GET", authority: uri.host, path: uri.request_uri,
    headers: { "signature-input" => "#{label}=#{input}", "signature" => "#{label}=#{signature}" }
  )
rescue WebBotAuth::Error, OpenSSL::PKey::PKeyError, ArgumentError
  false
end

def check(description, passed)
  puts "#{passed ? "ok  " : "FAIL"}  #{description}"
  FAILED << description unless passed
  passed
end

uri = URI(URL)
response = fetch(uri)
inputs = members(response["Signature-Input"])
signatures = members(response["Signature"])
keys = ed25519_keys(response.body)

puts "GET #{URL}"
puts "User-Agent: #{USER_AGENT}"
puts

check("HTTP 200 (got #{response.code})", response.code == "200")
check("Content-Type is exactly #{CONTENT_TYPE} (got #{response["Content-Type"]})", response["Content-Type"] == CONTENT_TYPE)
check("directory publishes at least one Ed25519 key", keys.any?)

keys.each do |jwk|
  key = WebBotAuth::Key.from_jwk(jwk)
  label, input = inputs.find { |_, value| value.include?(%(keyid="#{key.keyid}")) && value.include?(%(tag="#{TAG}")) }

  puts
  puts "key #{key.keyid}"
  next unless check(%(response carries a signature with this keyid and tag="#{TAG}"), !input.nil?)

  puts "      #{label}=#{input}"
  covered = input[/\A\(([^)]*)\)/, 1].to_s.split(" ")
  created = input[/;created=(\d+)/, 1].to_i
  expires = input[/;expires=(\d+)/, 1].to_i

  check(%(covers "@authority";req, not a plain "@authority"), covered.include?(%("@authority";req)))
  check("has created and an unexpired expires", created.positive? && Time.now.to_i < expires)
  check("signature verifies over @authority=#{uri.host}", verified?(key, uri, label, input, signatures[label]))
end

puts
puts FAILED.empty? ? "PASS" : "FAIL: #{FAILED.length} check(s) failed"
exit(FAILED.empty? ? 0 : 1)
