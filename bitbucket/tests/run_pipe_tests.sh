#!/usr/bin/env bash
# Dry-run tests for pipe/pipe.sh. No network, no docker:
# UPWIND_PIPE_DRY_RUN=1 prints the resolved `shiftleft image` command and the
# comment decision instead of downloading/scanning/posting.
set -u
cd "$(dirname "$0")/.."
PIPE=pipe/pipe.sh
PASS=0; FAIL=0

check() { # $1=name $2=rc(0=pass)
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi
}

BASE_ENV=(
  UPWIND_PIPE_DRY_RUN=1
  UPWIND_CLIENT_ID=cid UPWIND_CLIENT_SECRET=csecret
  UPWIND_DOCKER_IMAGE=myapp:abc123
  BITBUCKET_COMMIT=abcdef1234567890 BITBUCKET_BRANCH=feature/x
  BITBUCKET_REPO_FULL_NAME=ws/repo BITBUCKET_WORKSPACE=ws
  BITBUCKET_REPO_SLUG=repo BITBUCKET_BUILD_NUMBER=55
  BITBUCKET_STEP_TRIGGERER_UUID='{uuid-1}'
)

run_pipe() { # extra env as args -> OUT, RC
  OUT=$(env "${BASE_ENV[@]}" "$@" bash "$PIPE" 2>&1); RC=$?
}

# ---- required-variable validation ----
OUT=$(env UPWIND_PIPE_DRY_RUN=1 UPWIND_CLIENT_SECRET=s UPWIND_DOCKER_IMAGE=i \
  BITBUCKET_COMMIT=c BITBUCKET_REPO_FULL_NAME=ws/repo bash "$PIPE" 2>&1); RC=$?
[ "$RC" -ne 0 ]; check "missing client id: nonzero exit" "$?"
echo "$OUT" | grep -q 'UPWIND_CLIENT_ID'; check "missing client id: names the variable" "$?"

OUT=$(env UPWIND_PIPE_DRY_RUN=1 UPWIND_CLIENT_ID=c UPWIND_CLIENT_SECRET=s \
  BITBUCKET_COMMIT=c BITBUCKET_REPO_FULL_NAME=ws/repo bash "$PIPE" 2>&1); RC=$?
[ "$RC" -ne 0 ]; check "missing docker image: nonzero exit" "$?"
echo "$OUT" | grep -q 'UPWIND_DOCKER_IMAGE'; check "missing docker image: names the variable" "$?"

# ---- non-PR pipeline: no PR args, pipeline args present ----
run_pipe
check "non-pr: exits 0" "$RC"
echo "$OUT" | grep -q -- '--source=BITBUCKET'; check "non-pr: source flag" "$?"
echo "$OUT" | grep -q -- '--docker-image myapp:abc123 '; check "non-pr: docker image (exact, no stray brace)" "$?"
echo "$OUT" | grep -q -- '--commit-sha abcdef1234567890'; check "non-pr: commit sha" "$?"
echo "$OUT" | grep -q -- '--branch feature/x'; check "non-pr: branch" "$?"
echo "$OUT" | grep -q -- '--pipeline-run-id=55'; check "non-pr: pipeline run id" "$?"
echo "$OUT" | grep -q -- '--pipeline-run-link=https://bitbucket.org/ws/repo/pipelines/results/55'; check "non-pr: pipeline run link" "$?"
if echo "$OUT" | grep -q -- '--pr-id'; then check "non-pr: no pr args" 1; else check "non-pr: no pr args" 0; fi
echo "$OUT" | grep -q 'not a pull-request pipeline; skipping Upwind PR comment'; check "non-pr: comment skipped" "$?"
echo "$OUT" | grep -q -- '--docker-pull=true'; check "non-pr: docker-pull defaults true" "$?"
echo "$OUT" | grep -q -- '--oci-client=docker'; check "non-pr: oci client docker" "$?"
echo "$OUT" | grep -q -- '--upwind-uri=upwind.io'; check "non-pr: uri defaults upwind.io" "$?"
echo "$OUT" | grep -q -- '--upwind-client-secret=\*\*\*'; check "non-pr: secret masked" "$?"
echo "$OUT" | grep -q -- '--upwind-client-id=\*\*\*'; check "non-pr: client id masked" "$?"
if echo "$OUT" | grep -qE 'csecret|=cid( |$)'; then check "non-pr: no raw credentials in output" 1; else check "non-pr: no raw credentials in output" 0; fi

# ---- PR pipeline: PR args + comment decision ----
run_pipe BITBUCKET_PR_ID=7 BITBUCKET_PR_DESTINATION_BRANCH=main
check "pr: exits 0" "$RC"
echo "$OUT" | grep -q -- '--pr-id=7'; check "pr: pr id" "$?"
echo "$OUT" | grep -q -- '--main-branch=main'; check "pr: main branch" "$?"
echo "$OUT" | grep -q -- '--pr-link=https://bitbucket.org/ws/repo/pull-requests/7'; check "pr: pr link" "$?"
echo "$OUT" | grep -q 'UPWIND_COMMENT_TOKEN not set; skipping Upwind PR comment'; check "pr no token: comment skipped" "$?"

run_pipe BITBUCKET_PR_ID=7 BITBUCKET_PR_DESTINATION_BRANCH=main UPWIND_COMMENT_TOKEN=tok
check "pr+token: exits 0" "$RC"
echo "$OUT" | grep -q 'would post Upwind PR comment'; check "pr+token: would post comment" "$?"

# ---- knobs pass through ----
run_pipe UPWIND_DOCKER_PULL=false UPWIND_BLOCK_ON=do_not_deploy \
  UPWIND_ENFORCE_BLOCK_POLICY=true UPWIND_URI=upwind.dev \
  UPWIND_DOCKER_USER=reguser UPWIND_DOCKER_PASSWORD=regpass \
  UPWIND_ADDITIONAL_REGISTRIES=reg1.io,reg2.io UPWIND_FAIL_ON_SCAN_ERROR=true
check "knobs: exits 0" "$RC"
echo "$OUT" | grep -q -- '--docker-pull=false'; check "knobs: docker-pull false" "$?"
echo "$OUT" | grep -q -- '--block-on=do_not_deploy'; check "knobs: block-on" "$?"
echo "$OUT" | grep -q -- '--enforce-block-policy=true'; check "knobs: enforce block policy" "$?"
echo "$OUT" | grep -q -- '--upwind-uri=upwind.dev'; check "knobs: uri override" "$?"
echo "$OUT" | grep -q -- '--docker-user=reguser'; check "knobs: docker user" "$?"
echo "$OUT" | grep -q -- '--docker-password=\*\*\*'; check "knobs: docker password masked" "$?"
if echo "$OUT" | grep -q 'regpass'; then check "knobs: no raw docker password" 1; else check "knobs: no raw docker password" 0; fi
echo "$OUT" | grep -q -- '--additional-registries=reg1.io,reg2.io'; check "knobs: additional registries" "$?"
echo "$OUT" | grep -q -- '--fail-on-scan-error'; check "knobs: fail-on-scan-error flag" "$?"

# default: fail-on-scan-error must NOT be passed (older binaries reject unknown flags)
run_pipe
if echo "$OUT" | grep -q -- '--fail-on-scan-error'; then check "default: no fail-on-scan-error flag" 1; else check "default: no fail-on-scan-error flag" 0; fi

# ---- tag pipeline: branch falls back to tag ----
OUT=$(env "${BASE_ENV[@]/BITBUCKET_BRANCH=feature\/x/BITBUCKET_TAG=v9.9.9}" bash "$PIPE" 2>&1); RC=$?
check "tag: exits 0" "$RC"
echo "$OUT" | grep -q -- '--branch v9.9.9'; check "tag: branch falls back to tag" "$?"

# ---- initiator fallback: commit author on non-PR pipelines, else uuid ----
SAFE_DIRS_BEFORE=$(git config --global --get-all safe.directory 2>/dev/null | wc -l | tr -d ' ')
ABS_PIPE="$PWD/$PIPE"
GITDIR=$(mktemp -d)
git -C "$GITDIR" init -q
git -C "$GITDIR" -c user.name='Test Author' -c user.email=t@e.st commit -q --allow-empty -m x
OUT=$(cd "$GITDIR" && env "${BASE_ENV[@]}" bash "$ABS_PIPE" 2>&1); RC=$?
check "git author: exits 0" "$RC"
echo "$OUT" | grep -q -- '--initiator=Test Author'; check "git author: non-pr initiator is commit author" "$?"
rm -rf "$GITDIR"
SAFE_DIRS_AFTER=$(git config --global --get-all safe.directory 2>/dev/null | wc -l | tr -d ' ')
[ "$SAFE_DIRS_AFTER" = "${SAFE_DIRS_BEFORE:-0}" ]; check "git author: global git config untouched" "$?"

NOGIT=$(mktemp -d)
OUT=$(cd "$NOGIT" && env "${BASE_ENV[@]}" bash "$ABS_PIPE" 2>&1); RC=$?
check "no git repo: exits 0" "$RC"
echo "$OUT" | grep -q -- '--initiator={uuid-1}'; check "no git repo: initiator falls back to uuid" "$?"
rmdir "$NOGIT"

# ---- pre-provisioned binary seam ----
TMPBIN=$(mktemp); printf '#!/bin/sh\n' > "$TMPBIN"; chmod +x "$TMPBIN"
run_pipe UPWIND_SHIFTLEFT_PATH="$TMPBIN"
check "shiftleft path: exits 0" "$RC"
echo "$OUT" | grep -q -- "DRY RUN: ${TMPBIN} image"; check "shiftleft path: used in command" "$?"
rm -f "$TMPBIN"
run_pipe UPWIND_SHIFTLEFT_PATH=/nonexistent/shiftleft
[ "$RC" -ne 0 ]; check "shiftleft path missing: nonzero exit" "$?"
echo "$OUT" | grep -q 'not an executable file'; check "shiftleft path missing: error message" "$?"

# ---- integration: comment posts, then the step fails on block ----
# Stub binary honours --output-json and exits STUB_EXIT; stub server serves the
# PR-author lookup and the comments API. BB_API_BASE points both the pipe and
# the comment script at the stub.
WORKDIR=$(mktemp -d)
STUB="$WORKDIR/shiftleft-stub"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
echo "STUB_ARGS: $*"
for a in "$@"; do case "$a" in --output-json=*) cp "$STUB_FIXTURE" "${a#*=}";; esac; done
exit "${STUB_EXIT:-0}"
EOS
chmod +x "$STUB"

python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if '/pullrequests/7/comments' in self.path:
            body = {"values": []}
        elif '/pullrequests/7' in self.path:
            body = {"author": {"display_name": "Stub Author"}}
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_POST(self):
        self.send_response(201); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{"id": 7001}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8978), H).serve_forever()
PY
STUB_PID=$!
sleep 1

INTEG_ENV=(
  UPWIND_CLIENT_ID=cid UPWIND_CLIENT_SECRET=csecret
  UPWIND_DOCKER_IMAGE=myapp:abc123 UPWIND_SHIFTLEFT_PATH="$STUB"
  UPWIND_COMMENT_SCRIPT="$PWD/scripts/upwind_bb_comment.sh"
  UPWIND_CHECK_SCRIPT="$PWD/../scripts/check_scan_output.sh"
  BB_API_BASE=http://127.0.0.1:8978
  UPWIND_COMMENT_TOKEN=tok UPWIND_URI=upwind.dev
  BITBUCKET_COMMIT=abcdef1234567890 BITBUCKET_BRANCH=feature/x
  BITBUCKET_REPO_FULL_NAME=ws/repo BITBUCKET_WORKSPACE=ws
  BITBUCKET_REPO_SLUG=repo BITBUCKET_BUILD_NUMBER=55
  BITBUCKET_PR_ID=7 BITBUCKET_PR_DESTINATION_BRANCH=main
)

# blocked scan (exit 1): the comment still posts, the pipe still exits 1
OUT=$(cd "$WORKDIR" && env "${INTEG_ENV[@]}" STUB_FIXTURE="$OLDPWD/tests/fixtures/single.json" STUB_EXIT=1 bash "$ABS_PIPE" 2>&1); RC=$?
[ "$RC" -eq 1 ]; check "integ block: pipe exits 1" "$?"
echo "$OUT" | grep -qi 'posting new.*comment'; check "integ block: comment posted before failing" "$?"
echo "$OUT" | grep -q -- '--initiator=Stub Author'; check "integ block: initiator resolved via BB_API_BASE" "$?"

# scan silently produced no result: fail-on-scan-error turns green into red
OUT=$(cd "$WORKDIR" && env "${INTEG_ENV[@]}" STUB_FIXTURE="$OLDPWD/tests/fixtures/empty.json" STUB_EXIT=0 UPWIND_FAIL_ON_SCAN_ERROR=true bash "$ABS_PIPE" 2>&1); RC=$?
[ "$RC" -ne 0 ]; check "integ no-result: exits nonzero with fail-on-scan-error" "$?"
echo "$OUT" | grep -q 'no result'; check "integ no-result: explains why" "$?"

# same silent-zero without the knob keeps the historical fail-open behavior
OUT=$(cd "$WORKDIR" && env "${INTEG_ENV[@]}" STUB_FIXTURE="$OLDPWD/tests/fixtures/empty.json" STUB_EXIT=0 bash "$ABS_PIPE" 2>&1); RC=$?
check "integ no-result default: exits 0 (fail-open preserved)" "$RC"

kill $STUB_PID 2>/dev/null
rm -rf "$WORKDIR"

# ---- syntax check both scripts ----
bash -n pipe/pipe.sh; check "pipe.sh: bash -n" "$?"
bash -n scripts/upwind_bb_comment.sh; check "upwind_bb_comment.sh: bash -n" "$?"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
