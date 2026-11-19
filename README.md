# shared-workflows

Reusable GitHub Actions workflows for the Arcanada ecosystem.

Public because cross-organization `workflow_call` on the GitHub Free plan
requires the reusable workflow to live in a public repository. This repo holds
reusable workflow definitions and their tested shell helpers — no secrets and no
directly scheduled self-hosted jobs run here.
Per-site callers (in private site repos) reference these via
`uses: Arcanada-one/shared-workflows/.github/workflows/<name>.yml@v1`.

## Workflows

### `deploy-static-site.yml`

Push-to-main deploy for static / PHP sites onto the `arcana-www` self-hosted
runner. Atomic install via temp-dir + double `mv` (opcache-safe — no fpm reload
needed). Inputs: `domain`, `webroot`, optional `build`, `health_scheme`.

Pipeline: checkout → disk preflight → optional `build` → footer build-stamp →
filtered atomic install → health check (rollback on failure) → retain two rollback
generations → Cloudflare cache purge (opt-in) → Ops Bot notify on failure.

**Disk controls.** Before dependency installation/build, the workflow warns at
80% filesystem usage and fails at 90%. The publish rsync excludes dependency and
cache directories (`node_modules`, `.cache`, `.venv`, and equivalents) at every
depth while preserving legitimate `dist`/`build` content. After a green health
check, it keeps the two newest `${webroot}.old.<sha>` rollback generations and
removes only older controlled-name directories.

**Footer build-stamp.** Before the atomic install the workflow writes
`build-info.php` (`$config['build_sha'] = '<short-sha>'`) from this site repo's
`github.sha`. This is parity with `Projects/Websites/deploy.sh` — the footer keeps
rendering the deployed SHA and the ecosystem drift detector still works after a
site moves off `deploy.sh` to gh-actions. The file is regenerated every deploy;
keep it gitignored in the site repo.

**Cloudflare cache purge.** After a green health check the workflow purges the
deployed domain's CF zone (`purge_everything`) so direct links reflect the deploy
immediately. Input `cloudflare_purge` (default `required`):

- `required` — missing `CF_API_TOKEN` fails the job. Callers **must** forward
  `secrets.CF_API_TOKEN` (explicit map or `secrets: inherit`). This closes the
  failure mode where a green deploy silently skipped purge because the secret
  was never mapped (shared-workflows#9).
- `optional` — legacy fail-soft skip when the secret is unset.
- `off` — skip purge entirely.

A domain that is not a CF zone is still skipped with a note (even in `required`
mode). Grant the token `Zone.Zone:Read` and `Cache Purge:Purge`. A 403 on zone
lookup means the stored token is dead — rotate it; code cannot invent a live
credential.

The post-deploy health check follows redirects (`curl -L`) and accepts any
final `2xx`: a site whose `/` issues a language/canonical redirect
(e.g. `/` → `/en/`) is healthy when the chain lands on a `2xx`. A `3xx` that
`-L` cannot follow (off-host `Location`), or any `4xx`/`5xx`/connection error,
triggers rollback to the previous webroot.

Caller example (in a private site repo, `.github/workflows/deploy.yml`):

```yaml
name: deploy
on: { push: { branches: [main] } }
jobs:
  call:
    uses: Arcanada-one/shared-workflows/.github/workflows/deploy-static-site.yml@v1
    with:
      domain: cubrim.com
      webroot: cubrim.com
      # cloudflare_purge: required  # default
    secrets:
      CF_API_TOKEN: ${{ secrets.CF_API_TOKEN }}
```

Origin: INFRA-0302 (parent INFRA-0299).

### `runner-workdir-janitor.yml`

Reusable cleanup for private consumer repositories. It targets explicitly supplied
self-hosted runner roots and removes only reproducible build/dependency directories
below `_work/<repo>/<repo>`. It never removes source files, `.git`, `_tool`,
`_actions`, `_diag`, webroots, or paths outside configured roots.

Dry-run is the default. The janitor refuses all cleanup while an exact
`Runner.Worker` process is active; the permanently running `Runner.Listener` does
not count as a job. Schedule this workflow only from a trusted private repository:

```yaml
name: runner-workdir-maintenance
on:
  schedule:
    - cron: '17 2 * * 0'
  workflow_dispatch:
jobs:
  dry-run:
    uses: Arcanada-one/shared-workflows/.github/workflows/runner-workdir-janitor.yml@v1
    with:
      dry_run: true
```

Review the uploaded report before changing a private caller to `dry_run: false`.
The deploy workflow never invokes this janitor.

### Per-runner pnpm store isolation

Self-hosted fleets that run several `Runner.Listener` units as one OS user
(for example every `arcana-prd-general-*` as `ci-runner`) share
`~/.local/share/pnpm/store/v11/index.db` by default. Concurrent `pnpm install`
jobs then contend on that SQLite index and can fail with
`[ERR_PNPM_ERR_SQLITE_ERROR] disk I/O error` even when the host disk itself is
healthy.

Two complementary fixes ship here:

1. **Host drop-in (preferred for the whole fleet).** Render a systemd drop-in
   that sets `pnpm_config_store_dir=<runner-root>/_work/_pnpm-store` (mirrors the
   existing per-runner `npm_config_cache` pattern). Do **not** use
   `npm_config_store_dir` for pnpm 11 — it is ignored.

```bash
# Requires an existing <runner-root>/_work directory; refuses relative paths,
# '..' segments, and characters outside [A-Za-z0-9/._-] (no Environment= injection).
./scripts/render-runner-pnpm-store-dropin.sh /opt/arcanada-runners/arcana-prd-general-11 \
  > /tmp/30-pnpm-store.conf
# Root/ops installs the file under the unit's .service.d/ and reloads; this
# repository never mutates production hosts.
```

2. **Job-level composite (immediate, per workflow).** Call before any
   `pnpm install`:

```yaml
- uses: Arcanada-one/shared-workflows/.github/actions/isolate-pnpm-store@<sha>
```

Regression coverage: `tests/pnpm-store-isolation.bats` plus
`scripts/assert-pnpm-store-isolation.sh` (pinned `pnpm@11.20.0` via corepack).
