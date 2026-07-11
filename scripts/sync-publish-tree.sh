#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: sync-publish-tree.sh SOURCE DESTINATION" >&2
  exit 2
fi

source_dir="$1"
destination="$2"
[[ -d "$source_dir" ]] || { echo "source directory not found: $source_dir" >&2; exit 2; }

rsync -a --delete \
  --exclude='node_modules/' \
  --exclude='.git/' \
  --exclude='.github/' \
  --exclude='.shared-workflows/' \
  --exclude='.cache/' \
  --exclude='.npm/' \
  --exclude='.pnpm-store/' \
  --exclude='__pycache__/' \
  --exclude='.pytest_cache/' \
  --exclude='.venv/' \
  "${source_dir%/}/" "${destination%/}/"
