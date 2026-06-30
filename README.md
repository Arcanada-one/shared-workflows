# shared-workflows

Reusable GitHub Actions workflows for the Arcanada ecosystem.

Public because cross-organization `workflow_call` on the GitHub Free plan
requires the reusable workflow to live in a public repository. This repo holds
**workflow definitions only** — no secrets, no self-hosted jobs run here.
Per-site callers (in private site repos) reference these via
`uses: Arcanada-one/shared-workflows/.github/workflows/<name>.yml@v1`.

## Workflows

### `deploy-static-site.yml`

Push-to-main deploy for static / PHP sites onto the `arcana-www` self-hosted
runner. Atomic install via temp-dir + double `mv` (opcache-safe — no fpm reload
needed). Inputs: `domain`, `webroot`, optional `build`, `health_scheme`.

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
