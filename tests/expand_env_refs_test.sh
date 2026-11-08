#!/usr/bin/env bash
# Exercises scripts/expand_env_refs.sh: env-var references in action inputs are
# expanded, everything else (command substitution included) stays literal text.
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=../scripts/expand_env_refs.sh

export GITHUB_SHA=abc123 GITHUB_REPOSITORY=owner/repo IMAGE_TAG=v1
export INPUT_UPWIND_CLIENT_SECRET=topsecret
unset UNSET_VAR

fail=0
check() {
  local name="$1" in="$2" want="$3" got
  got="$(bash "$SCRIPT" "$in")"
  if [ "$got" != "$want" ]; then
    echo "FAIL: $name: got '$got' want '$want'"; fail=1; return
  fi
  echo "ok: $name"
}

check "plain value"          'ubuntu:22.04'                   'ubuntu:22.04'
check "empty"                ''                               ''
check "braced ref"           'app:${GITHUB_SHA}'              'app:abc123'
check "bare ref"             'app:$GITHUB_SHA'                'app:abc123'
check "several refs"         '${GITHUB_REPOSITORY}:${GITHUB_SHA}' 'owner/repo:abc123'
check "custom job env"       'repo/app:${IMAGE_TAG}'          'repo/app:v1'
check "unset ref is empty"   'app:${UNSET_VAR}'               'app:'
check "trims whitespace"     $'  app:1 \n'                    'app:1'
check "lone dollar"          'a$'                             'a$'
check "dollar digit"         'a$1b'                           'a$1b'
check "command substitution" 'x$(touch /tmp/pwned)'           'x$(touch /tmp/pwned)'
check "backticks"            'x`touch /tmp/pwned`'            'x`touch /tmp/pwned`'
check "default syntax"       '${GITHUB_SHA:-x}'               '${GITHUB_SHA:-x}'
check "input ref kept"       'x${INPUT_UPWIND_CLIENT_SECRET}' 'x${INPUT_UPWIND_CLIENT_SECRET}'
check "bare input ref kept"  'x$INPUT_UPWIND_CLIENT_SECRET'   'x$INPUT_UPWIND_CLIENT_SECRET'

DOLLAR_VALUE='$GITHUB_SHA' bash "$SCRIPT" 'a${DOLLAR_VALUE}' | grep -qx 'a\$GITHUB_SHA' \
  && echo "ok: expanded value is not re-expanded" \
  || { echo "FAIL: expanded value was re-expanded"; fail=1; }

exit "$fail"
