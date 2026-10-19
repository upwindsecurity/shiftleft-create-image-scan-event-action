#!/usr/bin/env bash
# Upwind ShiftLeft image scan - Bitbucket pipe entrypoint.
#
# Runs inside the pipe container (see Dockerfile) with the customer's
# variables passed through the pipe `variables:` block and Bitbucket's
# BITBUCKET_* predefined variables injected by Pipelines. The working
# directory is the pipeline clone dir, so upwind-shift-left.json lands in
# the customer's workspace (declarable as a step artifact).
#
# Variables (see pipe.yml / README):
#   UPWIND_CLIENT_ID            required  Upwind sensor credential id
#   UPWIND_CLIENT_SECRET        required  Upwind sensor credential secret
#   UPWIND_DOCKER_IMAGE         required  image to scan, e.g. myapp:abc123
#   UPWIND_COMMENT_TOKEN        optional  repo access token (pullrequest:write)
#   UPWIND_URI                  optional  upwind.io (default) | upwind.dev
#   UPWIND_BLOCK_ON             optional  do_not_deploy | deploy_with_caution
#   UPWIND_ENFORCE_BLOCK_POLICY optional  true to fail on org PR-block policy
#   UPWIND_DOCKER_PULL          optional  false when the image was built in
#                                         this pipeline (default true)
#   UPWIND_DOCKER_USER          optional  registry user, for images pulled from
#   UPWIND_DOCKER_PASSWORD      optional  a private registry (the pipe container
#                                         does not see docker logins done in the
#                                         customer step)
#   UPWIND_ADDITIONAL_REGISTRIES optional comma-separated registries to also
#                                         associate with the image
#   UPWIND_FAIL_ON_SCAN_ERROR   optional  true to fail the step when the scan
#                                         could not complete at all (the CLI
#                                         fails open by default); recommended
#                                         together with UPWIND_BLOCK_ON /
#                                         UPWIND_ENFORCE_BLOCK_POLICY
#   UPWIND_AGENT_CHANNEL        optional  shiftleft release channel (stable)
# Test seams:
#   UPWIND_PIPE_DRY_RUN=1   print the resolved scan command and the comment
#                           decision; no network, no docker, exit 0.
#   UPWIND_SHIFTLEFT_PATH   path to a pre-provisioned shiftleft binary; skips
#                           the OAuth + download (e2e with pre-release builds).
#   UPWIND_COMMENT_SCRIPT   override the comment script location (default
#                           /usr/local/bin/upwind_bb_comment.sh in the image).
#   UPWIND_CHECK_SCRIPT     override the scan-output guard location (default
#                           /usr/local/bin/check_scan_output.sh in the image).
#   BB_API_BASE             override the Bitbucket API base (stub server).
set -eu

DRY_RUN="${UPWIND_PIPE_DRY_RUN:-0}"
COMMENT_SCRIPT="${UPWIND_COMMENT_SCRIPT:-/usr/local/bin/upwind_bb_comment.sh}"
CHECK_SCRIPT="${UPWIND_CHECK_SCRIPT:-/usr/local/bin/check_scan_output.sh}"
BB_API="${BB_API_BASE:-https://api.bitbucket.org/2.0}"

CLIENT_ID="${UPWIND_CLIENT_ID:?set UPWIND_CLIENT_ID in the pipe variables (Upwind sensor credential id)}"
CLIENT_SECRET="${UPWIND_CLIENT_SECRET:?set UPWIND_CLIENT_SECRET in the pipe variables (Upwind sensor credential secret)}"
DOCKER_IMAGE="${UPWIND_DOCKER_IMAGE:?set UPWIND_DOCKER_IMAGE to the image to scan, e.g. myapp:<commit-sha>}"
UPWIND_URI="${UPWIND_URI:-upwind.io}"
BLOCK_ON="${UPWIND_BLOCK_ON:-}"                     # do_not_deploy | deploy_with_caution | empty
ENFORCE_BLOCK_POLICY="${UPWIND_ENFORCE_BLOCK_POLICY:-false}"
DOCKER_PULL="${UPWIND_DOCKER_PULL:-true}"           # false when the image is built in this pipeline
AGENT_CHANNEL="${UPWIND_AGENT_CHANNEL:-stable}"
DOCKER_USER="${UPWIND_DOCKER_USER:-}"
DOCKER_PASSWORD="${UPWIND_DOCKER_PASSWORD:-}"
ADDITIONAL_REGISTRIES="${UPWIND_ADDITIONAL_REGISTRIES:-}"
FAIL_ON_SCAN_ERROR="${UPWIND_FAIL_ON_SCAN_ERROR:-false}"
OUTPUT_JSON="upwind-shift-left.json"

SHIFTLEFT="${UPWIND_SHIFTLEFT_PATH:-./shiftleft}"
if [ -n "${UPWIND_SHIFTLEFT_PATH:-}" ]; then
  [ -x "$SHIFTLEFT" ] || { echo "Error: UPWIND_SHIFTLEFT_PATH=${SHIFTLEFT} is not an executable file"; exit 1; }
elif [ "$DRY_RUN" != "1" ]; then
  # ---- OAuth + binary download (same release bucket as the GHA action) ----
  TOKEN=$(curl -sSL -X POST "https://oauth.${UPWIND_URI}/oauth/token" \
    --data "audience=https://agent.${UPWIND_URI}" \
    --data "client_id=${CLIENT_ID}" \
    --data "client_secret=${CLIENT_SECRET}" \
    --data "grant_type=client_credentials" | jq -r '.access_token // empty')
  [ -n "$TOKEN" ] || { echo "Error: could not obtain Upwind OAuth token"; exit 1; }
  OS=$(uname | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) echo "Unsupported arch: $ARCH"; exit 1;; esac
  RELEASE_BUCKET="releases.upwind.io"; [ "$UPWIND_URI" = "upwind.dev" ] && RELEASE_BUCKET="releases.upwind.dev"
  curl -fsS -H "Authorization: Bearer $TOKEN" -L \
    "https://${RELEASE_BUCKET}/shiftleft/${AGENT_CHANNEL}/${OS}/${ARCH}/shiftleft-${OS}-${ARCH}" -o "$SHIFTLEFT"
  chmod +x "$SHIFTLEFT"
fi

# ---- PR context (only on pull-request pipelines) ----
set --
if [ -n "${BITBUCKET_PR_ID:-}" ]; then
  set -- "$@" --main-branch="${BITBUCKET_PR_DESTINATION_BRANCH}"
  set -- "$@" --pr-id="${BITBUCKET_PR_ID}"
  set -- "$@" --pr-link="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/pull-requests/${BITBUCKET_PR_ID}"
fi
set -- "$@" --pipeline-run-id="${BITBUCKET_BUILD_NUMBER:-}"
set -- "$@" --pipeline-run-link="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/pipelines/results/${BITBUCKET_BUILD_NUMBER:-}"

# Initiator: Bitbucket only exposes the triggerer as a UUID, and repo
# access tokens cannot read /2.0/users/{uuid} (403, verified). On PR
# pipelines, use the PR author's display name via the PR endpoint
# (within the pullrequest scope); otherwise fall back to the UUID.
INITIATOR="${BITBUCKET_STEP_TRIGGERER_UUID:-bitbucket-pipelines}"
if [ "$DRY_RUN" != "1" ] && [ -n "${UPWIND_COMMENT_TOKEN:-}" ] && [ -n "${BITBUCKET_PR_ID:-}" ]; then
  DISPLAY=$(curl -fsSL -H "Authorization: Bearer ${UPWIND_COMMENT_TOKEN}" \
    "${BB_API}/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests/${BITBUCKET_PR_ID}" 2>/dev/null \
    | jq -r '.author.display_name // empty' || true)
  [ -n "$DISPLAY" ] && INITIATOR="$DISPLAY"
fi
# Still a UUID (branch/tag pipelines, or no token): fall back to the commit
# author from the clone - not always the triggerer, but readable. The pipe
# container runs as root over a clone owned by another uid, so git needs
# safe.directory before it will read it.
if [ "$INITIATOR" = "${BITBUCKET_STEP_TRIGGERER_UUID:-bitbucket-pipelines}" ] && command -v git >/dev/null 2>&1; then
  AUTHOR=$(git -c safe.directory="$PWD" log -1 --format=%an 2>/dev/null || true)
  [ -n "$AUTHOR" ] && INITIATOR="$AUTHOR"
fi

SCAN_CMD=("$SHIFTLEFT" image
  --source=BITBUCKET
  --initiator="${INITIATOR}"
  --upwind-uri="${UPWIND_URI}"
  --upwind-client-id="${CLIENT_ID}"
  --upwind-client-secret="${CLIENT_SECRET}"
  --docker-image "${DOCKER_IMAGE}"
  --commit-sha "${BITBUCKET_COMMIT:-}"
  --branch "${BITBUCKET_BRANCH:-${BITBUCKET_TAG:-}}"
  --repository "https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}"
  --output-json="${OUTPUT_JSON}"
  --block-on="${BLOCK_ON}"
  --enforce-block-policy="${ENFORCE_BLOCK_POLICY}"
  --docker-pull="${DOCKER_PULL}"
  --docker-user="${DOCKER_USER}"
  --docker-password="${DOCKER_PASSWORD}"
  --additional-registries="${ADDITIONAL_REGISTRIES}"
  --oci-client=docker
  "$@")
# Only when asked for: older binaries reject unknown flags.
if [ "$FAIL_ON_SCAN_ERROR" = "true" ]; then
  SCAN_CMD+=(--fail-on-scan-error)
fi

if [ "$DRY_RUN" = "1" ]; then
  # Credentials stay out of the dry-run output.
  DRY_CMD="${SCAN_CMD[*]/--upwind-client-secret=${CLIENT_SECRET}/--upwind-client-secret=***}"
  DRY_CMD="${DRY_CMD/--upwind-client-id=${CLIENT_ID}/--upwind-client-id=***}"
  if [ -n "$DOCKER_PASSWORD" ]; then
    DRY_CMD="${DRY_CMD/--docker-password=${DOCKER_PASSWORD}/--docker-password=***}"
  fi
  echo "DRY RUN: ${DRY_CMD}"
  SCAN_EXIT=0
else
  # ---- Scan (capture exit code so the comment still posts on block) ----
  SCAN_START=$(date +%s)
  if "${SCAN_CMD[@]}"; then SCAN_EXIT=0; else SCAN_EXIT=$?; fi
  ELAPSED=$(( $(date +%s) - SCAN_START ))
  if [ "$ELAPSED" -ge 60 ]; then SCAN_DURATION_HUMAN="$((ELAPSED/60))m $((ELAPSED%60))s"; else SCAN_DURATION_HUMAN="${ELAPSED}s"; fi
  # Guard against the CLI's fail-open paths: an output file with no result
  # means the scan did not complete. Fails the step only when
  # UPWIND_FAIL_ON_SCAN_ERROR=true; the comment below still runs first.
  CHECK_EXIT=0
  bash "$CHECK_SCRIPT" "$OUTPUT_JSON" "$FAIL_ON_SCAN_ERROR" || CHECK_EXIT=$?
fi

# ---- Sticky PR comment (never fails the build) ----
if [ -z "${BITBUCKET_PR_ID:-}" ]; then
  echo "Info: not a pull-request pipeline; skipping Upwind PR comment"
elif [ -z "${UPWIND_COMMENT_TOKEN:-}" ]; then
  echo "Info: UPWIND_COMMENT_TOKEN not set; skipping Upwind PR comment"
elif [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: would post Upwind PR comment via ${COMMENT_SCRIPT}"
else
  export UPWIND_COMMENT_TOKEN OUTPUT_JSON UPWIND_URI SCAN_DURATION_HUMAN
  bash "$COMMENT_SCRIPT" || echo "Warning: failed to post Upwind PR comment"
fi

if [ "$SCAN_EXIT" -ne 0 ]; then exit "$SCAN_EXIT"; fi
exit "${CHECK_EXIT:-0}"
