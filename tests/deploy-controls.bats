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

setup_cloudflare_fixture() {
  WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/deploy-static-site.yml"
  CF_SCRIPT="$BATS_TEST_TMPDIR/cloudflare-purge.sh"
  CF_BIN="$BATS_TEST_TMPDIR/bin"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  mkdir -p "$CF_BIN"

  awk '
    /^      - name: Cloudflare cache purge / { in_step = 1; next }
    in_step && /^        run: \|$/ { in_run = 1; next }
    in_run && /^      - name:/ { exit }
    in_run { sub(/^          /, ""); print }
  ' "$WORKFLOW" > "$CF_SCRIPT"

  cat > "$CF_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"/purge_cache"* ]]; then
  printf '%s\n' purge >> "$CURL_LOG"
  case "$CURL_SCENARIO" in
    purge-http-error)
      if [[ "$*" == *"-fsS"* ]]; then
        echo 'curl: (22) The requested URL returned error: 500' >&2
        exit 22
      fi
      printf '%s\n' '{"success":false,"errors":[{"message":"SENSITIVE_PURGE_HTTP_BODY"}]}'
      ;;
    purge-api-error)
      printf '%s\n' '{"success":false,"errors":[{"message":"SENSITIVE_PURGE_API_BODY"}]}'
      ;;
    noncompact-success)
      printf '%s\n' '{"success" : true}'
      ;;
    *)
      echo "unexpected purge scenario: $CURL_SCENARIO" >&2
      exit 64
      ;;
  esac
  exit 0
fi

printf '%s\n' lookup >> "$CURL_LOG"
case "$CURL_SCENARIO" in
  empty-zone)
    printf '%s\n' '{"success":true,"result":[]}'
    ;;
  auth-error)
    if [[ "$*" == *"-fsS"* ]]; then
      echo 'curl: (22) The requested URL returned error: 401' >&2
      exit 22
    fi
    printf '%s\n' '{"success":false,"errors":[{"message":"SENSITIVE_LOOKUP_HTTP_BODY"}]}'
    ;;
  api-error)
    printf '%s\n' '{"success":false,"errors":[{"code":10000,"message":"SENSITIVE_LOOKUP_API_BODY"}]}'
    ;;
  purge-http-error|purge-api-error)
    printf '%s\n' '{"success":true,"result":[{"id":"0123456789abcdef0123456789abcdef"}]}'
    ;;
  noncompact-success)
    printf '%s\n' '{
      "success" : true,
      "result" : [
        { "id" : "0123456789abcdef0123456789abcdef" }
      ]
    }'
    ;;
  *)
    echo "unexpected curl scenario: $CURL_SCENARIO" >&2
    exit 64
    ;;
esac
EOF
  chmod +x "$CF_BIN/curl"
}

run_cloudflare_step() {
  run env \
    DOMAIN=example.com \
    CF_API_TOKEN=synthetic-test-token \
    CURL_SCENARIO="$1" \
    CURL_LOG="$CURL_LOG" \
    PATH="$CF_BIN:$PATH" \
    bash "$CF_SCRIPT"
}

assert_cloudflare_outputs_redacted() {
  [[ "$output" != *"synthetic-test-token"* ]] \
    && ! grep -qF "synthetic-test-token" "$CURL_LOG"
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

@test "reusable workflows pin actions and bind control checkouts to their exact revision" {
  deploy="$BATS_TEST_DIRNAME/../.github/workflows/deploy-static-site.yml"
  janitor="$BATS_TEST_DIRNAME/../.github/workflows/runner-workdir-janitor.yml"

  for workflow in "$deploy" "$janitor"; do
    while IFS= read -r action; do
      [[ "$action" =~ ^[^@[:space:]]+@[0-9a-f]{40}$ ]] || return 1
    done < <(
      sed 's/[[:space:]]*#.*$//' "$workflow" |
        sed -n 's/^[[:space:]]*uses:[[:space:]]*//p'
    )

    mapfile -t refs < <(
      sed 's/[[:space:]]*#.*$//' "$workflow" |
        sed -n 's/^[[:space:]]*ref:[[:space:]]*//p'
    )
    [ "${#refs[@]}" -eq 1 ] \
      && [ "${refs[0]}" = '${{ job.workflow_sha }}' ] \
      && grep -qF 'repository: ${{ job.workflow_repository }}' "$workflow"
  done
}

@test "reusable workflows explicitly restrict their token to read-only contents" {
  deploy="$BATS_TEST_DIRNAME/../.github/workflows/deploy-static-site.yml"
  janitor="$BATS_TEST_DIRNAME/../.github/workflows/runner-workdir-janitor.yml"

  grep -A1 '^permissions:$' "$deploy" | grep -qF 'contents: read' \
    && grep -A1 '^permissions:$' "$janitor" | grep -qF 'contents: read'
}

@test "Cloudflare empty zone lookup skips purge successfully with an explicit note" {
  setup_cloudflare_fixture
  run_cloudflare_step empty-zone
  assert_cloudflare_outputs_redacted \
    && [ "$status" -eq 0 ] \
    && [[ "$output" == *"NOTE: example.com is not a Cloudflare zone — skipping purge."* ]] \
    && [ "$(wc -l < "$CURL_LOG")" -eq 1 ]
}

@test "Cloudflare authentication error remains a hard failure" {
  setup_cloudflare_fixture
  run_cloudflare_step auth-error
  assert_cloudflare_outputs_redacted \
    && [[ "$output" != *"SENSITIVE_LOOKUP_HTTP_BODY"* ]] \
    && [ "$status" -ne 0 ] \
    && [[ "$output" == *"requested URL returned error: 401"* ]]
}

@test "Cloudflare API error remains a hard failure" {
  setup_cloudflare_fixture
  run_cloudflare_step api-error
  assert_cloudflare_outputs_redacted \
    && [[ "$output" != *"SENSITIVE_LOOKUP_API_BODY"* ]] \
    && [ "$status" -ne 0 ] \
    && [[ "$output" == *"Cloudflare zone lookup did not report success"* ]]
}

@test "Cloudflare purge HTTP error remains a hard failure without response-body logging" {
  setup_cloudflare_fixture
  run_cloudflare_step purge-http-error
  assert_cloudflare_outputs_redacted \
    && [[ "$output" != *"SENSITIVE_PURGE_HTTP_BODY"* ]] \
    && [ "$status" -ne 0 ] \
    && [[ "$output" == *"requested URL returned error: 500"* ]] \
    && [ "$(wc -l < "$CURL_LOG")" -eq 2 ]
}

@test "Cloudflare purge API error remains a hard failure without response-body logging" {
  setup_cloudflare_fixture
  run_cloudflare_step purge-api-error
  assert_cloudflare_outputs_redacted \
    && [[ "$output" != *"SENSITIVE_PURGE_API_BODY"* ]] \
    && [ "$status" -ne 0 ] \
    && [[ "$output" == *"Cloudflare cache purge did not report success"* ]] \
    && [ "$(wc -l < "$CURL_LOG")" -eq 2 ]
}

@test "Cloudflare non-compact zone JSON resolves the zone and purges successfully" {
  setup_cloudflare_fixture
  run_cloudflare_step noncompact-success
  assert_cloudflare_outputs_redacted \
    && [ "$status" -eq 0 ] \
    && [[ "$output" == *"Cloudflare cache purged (purge_everything)."* ]] \
    && [ "$(wc -l < "$CURL_LOG")" -eq 2 ]
}
