#!/usr/bin/env bash
# Dry-run tests for upwind_bb_comment.sh. No network: UPWIND_BB_DRY_RUN=1,
# plus one stub-server pass for pagination + warn-don't-fail behavior.
set -u
cd "$(dirname "$0")/.."
SCRIPT=scripts/upwind_bb_comment.sh
MARKER='[//]: # (upwind-image-scan-report)'
PASS=0; FAIL=0

run_dry() { # $1=fixture -> body in $BODY, rc in $RC
  BODY=$(UPWIND_BB_DRY_RUN=1 \
    UPWIND_COMMENT_TOKEN=dummy OUTPUT_JSON="$1" UPWIND_URI=upwind.dev \
    SCAN_DURATION_HUMAN=38s BITBUCKET_WORKSPACE=ws BITBUCKET_REPO_SLUG=repo \
    BITBUCKET_REPO_FULL_NAME=ws/repo BITBUCKET_PR_ID=7 \
    BITBUCKET_COMMIT=abcdef1234567890 BITBUCKET_PR_DESTINATION_BRANCH=main \
    bash "$SCRIPT" 2>/dev/null); RC=$?
}

check() { # $1=name $2=rc(0=pass)
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi
}

# test_single_result_object
run_dry tests/fixtures/single.json
check "single: exits 0" "$RC"
echo "$BODY" | grep -qF "$MARKER"; check "single: marker present" "$?"
echo "$BODY" | grep -q '\*\*Image:\*\* `myapp:1.2.3`'; check "single: image line" "$?"
echo "$BODY" | grep -q 'CVE-2025-1111'; check "single: critical CVE row" "$?"
echo "$BODY" | grep -qF '[//]: # (upwind-scan-history:'; check "single: history blob present" "$?"
echo "$BODY" | grep -q 'redirectToCodeScanId=fp-abc123'; check "single: console link" "$?"
if echo "$BODY" | grep -qE '<details>|<br>|<strong>'; then check "single: no raw html tags" 1; else check "single: no raw html tags" 0; fi
B64=$(echo "$BODY" | sed -n 's/.*upwind-scan-history:\([A-Za-z0-9+/=]*\)).*/\1/p' | head -n1)
printf '%s' "$B64" | base64 -d 2>/dev/null | jq -e 'type=="array" and (.[0].new==2) and (.[0].resolved==1)' >/dev/null
check "single: history blob decodes with counts" "$?"

# test_multi_arch_array
run_dry tests/fixtures/multiarch.json
check "multiarch: exits 0" "$RC"
N_ARCH=$(echo "$BODY" | grep -c '^## ')
[ "$N_ARCH" -eq 2 ]; check "multiarch: two arch sections (got $N_ARCH)" "$?"

# test_empty_output_skips
run_dry tests/fixtures/empty.json
check "empty: exits 0" "$RC"
if [ -z "$BODY" ] || ! echo "$BODY" | grep -qF "$MARKER"; then check "empty: no comment body" 0; else check "empty: no comment body" 1; fi

# test_pagination_follows_next + test_api_failure_is_warning (stub server)
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/repositories/ws/repo/pullrequests/7/comments'):
            if 'page=2' in self.path:
                body = {"values": [{"id": 42, "content": {"raw": "[//]: # (upwind-image-scan-report)\nold\n\n[//]: # (upwind-scan-history:W10=)"}}]}
            else:
                body = {"values": [{"id": 1, "content": {"raw": "unrelated"}}],
                        "next": "http://127.0.0.1:8977/repositories/ws/repo/pullrequests/7/comments?page=2"}
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(json.dumps(body).encode())
        else: self.send_response(404); self.end_headers()
    def do_PUT(self):
        self.send_response(401); self.end_headers()   # token revoked
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8977), H).serve_forever()
PY
STUB_PID=$!
sleep 1
OUT=$(UPWIND_COMMENT_TOKEN=dummy OUTPUT_JSON=tests/fixtures/single.json UPWIND_URI=upwind.dev \
  BB_API_BASE=http://127.0.0.1:8977 BITBUCKET_WORKSPACE=ws BITBUCKET_REPO_SLUG=repo \
  BITBUCKET_REPO_FULL_NAME=ws/repo BITBUCKET_PR_ID=7 BITBUCKET_COMMIT=abcdef1 \
  BITBUCKET_PR_DESTINATION_BRANCH=main bash "$SCRIPT" 2>&1); RC=$?
kill $STUB_PID 2>/dev/null
check "stub: exits 0 despite 401 on PUT" "$RC"
echo "$OUT" | grep -q 'Updating existing PR comment (42)'; check "stub: marker found on page 2 via .next" "$?"
echo "$OUT" | grep -q 'Warning: failed to update'; check "stub: 401 is a warning" "$?"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
