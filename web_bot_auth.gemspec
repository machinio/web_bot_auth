# frozen_string_literal: true

require_relative "lib/web_bot_auth/version"

Gem::Specification.new do |spec|
  spec.name          = "web_bot_auth"
  spec.version       = WebBotAuth::VERSION
  spec.authors       = ["Pavel Vlasikhin"]
  spec.email         = ["pavel.vlasikhin@machinio.com"]

  spec.summary       = "Web Bot Auth request signer for verified crawlers"
  spec.description   = "Cryptographically self-identifies HTTP requests per the Web Bot Auth scheme (RFC 9421 HTTP Message Signatures with Ed25519), so anti-bot systems can verify traffic without IP allowlisting."
  spec.homepage      = "https://github.com/machinio/web_bot_auth"

  spec.required_ruby_version = ">= 3.4.5"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files         = Dir["{lib/**/*,doc/**/*,README.md,*.gemspec}"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
