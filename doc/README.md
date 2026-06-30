# Deployment guide

Steps to take `web_bot_auth` from a working gem to verified traffic in production.

1. [`machinio-setup.md`](machinio-setup.md) — what to do on the Machinio side:
   generate the production key, store the private key, and host the key directory.
2. [`cloudflare-setup.md`](cloudflare-setup.md) — what to do in Cloudflare:
   register the key directory and verify with the `crawltest.com` endpoint.

Do these in order. The Machinio side must publish the directory before Cloudflare
can register the key.
