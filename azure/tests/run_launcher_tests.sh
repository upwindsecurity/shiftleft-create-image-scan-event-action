#!/usr/bin/env bash
# Tests for task/index.js (the Node20 launcher). No network, no docker.
# Most cases copy index.js next to a stub scan.sh that dumps the UPWIND_* env
# it received and exits with $STUB_EXIT; one case runs the real scan.sh in
# dry-run mode to prove the whole input -> command path.
set -u
cd "$(dirname "$0")/.."
ABS_ROOT="$PWD"
PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check() { # $1=name $2=rc(0=pass)
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi
}
has() { echo "$OUT" | grep -qF -- "$1"; }
hasnt() { ! echo "$OUT" | grep -qF -- "$1"; }

# Launcher + stub scan.sh in an isolated dir.
mkdir -p "$TMP/stub"
cp task/index.js "$TMP/stub/index.js" 2>/dev/null
cat > "$TMP/stub/scan.sh" <<'STUB'
#!/usr/bin/env bash
env | grep '^UPWIND_' | sort
exit "${STUB_EXIT:-0}"
STUB

BASE_ENV=(
  INPUT_IMAGE=myapp:abc123
  INPUT_CLIENTID=cid
  INPUT_CLIENTSECRET=csecret
)

run_launcher() { # extra env as args -> OUT, RC (stub scan.sh)
  OUT=$(env -i PATH="$PATH" "${BASE_ENV[@]}" "$@" node "$TMP/stub/index.js" 2>&1); RC=$?
}

# ---- input mapping ----
run_launcher \
  INPUT_UPWINDURI=upwind.dev INPUT_BLOCKON=do_not_deploy INPUT_ENFORCEBLOCKPOLICY=true \
  INPUT_DOCKERPULL=false INPUT_AGENTCHANNEL=beta INPUT_POSTCOMMENT=true \
  INPUT_FAILONSCANERROR=true SYSTEM_ACCESSTOKEN=sys-token
check "mapping: exits 0" "$RC"
has 'UPWIND_DOCKER_IMAGE=myapp:abc123'; check "mapping: image" "$?"
has 'UPWIND_CLIENT_ID=cid'; check "mapping: client id" "$?"
has 'UPWIND_CLIENT_SECRET=csecret'; check "mapping: client secret reaches scan.sh" "$?"
has 'UPWIND_URI=upwind.dev'; check "mapping: upwind uri" "$?"
has 'UPWIND_BLOCK_ON=do_not_deploy'; check "mapping: block on" "$?"
has 'UPWIND_ENFORCE_BLOCK_POLICY=true'; check "mapping: enforce block policy" "$?"
has 'UPWIND_DOCKER_PULL=false'; check "mapping: docker pull" "$?"
has 'UPWIND_AGENT_CHANNEL=beta'; check "mapping: agent channel" "$?"
has 'UPWIND_POST_COMMENT=true'; check "mapping: post comment" "$?"
has 'UPWIND_FAIL_ON_SCAN_ERROR=true'; check "mapping: fail on scan error" "$?"

# ---- defaults when optional inputs are absent ----
run_launcher SYSTEM_ACCESSTOKEN=t
has 'UPWIND_URI=upwind.io'; check "defaults: uri upwind.io" "$?"
echo "$OUT" | grep -qE '^UPWIND_BLOCK_ON=$'; check "defaults: block on empty" "$?"
has 'UPWIND_ENFORCE_BLOCK_POLICY=false'; check "defaults: enforce false" "$?"
has 'UPWIND_DOCKER_PULL=true'; check "defaults: docker pull true" "$?"
has 'UPWIND_AGENT_CHANNEL=stable'; check "defaults: channel stable" "$?"
has 'UPWIND_POST_COMMENT=true'; check "defaults: post comment true" "$?"
has 'UPWIND_FAIL_ON_SCAN_ERROR=false'; check "defaults: fail on scan error false" "$?"

# ---- boolean normalization (ADO may deliver True/False) ----
run_launcher INPUT_POSTCOMMENT=False INPUT_DOCKERPULL=False INPUT_ENFORCEBLOCKPOLICY=True SYSTEM_ACCESSTOKEN=t
has 'UPWIND_POST_COMMENT=false'; check "bool: INPUT_POSTCOMMENT=False -> false" "$?"
has 'UPWIND_DOCKER_PULL=false'; check "bool: INPUT_DOCKERPULL=False -> false" "$?"
has 'UPWIND_ENFORCE_BLOCK_POLICY=true'; check "bool: INPUT_ENFORCEBLOCKPOLICY=True -> true" "$?"
run_launcher INPUT_POSTCOMMENT=TRUE SYSTEM_ACCESSTOKEN=t
has 'UPWIND_POST_COMMENT=true'; check "bool: TRUE -> true" "$?"
run_launcher INPUT_DOCKERPULL=1 INPUT_ENFORCEBLOCKPOLICY=yes INPUT_POSTCOMMENT=0 SYSTEM_ACCESSTOKEN=t
has 'UPWIND_DOCKER_PULL=true'; check "bool: INPUT_DOCKERPULL=1 -> true" "$?"
has 'UPWIND_ENFORCE_BLOCK_POLICY=true'; check "bool: yes -> true" "$?"
has 'UPWIND_POST_COMMENT=false'; check "bool: INPUT_POSTCOMMENT=0 -> false" "$?"
hasnt 'Unrecognised boolean'; check "bool: recognised forms emit no warning" "$?"
run_launcher INPUT_POSTCOMMENT=' No ' SYSTEM_ACCESSTOKEN=t
has 'UPWIND_POST_COMMENT=false'; check "bool: ' No ' (trimmed, case-insensitive) -> false" "$?"
run_launcher INPUT_POSTCOMMENT=garbage INPUT_DOCKERPULL=maybe INPUT_ENFORCEBLOCKPOLICY=whatever SYSTEM_ACCESSTOKEN=t
check "bool: garbage -> still exits 0" "$RC"
has 'UPWIND_POST_COMMENT=true'; check "bool: INPUT_POSTCOMMENT=garbage -> default true" "$?"
has 'UPWIND_DOCKER_PULL=true'; check "bool: INPUT_DOCKERPULL=maybe -> default true" "$?"
has 'UPWIND_ENFORCE_BLOCK_POLICY=false'; check "bool: INPUT_ENFORCEBLOCKPOLICY=whatever -> default false" "$?"
has 'Unrecognised boolean value for INPUT_POSTCOMMENT'; check "bool: garbage warning names the input" "$?"

# ---- token precedence ----
run_launcher ENDPOINT_AUTH_PARAMETER_SYSTEMVSSCONNECTION_ACCESSTOKEN=job-token SYSTEM_ACCESSTOKEN=sys-token
has 'UPWIND_COMMENT_TOKEN=job-token'; check "token: endpoint auth param wins" "$?"
hasnt 'sys-token'; check "token: system token not used when endpoint token present" "$?"

run_launcher SYSTEM_ACCESSTOKEN=sys-token
has 'UPWIND_COMMENT_TOKEN=sys-token'; check "token: falls back to SYSTEM_ACCESSTOKEN" "$?"
hasnt 'Contribute to pull requests'; check "token: no warning when a token exists" "$?"

run_launcher SYSTEM_PULLREQUEST_PULLREQUESTID=9
check "token: none (PR run) -> still exits 0" "$RC"
echo "$OUT" | grep -qE '^UPWIND_COMMENT_TOKEN=$'; check "token: none -> exported empty" "$?"
has 'Contribute to pull requests'; check "token: none on a PR run -> warning names the grant" "$?"

run_launcher
check "token: none (non-PR run) -> still exits 0" "$RC"
hasnt 'Contribute to pull requests'; check "token: none on a non-PR run -> no warning" "$?"

# ---- required inputs ----
for pair in "INPUT_IMAGE:image" "INPUT_CLIENTID:clientId" "INPUT_CLIENTSECRET:clientSecret"; do
  var=${pair%%:*}; name=${pair##*:}
  rest=()
  for kv in "${BASE_ENV[@]}"; do [ "${kv%%=*}" = "$var" ] || rest+=("$kv"); done
  OUT=$(env -i PATH="$PATH" "${rest[@]}" node "$TMP/stub/index.js" 2>&1); RC=$?
  [ "$RC" -eq 1 ]; check "missing $name: exit 1" "$?"
  has "$name"; check "missing $name: names the input" "$?"
done

# ---- secrets never printed by the launcher itself ----
cat > "$TMP/stub/scan.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
run_launcher SYSTEM_ACCESSTOKEN=sys-token
hasnt 'csecret'; check "secrets: client secret not printed" "$?"
hasnt 'sys-token'; check "secrets: job token not printed" "$?"

# ---- exit code propagation ----
cat > "$TMP/stub/scan.sh" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_EXIT:-0}"
STUB
run_launcher STUB_EXIT=7 SYSTEM_ACCESSTOKEN=t
[ "$RC" -eq 7 ]; check "exit: child 7 -> launcher 7" "$?"
has '##vso[task.complete result=Failed;]'; check "exit: nonzero emits task.complete Failed" "$?"
run_launcher STUB_EXIT=0 SYSTEM_ACCESSTOKEN=t
[ "$RC" -eq 0 ]; check "exit: child 0 -> launcher 0" "$?"
hasnt 'task.complete'; check "exit: success emits no task.complete" "$?"

# ---- end to end through the real scan.sh (dry run) ----
OUT=$(env -i PATH="$PATH" "${BASE_ENV[@]}" INPUT_BLOCKON=deploy_with_caution INPUT_ENFORCEBLOCKPOLICY=True \
  INPUT_DOCKERPULL=False UPWIND_PIPE_DRY_RUN=1 BUILD_SOURCEVERSION=abc BUILD_SOURCEBRANCH=refs/heads/main \
  node "$ABS_ROOT/task/index.js" 2>&1); RC=$?
check "real scan.sh dry run: exits 0" "$RC"
has '--docker-image myapp:abc123'; check "real scan.sh: image reaches command" "$?"
has '--block-on=deploy_with_caution'; check "real scan.sh: block-on reaches command" "$?"
has '--enforce-block-policy=true'; check "real scan.sh: enforce normalized" "$?"
has '--docker-pull=false'; check "real scan.sh: docker-pull normalized" "$?"
hasnt 'csecret'; check "real scan.sh: secret masked end to end" "$?"

echo; echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
