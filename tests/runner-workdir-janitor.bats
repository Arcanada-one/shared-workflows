#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/runner-workdir-janitor.sh"
  ROOT="$BATS_TEST_TMPDIR/runner"
  WORKSPACE="$ROOT/_work/project/project"
  REPORT="$BATS_TEST_TMPDIR/report.txt"
  OUTPUT_FILE="$BATS_TEST_TMPDIR/github-output"
  mkdir -p "$WORKSPACE/node_modules/pkg" "$WORKSPACE/.cache" \
    "$WORKSPACE/.parcel-cache" "$WORKSPACE/dist" "$WORKSPACE/src" \
    "$WORKSPACE/.git" "$ROOT/_tool/node" "$ROOT/_actions/action"
  printf dep > "$WORKSPACE/node_modules/pkg/index.js"
  printf cache > "$WORKSPACE/.cache/value"
  printf parcel > "$WORKSPACE/.parcel-cache/value"
  printf bundle > "$WORKSPACE/dist/app.js"
  printf source > "$WORKSPACE/src/main.js"
  printf ref > "$WORKSPACE/.git/HEAD"
  printf tool > "$ROOT/_tool/node/version"
}

run_janitor() {
  run env HOME="$BATS_TEST_TMPDIR/home" RUNNER_ROOTS="$ROOT" \
    JANITOR_REPORT="$REPORT" GITHUB_OUTPUT="$OUTPUT_FILE" \
    RUNNER_WORKER_PIDS_OVERRIDE="${RUNNER_WORKER_PIDS_OVERRIDE:-}" \
    SELF_RUNNER_WORKER_PID_OVERRIDE="${SELF_RUNNER_WORKER_PID_OVERRIDE:-}" \
    DRY_RUN="${DRY_RUN:-true}" bash "$SCRIPT"
}

@test "dry-run is default and reports candidates without deleting" {
  run_janitor
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"dry-run would reclaim"* ]] \
    && [ -d "$WORKSPACE/node_modules" ] \
    && grep -qF "$WORKSPACE/node_modules" "$REPORT" \
    && grep -qx 'total_bytes_reclaimed=0' "$OUTPUT_FILE"
}

@test "real run deletes only reproducible workspace artifacts" {
  DRY_RUN=false run_janitor
  [ "$status" -eq 0 ] \
    && [ ! -e "$WORKSPACE/node_modules" ] \
    && [ ! -e "$WORKSPACE/.cache" ] \
    && [ ! -e "$WORKSPACE/.parcel-cache" ] \
    && [ ! -e "$WORKSPACE/dist" ] \
    && [ -f "$WORKSPACE/src/main.js" ] \
    && [ -f "$WORKSPACE/.git/HEAD" ] \
    && [ -f "$ROOT/_tool/node/version" ] \
    && grep -Eq '^total_bytes_reclaimed=[1-9][0-9]*$' "$OUTPUT_FILE"
}

@test "active Runner.Worker blocks all deletion" {
  RUNNER_WORKER_PIDS_OVERRIDE=123 DRY_RUN=false run_janitor
  [ "$status" -eq 3 ] \
    && [[ "$output" == *"Runner.Worker is active"* ]] \
    && [ -d "$WORKSPACE/node_modules" ] \
    && grep -qx 'runner_busy=true' "$OUTPUT_FILE"
}

@test "Runner.Listener alone does not block cleanup" {
  RUNNER_WORKER_PIDS_OVERRIDE=none DRY_RUN=false run_janitor
  [ "$status" -eq 0 ] && [ ! -e "$WORKSPACE/node_modules" ]
}

@test "janitor allows only its own Runner.Worker ancestor" {
  RUNNER_WORKER_PIDS_OVERRIDE=123 SELF_RUNNER_WORKER_PID_OVERRIDE=123 DRY_RUN=false run_janitor
  [ "$status" -eq 0 ] && [ ! -e "$WORKSPACE/node_modules" ]
}

@test "janitor blocks when another worker exists beside its own" {
  RUNNER_WORKER_PIDS_OVERRIDE='123 456' SELF_RUNNER_WORKER_PID_OVERRIDE=123 DRY_RUN=false run_janitor
  [ "$status" -eq 3 ] && [ -d "$WORKSPACE/node_modules" ]
}

@test "relative runner root is rejected" {
  run env HOME="$BATS_TEST_TMPDIR/home" RUNNER_ROOTS='./runner' \
    RUNNER_WORKER_PIDS_OVERRIDE=none bash "$SCRIPT"
  [ "$status" -eq 2 ] \
    && [[ "$output" == *"runner root must be absolute"* ]] \
    && [ -d "$WORKSPACE/node_modules" ]
}

@test "all runner roots validate before any deletion" {
  DRY_RUN=false
  run env HOME="$BATS_TEST_TMPDIR/home" RUNNER_ROOTS="$ROOT,./invalid" \
    RUNNER_WORKER_PIDS_OVERRIDE=none DRY_RUN=false bash "$SCRIPT"
  [ "$status" -eq 2 ] && [ -d "$WORKSPACE/node_modules" ]
}

@test "mismatched workspace pair and reserved workdirs are untouched" {
  mkdir -p "$ROOT/_work/one/two/node_modules" "$ROOT/_work/_temp/job/node_modules"
  RUNNER_WORKER_PIDS_OVERRIDE=none DRY_RUN=false run_janitor
  [ "$status" -eq 0 ] \
    && [ -d "$ROOT/_work/one/two/node_modules" ] \
    && [ -d "$ROOT/_work/_temp/job/node_modules" ]
}

@test "symlink candidate is refused and external target is untouched" {
  rm -rf "$WORKSPACE/node_modules"
  mkdir -p "$BATS_TEST_TMPDIR/external"
  printf external > "$BATS_TEST_TMPDIR/external/value"
  ln -s "$BATS_TEST_TMPDIR/external" "$WORKSPACE/node_modules"
  DRY_RUN=false run_janitor
  [ "$status" -eq 0 ] \
    && [ -L "$WORKSPACE/node_modules" ] \
    && [ -f "$BATS_TEST_TMPDIR/external/value" ]
}
