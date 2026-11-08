#!/usr/bin/env bash
# Runs the run: steps of action.yml with shell-injection payloads in every input
# and fails if any payload executes. Inputs must reach the scripts through env:,
# because GitHub pastes ${{ inputs.* }} into the script as text before bash
# parses it. curl and the shiftleft binary are stubbed; nothing leaves the host.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STEPS="$WORK/steps" BIN="$WORK/bin" RUN="$WORK/run"
mkdir -p "$STEPS" "$BIN" "$RUN"
MARK="$WORK/pwned"

fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

python3 "$ROOT/tests/extract_run_steps.py" "$ROOT/action.yml" "$STEPS" > "$WORK/index" || exit 1

while IFS=$'\t' read -r n name; do
  if grep -q '\${{ *inputs\.' "$STEPS/$n.sh"; then
    bad "step '$name' inlines \${{ inputs.* }}"
  else
    ok "step '$name' has no inline inputs"
  fi
  script="$(cat "$STEPS/$n.sh")"
  printf '%s\n' "${script//'${{ github.action_path }}'/$ROOT}" > "$STEPS/$n.sh"
done < "$WORK/index"

step_file() {
  local n
  n="$(while IFS=$'\t' read -r i name; do [ "$name" = "$1" ] && echo "$i"; done < "$WORK/index")"
  [ -n "$n" ] || { echo "no step named '$1'" >&2; exit 1; }
  echo "$STEPS/$n.sh"
}

# curl stub: answers the token request, and "downloads" the shiftleft stub.
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/curl_args"
out=""
while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
if [ -n "\$out" ]; then cp "$BIN/shiftleft_stub" "\$out"; else echo '{"access_token":"t"}'; fi
EOF
cat > "$BIN/shiftleft_stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/shiftleft_args"
for a in "\$@"; do case "\$a" in --output-json=*) cp "$ROOT/tests/fixtures/valid.json" "\${a#--output-json=}" ;; esac; done
EOF
chmod +x "$BIN/curl" "$BIN/shiftleft_stub"

run_step() {
  local label="$1" file="$2"; shift 2
  rm -f "$MARK"
  (cd "$RUN" && env "$@" PATH="$BIN:$PATH" GITHUB_ENV="$WORK/github_env" \
    GITHUB_ACTION_PATH="$ROOT" GITHUB_SHA=abc123 GITHUB_REF=refs/heads/main \
    GITHUB_REPOSITORY=owner/repo GITHUB_SERVER_URL=https://github.com \
    bash --noprofile --norc -eo pipefail "$file") > "$WORK/out" 2>&1
  local code=$?
  if [ -e "$MARK" ]; then bad "$label: payload executed"; else ok "$label: payload inert"; fi
  return "$code"
}

for payload in "x\$(touch $MARK)" "x\`touch $MARK\`" "x\"; touch $MARK; echo \"" "x'; touch $MARK; echo '"; do
  P=(
    INPUT_UPWIND_URI="$payload" INPUT_UPWIND_CLIENT_ID="$payload" INPUT_UPWIND_CLIENT_SECRET="$payload"
    INPUT_DOCKER_IMAGE="$payload" INPUT_DOCKER_USER="$payload" INPUT_DOCKER_PASSWORD="$payload"
    INPUT_PULL_IMAGE="$payload" INPUT_OCI_CLIENT="$payload" INPUT_ADDITIONAL_REGISTRIES="$payload"
    INPUT_COMMIT_SHA="$payload" INPUT_REPOSITORY="$payload" INPUT_BRANCH="$payload"
    INPUT_USE_SUDO="$payload" INPUT_PERFORM_MULTIARCH_SCAN="$payload" INPUT_DEBUG="$payload"
    INPUT_BLOCK_ON="$payload" INPUT_GITHUB_TOKEN="$payload" INPUT_PR_NUMBER="$payload"
    INPUT_REPO_NAME="$payload" MAIN_BRANCH="$payload" PR_ID="$payload" PR_LINK="$payload"
    GH_TOKEN="$payload" REPO="$payload" PR_NUMBER="$payload" UPWIND_URI="$payload"
  )

  run_step "validate [$payload]" "$(step_file 'Validate required inputs')" "${P[@]}" INPUT_ADD_COMMENT=true
  run_step "download [$payload]" "$(step_file 'Download Binary')" "${P[@]}" \
    || bad "download step failed: $(cat "$WORK/out")"
  run_step "scan [$payload]" "$(step_file 'Execute scan against the docker image')" "${P[@]}" \
    OUTPUT_JSON=out.json FAIL_ON_SCAN_ERROR=false \
    || bad "scan step failed: $(cat "$WORK/out")"
  grep -qxF -- "$payload" "$WORK/shiftleft_args" \
    && ok "scan passes the payload to the CLI as data" \
    || bad "scan did not pass the payload through verbatim: $(cat "$WORK/shiftleft_args")"
  run_step "comment [$payload]" "$(step_file 'Comment on PR (conditional)')" "${P[@]}" \
    ADD_COMMENT="$payload" OUTPUT_JSON="$payload"
  run_step "enforce [$payload]" "$(step_file 'Enforce Upwind block policy')" OUTPUT_JSON="$payload"
done

# Backward compatibility: env-var references in inputs, and the commit_sha default.
run_step "scan with env refs" "$(step_file 'Execute scan against the docker image')" \
  INPUT_DOCKER_IMAGE='  ${GITHUB_REPOSITORY}:${GITHUB_SHA} ' INPUT_COMMIT_SHA='${GITHUB_SHA}' \
  INPUT_USE_SUDO=false INPUT_DEBUG=false INPUT_PULL_IMAGE=true INPUT_OCI_CLIENT=docker \
  OUTPUT_JSON=out.json FAIL_ON_SCAN_ERROR=false \
  || bad "scan step failed: $(cat "$WORK/out")"
grep -qxF 'owner/repo:abc123' "$WORK/shiftleft_args" && ok "docker_image env refs expanded" \
  || bad "docker_image env refs not expanded: $(cat "$WORK/shiftleft_args")"
grep -A1 -xF -- '--commit-sha' "$WORK/shiftleft_args" | grep -qxF abc123 && ok "commit_sha default expanded" \
  || bad "commit_sha default not expanded: $(cat "$WORK/shiftleft_args")"
grep -qxF 'RESOLVED_COMMIT_SHA=abc123' "$WORK/github_env" && ok "resolved commit sha exported" \
  || bad "resolved commit sha not exported: $(cat "$WORK/github_env")"

exit "$fail"
