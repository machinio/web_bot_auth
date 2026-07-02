# Machinio side setup

What we have to do ourselves before Cloudflare (or any other verifier) can trust
our crawler. Three things: generate a production key, keep the private key safe,
and publish the key directory at a Machinio-controlled HTTPS origin.

## 1. Generate the production keypair

Generate one Ed25519 keypair. The private key goes into the secrets manager as the
`WEB_BOT_AUTH_PRIVATE_KEY` environment variable; only the public key is published in
the directory. This command prints the private PEM to stderr (copy it straight into
the secrets manager — it is never written to disk) and the public directory document
to stdout:

```sh
ruby -Ilib -rweb_bot_auth -e '
  key = WebBotAuth::Key.generate
  warn "keyid: #{key.keyid}"
  warn key.to_pem
  puts WebBotAuth::Directory.new(keys: [key]).to_json
' > http-message-signatures-directory.json
```

- The private PEM (stderr) is the secret — store it as `WEB_BOT_AUTH_PRIVATE_KEY`
  in the secrets manager. Do not commit it and do not leave it on disk.
- `http-message-signatures-directory.json` (stdout) holds only the public key and
  is safe to publish (see step 3).

## 2. Store the private key (12-factor: env, not files)

Machinio is a 12-factor app: the private key is configuration and lives in the
environment, injected by the secrets manager at runtime. It is never a file the app
reads and never committed.

- Store the PEM from step 1 as `WEB_BOT_AUTH_PRIVATE_KEY` in the secrets manager.
- The signer loads it from the environment once per process:

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
KEY = WebBotAuth::Key.from_pem(ENV.fetch("WEB_BOT_AUTH_PRIVATE_KEY"))
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
