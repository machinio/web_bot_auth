# machinio PR — serve the Web Bot Auth key directory

Self-contained spec for a **separate session working in the `machinio` repo**
(`/Users/vpa/work/machinio/machinio`). It has none of the context that produced
this file, so everything needed is below. Verify the "Repo facts" still hold before
writing code.

## Context (why this PR exists)

Machinio crawlers are being made into *verified bots* via **Web Bot Auth** (RFC 9421
HTTP Message Signatures). Each crawler request is signed; the anti-bot vendor in
front of the crawled site verifies it by fetching **our public key directory** at:

```
https://www.machinio.com/.well-known/http-message-signatures-directory
```

This PR adds that endpoint to the `machinio` Rails app. It serves a small, **public**
JSON document (an Ed25519 **public** key). There is **no secret, no private key, and
no new gem** involved — the private key lives only in the crawler app's environment.

## Scope

- Add one public `GET` endpoint that returns a static JSON with a specific
  content-type.
- Four changes: the JSON file, a controller, a route, a request spec.

**Out of scope (do NOT do):** the `web_bot_auth` gem, any secret/private key, Akamai
configuration (separate infra ticket), Cloudflare registration.

## Repo facts (verified 2026-07-08 on Rails 8.1.3 — re-confirm before coding)

- Tests are **RSpec** (`spec/requests/*_spec.rb`).
- **`ApplicationController` applies `before_action :http_auth`** (HTTP basic auth via
  `authenticate_or_request_with_http_basic`) plus a heavy stack (current_user,
  ability, geo, growthbook…). **Do NOT inherit it** — the endpoint must be publicly
  fetchable by machines with no auth.
- **Precedent to mirror: `app/controllers/service_worker_controller.rb`** —
  `class ServiceWorkerController < ActionController::API`. It serves `/sw.js`
  publicly through Rails, deliberately skipping the `ApplicationController` stack and
  setting its own headers. Our controller should look just like it.
- Precedent routes in `config/routes.rb`: `get 'ads.txt' => 'pages#app_ads'`,
  `get '/sw.js', to: 'service_worker#show'`, and a dev-only
  `get "/.well-known/appspecific/com.chrome.devtools.json"` rack lambda. Our route
  goes next to these and is **served in all environments** (not dev-only).

## Input: the directory JSON

The endpoint serves the production public directory. Its shape:

```json
{"keys":[{"kty":"OKP","crv":"Ed25519","x":"<base64url public key>","kid":"<RFC7638 thumbprint>","use":"sig"}]}
```

- If the production key already exists, commit its published directory JSON (it is
  public, not a secret).
- If it does not exist yet, generate a **placeholder** to unblock the PR, from a
  checkout of `github.com/machinio/web_bot_auth`:

  ```sh
  ruby -Ilib -rweb_bot_auth -e 'puts WebBotAuth::Directory.new(keys: [WebBotAuth::Key.generate]).to_json'
  ```

  ⚠️ **Coordination gate:** the committed JSON must be the **production** public key —
  the one whose private half is stored in the crawler app's `WEB_BOT_AUTH_PRIVATE_KEY`
  — **before** Cloudflare registration. If you commit a placeholder, add a `TODO`
  and block go-live on replacing it. A mismatched key verifies to 401, not 200.

## Changes

### 1. `config/web_bot_auth_directory.json`

The JSON document above (one line is fine).

### 2. `app/controllers/web_bot_auth_directory_controller.rb`

Mirror `ServiceWorkerController` — `ActionController::API`, not `ApplicationController`:

```ruby
class WebBotAuthDirectoryController < ActionController::API
  CONTENT_TYPE = 'application/http-message-signatures-directory+json'
  DIRECTORY = Rails.root.join('config/web_bot_auth_directory.json').read.freeze

  def show
    response.headers['Cache-Control'] = 'public, max-age=3600'
    render plain: DIRECTORY, content_type: CONTENT_TYPE
  end
end
```

### 3. `config/routes.rb`

Add next to the `ads.txt` / `sw.js` routes (served in all environments):

```ruby
get '/.well-known/http-message-signatures-directory',
    to: 'web_bot_auth_directory#show'
```

### 4. `spec/requests/web_bot_auth_directory_spec.rb`

```ruby
require 'rails_helper'

RSpec.describe 'Web Bot Auth directory', type: :request do
  it 'serves the directory with the spec content type' do
    get '/.well-known/http-message-signatures-directory'

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/http-message-signatures-directory+json')

    body = JSON.parse(response.body)
    expect(body['keys']).to be_an(Array)
    expect(body['keys'].first).to include('kty' => 'OKP', 'crv' => 'Ed25519', 'use' => 'sig')
  end

  it 'is public (no HTTP basic auth challenge)' do
    get '/.well-known/http-message-signatures-directory'
    expect(response).not_to have_http_status(:unauthorized)
  end
end
```

## Critical requirements (must all hold)

- Content-Type is **exactly** `application/http-message-signatures-directory+json`.
- The endpoint is **public** — no HTTP basic auth, no login. (Reason for the
  `ActionController::API` base.)
- Served in **production**, not gated by `Rails.env`.
- Response body is the **raw JSON bytes** of the file.

## Verify locally

```sh
bin/rails s
curl -i http://localhost:3000/.well-known/http-message-signatures-directory
#   200
#   content-type: application/http-message-signatures-directory+json
#   body == the JSON document
bundle exec rspec spec/requests/web_bot_auth_directory_spec.rb
```

Note: **externally, through Akamai, this path returns 403** until the infra team adds
the Akamai bot-manager exemption for it. That is tracked in a separate infra ticket
and is **not** part of this PR. A local/origin **200** is what this PR proves.

## PR description (template)

> **Serve Web Bot Auth key directory at `/.well-known/http-message-signatures-directory`**
>
> Adds a public endpoint returning our Web Bot Auth key directory (a public Ed25519
> key) so anti-bot verifiers can confirm our crawlers. Serves a static JSON with
> content-type `application/http-message-signatures-directory+json`, using an
> `ActionController::API` controller (mirrors `ServiceWorkerController`) so it is not
> behind the app's HTTP basic auth.
>
> No secrets and no new gem — the private key lives only in the crawler app.
>
> Depends on: (1) an Akamai exemption so the path is externally fetchable (infra
> ticket), (2) the production directory JSON (replace the placeholder before
> Cloudflare registration).

## Definition of done

- [ ] Repo facts re-confirmed (RSpec; ApplicationController still auth-gated;
      ServiceWorkerController pattern still present)
- [ ] Four files added; controller uses `ActionController::API`
- [ ] `curl` to localhost returns 200 + correct content-type + JSON body
- [ ] Request spec green
- [ ] PR opened with the description above; TODO noted if the directory JSON is a
      placeholder
