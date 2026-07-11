#!/usr/bin/env bash
set -euo pipefail

warn_threshold="${WARN_THRESHOLD:-80}"
fail_threshold="${FAIL_THRESHOLD:-90}"
target_path="${1:-${GITHUB_WORKSPACE:-$PWD}}"

if ! [[ "$warn_threshold" =~ ^[0-9]+$ && "$fail_threshold" =~ ^[0-9]+$ ]]; then
  echo "::error::Disk thresholds must be integers" >&2
  exit 2
fi
if (( warn_threshold >= fail_threshold || fail_threshold > 100 )); then
  echo "::error::Disk warning threshold must be lower than failure threshold (max 100)" >&2
  exit 2
fi

usage="${DISK_USAGE_OVERRIDE:-}"
if [[ -z "$usage" ]]; then
  usage="$(df -P "$target_path" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')" || true
fi

if ! [[ "$usage" =~ ^[0-9]+$ ]] || (( usage > 100 )); then
  echo "::warning::Unable to measure disk usage for ${target_path}; preflight is degraded" >&2
  exit 0
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'disk_usage_percent=%s\n' "$usage" >> "$GITHUB_OUTPUT"
fi

echo "Disk preflight: usage=${usage}% warn=${warn_threshold}% fail=${fail_threshold}% path=${target_path}"
if (( usage >= fail_threshold )); then
  echo "::error::Preflight disk usage ${usage}% >= ${fail_threshold}%" >&2
  exit 1
fi
if (( usage >= warn_threshold )); then
  echo "::warning::Preflight disk usage ${usage}% >= ${warn_threshold}%" >&2
fi
