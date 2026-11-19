#!/usr/bin/env bash
# Assert that pnpm_config_store_dir isolates the content-addressable store path.
# Uses a pinned pnpm version via corepack; never reads a moving git ref. Exits 0
# only when:
#   1) unset env resolves under the process HOME (shared-user risk surface)
#   2) pnpm_config_store_dir is honored (pnpm 11+)
#   3) npm_config_store_dir alone is NOT sufficient for pnpm 11 (regression lock)
#   4) two distinct store roots produce two distinct store paths
set -euo pipefail

PNPM_VERSION="${PNPM_VERSION:-11.20.0}"
WORK="${ASSERT_WORKDIR:-}"
cleanup=0
if [[ -z "$WORK" ]]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/pnpm-store-assert.XXXXXX")"
  cleanup=1
fi
if [[ "$cleanup" -eq 1 ]]; then
  trap 'rm -rf "$WORK"' EXIT
fi

home_a="${WORK}/home-a"
home_b="${WORK}/home-b"
store_a="${WORK}/runner-a/_work/_pnpm-store"
store_b="${WORK}/runner-b/_work/_pnpm-store"
mkdir -p "$home_a" "$home_b" "$store_a" "$store_b"

store_path() {
  # corepack pnpm@VER without --activate (host-boundary safe).
  env "$@" corepack pnpm@"$PNPM_VERSION" store path
}

default_a="$(store_path HOME="$home_a")"
default_b="$(store_path HOME="$home_b")"
case "$default_a" in
  "$home_a"/*) ;;
  *)
    echo "expected default store under HOME=$home_a, got: $default_a" >&2
    exit 1
    ;;
esac
case "$default_b" in
  "$home_b"/*) ;;
  *)
    echo "expected default store under HOME=$home_b, got: $default_b" >&2
    exit 1
    ;;
esac
if [[ "$default_a" == "$default_b" ]]; then
  echo "two different HOMEs must not share one default store path" >&2
  exit 1
fi

# Same HOME, different pnpm_config_store_dir → isolated paths (the fleet case).
shared_home="${WORK}/home-shared"
mkdir -p "$shared_home"
isolated_a="$(
  store_path HOME="$shared_home" pnpm_config_store_dir="$store_a"
)"
isolated_b="$(
  store_path HOME="$shared_home" pnpm_config_store_dir="$store_b"
)"
case "$isolated_a" in
  "$store_a"/*|"$store_a") ;;
  *)
    echo "pnpm_config_store_dir not honored for A: $isolated_a" >&2
    exit 1
    ;;
esac
case "$isolated_b" in
  "$store_b"/*|"$store_b") ;;
  *)
    echo "pnpm_config_store_dir not honored for B: $isolated_b" >&2
    exit 1
    ;;
esac
if [[ "$isolated_a" == "$isolated_b" ]]; then
  echo "isolated store paths must differ: $isolated_a" >&2
  exit 1
fi

# npm_config_store_dir must not be treated as sufficient for pnpm 11.
npm_ignored="$(
  env -u pnpm_config_store_dir HOME="$shared_home" \
    npm_config_store_dir="$store_a" \
    corepack pnpm@"$PNPM_VERSION" store path
)"
case "$npm_ignored" in
  "$store_a"/*|"$store_a")
    echo "npm_config_store_dir unexpectedly moved the store: $npm_ignored" >&2
    exit 1
    ;;
esac
case "$npm_ignored" in
  "$shared_home"/*) ;;
  *)
    echo "expected npm_config_store_dir to leave the default HOME store, got: $npm_ignored" >&2
    exit 1
    ;;
esac

printf 'assert-pnpm-store-isolation: ok pnpm=%s default_a=%s isolated_a=%s isolated_b=%s\n' \
  "$PNPM_VERSION" "$default_a" "$isolated_a" "$isolated_b"
