# Machinio side setup

What we have to do ourselves before Cloudflare (or any other verifier) can trust
our crawler. Three things: generate a production key, keep the private key safe,
and publish the key directory at a Machinio-controlled HTTPS origin.

## 1. Generate the production keypair

Generate one Ed25519 keypair. Keep the private key secret; only the public key
goes into the directory.

```sh
ruby -Ilib -rweb_bot_auth -e '
  key = WebBotAuth::Key.generate
  File.write("web_bot_auth_private.pem", key.to_pem)
  File.write("http-message-signatures-directory.json", WebBotAuth::Directory.new(keys: [key]).to_json)
  puts "keyid: #{key.keyid}"
'
```

This writes:

- `web_bot_auth_private.pem` — the private key (**secret**).
- `http-message-signatures-directory.json` — the public directory document.

## 2. Store the private key

- Do **not** commit the PEM. Put it in the secrets manager / environment used by
  the crawlers (e.g. `WEB_BOT_AUTH_PRIVATE_KEY` holding the PEM contents, or
  `WEB_BOT_AUTH_PRIVATE_KEY_PATH` pointing at a mounted secret).
- The signer loads it once per process:

  ```ruby
  SIGNER = WebBotAuth::Signer.new(
    key: WebBotAuth::Key.from_pem(ENV.fetch("WEB_BOT_AUTH_PRIVATE_KEY")),
    signature_agent: "https://www.machinio.com"
  )
  ```

## 3. Publish the key directory

Serve the directory document at:

```
https://www.machinio.com/.well-known/http-message-signatures-directory
```

Requirements:

- Content-Type **must** be `application/http-message-signatures-directory+json`.
- Must be reachable over HTTPS without authentication.
- The host **must** match the `Signature-Agent` value the signer sends
  (`https://www.machinio.com`). Verifiers discover the key directory from
  `Signature-Agent`.

Rack example:

```ruby
DIRECTORY = WebBotAuth::Directory.new(keys: [KEY]).to_json

map "/.well-known/http-message-signatures-directory" do
  run ->(_env) {
    [200, { "content-type" => WebBotAuth::Directory::CONTENT_TYPE }, [DIRECTORY]]
  }
end
```

If served as a static file, configure the web server to send the content-type
above for that path (browsers/CDNs will otherwise default to `application/json`).

## 4. Wire the signer into the crawlers

See the "Integration with Athena" section of the top-level
[`README.md`](../README.md). In short: compute the headers per request from the
method/authority/path and attach them — via `Downloader`'s `custom_headers:` for
asset fetches, or `Athena::Session#set_headers` for main crawl requests.

## 5. Key rotation

To rotate without downtime, publish both the old and new public keys in the
directory during an overlap window, switch signing to the new private key, then
drop the old key once no in-flight signatures reference it:

```ruby
WebBotAuth::Directory.new(keys: [new_key, old_key]).to_json
```

The `keyid` in each signature tells the verifier which directory entry to use, so
multiple keys can coexist.
