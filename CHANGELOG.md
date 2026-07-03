# Changelog

## v1.2 — 2026-07-03

- **feat(deploy-static-site):** footer build-stamp — a new step writes
  `build-info.php` (`$config['build_sha'] = '<short-sha>'`) from this site repo's
  `github.sha` into the checked-out tree before the atomic install. Parity with
  `Projects/Websites/deploy.sh` `write_build_stamp`: preserves the footer build-SHA
  and the ecosystem drift detector (`check-repo-site-sync.sh`) after a site migrates
  off `deploy.sh` to gh-actions. Under gh-actions the site repo is the payload's
  source of truth, so `github.sha` is the correct stamp (not a cross-repo SHA). (INFRA-0320)
- **feat(deploy-static-site):** Cloudflare cache purge (opt-in) — after a green
  health check, purges the deployed domain's CF zone (`purge_everything`) so direct
  links reflect the deploy immediately. Parity with `deploy.sh`. Fail-soft: if the
  `CF_API_TOKEN` secret is unset, or the domain is not a CF zone, the purge is
  skipped with a note — the deploy already succeeded and the edge cache self-expires.
  Migration stays unblocked when the CF secret is not yet provisioned. (INFRA-0320)
- The floating `v1` tag is moved to this commit so existing `@v1` callers pick up
  both features; `v1.2` is the immutable pin.

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
