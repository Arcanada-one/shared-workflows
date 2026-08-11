#!/usr/bin/env bash
# governance-diff-guard — fail a change that touches a governance path unless it
# carries an explicit, substantive justification.
#
# Governance paths are the ones an autonomous agent must not be able to alter
# silently: CI workflow definitions, CODEOWNERS, branch-protection config, the
# governance witness key and its verifier, and the credential/execution boundary.
#
# Justification is a line in the PR body:
#   GOVERNANCE-CHANGE: <at least 20 characters saying why>
# An empty or token marker is rejected on purpose — the point is an auditable
# reason, not a rubber stamp.
#
# Usage:
#   governance-diff-guard.sh --files <file-with-changed-paths> --body <file-with-pr-body>
#                            [--patterns <file-with-extra-globs>]
# Exit: 0 clean or justified; 1 unjustified governance change; 2 usage error.

set -euo pipefail

FILES=""; BODY=""; EXTRA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --files)    FILES="${2:-}"; shift 2 ;;
    --body)     BODY="${2:-}"; shift 2 ;;
    --patterns) EXTRA="${2:-}"; shift 2 ;;
    *) echo "usage: $0 --files <f> --body <f> [--patterns <f>]" >&2; exit 2 ;;
  esac
done
[ -n "$FILES" ] && [ -r "$FILES" ] || { echo "governance-diff-guard: --files is required and must be readable" >&2; exit 2; }
[ -n "$BODY" ]  && [ -r "$BODY" ]  || { echo "governance-diff-guard: --body is required and must be readable" >&2; exit 2; }

# Default governance path globs. Kept as bash extglob-free patterns matched with
# `case`, so this runs on a bare POSIX-ish shell without shopt gymnastics.
DEFAULT_PATTERNS='
.github/workflows/*
.github/CODEOWNERS
.github/settings.yml
.github/branch-protection*
.github/*governance*
.github/*.pub
dev-tools/*governance*
dev-tools/*ssh-sign*
*/credential-broker/*
*/execution-boundary/*
*/supervisor/src/spawn.rs
*/tools/src/bash.rs
'

patterns=$(printf '%s\n' "$DEFAULT_PATTERNS" | sed '/^[[:space:]]*$/d')
if [ -n "$EXTRA" ] && [ -r "$EXTRA" ]; then
  patterns=$(printf '%s\n%s\n' "$patterns" "$(sed '/^[[:space:]]*$/d;/^#/d' "$EXTRA")")
fi

hits=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2254
    case "$f" in
      $p) hits="${hits}${f}"$'\n'; break ;;
    esac
  done <<EOF
$patterns
EOF
done < "$FILES"

hits=$(printf '%s' "$hits" | sed '/^[[:space:]]*$/d' || true)

if [ -z "$hits" ]; then
  echo "governance-diff-guard: no governance paths touched."
  exit 0
fi

echo "governance-diff-guard: governance paths touched by this change:"
printf '%s\n' "$hits" | sed 's/^/  - /'

# Require a substantive justification line. \S{20,} keeps out "GOVERNANCE-CHANGE: ok".
if grep -qE '^[[:space:]]*GOVERNANCE-CHANGE:[[:space:]]*[^[:space:]].{19,}' "$BODY"; then
  echo
  echo "governance-diff-guard: justification present:"
  grep -E '^[[:space:]]*GOVERNANCE-CHANGE:' "$BODY" | sed 's/^/  /'
  exit 0
fi

cat >&2 <<'MSG'

governance-diff-guard: FAILED — this change touches a governance path but carries
no justification.

These paths gate who and what may change CI, code ownership, branch protection,
and the credential/execution boundary. A change here must state why, in the PR
body, on its own line:

  GOVERNANCE-CHANGE: <at least 20 characters explaining why this is necessary>

If a dependency bot opened this PR, that is exactly the case this guard exists
for: routine dependency automation must not silently rewrite CI or ownership.
MSG
exit 1
