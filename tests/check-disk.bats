#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-disk.sh"
  OUTPUT_FILE="$BATS_TEST_TMPDIR/github-output"
}

@test "passes below warning threshold and exports usage" {
  run env DISK_USAGE_OVERRIDE=79 GITHUB_OUTPUT="$OUTPUT_FILE" bash "$SCRIPT" /tmp
  [ "$status" -eq 0 ] \
    && [[ "$output" != *"::warning::"* ]] \
    && grep -qx 'disk_usage_percent=79' "$OUTPUT_FILE"
}

@test "warns at warning threshold" {
  run env DISK_USAGE_OVERRIDE=80 GITHUB_OUTPUT="$OUTPUT_FILE" bash "$SCRIPT" /tmp
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"::warning::Preflight disk usage 80% >= 80%"* ]]
}

@test "fails at failure threshold" {
  run env DISK_USAGE_OVERRIDE=90 GITHUB_OUTPUT="$OUTPUT_FILE" bash "$SCRIPT" /tmp
  [ "$status" -eq 1 ] \
    && [[ "$output" == *"::error::Preflight disk usage 90% >= 90%"* ]]
}

@test "rejects invalid threshold ordering" {
  run env DISK_USAGE_OVERRIDE=50 WARN_THRESHOLD=90 FAIL_THRESHOLD=80 bash "$SCRIPT" /tmp
  [ "$status" -eq 2 ] \
    && [[ "$output" == *"warning threshold must be lower"* ]]
}

@test "measurement failure degrades with warning" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/df"
  chmod +x "$BATS_TEST_TMPDIR/bin/df"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" GITHUB_OUTPUT="$OUTPUT_FILE" bash "$SCRIPT" /tmp
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"::warning::Unable to measure disk usage"* ]]
}
