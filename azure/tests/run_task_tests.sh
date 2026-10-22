#!/usr/bin/env bash
# Tests for task/scan.sh. No network, no docker:
#  - dry-run cases (UPWIND_PIPE_DRY_RUN=1) assert on the resolved
#    `shiftleft image` command and the comment decision.
#  - live-path cases use stub shiftleft / comment scripts (UPWIND_SHIFTLEFT_PATH,
#    UPWIND_COMMENT_SCRIPT) to assert exit-code propagation and that the
#    comment is posted before a blocking exit.
set -u
cd "$(dirname "$0")/.."
ABS_ROOT="$PWD"
SCAN=task/scan.sh
PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check() { # $1=name $2=rc(0=pass)
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi
}
has() { echo "$OUT" | grep -qF -- "$1"; }

BASE_ENV=(
  UPWIND_PIPE_DRY_RUN=1
  UPWIND_CLIENT_ID=cid UPWIND_CLIENT_SECRET=csecret
  UPWIND_DOCKER_IMAGE=myapp:abc123
  BUILD_SOURCEVERSION=abcdef1234567890
  BUILD_SOURCEBRANCH=refs/heads/feature/x
  BUILD_REPOSITORY_URI=https://dev.azure.com/testorg/proj/_git/repo
  BUILD_REPOSITORY_NAME=repo
  BUILD_BUILDID=55
  BUILD_DEFINITIONNAME=my-pipeline
  BUILD_REQUESTEDFOR='Sarel Peller'
  SYSTEM_TEAMFOUNDATIONCOLLECTIONURI=https://dev.azure.com/testorg/
  SYSTEM_TEAMPROJECT=proj
)
PR_ENV=(
  BUILD_SOURCEBRANCH=refs/pull/9/merge
  SYSTEM_PULLREQUEST_SOURCEBRANCH=refs/heads/feature/x
  SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/main
  SYSTEM_PULLREQUEST_PULLREQUESTID=9
)

run_scan() { # extra env as args -> OUT, RC
  OUT=$(env "${BASE_ENV[@]}" "$@" bash "$SCAN" 2>&1); RC=$?
}

# ---- required-variable validation ----
OUT=$(env UPWIND_PIPE_DRY_RUN=1 UPWIND_CLIENT_SECRET=s UPWIND_DOCKER_IMAGE=i bash "$SCAN" 2>&1); RC=$?
[ "$RC" -ne 0 ]; check "missing client id: nonzero exit" "$?"
has 'UPWIND_CLIENT_ID'; check "missing client id: names the variable" "$?"

OUT=$(env UPWIND_PIPE_DRY_RUN=1 UPWIND_CLIENT_ID=c UPWIND_DOCKER_IMAGE=i bash "$SCAN" 2>&1); RC=$?
[ "$RC" -ne 0 ]; check "missing client secret: nonzero exit" "$?"
has 'UPWIND_CLIENT_SECRET'; check "missing client secret: names the variable" "$?"

OUT=$(env UPWIND_PIPE_DRY_RUN=1 UPWIND_CLIENT_ID=c UPWIND_CLIENT_SECRET=s bash "$SCAN" 2>&1); RC=$?
[ "$RC" -ne 0 ]; check "missing docker image: nonzero exit" "$?"
has 'UPWIND_DOCKER_IMAGE'; check "missing docker image: names the variable" "$?"

# ---- repository URL: userinfo stripped from the ADO clone URL ----
run_scan BUILD_REPOSITORY_URI='https://myorg@dev.azure.com/myorg/proj/_git/repo'
check "repo userinfo: exits 0" "$RC"
has '--repository https://dev.azure.com/myorg/proj/_git/repo '; check "repo userinfo: org@ stripped to canonical URL" "$?"
if has '--repository https://myorg@'; then check "repo userinfo: no userinfo in repository flag" 1; else check "repo userinfo: no userinfo in repository flag" 0; fi

# ---- non-PR run: no PR args, pipeline args present ----
run_scan
check "non-pr: exits 0" "$RC"
has '--source=AZURE_DEVOPS'; check "non-pr: source flag" "$?"
has '--initiator=Sarel Peller'; check "non-pr: initiator is requestedFor display name" "$?"
has '--pipeline-name=my-pipeline'; check "non-pr: pipeline name" "$?"
has '--docker-image myapp:abc123 '; check "non-pr: docker image (exact, no stray brace)" "$?"
has '--commit-sha abcdef1234567890'; check "non-pr: commit sha" "$?"
has '--branch feature/x '; check "non-pr: branch is BUILD_SOURCEBRANCH stripped of refs/heads/" "$?"
has '--repository https://dev.azure.com/testorg/proj/_git/repo '; check "non-pr: repository is BUILD_REPOSITORY_URI" "$?"
has '--pipeline-run-id=55'; check "non-pr: pipeline run id" "$?"
has '--pipeline-run-link=https://dev.azure.com/testorg/proj/_build/results?buildId=55'; check "non-pr: pipeline run link" "$?"
for f in --pr-id --pr-link --main-branch; do
  if has "$f"; then check "non-pr: no $f" 1; else check "non-pr: no $f" 0; fi
done
has 'not a pull-request run; skipping Upwind PR comment'; check "non-pr: comment skipped" "$?"
has '--docker-pull=true'; check "non-pr: docker-pull defaults true" "$?"
has '--oci-client=docker'; check "non-pr: oci client docker" "$?"
has '--upwind-uri=upwind.io'; check "non-pr: uri defaults upwind.io" "$?"
has '--enforce-block-policy=false'; check "non-pr: enforce block policy defaults false" "$?"
has '--upwind-client-secret=***'; check "non-pr: secret masked" "$?"
has '--upwind-client-id=***'; check "non-pr: client id masked" "$?"
if echo "$OUT" | grep -qE 'csecret|=cid( |$)'; then check "non-pr: no raw credentials in output" 1; else check "non-pr: no raw credentials in output" 0; fi

# ---- initiator fallback when requestedFor is absent ----
OUT=$(env "${BASE_ENV[@]}" BUILD_REQUESTEDFOR= bash "$SCAN" 2>&1); RC=$?
check "no requestedFor: exits 0" "$RC"
has '--initiator=azure-pipelines'; check "no requestedFor: initiator falls back" "$?"

# ---- PR run: PR args + comment decision ----
run_scan "${PR_ENV[@]}"
check "pr: exits 0" "$RC"
has '--pr-id=9'; check "pr: pr id" "$?"
has '--main-branch=main'; check "pr: main branch stripped of refs/heads/" "$?"
has '--pr-link=https://dev.azure.com/testorg/proj/_git/repo/pullrequest/9'; check "pr: pr link" "$?"
run_scan "${PR_ENV[@]}" SYSTEM_TEAMPROJECT='My Proj' BUILD_REPOSITORY_NAME='my repo'
has '--pr-link=https://dev.azure.com/testorg/My%20Proj/_git/my%20repo/pullrequest/9'; check "pr: spaces encoded as %20 in pr link" "$?"
run_scan "${PR_ENV[@]}" SYSTEM_TEAMPROJECT='Café & Co' BUILD_REPOSITORY_NAME='r&d repo'
has '--pr-link=https://dev.azure.com/testorg/Caf%C3%A9%20%26%20Co/_git/r%26d%20repo/pullrequest/9'; check "pr: non-ASCII and & encoded in pr link" "$?"
has '--pipeline-run-link=https://dev.azure.com/testorg/Caf%C3%A9%20%26%20Co/_build/results?buildId=55'; check "pr: non-ASCII and & encoded in pipeline run link" "$?"
run_scan "${PR_ENV[@]}"
has '--branch feature/x '; check "pr: branch is the PR source branch" "$?"
if has 'refs/pull/9/merge'; then check "pr: merge ref never leaks into output" 1; else check "pr: merge ref never leaks into output" 0; fi
has 'UPWIND_COMMENT_TOKEN not set; skipping Upwind PR comment'; check "pr no token: comment skipped" "$?"

run_scan "${PR_ENV[@]}" UPWIND_COMMENT_TOKEN=tok
check "pr+token: exits 0" "$RC"
has 'would post Upwind PR comment via task/upwind_ado_comment.sh'; check "pr+token: would post via task-folder default script" "$?"
if echo "$OUT" | grep -qw 'tok'; then check "pr+token: token not echoed" 1; else check "pr+token: token not echoed" 0; fi

run_scan "${PR_ENV[@]}" UPWIND_COMMENT_TOKEN=tok UPWIND_COMMENT_SCRIPT=/x/custom.sh
has 'via /x/custom.sh'; check "pr+token: UPWIND_COMMENT_SCRIPT override" "$?"

run_scan "${PR_ENV[@]}" UPWIND_COMMENT_TOKEN=tok UPWIND_POST_COMMENT=false
check "post-comment=false: exits 0" "$RC"
has 'UPWIND_POST_COMMENT=false; skipping Upwind PR comment'; check "post-comment=false: comment skipped" "$?"
if has 'would post'; then check "post-comment=false: no post even with token+PR" 1; else check "post-comment=false: no post even with token+PR" 0; fi

# ---- knobs pass through ----
run_scan UPWIND_DOCKER_PULL=false UPWIND_BLOCK_ON=do_not_deploy \
  UPWIND_ENFORCE_BLOCK_POLICY=true UPWIND_URI=upwind.dev
check "knobs: exits 0" "$RC"
has '--docker-pull=false'; check "knobs: docker-pull false" "$?"
has '--block-on=do_not_deploy'; check "knobs: block-on" "$?"
has '--enforce-block-policy=true'; check "knobs: enforce block policy" "$?"
has '--upwind-uri=upwind.dev'; check "knobs: uri override" "$?"

# ---- fail on scan error: opt-in flag ----
run_scan
if has '--fail-on-scan-error'; then check "fail-on-scan-error: absent by default" 1; else check "fail-on-scan-error: absent by default" 0; fi
run_scan UPWIND_FAIL_ON_SCAN_ERROR=true
check "fail-on-scan-error=true: exits 0" "$RC"
has '--fail-on-scan-error'; check "fail-on-scan-error=true: flag added" "$?"

# ---- non-Azure-Repos provider: branch context kept, no PR id/link, no comment ----
run_scan "${PR_ENV[@]}" BUILD_REPOSITORY_PROVIDER=GitHub UPWIND_COMMENT_TOKEN=tok
check "github provider: exits 0" "$RC"
has '--main-branch=main'; check "github provider: main branch kept for the baseline diff" "$?"
for f in --pr-id --pr-link; do
  if has "$f"; then check "github provider: no $f" 1; else check "github provider: no $f" 0; fi
done
has "repository provider 'GitHub' is not Azure Repos; skipping Upwind PR comment"; check "github provider: comment skipped with provider message" "$?"
if has 'would post'; then check "github provider: no post even with token" 1; else check "github provider: no post even with token" 0; fi
run_scan "${PR_ENV[@]}" BUILD_REPOSITORY_PROVIDER=TfsGit UPWIND_COMMENT_TOKEN=tok
has '--pr-id=9'; check "tfsgit provider: pr id present" "$?"
has 'would post'; check "tfsgit provider: would post comment" "$?"

# ---- tag run ----
run_scan BUILD_SOURCEBRANCH=refs/tags/v9.9.9
check "tag: exits 0" "$RC"
has '--branch v9.9.9 '; check "tag: branch is the bare tag name" "$?"

# ---- pre-provisioned binary seam ----
TMPBIN="$TMP/shiftleft"; printf '#!/bin/sh\n' > "$TMPBIN"; chmod +x "$TMPBIN"
run_scan UPWIND_SHIFTLEFT_PATH="$TMPBIN"
check "shiftleft path: exits 0" "$RC"
has "DRY RUN: ${TMPBIN} image"; check "shiftleft path: used in command" "$?"
run_scan UPWIND_SHIFTLEFT_PATH=/nonexistent/shiftleft
[ "$RC" -ne 0 ]; check "shiftleft path missing: nonzero exit" "$?"
has 'not an executable file'; check "shiftleft path missing: error message" "$?"

# ---- live path (stubs): exit code propagates, comment posts BEFORE exit ----
LIVE="$TMP/live"; mkdir -p "$LIVE"
cat > "$TMP/stub_shiftleft.sh" <<'STUB'
#!/bin/sh
# Writes a plausible scan output unless told otherwise, so the output guard
# sees a completed scan by default.
if [ "${STUB_NO_OUTPUT:-0}" != "1" ]; then
  if [ "${STUB_EMPTY_RESULT:-0}" = "1" ]; then
    printf '{"status":"partial"}\n' > upwind-shift-left.json
  else
    printf '{"imageName":"myapp:abc123"}\n' > upwind-shift-left.json
  fi
fi
exit "${STUB_SCAN_EXIT:-0}"
STUB
cat > "$TMP/stub_comment.sh" <<'STUB'
#!/bin/bash
echo "COMMENT_RAN token=${UPWIND_COMMENT_TOKEN:-} json=${OUTPUT_JSON:-} uri=${UPWIND_URI:-} dur=${SCAN_DURATION_HUMAN:-}" >> "$STUB_LOG"
exit "${STUB_COMMENT_EXIT:-0}"
STUB
chmod +x "$TMP/stub_shiftleft.sh"

run_live() { # extra env as args -> RC, LOG (comment log), OUT
  rm -f "$TMP/comment.log" "$LIVE/upwind-shift-left.json"
  OUT=$(cd "$LIVE" && env "${BASE_ENV[@]}" UPWIND_PIPE_DRY_RUN=0 \
    UPWIND_SHIFTLEFT_PATH="$TMP/stub_shiftleft.sh" UPWIND_COMMENT_SCRIPT="$TMP/stub_comment.sh" \
    STUB_LOG="$TMP/comment.log" "$@" bash "$ABS_ROOT/$SCAN" 2>&1); RC=$?
  LOG=$(cat "$TMP/comment.log" 2>/dev/null || true)
}

run_live "${PR_ENV[@]}" UPWIND_COMMENT_TOKEN=tok STUB_SCAN_EXIT=0
check "live ok: exits 0" "$RC"
echo "$LOG" | grep -q 'COMMENT_RAN token=tok json=upwind-shift-left.json uri=upwind.io dur=[0-9]'; check "live ok: comment script gets exported env" "$?"

run_live "${PR_ENV[@]}" UPWIND_COMMENT_TOKEN=tok STUB_SCAN_EXIT=3
[ "$RC" -eq 3 ]; check "live block: exit code is the scan's exit code" "$?"
echo "$LOG" | grep -q 'COMMENT_RAN'; check "live block: comment posted before exiting" "$?"

run_live "${PR_ENV[@]}" UPWIND_COMMENT_TOKEN=tok STUB_SCAN_EXIT=3 STUB_COMMENT_EXIT=1
[ "$RC" -eq 3 ]; check "live comment failure: scan exit code still wins" "$?"
echo "$OUT" | grep -q 'Warning: failed to post Upwind PR comment'; check "live comment failure: warning printed" "$?"

run_live "${PR_ENV[@]}" UPWIND_COMMENT_TOKEN=tok UPWIND_POST_COMMENT=false STUB_SCAN_EXIT=0
[ -z "$LOG" ]; check "live post-comment=false: comment script not run" "$?"

run_live UPWIND_COMMENT_TOKEN=tok STUB_SCAN_EXIT=0
[ -z "$LOG" ]; check "live non-pr: comment script not run" "$?"

run_live "${PR_ENV[@]}" STUB_SCAN_EXIT=0
[ -z "$LOG" ]; check "live no token: comment script not run" "$?"

run_live "${PR_ENV[@]}" UPWIND_COMMENT_TOKEN=tok BUILD_REPOSITORY_PROVIDER=GitHub STUB_SCAN_EXIT=0
[ -z "$LOG" ]; check "live non-ado provider: comment script not run" "$?"

# ---- output guard: the real check_scan_output.sh runs on the live path ----
run_live STUB_SCAN_EXIT=0
[ "$RC" -eq 0 ]; check "guard result present: exit 0" "$?"
echo "$OUT" | grep -q 'Image scan completed'; check "guard result present: completion message" "$?"

run_live STUB_SCAN_EXIT=0 STUB_EMPTY_RESULT=1
[ "$RC" -eq 0 ]; check "guard no result, flag unset: exit 0" "$?"
echo "$OUT" | grep -q 'Continuing because fail_on_scan_error is not set'; check "guard no result, flag unset: warning printed" "$?"

run_live STUB_SCAN_EXIT=0 STUB_EMPTY_RESULT=1 UPWIND_FAIL_ON_SCAN_ERROR=true
[ "$RC" -eq 1 ]; check "guard no result, flag true: exit 1" "$?"

run_live STUB_SCAN_EXIT=0 STUB_NO_OUTPUT=1
[ "$RC" -ne 0 ]; check "guard missing output file: nonzero even without the flag" "$?"

run_live "${PR_ENV[@]}" UPWIND_COMMENT_TOKEN=tok STUB_SCAN_EXIT=3 STUB_EMPTY_RESULT=1 UPWIND_FAIL_ON_SCAN_ERROR=true
[ "$RC" -eq 3 ]; check "guard + blocking scan: the scan's exit code wins" "$?"
echo "$LOG" | grep -q 'COMMENT_RAN'; check "guard + blocking scan: comment still posted first" "$?"

cat > "$TMP/stub_check.sh" <<'STUB'
#!/bin/bash
echo "CHECK_RAN $1 $2"
exit 0
STUB
run_live STUB_SCAN_EXIT=0 UPWIND_CHECK_SCRIPT="$TMP/stub_check.sh" UPWIND_FAIL_ON_SCAN_ERROR=true
echo "$OUT" | grep -q 'CHECK_RAN upwind-shift-left.json true'; check "guard: UPWIND_CHECK_SCRIPT override gets file + flag args" "$?"

# ---- drift guard: the shipped copy must match the canonical script ----
cmp -s ../scripts/check_scan_output.sh task/check_scan_output.sh; check "check_scan_output.sh: azure/task copy matches scripts/ canonical" "$?"

# ---- syntax check ----
bash -n task/scan.sh; check "scan.sh: bash -n" "$?"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
