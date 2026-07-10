# Deployment guide

Start here: [`machinio-implementation-plan.md`](machinio-implementation-plan.md) —
the end-to-end runbook (phases, copy-pasteable code, checklist) for rolling this
out across the `machinio` web app and `athena_crawlers`.

Reference docs it draws on:

1. [`machinio-setup.md`](machinio-setup.md) — what to do on the Machinio side:
   generate the production key, store the private key, and host the key directory.
2. [`cloudflare-setup.md`](cloudflare-setup.md) — what to do in Cloudflare:
   register the key directory and verify with the `crawltest.com` endpoint.
3. [`machinio-pr-plan.md`](machinio-pr-plan.md) — self-contained spec for the
   `machinio` Rails PR that serves the key directory (for a separate session).

Do these in order. The Machinio side must publish the directory before Cloudflare
can register the key.
