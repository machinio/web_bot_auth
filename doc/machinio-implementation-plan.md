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
| `machinio` web app (behind **Akamai**) | the **public** directory JSON only | one route + one config file (**no gem, no secret**) **+ an Akamai exemption so the path is publicly fetchable** |
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

The directory is public and static (changes only on key rotation), so the web app
serves a committed JSON file. **No gem and no private key** in this app.

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

Gate: do not start Phase 3 until an external `curl` of the directory returns **200**.

---

## Phase 3 — Register with Cloudflare & verify the gate

Precondition: the directory URL returns 200 to an external `curl` (Phase 2 step 5).
If Akamai still 403s it, Cloudflare cannot read our key and registration finds
nothing.

- [ ] In the Cloudflare dashboard, register Machinio as a signed/verified bot and
      submit the directory URL:
      `https://www.machinio.com/.well-known/http-message-signatures-directory`
      (details in [`cloudflare-setup.md`](cloudflare-setup.md)).
- [ ] From the `web_bot_auth` repo, sign with the production key and hit the gate:

  ```sh
  export WEB_BOT_AUTH_PRIVATE_KEY="$(<the production PEM>)"
  rake crawltest        # expect HTTP 200 (was 401 before registration)
  ```

200 here means the full path — signing, directory, registration, Cloudflare
verification — works end to end.

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
- [ ] Production key generated; private key in crawler secrets; keyid recorded
- [ ] `machinio`: directory JSON committed, route added, test green, deployed
- [ ] **Akamai exemption** for the directory path (or off-Akamai host chosen)
- [ ] Directory returns **200 to an external curl** with the correct content-type
- [ ] Cloudflare registration submitted
- [ ] `rake crawltest` → 200
- [ ] Gem added to `athena_crawlers`; lazy signer helper added
- [ ] Per-request signing wired into `ApplicationCrawler` (direct-fetch)
- [ ] Pilot crawler verified against a real target
- [ ] Rollout expanded; error rates monitored
