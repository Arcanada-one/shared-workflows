# Changelog

## v1.1 — 2026-07-02

- **fix(deploy-static-site):** health check now follows redirects (`curl -fsSL`)
  and accepts any final `2xx`. Previously it required exactly `200` on `/` with
  no `-L`, so any site issuing a language/canonical redirect (`/` → `/en/`)
  was misreported as unhealthy and rolled back. Discovered on the first live
  migration (cubrim.com, INFRA-0301) which returns `302 → /en/`. (INFRA-0318)
- **fix(deploy-static-site):** health probe adds `-k` — it resolves to 127.0.0.1
  (bypassing the CDN) so it hits the origin cert (Cloudflare origin / self-signed),
  which is not a publicly-trusted chain; without `-k` an http->https redirect on
  loopback fails cert verification (curl 60). Edge TLS is validated by the CDN.
- The floating `v1` tag is moved to this commit so existing `@v1` callers pick
  up the fix; `v1.1` is the immutable pin.

## v1 — 2026-06-30

- Initial `deploy-static-site.yml`: push-to-main deploy onto arcana-www
  self-hosted runner, atomic install (temp-dir + double `mv`), health check
  with rollback, Ops Bot failure notification. (INFRA-0302)
