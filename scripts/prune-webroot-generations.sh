#!/usr/bin/env bash
set -euo pipefail

webroot="${1:-}"
parent="${WEBROOT_PARENT:-/var/www}"
retain="${RETAIN_GENERATIONS:-2}"

if [[ -z "$webroot" || "$webroot" == */* || "$webroot" == "." || "$webroot" == ".." ]]; then
  echo "[prune-webroot] unsafe webroot basename: ${webroot:-<empty>}" >&2
  exit 2
fi
if ! [[ "$retain" =~ ^[0-9]+$ ]] || (( retain < 1 )); then
  echo "[prune-webroot] RETAIN_GENERATIONS must be a positive integer" >&2
  exit 2
fi
[[ -d "$parent" && ! -L "$parent" ]] || { echo "[prune-webroot] unsafe parent: $parent" >&2; exit 2; }

records=()
for candidate in "$parent/$webroot.old."*; do
  [[ -e "$candidate" || -L "$candidate" ]] || continue
  if [[ -L "$candidate" || ! -d "$candidate" ]]; then
    echo "[prune-webroot] refusing non-directory or symlink candidate: $candidate" >&2
    exit 2
  fi
  case "$candidate" in
    "$parent/$webroot.old."*) ;;
    *) echo "[prune-webroot] candidate escaped controlled prefix: $candidate" >&2; exit 2 ;;
  esac
  if mtime="$(stat -c %Y "$candidate" 2>/dev/null)"; then :; else mtime="$(stat -f %m "$candidate")"; fi
  records+=("$mtime"$'\t'"$candidate")
done

if (( ${#records[@]} <= retain )); then
  echo "[prune-webroot] retained ${#records[@]} generation(s); nothing to remove"
  exit 0
fi

mapfile_cmd="mapfile"
if ! command -v "$mapfile_cmd" >/dev/null 2>&1; then
  sorted_tmp="$(mktemp)"
  trap 'rm -f "$sorted_tmp"' EXIT
  printf '%s\n' "${records[@]}" | sort -rn > "$sorted_tmp"
  sorted=()
  while IFS= read -r line; do sorted+=("$line"); done < "$sorted_tmp"
else
  mapfile -t sorted < <(printf '%s\n' "${records[@]}" | sort -rn)
fi

for (( index=retain; index<${#sorted[@]}; index++ )); do
  candidate="${sorted[$index]#*$'\t'}"
  rm -rf -- "$candidate"
  echo "[prune-webroot] removed $candidate"
done
echo "[prune-webroot] retained $retain newest generation(s)"
