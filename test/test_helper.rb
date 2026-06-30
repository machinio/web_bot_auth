# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "web_bot_auth"
require "minitest/autorun"

module Fixtures
  TEST_JWK = {
    "kty" => "OKP",
    "crv" => "Ed25519",
    "d" => "n4Ni-HpISpVObnQMW0wOhCKROaIKqKtW_2ZYb2p9KcU",
    "x" => "JrQLj5P_89iXES9-vFgrIy29clF9CC_oPPsw3c5D0bs"
  }.freeze

  TEST_KEYID = "poqkLGiymh_W0uP6PZFw-dvez3QJT5SolqXBCW38r0U"
end
