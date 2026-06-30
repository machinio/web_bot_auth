# frozen_string_literal: true

require_relative "web_bot_auth/version"

module WebBotAuth
  class Error < StandardError; end
end

require_relative "web_bot_auth/key"
require_relative "web_bot_auth/signature_base"
require_relative "web_bot_auth/signer"
require_relative "web_bot_auth/verifier"
require_relative "web_bot_auth/directory"
