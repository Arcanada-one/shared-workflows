**QCK-0052 · Arcana-WWW Disk-Pressure Controls**

## Overview

Arcana-WWW deployment workflows running on GitHub‑hosted or self‑hosted runners occasionally hit disk‑pressure errors that cause build failures or partial deployments. This design introduces four mutually reinforcing controls:

1. Publish‑artifact exclusion – avoid uploading bulky, non‑publishable directories when the publish root is the repository root.
2. Preflight disk check – warn at 80 % usage, fail at 90 % before any npm/build step.
3. Atomic webroot version retention – keep exactly two prior generations after a successful health check, removing older ones safely.
4. Safe runner‑workdir janitor – a standalone tool that reclaims space from reproducible caches on idle runners without touching active webroots, source checkouts, or the toolcache.

The deploy controls stay in the existing reusable workflow. The runner janitor is a separate tested script plus a manually/scheduled reusable workflow, so deploys never delete unrelated runner state.

## Architecture

### 1. Publish-artifact exclusion (`deploy-static-site`)

**Trigger:** always, when the action’s `publish_dir` equals `"."` (repository root).

**Behaviour:**
- The existing atomic-install `rsync` always excludes dependency and cache directories that cannot be runtime site content: `node_modules`, `.git`, `.github`, `.cache`, `.npm`, `.pnpm-store`, `__pycache__`, `.pytest_cache`, and `.venv`.
- Compiled directories such as `dist` and `build` are not globally excluded because a caller may intentionally select them through `publish_dir`.
- `.gitignore` is not treated as a deployment manifest: it may contain generated runtime files that a site intentionally publishes.
- The same excludes apply for root and non-root `publish_dir` values, including nested dependency directories.

### 2. Preflight disk check (`check-disk` composite)

**Location:** emitted as a discrete step before `npm install` or equivalent heavy operations.

**Logic:**
```bash
used=$(df -P "$GITHUB_WORKSPACE" | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$used" -ge 90 ]; then
  echo "::error::Preflight disk usage ${used}% >= 90% – aborting"
  exit 1
elif [ "$used" -ge 80 ]; then
  echo "::warning::Preflight disk usage ${used}% >= 80% – consider running the janitor"
fi
```
- The action accepts an optional `fail_threshold` (default 90) and `warn_threshold` (default 80). It outputs `disk_usage_percent` for later use.
- If the `df` command fails or the filesystem type does not support `%` output, the step passes with a warning and marks itself as degraded.

### 3. Atomic webroot version retention

**Deployment script behavior (inside `deploy-static-site`).**

The existing workflow uses rename-based atomic installation, not symlinks:

```
/var/www/example.com
/var/www/example.com.old.<sha>
/var/www/example.com.old.<older-sha>
```

**Sequence:**
1. Keep the existing `next -> live` and `live -> old.<sha>` rename sequence and rollback behavior.
2. Only after the health check succeeds, enumerate sibling directories matching the exact basename-controlled pattern `${WEBROOT}.old.*`.
3. Sort by mtime, retain exactly the two newest previous generations, and remove older matches.
4. Refuse pruning if `WEBROOT` is empty, contains `/`, or resolves outside `/var/www`; never match `.broken.*`, the live webroot, or unrelated directories.
5. Log every removed generation and the resulting retained set.

### 4. Safe runner‑workdir janitor

A separate reusable workflow (`runner-workdir-janitor.yml`) and shell helper. Because this repository is public, it has no direct schedule or manual self-hosted trigger; a trusted private consumer owns the schedule and calls it with `workflow_call`. It is never invoked during a deployment.

**Safety gates (order of execution):**
1. **Active worker detection** – scan the process table for `Runner.Worker`. `Runner.Listener` is expected to be permanently active and does not indicate a running job. If any worker exists, set `runner_busy=true` and exit without deletion.
2. **Dry‑run support** – input `dry_run` (default `true` for safety). When set, all deletions are logged and sized but not executed.
3. **Target roots** – trusted constants in the reusable workflow; callers cannot widen the deletion scope. The script still requires and validates comma-separated absolute roots for direct operator use and tests.
4. **Safe-to-delete patterns** – only `node_modules`, `.cache`, `.parcel-cache`, `.turbo`, `.next/cache`, `coverage`, `target`, `dist`, and `build` below repository workspaces under `<runner-root>/_work/<repo>/<repo>/`. Source checkouts, `_actions`, `_tool`, `_diag`, package-manager home caches, active webroots, and paths outside configured roots are never candidates.
5. **Reclaimed bytes report** – the action walks the eligible trees, sums sizes, and prints a line `[janitor] reclaimed <N> bytes` for each deletion. A summary job output `total_bytes_reclaimed` is set. In dry‑run mode, the log states `[janitor] dry-run would reclaim <N> bytes`.

**Outputs:** `total_bytes_reclaimed`, `runner_busy` (boolean), and a list of deleted paths (JSON array).

## Safety & Error handling

- All scripts use `set -euo pipefail` and handle missing commands gracefully.
- The janitor’s process detection uses an exact executable/command-line probe for `Runner.Worker` that does not match its own grep/probe command. If `pgrep` is unavailable, it examines `/proc/*/cmdline` on Linux; otherwise it exits conservatively.
- Symlinks: the janitor never follows symlinks when deleting; it resolves real paths first and verifies they remain within `runner_roots`.
- The webroot retention script atomically creates a per-webroot lock directory to prevent concurrent pruning, using only portable filesystem primitives.
- The preflight check respects the `ACTIONS_RUNNER_FORCE_ACTIONS_NODE_VERSION` and other known edge cases by parsing `df` output in POSIX‑defined unit‑based mode (`df -P`).
- Exclusions during publish‑artifact creation are precise: the script only excludes directories, not files that happen to share a name (unless explicitly blacklisted files like `yarn.lock` under `node_modules`).

## Tests

### Unit / functional
- **Exclusion logic:** test driver creates a fake publish tree with nested `node_modules/`, `.cache/`, and a legitimate `dist/`; it verifies dependencies/caches are excluded while `dist/` and normal site files remain.
- **Preflight check:** simulate filesystem usage by creating a dummy volume with known usage; assert `exit 0` below warn, `exit 0` with warning between 80–90, `exit 1` above 90.
- **Janitor pattern matching:** feed a directory tree containing `.git`, `node_modules`, `_temp`, and a mis‑named `toolcache/` under a runner root. Dry‑run checks expected deletions and untouched directories.

### Integration (CI)
- Deterministic shell tests use temporary directories and an injectable disk-usage value; they do not require loop devices, root, or a live self-hosted runner.
  - A dummy node project is checked out.
  - The janitor is invoked with `dry_run: false` while no worker process is active – verify `node_modules` and `_temp` are removed and bytes reclaimed logged.
  - Then, artificially start a background process named `Runner.Worker` (echo shell script), call janitor – confirm exit code 1 and no deletions.
  - Verify active webroot path remains untouched.
- **Webroot retention:** a dockerised test that deploys three successive builds to a local webroot; health‑check passes for all; script prunes leaving only the two newest plus current; then deploy a fourth and confirm oldest is gone.
- **Disk preflight:** inject usage values below 80, at 80, and at 90; assert pass, warning, and failure respectively.

## Rollout

1. **Implementation** – Deliver all features as new composite actions (`check-disk/action.yml`, `janitor/action.yml`, `prune-webroot/action.yml`) and a reusable workflow `janitor.yml`) in `shared-workflows/`.
2. **arcana-www integration** – Consumers remain unchanged because the protections are safe defaults in `deploy-static-site@v1`.
3. **Janitor deployment** – Deploy `janitor.yml` as a manually triggerable workflow for all self‑hosted runner pools. Establish a recommendation: run it weekly or whenever disk usage crosses 70 %.
4. **Monitoring** – Alert on failed `check-disk` steps; track `total_bytes_reclaimed` from janitor runs to validate effectiveness.

## Acceptance Criteria

The following criteria must be satisfied before the design is considered complete. Each links to the corresponding success criterion in the product requirements document (none for this small operational hardening task, but the format is retained for traceability).

| Id | Criterion | Verification |
|----|-----------|--------------|
| QCK‑0052‑AC1 | Every publish directory excludes dependency and cache directories, including nested node_modules. | Automated rsync-filter test against a temporary payload. |
| QCK‑0052‑AC2 | Preflight check warns at >=80% disk usage and fails at >=90% (default thresholds). | Integration test with controlled disk fill. |
| QCK‑0052‑AC3 | After a successful health check, exactly two prior rename-based webroot generations remain alongside the live directory. | Test with four controlled generations; verify names and count. |
| QCK‑0052‑AC4 | Janitor refuses to delete when a Runner.Worker process is active; exits with code 1 and does not modify disk. | Integration test with simulated process. |
| QCK‑0052‑AC5 | Janitor dry‑run logs the exact directories that would be deleted and total size, but performs no deletions. | Dry‑run test; check logs and file system state. |
| QCK‑0052‑AC6 | Janitor never removes source checkouts (.git directories), active webroots, or the toolcache. | Targeted integration tests attempting deletion of protected paths. |
| QCK‑0052‑AC7 | Janitor reports total reclaimed bytes when run normally. | Check job output and log lines. |
| QCK‑0052‑AC8 | All components are implemented as reusable assets in shared‑workflows and integrated into arcana‑www. | Repository structure verification and successful deployment of arcana‑www using the new actions. |
