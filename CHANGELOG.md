# Changelog

## v1.1 — 2026-07-02

- **fix(deploy-static-site):** health check now follows redirects (`curl -fsSL`)
  and accepts any final `2xx`. Previously it required exactly `200` on `/` with
  no `-L`, so any site issuing a language/canonical redirect (`/` → `/en/`)
  was misreported as unhealthy and rolled back. Discovered on the first live
  migration (cubrim.com, INFRA-0301) which returns `302 → /en/`. (INFRA-0318)
- The floating `v1` tag is moved to this commit so existing `@v1` callers pick
  up the fix; `v1.1` is the immutable pin.

## v1 — 2026-06-30

- Initial `deploy-static-site.yml`: push-to-main deploy onto arcana-www
  self-hosted runner, atomic install (temp-dir + double `mv`), health check
  with rollback, Ops Bot failure notification. (INFRA-0302)
