#!/usr/bin/env bats

setup() {
  SYNC_SCRIPT="$BATS_TEST_DIRNAME/../scripts/sync-publish-tree.sh"
  PRUNE_SCRIPT="$BATS_TEST_DIRNAME/../scripts/prune-webroot-generations.sh"
  mkdir -p "$BATS_TEST_TMPDIR/source/dist" \
    "$BATS_TEST_TMPDIR/source/nested/node_modules/pkg" \
    "$BATS_TEST_TMPDIR/source/.shared-workflows/scripts" \
    "$BATS_TEST_TMPDIR/source/.cache" \
    "$BATS_TEST_TMPDIR/source/.venv" \
    "$BATS_TEST_TMPDIR/source/.git"
  printf site > "$BATS_TEST_TMPDIR/source/index.php"
  printf bundle > "$BATS_TEST_TMPDIR/source/dist/app.js"
  printf dep > "$BATS_TEST_TMPDIR/source/nested/node_modules/pkg/index.js"
  printf helper > "$BATS_TEST_TMPDIR/source/.shared-workflows/scripts/helper.sh"
  printf cache > "$BATS_TEST_TMPDIR/source/.cache/value"
  printf venv > "$BATS_TEST_TMPDIR/source/.venv/value"
  printf ref > "$BATS_TEST_TMPDIR/source/.git/HEAD"
}

@test "publish sync excludes dependencies and caches but retains build output" {
  run bash "$SYNC_SCRIPT" "$BATS_TEST_TMPDIR/source" "$BATS_TEST_TMPDIR/dest"
  [ "$status" -eq 0 ] \
    && [ -f "$BATS_TEST_TMPDIR/dest/index.php" ] \
    && [ -f "$BATS_TEST_TMPDIR/dest/dist/app.js" ] \
    && [ ! -e "$BATS_TEST_TMPDIR/dest/nested/node_modules" ] \
    && [ ! -e "$BATS_TEST_TMPDIR/dest/.cache" ] \
    && [ ! -e "$BATS_TEST_TMPDIR/dest/.venv" ] \
    && [ ! -e "$BATS_TEST_TMPDIR/dest/.shared-workflows" ] \
    && [ ! -e "$BATS_TEST_TMPDIR/dest/.git" ]
}

@test "pruning retains two newest old generations and ignores live and broken" {
  parent="$BATS_TEST_TMPDIR/www"
  mkdir -p "$parent/site" "$parent/site.old.111" "$parent/site.old.222" \
    "$parent/site.old.333" "$parent/site.old.444" "$parent/site.broken.555"
  touch -t 202601010101 "$parent/site.old.111"
  touch -t 202602010101 "$parent/site.old.222"
  touch -t 202603010101 "$parent/site.old.333"
  touch -t 202604010101 "$parent/site.old.444"

  run env WEBROOT_PARENT="$parent" bash "$PRUNE_SCRIPT" site
  [ "$status" -eq 0 ] \
    && [ ! -e "$parent/site.old.111" ] \
    && [ ! -e "$parent/site.old.222" ] \
    && [ -d "$parent/site.old.333" ] \
    && [ -d "$parent/site.old.444" ] \
    && [ -d "$parent/site" ] \
    && [ -d "$parent/site.broken.555" ] \
    && [ ! -e "$parent/.site.prune.lock" ]

  run env WEBROOT_PARENT="$parent" bash "$PRUNE_SCRIPT" site
  [ "$status" -eq 0 ] && [ ! -e "$parent/.site.prune.lock" ]
}

@test "pruning rejects unsafe webroot names without deletion" {
  parent="$BATS_TEST_TMPDIR/www"
  mkdir -p "$parent/site.old.111"
  run env WEBROOT_PARENT="$parent" bash "$PRUNE_SCRIPT" '../site'
  [ "$status" -ne 0 ] && [ -d "$parent/site.old.111" ]
}

@test "pruning refuses symlink generations" {
  parent="$BATS_TEST_TMPDIR/www"
  mkdir -p "$parent/site" "$parent/site.old.111" "$parent/site.old.222" "$parent/outside"
  ln -s "$parent/outside" "$parent/site.old.000"
  run env WEBROOT_PARENT="$parent" bash "$PRUNE_SCRIPT" site
  [ "$status" -ne 0 ] \
    && [ -L "$parent/site.old.000" ] \
    && [ -d "$parent/outside" ]
}

@test "pruning refuses a concurrent lock holder" {
  parent="$BATS_TEST_TMPDIR/www"
  mkdir -p "$parent/site" "$parent/.site.prune.lock"
  run env WEBROOT_PARENT="$parent" bash "$PRUNE_SCRIPT" site
  [ "$status" -eq 3 ] && [ -d "$parent/site" ]
}

@test "workflow invokes disk check before optional build and prunes after health" {
  workflow="$BATS_TEST_DIRNAME/../.github/workflows/deploy-static-site.yml"
  disk_line="$(grep -n 'Check disk capacity before build' "$workflow" | cut -d: -f1)"
  build_line="$(grep -n 'Optional build step' "$workflow" | cut -d: -f1)"
  health_line="$(grep -n 'Health check with rollback' "$workflow" | cut -d: -f1)"
  prune_line="$(grep -n 'Prune old webroot generations' "$workflow" | cut -d: -f1)"
  [ -n "$disk_line" ] \
    && [ -n "$prune_line" ] \
    && [ "$disk_line" -lt "$build_line" ] \
    && [ "$prune_line" -gt "$health_line" ]
}

@test "janitor workflow restricts execution to the trusted private caller" {
  workflow="$BATS_TEST_DIRNAME/../.github/workflows/runner-workdir-janitor.yml"
  grep -qF "github.repository == 'Arcanada-one/datarim-club-site'" "$workflow"
}
