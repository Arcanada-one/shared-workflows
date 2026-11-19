#!/usr/bin/env bats

setup() {
  RENDER="$BATS_TEST_DIRNAME/../scripts/render-runner-pnpm-store-dropin.sh"
  RESOLVE="$BATS_TEST_DIRNAME/../scripts/resolve-runner-pnpm-store-dir.sh"
  ASSERT="$BATS_TEST_DIRNAME/../scripts/assert-pnpm-store-isolation.sh"
  ACTION="$BATS_TEST_DIRNAME/../.github/actions/isolate-pnpm-store/action.yml"
  FIXTURE_ROOT="$BATS_TEST_DIRNAME/fixtures/pnpm-store-isolation"
  for f in "$RENDER" "$RESOLVE" "$ASSERT"; do
    [[ -f "$f" ]] && chmod +x "$f"
  done
  RUNNER_ROOT="$BATS_TEST_TMPDIR/fake-runner"
  mkdir -p "$RUNNER_ROOT/_work"
}

@test "render drop-in pins pnpm_config_store_dir under the runner _work tree" {
  # stdout only — annotations go to stderr
  run bash -c '"$1" "$2" 2>/dev/null' _ "$RENDER" "$RUNNER_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Environment=pnpm_config_store_dir=${RUNNER_ROOT}/_work/_pnpm-store"* ]]
  [[ "$output" != *"Environment=npm_config_store_dir="* ]]
}

@test "render drop-in rejects a relative runner root" {
  run bash "$RENDER" relative/runner
  [ "$status" -eq 2 ]
  [[ "$output" == *"runner root must be absolute"* ]]
}

@test "render drop-in rejects a runner root whose _work directory is missing" {
  bare="$BATS_TEST_TMPDIR/no-work-runner"
  mkdir -p "$bare"
  run bash "$RENDER" "$bare"
  [ "$status" -eq 2 ]
  [[ "$output" == *"_work"* ]]
}

@test "render drop-in rejects path injection via newline in the runner root" {
  # shellcheck disable=SC2016
  evil=$'/opt/evil\nEnvironment=INJECTED=1'
  run bash "$RENDER" "$evil"
  [ "$status" -eq 2 ]
  [[ "$output" != *"INJECTED"* ]]
}

@test "render drop-in rejects spaces equals and parent segments in the runner root" {
  mkdir -p "$BATS_TEST_TMPDIR/bad space/_work"
  run bash "$RENDER" "$BATS_TEST_TMPDIR/bad space"
  [ "$status" -eq 2 ]

  mkdir -p "$BATS_TEST_TMPDIR/bad=eq/_work"
  run bash "$RENDER" "$BATS_TEST_TMPDIR/bad=eq"
  [ "$status" -eq 2 ]

  parent="$BATS_TEST_TMPDIR/parent"
  mkdir -p "$parent/child/_work" "$parent/_work"
  run bash "$RENDER" "$parent/child/.."
  [ "$status" -eq 2 ]
}

@test "render drop-in matches the committed fixture byte-for-byte on the body lines" {
  # Fixture documents the drop-in shape with an example absolute root; substitute
  # the live temp runner so the test never depends on a host path existing under /opt.
  run bash -c '"$1" "$2" 2>/dev/null' _ "$RENDER" "$RUNNER_ROOT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/rendered.conf"
  sed "s|/opt/arcanada-runners/arcana-prd-general-11|${RUNNER_ROOT}|g" \
    "$FIXTURE_ROOT/30-pnpm-store.conf" > "$BATS_TEST_TMPDIR/expected.conf"
  run diff -u "$BATS_TEST_TMPDIR/expected.conf" "$BATS_TEST_TMPDIR/rendered.conf"
  [ "$status" -eq 0 ]
}

@test "resolve-runner-pnpm-store-dir binds nested RUNNER_TEMP to _work/_pnpm-store" {
  temp="$RUNNER_ROOT/_work/_temp/job-uuid-abc"
  mkdir -p "$temp"
  run bash "$RESOLVE" "$temp"
  [ "$status" -eq 0 ]
  [ "$output" = "${RUNNER_ROOT}/_work/_pnpm-store" ]
}

@test "resolve-runner-pnpm-store-dir refuses temps outside a runner _work tree" {
  outside="$BATS_TEST_TMPDIR/not-a-runner/tmp/job"
  mkdir -p "$outside"
  run bash "$RESOLVE" "$outside"
  [ "$status" -eq 2 ]
  [[ "$output" == *"_work"* ]]
}

@test "isolate-pnpm-store action uses the resolve helper and pnpm_config_store_dir" {
  [[ -f "$ACTION" ]]
  action_resolve="$BATS_TEST_DIRNAME/../.github/actions/isolate-pnpm-store/resolve-runner-pnpm-store-dir.sh"
  [[ -f "$action_resolve" ]]
  run diff -u "$RESOLVE" "$action_resolve"
  [ "$status" -eq 0 ]
  grep -q 'pnpm_config_store_dir' "$ACTION"
  grep -q 'resolve-runner-pnpm-store-dir.sh' "$ACTION"
  grep -q 'GITHUB_ACTION_PATH' "$ACTION"
  grep -q '_pnpm-store' "$ACTION"
  if grep -q 'Environment=npm_config_store_dir' "$ACTION"; then
    echo "action must not set npm_config_store_dir as the isolation mechanism" >&2
    return 1
  fi
  if grep -q 'dirname "\$RUNNER_TEMP"' "$ACTION"; then
    echo "action must not derive the store from a single dirname of RUNNER_TEMP" >&2
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
