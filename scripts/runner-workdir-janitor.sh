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

worker_pids=()
if [[ -n "${RUNNER_WORKER_PIDS_OVERRIDE:-}" ]]; then
  if [[ "$RUNNER_WORKER_PIDS_OVERRIDE" != "none" ]]; then read -r -a worker_pids <<< "$RUNNER_WORKER_PIDS_OVERRIDE"; fi
elif command -v pgrep >/dev/null 2>&1; then
  while IFS= read -r pid; do [[ -n "$pid" ]] && worker_pids+=("$pid"); done < <(pgrep -x Runner.Worker || true)
elif [[ -d /proc ]]; then
  for comm in /proc/[0-9]*/comm; do
    [[ -r "$comm" ]] || continue
    if [[ "$(<"$comm")" == "Runner.Worker" ]]; then
      pid="${comm#/proc/}"
      worker_pids+=("${pid%/comm}")
    fi
  done
else
  echo "[janitor] cannot verify Runner.Worker state; refusing cleanup" >&2
  exit 3
fi

self_worker_pid="${SELF_RUNNER_WORKER_PID_OVERRIDE:-}"
if [[ -z "$self_worker_pid" && ${#worker_pids[@]} -gt 0 ]]; then
  ancestor="$PPID"
  while [[ "$ancestor" =~ ^[0-9]+$ ]] && (( ancestor > 1 )); do
    comm="$(ps -o comm= -p "$ancestor" 2>/dev/null | awk '{print $1}')"
    if [[ "${comm##*/}" == "Runner.Worker" ]]; then self_worker_pid="$ancestor"; break; fi
    ancestor="$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d ' ')"
  done
fi

other_worker=false
for pid in ${worker_pids[@]+"${worker_pids[@]}"}; do
  if [[ -z "$self_worker_pid" || "$pid" != "$self_worker_pid" ]]; then other_worker=true; break; fi
done
if [[ "$other_worker" == "true" ]]; then
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
canonical_roots=()
for root in "${roots[@]}"; do
  if [[ "$root" != /* ]]; then
    echo "[janitor] runner root must be absolute: $root" >&2
    exit 2
  fi
  if [[ ! -d "$root" || -L "$root" || ! -d "$root/_work" || -L "$root/_work" ]]; then
    echo "[janitor] invalid runner root: $root" >&2
    exit 2
  fi
  canonical_roots+=("$(cd "$root" && pwd -P)")
done

for canonical_root in "${canonical_roots[@]}"; do
  for workspace in "$canonical_root"/_work/*/*; do
    [[ -d "$workspace" && ! -L "$workspace" ]] || continue
    repo_name="$(basename "$(dirname "$workspace")")"
    checkout_name="$(basename "$workspace")"
    [[ "$repo_name" == "$checkout_name" && "$repo_name" != _* ]] || continue
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
