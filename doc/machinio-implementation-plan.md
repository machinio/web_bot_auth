# Web Bot Auth — Machinio implementation plan

End-to-end runbook to take the `web_bot_auth` gem from "built and green" to
"crawlers are verified bots on Cloudflare-fronted targets".

## How a request becomes a verified 200

```
athena_crawlers (holds the PRIVATE key)
  └─ signs each request: Signature-Agent / Signature-Input / Signature
       │
       ▼
target site's anti-bot vendor (Cloudflare for the crawltest gate; real targets vary)
  └─ reads keyid, fetches our directory:
       https://www.machinio.com/.well-known/http-message-signatures-directory
       │  (served by the `machinio` Rails app — PUBLIC key only)
       │  ⚠️ www.machinio.com is behind AKAMAI, which 403s plain requests —
       │     this path MUST be exempted so external verifiers can fetch it
       ▼
  the verifier checks the Ed25519 signature against the fetched key → allow
```

Acceptance gate: `rake crawltest` (in the `web_bot_auth` repo) returns **200**
once the directory is published and registered. Today it returns 401 (signature
valid, key not registered) — that already proves our signing is byte-correct.

## Who holds what (blast radius)

| Component | Needs | Change |
| --- | --- | --- |
| `athena_crawlers` | the **private** key (`WEB_BOT_AUTH_PRIVATE_KEY` env) + the gem | signer wiring |
| `machinio` web app (behind **Akamai**) | the public directory JSON **and** the private key (`WEB_BOT_AUTH_PRIVATE_KEY` env), because Cloudflare requires the directory *response* to be signed | one route + one config file + ~15 lines of OpenSSL signing (**no gem**) **+ an Akamai exemption so the path is publicly fetchable** |
| Cloudflare | the directory URL registered | dashboard step |

`Signature-Agent = https://www.machinio.com` — the host that serves the directory
and the identity the crawler presents.

---

## Phase 0 — Decisions & prerequisites

Confirm before starting:

- [ ] `www.machinio.com` is the right Signature-Agent (directory is hosted there;
      crawlers identify as machinio.com). 
- [ ] `www.machinio.com` is behind **Akamai**, which returns **403 to plain
      (non-browser) requests** — confirmed by `curl -I https://www.machinio.com`
      (Akamai "Access Denied"). The directory path therefore needs an Akamai
      exemption (Phase 2 step 5), or the directory must be hosted off-Akamai.
      Engage the **Akamai/infra team** early — this is the critical-path dependency.
- [ ] We have Cloudflare dashboard access for the Verified Bots / signed-agent
      registration.
- [ ] Pilot crawler is a **direct-fetch** crawler, **not** a proxy-routed one
      (see the caveat in Phase 4).

---

## Phase 1 — Generate the production key (one-time)

From the `web_bot_auth` repo. The private PEM goes to stderr (into the secrets
manager); the public directory JSON goes to stdout (into the `machinio` app). The
private key never touches disk.

```sh
ruby -Ilib -rweb_bot_auth -e '
  key = WebBotAuth::Key.generate
  warn "keyid: #{key.keyid}"
  warn key.to_pem
  puts WebBotAuth::Directory.new(keys: [key]).to_json
' > web_bot_auth_directory.json
```

- [ ] Store the printed PEM as `WEB_BOT_AUTH_PRIVATE_KEY` in the **crawlers'**
      secrets (production env; locally `athena_crawlers/.env` via dotenv).
- [ ] Keep `web_bot_auth_directory.json` for Phase 2. Record the `keyid`.

---

## Phase 2 — Serve the directory on www.machinio.com (`machinio` Rails app)

The directory body is public and static (changes only on key rotation), so the web
app serves a committed JSON file. The app does **not** need the gem — but it does
need the **private key**, because Cloudflare requires the response itself to be
signed (step 6).

**1. Commit the public directory** produced in Phase 1:

```
machinio/config/web_bot_auth_directory.json
```

**2. Add the route** (served in **production**; mirrors the existing `.well-known`
lambda and `ads.txt` / `sw.js` conventions). Recommended: a tiny controller.

```ruby
# app/controllers/well_known_controller.rb
class WellKnownController < ApplicationController
  CONTENT_TYPE = "application/http-message-signatures-directory+json"
  DIRECTORY = Rails.root.join("config/web_bot_auth_directory.json").read.freeze

  def http_message_signatures_directory
    expires_in 1.hour, public: true
    render plain: DIRECTORY, content_type: CONTENT_TYPE
  end
end
```

```ruby
# config/routes.rb
get "/.well-known/http-message-signatures-directory",
    to: "well_known#http_message_signatures_directory"
```

- Ensure no global `before_action` (auth) blocks it — `skip_before_action` if the
  app authenticates by default (it is a public marketplace, so likely fine).
- Zero-controller alternative (bypasses all filters, matches the existing
  `com.chrome.devtools.json` route exactly):

  ```ruby
  DIRECTORY = Rails.root.join("config/web_bot_auth_directory.json").read.freeze
  get "/.well-known/http-message-signatures-directory",
      to: ->(_env) {
            [200,
             { "content-type" => "application/http-message-signatures-directory+json",
               "cache-control" => "public, max-age=3600" },
             [DIRECTORY]]
          }
  ```

**3. Test** (adapt to the app's test framework):

```ruby
# spec/requests/web_bot_auth_directory_spec.rb
require "rails_helper"

RSpec.describe "Web Bot Auth directory" do
  it "serves the directory with the spec content type" do
    get "/.well-known/http-message-signatures-directory"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/http-message-signatures-directory+json")
    expect(JSON.parse(response.body)["keys"].first["kty"]).to eq("OKP")
  end
end
```

**4. Deploy**, then verify live **from outside** (this is what a verifier does — a
plain server-side GET, no browser):

```sh
curl -sI https://www.machinio.com/.well-known/http-message-signatures-directory
# want: 200 + content-type: application/http-message-signatures-directory+json
# NOT:  403 (Akamai "Access Denied") — the bare `curl -I https://www.machinio.com/`
#       already returns 403, so this path likely needs the exemption in step 5.
```

Done 2026-07-27: the endpoint is deployed and serves the production directory
correctly. It still fails this check — see step 5.

**5. Akamai: make the directory publicly fetchable (required).** Cloudflare — and
any verifier — fetches the directory server-side to read our key, and Akamai Bot
Manager currently 403s such requests. Pick one:

- **Preferred — exempt the path in Akamai.** Add a match on
  `/.well-known/http-message-signatures-directory` that bypasses Bot Manager / WAF,
  returns the origin 200, passes the content-type through, and caches with a modest
  TTL (e.g. 1h) that we purge on key rotation. Owner: Akamai/infra team. Keeps
  `Signature-Agent = https://www.machinio.com`.
- **Fallback — serve off-Akamai.** Host the directory on a subdomain that is not
  behind Akamai Bot Manager (e.g. `https://keys.machinio.com/.well-known/http-message-signatures-directory`)
  and set `Signature-Agent` to that host everywhere: the signer config, the
  `crawltest.rb` default, and the docs. Use this if the Akamai change is slow.

**6. Sign the directory response (required).** Discovered 2026-07-29 in
[Cloudflare's Web Bot Auth reference](https://developers.cloudflare.com/bots/reference/bot-verification/web-bot-auth/):
serving the JWKS is not enough. Cloudflare requires the *response* to carry
`Signature` / `Signature-Input` headers — "attaching one signature per key in your
key directory" — proving we hold the private key we publish. An unsigned directory
fails validation even once Akamai lets the fetch through.

The signature covers `("@authority";req)` only, with `tag="http-message-signatures-directory"`,
`alg="ed25519"` and `keyid` = the JWK thumbprint. `@authority` must equal the Host
header of the incoming request, so it is signed per request rather than baked into
the file.

The `req` parameter is mandatory, in both `Signature-Input` and the signature base
(`"@authority";req: www.machinio.com`). The signature sits on a *response*, and
`@authority` is a property of the request that produced it, which RFC 9421 §2.4
expresses with `req`. Cloudflare's validator refuses a plain `"@authority"` outright;
that is what bounced our first submission (Phase 3, status 2026-10-09).

`Content-Type` must be exactly `application/http-message-signatures-directory+json`,
with no `; charset=utf-8` suffix. Rails appends one to `render plain:`, so the
controller clears it with `response.charset = false`.

This is ~15 lines of stdlib `OpenSSL` in the controller — the app reads
`WEB_BOT_AUTH_PRIVATE_KEY` from the environment (the same key the crawlers use) and
signs on the fly. The gem is deliberately **not** added as a dependency here; the
gem's `WebBotAuth::Directory#response_headers` produces byte-identical headers and
is what the crawler side uses. Consequences to plan for:

- The private key must be deployed to the **web** app, not only the crawlers.
- If `WEB_BOT_AUTH_PRIVATE_KEY` is absent the endpoint still serves the directory,
  unsigned, and logs a warning — a missing secret degrades verification rather than
  taking a public URL down.
- `config/web_bot_auth_directory.json` and the env key must stay in sync. If they
  drift, the signature's `keyid` will not match any key in the published JWKS and
  Cloudflare will reject the directory.
- Verify after deploy that `@authority` in `Signature-Input` is the public host
  (`www.machinio.com`) — i.e. that Akamai forwards the original `Host` header.

### Status 2026-07-27 — endpoint is live, Akamai still blocks machines

The Rails endpoint is deployed and correct. Fetched from a real browser it returns:

- `200`
- `content-type: application/http-message-signatures-directory+json; charset=utf-8`
- `cache-control: max-age=3600, public`
- body `{"keys":[{"kty":"OKP","crv":"Ed25519","x":"ljEOtkibX3AHeiG_m7zhSxVfz0Tt1XzJTnB9lkk6kcc","kid":"jnJI0JDL8DMS8fO_gODlVd5-OYIJuQM8IAw5WkuS8Js","use":"sig"}]}`
  — the **production** keyid, matching the key held by the crawlers.

**The exemption is still not in place.** Akamai Bot Manager applies its normal
browser-fingerprint heuristics to this path, so it answers by *how the client
looks*, not by path. Same URL, same second, same source IP:

```sh
U=https://www.machinio.com/.well-known/http-message-signatures-directory

# a verifier-style request — what Cloudflare actually sends
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'Accept: application/http-message-signatures-directory+json' "$U"      # → 403

# a request carrying the full browser header signature
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36' \
  -H 'Accept-Language: en-US,en;q=0.9' -H 'Accept-Encoding: gzip, deflate, br' \
  -H 'sec-fetch-dest: document' -H 'sec-fetch-mode: navigate' -H 'sec-fetch-site: none' "$U"   # → 200
```

Both results are deterministic (5/5 runs each). The minimal header set that passes
is browser `User-Agent` **+** `Accept-Language` **+** `Accept-Encoding` **+** the
three `sec-fetch-*` headers; drop any one of those groups and it returns to 403.
Plain `curl`, `Go-http-client`, and a `Cloudflare-*` User-Agent are all denied, as is
a fetch from unrelated cloud infrastructure — so this is header heuristics, not an
IP reputation problem, and not TLS fingerprinting.

Since Cloudflare's directory fetch is a plain server-side GET, it will receive the
Akamai Access Denied page and find no key. Phase 3 remains blocked.

**Akamai exemption request (copy into the infra/Akamai ticket):**

> Please allow anonymous, automated GET requests to exactly this path on
> `www.machinio.com`, bypassing Bot Manager and any WAF rule that currently returns
> 403:
>
>     /.well-known/http-message-signatures-directory
>
> - It serves a small **public** JSON (an Ed25519 **public** key) — no secrets, no
>   PII — safe to expose anonymously. It is already deployed and returns 200 at the
>   origin; only the edge denies it.
> - External verifiers (Cloudflare, etc.) fetch it **server-side, with no browser
>   headers**, and must receive **200**, not the Access Denied page. Bot Manager
>   currently allows this path only for clients presenting a full browser header
>   signature, which a verifier never does — so please match on the path and skip
>   the bot checks entirely rather than relaxing a heuristic.
> - Preserve the origin `Content-Type: application/http-message-signatures-directory+json`.
> - Cacheable with a ~1h TTL; we purge on key rotation.
> - Denied-request sample for log lookup: Akamai reference
>   `18.dd55645f.1785152371.69f792ea` (2026-07-27 11:39:31 GMT), a `GET` of the path
>   above with `Accept: application/http-message-signatures-directory+json`.
>
> Acceptance test — this must return 200 from any host, with no browser headers:
>
>     curl -sSI https://www.machinio.com/.well-known/http-message-signatures-directory

If the exemption stalls, the fallback is the off-Akamai host in the list above.
Neither `keys.machinio.com` nor `well-known.machinio.com` resolves today
(`www.machinio.com` is a CNAME to `www.machinio.com.edgekey.net`), so that route
means standing up a new host and changing `Signature-Agent` everywhere.

Gate: do not start Phase 3 until an external `curl` of the directory returns **200**.

---

## Phase 3 — Register with Cloudflare & verify the gate

Precondition: `rake directory_check` prints `PASS`. It fetches the directory the way
Cloudflare does (`User-Agent: Cloudflare-Validator/1.0`) and runs the checks of
Cloudflare's own [`http-signature-directory`](https://crates.io/crates/http-signature-directory)
validator: 200, the exact content-type, and one valid signature per key covering
`"@authority";req`. Cloudflare runs that validation when it reviews the submission,
and a bounced submission costs a full review cycle (the first took four weeks).

- [x] In the Cloudflare dashboard (**Application security → BotBase → Submission
      form**), submit the bot with identity attestation **Web Bot Auth** and the
      directory URL
      `https://www.machinio.com/.well-known/http-message-signatures-directory`
      (details in [`cloudflare-setup.md`](cloudflare-setup.md)). Submitted
      2026-09-11 as `MachinioBot`.
- [ ] Resubmit once `rake directory_check` passes against production: BotBase →
      **Submission history** → `MachinioBot` → **Edit submission**.
- [ ] From the `web_bot_auth` repo, sign with the production key and hit the gate:

  ```sh
  export WEB_BOT_AUTH_PRIVATE_KEY="$(<the production PEM>)"
  rake crawltest        # expect HTTP 200 (was 401 before registration)
  ```

200 here means the full path — signing, directory, registration, Cloudflare
verification — works end to end.

### Status 2026-10-09 — submission bounced: the directory signature lacked `req`

Cloudflare answered the 2026-09-11 submission with **Changes requested**: "Web Bot
Auth keys directory validation failed … ensure you are signing the directory
correctly."

Cause: the directory response was signed over a plain `("@authority")`. Cloudflare's
validator requires `("@authority";req)` and treats the plain form as a missing
component, so the signature never gets as far as being verified. Everything else was
already right — the key, the keyid, the tag, the validity window, and the signature
itself, which verifies over `@authority=www.machinio.com`.

Evidence:

- The validator's source
  (`cloudflare/web-bot-auth`, `crates/http-signature-directory/src/main.rs`) has an
  explicit branch for it: "You are signing a plain `@authority` without the `req`
  component parameter."
- Cloudflare's reference vector
  (`packages/web-bot-auth/test/test_data/web_bot_auth_directory_response_v1.json`)
  signs `"@authority";req: signature-agent.test`. The gem reproduces its signature
  byte for byte (`test_matches_cloudflare_directory_response_vector`).
- `rake directory_check` against production reported exactly two failures: the
  missing `req`, and `Content-Type` carrying `; charset=utf-8`, which the same
  validator flags as a warning.

Fix: `;req` in the gem's `Directory::COMPONENTS` and in machinio's
`WebBotAuthDirectoryController`, which also drops the charset. The two still produce
byte-identical headers.

Akamai is no longer in the way of the validator. Cloudflare fetches the directory as
`User-Agent: Cloudflare-Validator/1.0`, and Bot Manager now exempts that user agent:
it gets 200 on both the directory and `/bot`. Any other non-browser client still
gets 403, so check the endpoint with `rake directory_check`, not a bare `curl`. The
edge does not cache the directory response, so a deploy is visible immediately.

The machinio fix (`machinio/machinio#12012`) was merged and live the same day.
Against production, `rake directory_check` prints `PASS`, and Cloudflare's own
validator (`http-signature-directory` 0.7.0) reports `"success": true` with
`"signature_verified": true` and no errors or warnings.

Next: **Edit submission** in BotBase.

---

## Phase 4 — Wire the signer into athena_crawlers (pilot)

**1. Add the gem** (`athena_crawlers/Gemfile`, same git-source style as `phashion`):

```ruby
gem "web_bot_auth", github: "machinio/web_bot_auth"
```

**2. Lazy global signer**, gated on the env var so absence is a safe no-op
(enables a gradual rollout). `config/boot.rb` auto-loads `lib/helpers/*.rb`:

```ruby
# lib/helpers/web_bot_auth_signer.rb
module WebBotAuthSigner
  ENABLED = ENV.key?("WEB_BOT_AUTH_PRIVATE_KEY")

  SIGNER =
    if ENABLED
      WebBotAuth::Signer.new(
        key: WebBotAuth::Key.from_pem(ENV.fetch("WEB_BOT_AUTH_PRIVATE_KEY")),
        signature_agent: "https://www.machinio.com"
      )
    end

  def self.headers_for(url)
    return {} unless ENABLED

    uri = Addressable::URI.parse(url.to_s)
    SIGNER.sign(method: "GET", authority: uri.host, path: (uri.request_uri || "/"), headers: {})
  end
end
```

**3. Inject per-request headers computed from the TARGET url.** Web Bot Auth
headers are per-request (bound to `@authority` + `created`/`expires`), so a static
`headers` DSL entry will not work. The seam is request construction —
`ApplicationCrawler.build_request` (the same override point `SingleProxyCrawler`
already uses), merging the signed headers with the crawler's static headers
(User-Agent, Authorization):

```ruby
# sketch — confirm ApplicationCrawler#build_request signature and header-merge
def self.build_request(url:, headers: {}, **options)
  super(url:, headers: WebBotAuthSigner.headers_for(url).merge(headers), **options)
end
```

To confirm while implementing:
- How `Athena::Request` headers combine with the crawler's `settings[:headers]`
  (merge vs replace) in the athena gem — the signature headers must be **added**,
  not drop the UA/Authorization.
- `Athena::Scheduler` sets headers per request (`set_headers(request.headers)`), so
  per-request signing works on both Mechanize and Cuprite. On Cuprite/Chrome the
  signature is bound to the top-level `@authority` and covers same-origin requests
  within the validity window.

### ⚠️ Critical caveat: proxy-routed crawlers

`SingleProxyCrawler` fetches through a proxy API
(`174.138.118.5/api/proxy?url=<target>`). A signature on that request is bound to
the **proxy's** authority, not the target's — the target's Cloudflare never sees
it, so Web Bot Auth does nothing there. Options, in order of preference:

1. **Pilot on a direct-fetch crawler** (Mechanize/Cuprite hitting the target
   directly). Start here.
2. For proxy-routed targets, the Web Bot Auth headers must be applied on the leg
   the proxy makes to the target — only possible if that proxy service can forward
   or add them. Out of scope for the pilot.

---

## Phase 5 — Verify end-to-end & roll out

- [ ] `rake crawltest` → 200 (Phase 3).
- [ ] Run the pilot direct-fetch crawler against a real Cloudflare-fronted target;
      confirm it is not blocked and shows up as a verified/known bot in Cloudflare
      analytics.
- [ ] Watch crawler error/block rates for the pilot vs baseline.
- [ ] Expand to additional direct-fetch crawlers.

---

## Rollback

- Crawler side: unset `WEB_BOT_AUTH_PRIVATE_KEY` (signer becomes a no-op) or revert
  the Gemfile/helper. No signatures are sent; behavior returns to baseline.
- Web app: revert the route. The directory is public and harmless if left up.

## Key rotation

Publish the new and old public keys together in the directory during an overlap
window, switch `WEB_BOT_AUTH_PRIVATE_KEY` to the new key, then drop the old entry
once no in-flight signatures reference it. The `keyid` selects the directory entry,
so both coexist. See [`machinio-setup.md`](machinio-setup.md).

## Ticket checklist

- [ ] Phase 0 decisions confirmed
- [x] Production key generated; keyid recorded (`jnJI0JDL8DMS8fO_gODlVd5-OYIJuQM8IAw5WkuS8Js`)
- [ ] Private key stored in the crawlers' secrets as `WEB_BOT_AUTH_PRIVATE_KEY`
- [x] `machinio`: directory JSON committed, route added, test green, deployed —
      verified live 2026-07-27, serving the production keyid above
- [x] **Akamai exemption** — Bot Manager exempts `Cloudflare-Validator/1.0`, the
      user agent Cloudflare fetches the directory with (verified 2026-10-09)
- [x] Cloudflare registration submitted (2026-09-11; changes requested 2026-10-09)
- [x] `machinio`: directory signed over `("@authority";req)`, exact content-type
      (deployed 2026-10-09)
- [x] `rake directory_check` → `PASS` against production, and Cloudflare's
      `http-signature-directory` validator agrees (2026-10-09)
- [ ] Submission edited and resubmitted in BotBase —
      ⬅ **the one thing blocking everything downstream**
- [ ] `rake crawltest` → 200
- [ ] Gem added to `athena_crawlers`; lazy signer helper added
- [ ] Per-request signing wired into `ApplicationCrawler` (direct-fetch)
- [ ] Pilot crawler verified against a real target
- [ ] Rollout expanded; error rates monitored
