# Cloudflare side setup

What to do in Cloudflare so that requests signed by `web_bot_auth` are recognized
as verified bot traffic. Prerequisite: the key directory is already published on
the Machinio side (see [`machinio-setup.md`](machinio-setup.md)).

## How Cloudflare verifies a request

1. The crawler sends `Signature-Agent`, `Signature-Input`, and `Signature`.
2. Cloudflare looks up the public key by the `keyid` (the RFC 7638 JWK thumbprint)
   among the keys it has registered from our directory.
3. It rebuilds the RFC 9421 signature base from the covered components and checks
   the Ed25519 signature.

Cloudflare verifies against keys it has **already registered** from our directory
URL — it does not trust an arbitrary key just because the request points at a
directory. So the directory URL must be submitted to Cloudflare first.

## 1. Register the key directory

In the Cloudflare dashboard, register Machinio as a signed/verified bot and submit
the key directory URL:

```
https://www.machinio.com/.well-known/http-message-signatures-directory
```

Cloudflare accepts all valid Ed25519 keys found there. After registration, our
`keyid` becomes "known" and signed requests can verify to **200**.

References:

- Cloudflare Web Bot Auth docs:
  https://developers.cloudflare.com/bots/reference/bot-verification/web-bot-auth/
- Verified Bots program:
  https://developers.cloudflare.com/bots/concepts/bot/verified-bots/

## 2. Verify with crawltest.com

`https://crawltest.com/cdn-cgi/web-bot-auth` is Cloudflare's test endpoint. Run:

```sh
# our own registered key: WEB_BOT_AUTH_PRIVATE_KEY set in the environment (from the secrets manager)
rake crawltest
```

Response codes:

| Status | Meaning |
| ------ | ------- |
| 200 | Key is known to Cloudflare and the signature verified. |
| 401 | Signature is valid but the key is unknown (not registered yet). |
| 400 | The signed request is malformed. |

Reading the result:

- **401 before registration** is the expected good signal: it proves our signing
  is byte-correct and only key registration is missing.
- **200 after registration** is the acceptance gate.

The script's default is the shared Web Bot Auth test key (keyid
`poqkLGiymh_W0uP6PZFw-dvez3QJT5SolqXBCW38r0U`). Against `crawltest.com` it returns
**401**: the signature is cryptographically valid but the key is not registered.
This confirms the signing implementation is correct independently of registration —
a malformed request would return **400**:

```sh
ruby script/crawltest.rb
```

## 3. Replay / nonce note

The signer emits `created` and `expires` (a 5-minute window by default). A `nonce`
parameter is optional; Cloudflare currently neither requires it nor guards against
replay using a nonce database. We can add `nonce` later if a verifier starts
enforcing it.
