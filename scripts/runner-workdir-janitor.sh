#!/usr/bin/env bash
set -euo pipefail

runner_roots="${RUNNER_ROOTS:-}"
dry_run="${DRY_RUN:-true}"
report="${JANITOR_REPORT:-${RUNNER_TEMP:-/tmp}/runner-janitor-report.txt}"

write_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
}

if [[ "$dry_run" != "true" && "$dry_run" != "false" ]]; then
  echo "[janitor] DRY_RUN must be true or false" >&2
  exit 2
fi
if [[ -z "$runner_roots" ]]; then
  echo "[janitor] RUNNER_ROOTS is required" >&2
  exit 2
fi

worker_active="${RUNNER_WORKER_OVERRIDE:-}"
if [[ -z "$worker_active" ]]; then
  if pgrep -x Runner.Worker >/dev/null 2>&1; then worker_active=1; else worker_active=0; fi
fi
if [[ "$worker_active" == "1" ]]; then
  write_output runner_busy true
  write_output total_bytes_reclaimed 0
  echo "[janitor] Runner.Worker is active; refusing cleanup" >&2
  exit 3
fi
write_output runner_busy false

mkdir -p "$(dirname "$report")"
: > "$report"
would_reclaim=0
reclaimed=0

IFS=',' read -r -a roots <<< "$runner_roots"
for root in "${roots[@]}"; do
  if [[ "$root" != /* ]]; then
    echo "[janitor] runner root must be absolute: $root" >&2
    exit 2
  fi
  if [[ ! -d "$root" || -L "$root" || ! -d "$root/_work" || -L "$root/_work" ]]; then
    echo "[janitor] invalid runner root: $root" >&2
    exit 2
  fi
  canonical_root="$(cd "$root" && pwd -P)"

  for workspace in "$canonical_root"/_work/*/*; do
    [[ -d "$workspace" && ! -L "$workspace" ]] || continue
    canonical_workspace="$(cd "$workspace" && pwd -P)"
    case "$canonical_workspace" in "$canonical_root/_work/"*) ;; *) echo "[janitor] workspace escaped root: $workspace" >&2; exit 2 ;; esac

    while IFS= read -r -d '' candidate; do
      [[ -d "$candidate" && ! -L "$candidate" ]] || continue
      canonical_candidate="$(cd "$candidate" && pwd -P)"
      case "$canonical_candidate" in "$canonical_workspace/"*) ;; *) echo "[janitor] candidate escaped workspace: $candidate" >&2; exit 2 ;; esac
      case "$canonical_candidate" in */.git/*|*/_tool/*|*/_actions/*|*/_diag/*|*/toolcache/*) continue ;; esac

      kib="$(du -sk "$candidate" | awk '{print $1}')"
      bytes=$((kib * 1024))
      would_reclaim=$((would_reclaim + bytes))
      printf '%s\t%s\n' "$bytes" "$canonical_candidate" >> "$report"
      if [[ "$dry_run" == "true" ]]; then
        echo "[janitor] dry-run candidate ${canonical_candidate} (${bytes} bytes)"
      else
        rm -rf -- "$candidate"
        reclaimed=$((reclaimed + bytes))
        echo "[janitor] removed ${canonical_candidate} (${bytes} bytes)"
      fi
    done < <(find "$workspace" -type d \
      \( -name node_modules -o -name .cache -o -name .parcel-cache -o -name .turbo \
         -o -name coverage -o -name target -o -name dist -o -name build \
         -o \( -name cache -a -path '*/.next/cache' \) \) -prune -print0)
  done
done

if [[ "$dry_run" == "true" ]]; then
  echo "[janitor] dry-run would reclaim ${would_reclaim} bytes"
  write_output total_bytes_reclaimed 0
else
  echo "[janitor] reclaimed ${reclaimed} bytes"
  write_output total_bytes_reclaimed "$reclaimed"
fi
