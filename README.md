# web_bot_auth

Ruby gem that lets a crawler cryptographically self-identify per the
[Web Bot Auth](https://datatracker.ietf.org/doc/draft-meunier-web-bot-auth-architecture/)
scheme, so anti-bot systems (Cloudflare, Akamai, AWS WAF, Fastly) can verify our
requests without IP allowlisting.

It signs outgoing HTTP requests with an Ed25519 key per
[RFC 9421 (HTTP Message Signatures)](https://www.rfc-editor.org/rfc/rfc9421.html)
and produces the `Signature-Agent`, `Signature-Input`, and `Signature` headers
that verifiers expect. This is the foundation for Machinio's verified-bot effort.

> Status: trial / MVP. The signer, local verifier, and key-directory document are
> implemented and round-trip tested. Production rollout (hosting the directory,
> registering with Cloudflare) is documented in [`doc/`](doc/).

## Installation

Add to the `Gemfile`, pulling from the Machinio GitHub org:

```ruby
gem "web_bot_auth", github: "machinio/web_bot_auth"
```

The gem has no runtime dependencies beyond the Ruby standard library
(OpenSSL, JSON, Digest, Base64). It requires Ruby `>= 3.4.5`.

## Quick start

```ruby
require "web_bot_auth"

key = WebBotAuth::Key.generate

signer = WebBotAuth::Signer.new(
  key: key,
  signature_agent: "https://www.machinio.com"
)

headers = signer.sign(
  method: "GET",
  authority: "crawltest.com",
  path: "/cdn-cgi/web-bot-auth"
)
# => {
#   "Signature-Agent" => "\"https://www.machinio.com\"",
#   "Signature-Input" => "sig1=(\"@authority\" \"signature-agent\");created=...;expires=...;keyid=\"...\";alg=\"ed25519\";tag=\"web-bot-auth\"",
#   "Signature"       => "sig1=:<base64 ed25519 signature>:"
# }

WebBotAuth::Verifier.new(key: key).verify(
  method: "GET",
  authority: "crawltest.com",
  path: "/cdn-cgi/web-bot-auth",
  headers: headers
)
# => true
```

`Verifier` checks signature correctness only. It does not enforce
`created`/`expires` against the current time and does not fetch the key directory
from `Signature-Agent`. It is for round-trip testing, not for verifying inbound
third-party bots.

## Key handling

```ruby
key = WebBotAuth::Key.generate                 # new Ed25519 keypair
key = WebBotAuth::Key.from_pem(File.read(pem)) # load a private (or public) key
key = WebBotAuth::Key.from_jwk(jwk_hash)       # load from a JWK (d => private, x-only => public)

key.keyid       # RFC 7638 JWK thumbprint (base64url, no padding) — used as the keyid
key.public_jwk  # { "kty" => "OKP", "crv" => "Ed25519", "x" => ..., "kid" => ..., "use" => "sig" }
key.to_pem      # PKCS#8 PEM of the private key
key.private?    # true if the key can sign
```

The `keyid` is the RFC 7638 thumbprint of the public JWK and is what verifiers use
to find your key in the directory.

## Key directory

The directory document is served at
`/.well-known/http-message-signatures-directory` with content-type
`application/http-message-signatures-directory+json`.

```ruby
directory = WebBotAuth::Directory.new(keys: [key])
directory.to_json
# => {"keys":[{"kty":"OKP","crv":"Ed25519","x":"...","kid":"...","use":"sig"}]}

WebBotAuth::Directory::CONTENT_TYPE
# => "application/http-message-signatures-directory+json"
```

See [`doc/machinio-setup.md`](doc/machinio-setup.md) for how to host this.

## Signed components

By default the signer covers `("@authority" "signature-agent")` with the
parameters `created`, `expires`, `keyid`, `alg="ed25519"`, and
`tag="web-bot-auth"`, matching Cloudflare's deployed format. The covered
components are overridable:

```ruby
signer.sign(
  method: "GET", authority: "crawltest.com", path: "/",
  components: ["@authority", "@path", "signature-agent"]
)
```

Note: when `signature-agent` is a covered component, its header value is
serialized into the signature base **with the surrounding quotes**, i.e. the base
line is `"signature-agent": "https://www.machinio.com"`. This is the part of
RFC 9421 most easily gotten wrong, so it is pinned by a unit test.

## Integration with Athena

The signer is transport-agnostic: it returns a hash of headers, which you attach
to whatever HTTP client makes the request. Load the private key once per process
and reuse the signer.

```ruby
SIGNER = WebBotAuth::Signer.new(
  key: WebBotAuth::Key.from_pem(ENV.fetch("WEB_BOT_AUTH_PRIVATE_KEY")),
  signature_agent: "https://www.machinio.com"
)
```

### Asset downloads (`athena_crawlers`, `Downloader`)

`Downloader.fetch` already accepts a `custom_headers:` keyword and builds the
request with raw `Net::HTTP`, which is the cleanest seam — the exact method,
authority, and path are known per request:

```ruby
uri  = Addressable::URI.parse(url)
auth = SIGNER.sign(method: "GET", authority: uri.host, path: uri.request_uri, headers: {})

Downloader.fetch(url, cookies, proxy, user_agent, custom_headers: auth)
```

### Main crawl requests (`athena` gem)

Per-request headers flow from the crawler DSL `headers` into `Athena::Request#headers`,
and `Athena::Scheduler` applies them via `Athena::Session#set_headers`
(Mechanize: `agent.request_headers=`, Cuprite: `driver.headers=`). The seam is to
compute the signed headers from `request.url` and merge them into `request.headers`
before `set_headers` is called.

Caveat: the signature is bound to `@authority`. On the `Net::HTTP` and Mechanize
paths this is naturally per-request. On the Cuprite/Chrome path headers are set on
the driver as a whole, so the signature is valid for same-origin requests within
the `created`..`expires` window but not for cross-origin subresources. The MVP
target is verification of the main request to the target origin.

## Acceptance check against crawltest.com

`script/crawltest.rb` signs a `GET` to `https://crawltest.com/cdn-cgi/web-bot-auth`
and reports the result:

```sh
rake crawltest                 # or: ruby script/crawltest.rb
DRY_RUN=1 ruby script/crawltest.rb   # print the signed headers without sending
```

Cloudflare's test endpoint returns:

- **200** — the key is known to Cloudflare and the signature verified.
- **401** — the signature is valid but the key is unknown.
- **400** — the signed request is malformed.

The script signs with the shared Web Bot Auth Ed25519 test key by default
(keyid `poqkLGiymh_W0uP6PZFw-dvez3QJT5SolqXBCW38r0U`). Against `crawltest.com` this
returns **401**: the signature is cryptographically verified, but the key is not
registered with Cloudflare. That 401 is the expected signal that our signing is
byte-correct — a malformed request would return **400**. Reaching **200** requires
publishing our own key directory and registering it with Cloudflare — see
[`doc/cloudflare-setup.md`](doc/cloudflare-setup.md). To sign with our own key:

```sh
WEB_BOT_AUTH_PRIVATE_KEY_PATH=path/to/private.pem ruby script/crawltest.rb
```

## Development

```sh
bundle install
rake test       # minitest suite
```

The signature base string is isolated in `WebBotAuth::SignatureBase` and has
focused tests pinning its exact bytes against a fixed fixture.

## References

Wire format validated against **draft-meunier-web-bot-auth-architecture-05** and
**draft-meunier-http-message-signatures-directory-05** (both 2026-03-02), plus
Cloudflare's deployed Web Bot Auth format — the acceptance anchor, pinned by the
`keyid` known-answer test. Note: the architecture draft was renamed to
`draft-meunier-webbotauth-httpsig-protocol` (-00, 2026-06-26); re-validate against
the latest revision before relying on it long-term.

- [RFC 9421 — HTTP Message Signatures](https://www.rfc-editor.org/rfc/rfc9421.html)
- [RFC 7638 — JWK Thumbprint](https://www.rfc-editor.org/rfc/rfc7638.html)
- [draft-meunier-webbotauth-httpsig-protocol (renamed from -web-bot-auth-architecture)](https://datatracker.ietf.org/doc/draft-meunier-webbotauth-httpsig-protocol/)
- [draft-meunier-http-message-signatures-directory](https://datatracker.ietf.org/doc/draft-meunier-http-message-signatures-directory/)
- [Cloudflare Web Bot Auth docs](https://developers.cloudflare.com/bots/reference/bot-verification/web-bot-auth/)
- [cloudflare/web-bot-auth (reference implementation)](https://github.com/cloudflare/web-bot-auth)
