#!/usr/bin/env bash
# Tests for task/upwind_ado_comment.sh. No real network: dry-run fixture cases
# (UPWIND_ADO_DRY_RUN=1) plus python stub-server cases that speak the Azure
# DevOps PR threads API shapes.
set -u
cd "$(dirname "$0")/.."
SCRIPT=task/upwind_ado_comment.sh
MARKER='<!-- upwind-image-scan-report -->'
HIST_RE='<!-- upwind-scan-history:\([A-Za-z0-9+/=]*\) -->'
PASS=0; FAIL=0
TMP=$(mktemp -d)
STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

check() { # $1=name $2=rc(0=pass)
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi
}

history_of() { # stdin=body -> decoded history JSON on stdout
  sed -n "s/.*${HIST_RE}.*/\1/p" | head -n1 | base64 -d 2>/dev/null
}

run_dry() { # $1=fixture [$2=project] -> body in $BODY, rc in $RC
  BODY=$(UPWIND_ADO_DRY_RUN=1 \
    UPWIND_COMMENT_TOKEN=dummy OUTPUT_JSON="$1" UPWIND_URI=upwind.dev \
    SCAN_DURATION_HUMAN=38s \
    SYSTEM_TEAMFOUNDATIONCOLLECTIONURI=https://dev.azure.com/org/ \
    SYSTEM_TEAMPROJECT="${2:-proj}" BUILD_REPOSITORY_NAME=repo \
    SYSTEM_PULLREQUEST_PULLREQUESTID=7 BUILD_SOURCEVERSION=abcdef1234567890 \
    SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/main \
    bash "$SCRIPT" 2>/dev/null); RC=$?
}

# test_single_result_object
run_dry tests/fixtures/single.json
check "single: exits 0" "$RC"
echo "$BODY" | grep -qF "$MARKER"; check "single: marker present" "$?"
echo "$BODY" | grep -q '\*\*Image:\*\* `myapp:1.2.3`'; check "single: image line" "$?"
echo "$BODY" | grep -q 'CVE-2025-1111'; check "single: critical CVE row" "$?"
echo "$BODY" | grep -q "$HIST_RE"; check "single: history blob present" "$?"
echo "$BODY" | grep -q 'redirectToCodeScanId=fp-abc123'; check "single: console link" "$?"
echo "$BODY" | grep -qF 'vs `main`'; check "single: base label strips refs/heads/" "$?"
echo "$BODY" | grep -qF 'https://dev.azure.com/org/proj/_git/repo/commit/abcdef1234567890'; check "single: ADO commit URL" "$?"
echo "$BODY" | grep -q '<details'; check "single: collapsible sections present" "$?"
echo "$BODY" | grep -qF '<details open>'; check "single: critical section open by default" "$?"
echo "$BODY" | grep -qF '[//]:'; [ "$?" -ne 0 ]; check "single: no bitbucket-style markers" "$?"
[ -z "$(echo "$BODY" | grep -B1 '^---$' | head -n1)" ]; check "single: blank line before history rule (no setext heading)" "$?"
echo "$BODY" | history_of | jq -e 'type=="array" and (.[0].new==2) and (.[0].resolved==1)' >/dev/null
check "single: history blob decodes with counts" "$?"

# project names with spaces are URL-encoded in links
run_dry tests/fixtures/single.json "My Proj"
echo "$BODY" | grep -qF '/My%20Proj/_git/repo/commit/'; check "single: project name encoded in commit URL" "$?"

# test_multi_arch_array
run_dry tests/fixtures/multiarch.json
check "multiarch: exits 0" "$RC"
N_ARCH=$(echo "$BODY" | grep -c '^## ')
[ "$N_ARCH" -eq 2 ]; check "multiarch: two arch sections (got $N_ARCH)" "$?"

# test_empty_output_skips
run_dry tests/fixtures/empty.json
check "empty: exits 0" "$RC"
if [ -z "$BODY" ] || ! echo "$BODY" | grep -qF "$MARKER"; then check "empty: no comment body" 0; else check "empty: no comment body" 1; fi

# missing output file is the one nonzero path
UPWIND_ADO_DRY_RUN=1 OUTPUT_JSON="$TMP/nope.json" bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -ne 0 ]; check "missing OUTPUT_JSON: exits nonzero" "$?"

# test_size_cap: ~3000 CVEs across 30 arch results must be cut to the cap
python3 - "$TMP/big.json" <<'PY'
import json, sys
sevs = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
with open(sys.argv[1], "w") as f:
    for a in range(30):
        cves = [{"cveId": "CVE-2025-%05d" % (a * 100 + i), "severity": sevs[i % 5],
                 "packageName": "package-name-%d" % i, "packageVersion": "1.0.%d" % i,
                 "fixedInVersion": "2.0.%d" % i} for i in range(100)]
        f.write(json.dumps({"imageName": "big", "imageVersion": "9", "fingerprint": "fp-big",
                            "arch": "arch-%d" % a, "compareTo": "fp-old",
                            "introducedCves": cves, "resolvedCves": [], "noChangeCves": []}) + "\n")
PY
run_dry "$TMP/big.json"
check "sizecap: exits 0" "$RC"
LEN=$(printf '%s' "$BODY" | python3 -c 'import sys; print(len(sys.stdin.read()))')
[ "$LEN" -le 135000 ]; check "sizecap: body <= 135000 chars (got $LEN)" "$?"
echo "$BODY" | grep -q 'Comment truncated'; check "sizecap: truncation notice present" "$?"
echo "$BODY" | history_of | jq -e 'type=="array" and (.[0].new==3000)' >/dev/null
check "sizecap: history blob decodable at tail with totals" "$?"
printf '%s' "$BODY" | tail -n 1 | grep -q "^${HIST_RE}\$"; check "sizecap: history blob is last line" "$?"
OPENS=$(echo "$BODY" | grep -c '^<details'); CLOSES=$(echo "$BODY" | grep -c '^</details>')
[ "$OPENS" -eq "$CLOSES" ]; check "sizecap: details tags balanced after truncation ($OPENS/$CLOSES)" "$?"

# ---- stub server cases (ADO shapes) ----
cat > "$TMP/stub.py" <<'PY'
import http.server, json, sys, base64
port, scenario, logfile = int(sys.argv[1]), sys.argv[2], sys.argv[3]
MARK = "<!-- upwind-image-scan-report -->"
PRIOR = base64.b64encode(json.dumps(
    [{"sha": "1111111", "url": "u", "ts": "t", "new": 0, "resolved": 0}]).encode()).decode()
OLD = MARK + "\nold\n\n<!-- upwind-scan-history:" + PRIOR + " -->"
def c(i, content, deleted=False): return {"id": i, "content": content, "isDeleted": deleted}
def t(i, comments, deleted=False): return {"id": i, "status": "closed", "isDeleted": deleted, "comments": comments}
THREADS = {
  # (a) marker in thread 2's first comment
  "update": [t(1, [c(1, "unrelated")]), t(2, [c(1, OLD), c(2, "a reply")])],
  # (b) empty comments, deleted thread, deleted first comment are all skipped
  "skip": [t(1, []), t(2, [c(1, OLD)], deleted=True), t(3, [c(1, OLD, deleted=True)]),
           t(4, [c(1, "gone", deleted=True), c(2, OLD)])],
  "none": [t(1, []), t(2, [c(1, "unrelated")])],
}
THREADS["post500"] = THREADS["none"]
THREADS["patch500"] = THREADS["update"]
class H(http.server.BaseHTTPRequestHandler):
    def log(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n).decode() if n else ""
        try: body = json.loads(raw) if raw else None
        except ValueError: body = raw
        with open(logfile, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization"), "body": body}) + "\n")
    def reply(self, code, body=None):
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.end_headers()
        if body is not None: self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        self.log()
        if self.path.startswith('/proj/_apis/git/repositories/repo/pullRequests/7/threads'):
            v = THREADS[scenario]; self.reply(200, {"count": len(v), "value": v})
        else: self.reply(404)
    def do_POST(self):
        self.log(); self.reply(500 if scenario == "post500" else 200, {"id": 99})
    def do_PATCH(self):
        self.log()
        if scenario == "patch500" and '/comments/' in self.path: self.reply(500)
        else: self.reply(200, {})
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY

run_stub() { # $1=scenario -> $OUT, $RC, request log in $LOG (JSON lines)
  local port
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  LOG="$TMP/$1.log"; : > "$LOG"
  python3 "$TMP/stub.py" "$port" "$1" "$LOG" &
  STUB_PID=$!
  local i=0
  while ! curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  : > "$LOG"   # drop the readiness probe from the log
  OUT=$(UPWIND_COMMENT_TOKEN=tok123 OUTPUT_JSON=tests/fixtures/single.json UPWIND_URI=upwind.dev \
    ADO_API_BASE="http://127.0.0.1:$port" SYSTEM_TEAMFOUNDATIONCOLLECTIONURI=https://dev.azure.com/org/ \
    SYSTEM_TEAMPROJECT=proj BUILD_REPOSITORY_NAME=repo SYSTEM_PULLREQUEST_PULLREQUESTID=7 \
    BUILD_SOURCEVERSION=abcdef1 SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/main \
    bash "$SCRIPT" 2>&1); RC=$?
  kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=""
}
reqs() { jq -r "select($1) | .path" "$LOG"; } # paths of logged requests matching a jq filter

# (a) marker lives in thread 2's comments[0] -> PATCH comment 1, then re-close thread
run_stub update
check "stub update: exits 0" "$RC"
reqs '.method=="PATCH"' | grep -qxF '/proj/_apis/git/repositories/repo/pullRequests/7/threads/2/comments/1?api-version=7.1'
check "stub update: PATCHes /threads/2/comments/1" "$?"
jq -e 'select(.method=="PATCH" and (.path|test("/threads/2\\?"))) | .body == {"status":"closed"}' "$LOG" | grep -q true
check "stub update: re-closes thread 2" "$?"
[ "$(jq -s '[.[] | select(.method=="POST")] | length' "$LOG")" -eq 0 ]; check "stub update: no new thread created" "$?"
jq -e 'select(.method=="PATCH" and (.path|test("/comments/1"))) | .body | keys == ["content"] and (.content|contains("<!-- upwind-image-scan-report -->"))' "$LOG" | grep -q true
check "stub update: flat {content} payload with marker" "$?"
jq -e 'select(.method=="PATCH" and (.path|test("/comments/1"))) | .body.content' "$LOG" | jq -r . | history_of \
  | jq -e 'type=="array" and length==2 and .[0].sha=="1111111"' >/dev/null
check "stub update: prior history carried into new body" "$?"
jq -e 'select(.auth=="Bearer tok123")' "$LOG" >/dev/null; check "stub update: Bearer auth header sent" "$?"

# (b) empty/deleted comments are skipped without error; first NON-deleted comment of thread 4 matches
run_stub skip
check "stub skip: exits 0" "$RC"
reqs '.method=="PATCH"' | grep -qxF '/proj/_apis/git/repositories/repo/pullRequests/7/threads/4/comments/2?api-version=7.1'
check "stub skip: matches thread 4 via first non-deleted comment" "$?"
[ "$(jq -s '[.[] | select(.method=="POST")] | length' "$LOG")" -eq 0 ]; check "stub skip: no new thread created" "$?"
echo "$OUT" | grep -q 'Warning'; [ "$?" -ne 0 ]; check "stub skip: no warnings" "$?"

# no marker anywhere -> create closed thread with ADO payload shape
run_stub none
check "stub create: exits 0" "$RC"
jq -e 'select(.method=="POST") | .body | (.status=="closed") and (.comments|length==1) and (.comments[0].parentCommentId==0) and (.comments[0].commentType==1) and (.comments[0].content|contains("<!-- upwind-image-scan-report -->"))' "$LOG" | grep -q true
check "stub create: thread payload shape" "$?"
reqs '.method=="POST"' | grep -qxF '/proj/_apis/git/repositories/repo/pullRequests/7/threads?api-version=7.1'
check "stub create: POSTs to /threads" "$?"

# (c) API 500 on POST is a warning, not a failure
run_stub post500
check "stub post500: exits 0" "$RC"
echo "$OUT" | grep -q 'Warning: failed to post'; check "stub post500: warning printed" "$?"

# 500 on comment PATCH is also a warning (and the thread is not touched)
run_stub patch500
check "stub patch500: exits 0" "$RC"
echo "$OUT" | grep -q 'Warning: failed to update'; check "stub patch500: warning printed" "$?"
[ "$(jq -s '[.[] | select(.method=="PATCH" and (.path|test("/threads/2\\?")))] | length' "$LOG")" -eq 0 ]
check "stub patch500: thread not re-closed after failed edit" "$?"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
