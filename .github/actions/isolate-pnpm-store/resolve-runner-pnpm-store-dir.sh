#!/usr/bin/env bash
# Resolve the canonical per-runner pnpm store directory from a GitHub Actions
# RUNNER_TEMP (or any path under <runner>/_work/...). Walks up to the nearest
# path component named `_work` and returns `<that>/_pnpm-store`, matching
# scripts/render-runner-pnpm-store-dropin.sh.
#
# Usage:
#   resolve-runner-pnpm-store-dir.sh <absolute-temp-or-work-path>
#   RUNNER_TEMP=<path> resolve-runner-pnpm-store-dir.sh
#
# Prints the store directory on stdout. Exit 2 on invalid input.
# Keep byte-identical with
# .github/actions/isolate-pnpm-store/resolve-runner-pnpm-store-dir.sh
# (composite actions only ship their own directory).
set -euo pipefail

candidate="${1:-${RUNNER_TEMP:-}}"
if [[ -z "$candidate" ]]; then
  echo "usage: $0 <absolute-temp-or-work-path>" >&2
  exit 2
fi
if [[ "$candidate" != /* ]]; then
  echo "path must be absolute: $candidate" >&2
  exit 2
fi
# Charset allowlist: reject newline/control/space/= before any path walk
# (same policy as the drop-in renderer).
if [[ "$candidate" == *$'\n'* ]] || [[ "$candidate" == *$'\r'* ]] \
  || [[ "$candidate" == *$'\t'* ]] || [[ "$candidate" == *' '* ]] \
  || [[ "$candidate" == *'='* ]] || [[ "$candidate" == *'"'* ]] \
  || [[ "$candidate" == *"'"* ]] || [[ "$candidate" == *'\\'* ]]; then
  echo "path contains disallowed characters: refuse" >&2
  exit 2
fi
case "$candidate" in
  *..*)
    echo "path must not contain '..' segments: $candidate" >&2
    exit 2
    ;;
esac
if [[ ! "$candidate" =~ ^[A-Za-z0-9/._-]+$ ]]; then
  echo "path charset must be [A-Za-z0-9/._-]: refuse" >&2
  exit 2
fi

# Require an ancestor path component named `_work` (refuse /tmp/... stores).
case "$candidate" in
  */_work|*/_work/*)
    ;;
  *)
    echo "path must lie under a runner */_work/ tree: $candidate" >&2
    exit 2
    ;;
esac

d="$candidate"
while [[ "$(basename -- "$d")" != "_work" ]]; do
  parent="$(dirname -- "$d")"
  if [[ "$parent" == "$d" ]]; then
    echo "could not find _work ancestor for: $candidate" >&2
    exit 2
  fi
  d="$parent"
done

printf '%s\n' "${d}/_pnpm-store"
