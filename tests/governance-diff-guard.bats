#!/usr/bin/env bats
#
# The negative controls are the point of this suite. A guard that only ever
# passes is worthless, so every protected path class has a test asserting the
# guard FAILS when the justification is missing.

setup() {
  GUARD="${BATS_TEST_DIRNAME}/../.github/actions/governance-diff-guard/governance-diff-guard.sh"
  TMP="$(mktemp -d)"
  BODY_PLAIN="${TMP}/body-plain"
  BODY_OK="${TMP}/body-ok"
  BODY_TOKEN="${TMP}/body-token"
  printf '%s\n' 'chore(deps): bump actions/checkout from 4 to 7' > "$BODY_PLAIN"
  printf '%s\n' 'GOVERNANCE-CHANGE: pinning the release action to a verified SHA after an upstream tag move' > "$BODY_OK"
  printf '%s\n' 'GOVERNANCE-CHANGE: ok' > "$BODY_TOKEN"
}

teardown() { rm -rf "$TMP"; }

files() { printf '%s\n' "$@" > "${TMP}/files"; echo "${TMP}/files"; }

@test "passes when no governance path is touched" {
  run "$GUARD" --files "$(files package.json pnpm-lock.yaml)" --body "$BODY_PLAIN"
  [ "$status" -eq 0 ]
}

@test "passes an ordinary source change" {
  run "$GUARD" --files "$(files src/index.ts README.md)" --body "$BODY_PLAIN"
  [ "$status" -eq 0 ]
}

@test "FAILS on a workflow change with no justification" {
  run "$GUARD" --files "$(files .github/workflows/ci.yml)" --body "$BODY_PLAIN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no justification"* ]]
}

@test "FAILS on CODEOWNERS with no justification" {
  run "$GUARD" --files "$(files .github/CODEOWNERS)" --body "$BODY_PLAIN"
  [ "$status" -eq 1 ]
}

@test "FAILS on the credential boundary with no justification" {
  run "$GUARD" --files "$(files crates/credential-broker/src/lib.rs)" --body "$BODY_PLAIN"
  [ "$status" -eq 1 ]
}

@test "FAILS on the execution boundary with no justification" {
  run "$GUARD" --files "$(files crates/execution-boundary/src/lib.rs)" --body "$BODY_PLAIN"
  [ "$status" -eq 1 ]
}

@test "FAILS on process spawn with no justification" {
  run "$GUARD" --files "$(files crates/supervisor/src/spawn.rs)" --body "$BODY_PLAIN"
  [ "$status" -eq 1 ]
}

@test "FAILS on the governance witness key with no justification" {
  run "$GUARD" --files "$(files .github/sec0030-governance-witness.pub)" --body "$BODY_PLAIN"
  [ "$status" -eq 1 ]
}

@test "FAILS on the witness verifier script with no justification" {
  run "$GUARD" --files "$(files dev-tools/sec0030-governance-witness-verify.sh)" --body "$BODY_PLAIN"
  [ "$status" -eq 1 ]
}

@test "passes a workflow change carrying a substantive justification" {
  run "$GUARD" --files "$(files .github/workflows/ci.yml)" --body "$BODY_OK"
  [ "$status" -eq 0 ]
}

@test "REJECTS a token justification" {
  run "$GUARD" --files "$(files .github/workflows/ci.yml)" --body "$BODY_TOKEN"
  [ "$status" -eq 1 ]
}

@test "extra patterns from a repo-supplied file are honoured" {
  printf '%s\n' 'infra/terraform/*' > "${TMP}/extra"
  run "$GUARD" --files "$(files infra/terraform/main.tf)" --body "$BODY_PLAIN" --patterns "${TMP}/extra"
  [ "$status" -eq 1 ]
}

@test "usage error when required arguments are missing" {
  run "$GUARD" --files "$(files package.json)"
  [ "$status" -eq 2 ]
}
