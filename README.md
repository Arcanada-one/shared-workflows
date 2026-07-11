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

**Cloudflare cache purge (opt-in).** After a green health check, if the
`CF_API_TOKEN` secret is provisioned on the runner/org, the workflow purges the
deployed domain's CF zone (`purge_everything`) so direct links reflect the deploy
immediately. Fail-soft and skipped entirely when the secret is unset or the domain
is not a CF zone — the deploy already succeeded and the edge cache self-expires,
so migration is never blocked on the secret. Grant the secret a token scoped to
`Cache Purge:Purge` only.

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
