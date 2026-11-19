#!/usr/bin/env bats

setup() {
  RENDER="$BATS_TEST_DIRNAME/../scripts/render-runner-pnpm-store-dropin.sh"
  ASSERT="$BATS_TEST_DIRNAME/../scripts/assert-pnpm-store-isolation.sh"
  ACTION="$BATS_TEST_DIRNAME/../.github/actions/isolate-pnpm-store/action.yml"
  FIXTURE_ROOT="$BATS_TEST_DIRNAME/fixtures/pnpm-store-isolation"
  chmod +x "$RENDER" "$ASSERT"
}

@test "render drop-in pins pnpm_config_store_dir under the runner _work tree" {
  # stdout only — annotations go to stderr
  run bash -c '"$1" /opt/arcanada-runners/arcana-prd-general-11 2>/dev/null' _ "$RENDER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Environment=pnpm_config_store_dir=/opt/arcanada-runners/arcana-prd-general-11/_work/_pnpm-store"* ]]
  [[ "$output" != *"Environment=npm_config_store_dir="* ]]
}

@test "render drop-in rejects a relative runner root" {
  run bash "$RENDER" relative/runner
  [ "$status" -eq 2 ]
  [[ "$output" == *"runner root must be absolute"* ]]
}

@test "render drop-in matches the committed fixture byte-for-byte on the body lines" {
  run bash -c '"$1" /opt/arcanada-runners/arcana-prd-general-11 2>/dev/null' _ "$RENDER"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/rendered.conf"
  run diff -u "$FIXTURE_ROOT/30-pnpm-store.conf" "$BATS_TEST_TMPDIR/rendered.conf"
  [ "$status" -eq 0 ]
}

@test "isolate-pnpm-store action exports pnpm_config_store_dir from RUNNER_TEMP" {
  [[ -f "$ACTION" ]]
  grep -q 'pnpm_config_store_dir' "$ACTION"
  grep -q '_pnpm-store' "$ACTION"
  if grep -q 'Environment=npm_config_store_dir' "$ACTION"; then
    echo "action must not set npm_config_store_dir as the isolation mechanism" >&2
    return 1
  fi
}

@test "assert script fails closed when corepack/pnpm is unavailable" {
  run env PATH="/usr/bin:/bin" ASSERT_WORKDIR="$BATS_TEST_TMPDIR/assert-work" \
    PNPM_VERSION=11.20.0 bash "$ASSERT"
  # On a host without corepack this exits non-zero; with corepack it passes.
  # Accept either measured outcome but never a silent skip.
  if command -v corepack >/dev/null 2>&1; then
    [ "$status" -eq 0 ]
    [[ "$output" == *"assert-pnpm-store-isolation: ok"* ]]
  else
    [ "$status" -ne 0 ]
  fi
}
