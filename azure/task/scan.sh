#!/usr/bin/env bash
# Upwind ShiftLeft image scan - Azure Pipelines task entrypoint.
#
# Invoked by the task launcher with the task inputs mapped to UPWIND_*
# environment variables and Azure Pipelines' predefined variables available
# as BUILD_* / SYSTEM_* env vars. The working directory is the job's working
# directory, so upwind-shift-left.json lands in the customer's workspace.
#
# Variables:
#   UPWIND_CLIENT_ID            required  Upwind sensor credential id
#   UPWIND_CLIENT_SECRET        required  Upwind sensor credential secret
#   UPWIND_DOCKER_IMAGE         required  image to scan, e.g. myapp:abc123
#   UPWIND_COMMENT_TOKEN        optional  token allowed to write PR threads
#   UPWIND_URI                  optional  upwind.io (default) | upwind.dev
#   UPWIND_BLOCK_ON             optional  do_not_deploy | deploy_with_caution
#   UPWIND_ENFORCE_BLOCK_POLICY optional  true to fail on org PR-block policy
#   UPWIND_DOCKER_PULL          optional  false when the image was built in
#                                         this pipeline (default true)
#   UPWIND_AGENT_CHANNEL        optional  shiftleft release channel (stable)
#   UPWIND_POST_COMMENT         optional  false to never post the PR comment
# Azure Pipelines predefined variables used:
#   BUILD_SOURCEVERSION, BUILD_SOURCEBRANCH, BUILD_REPOSITORY_URI,
#   BUILD_REPOSITORY_NAME, BUILD_BUILDID, BUILD_DEFINITIONNAME,
#   BUILD_REQUESTEDFOR, SYSTEM_TEAMFOUNDATIONCOLLECTIONURI, SYSTEM_TEAMPROJECT,
#   SYSTEM_PULLREQUEST_SOURCEBRANCH, SYSTEM_PULLREQUEST_TARGETBRANCH,
#   SYSTEM_PULLREQUEST_PULLREQUESTID
# Test seams:
#   UPWIND_PIPE_DRY_RUN=1   print the resolved scan command and the comment
#                           decision; no network, no docker, exit 0.
#   UPWIND_SHIFTLEFT_PATH   path to a pre-provisioned shiftleft binary; skips
#                           the OAuth + download (e2e with pre-release builds).
#   UPWIND_COMMENT_SCRIPT   override the comment script location (default
#                           upwind_ado_comment.sh next to this script).
set -eu

DRY_RUN="${UPWIND_PIPE_DRY_RUN:-0}"
COMMENT_SCRIPT="${UPWIND_COMMENT_SCRIPT:-$(dirname "$0")/upwind_ado_comment.sh}"

CLIENT_ID="${UPWIND_CLIENT_ID:?set UPWIND_CLIENT_ID in the task inputs (Upwind sensor credential id)}"
CLIENT_SECRET="${UPWIND_CLIENT_SECRET:?set UPWIND_CLIENT_SECRET in the task inputs (Upwind sensor credential secret)}"
DOCKER_IMAGE="${UPWIND_DOCKER_IMAGE:?set UPWIND_DOCKER_IMAGE to the image to scan, e.g. myapp:<commit-sha>}"
UPWIND_URI="${UPWIND_URI:-upwind.io}"
BLOCK_ON="${UPWIND_BLOCK_ON:-}"                     # do_not_deploy | deploy_with_caution | empty
ENFORCE_BLOCK_POLICY="${UPWIND_ENFORCE_BLOCK_POLICY:-false}"
DOCKER_PULL="${UPWIND_DOCKER_PULL:-true}"           # false when the image is built in this pipeline
AGENT_CHANNEL="${UPWIND_AGENT_CHANNEL:-stable}"
POST_COMMENT="${UPWIND_POST_COMMENT:-true}"
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

# ---- Azure DevOps URLs (spaces in the project/repo name are percent-encoded) ----
ADO_BASE="${SYSTEM_TEAMFOUNDATIONCOLLECTIONURI:-}"
ADO_BASE="${ADO_BASE%/}/${SYSTEM_TEAMPROJECT:-}"
ADO_BASE="${ADO_BASE// /%20}"
REPO_NAME_ENC="${BUILD_REPOSITORY_NAME:-}"
REPO_NAME_ENC="${REPO_NAME_ENC// /%20}"

# ---- Branch / PR context ----
# On PR runs BUILD_SOURCEBRANCH is refs/pull/N/merge, so the branch under scan
# is the PR source branch. Tags are reported as the bare tag name.
IS_PR=false
[ -n "${SYSTEM_PULLREQUEST_PULLREQUESTID:-}" ] && IS_PR=true

if [ "$IS_PR" = "true" ]; then
  BRANCH="${SYSTEM_PULLREQUEST_SOURCEBRANCH:-}"
else
  BRANCH="${BUILD_SOURCEBRANCH:-}"
fi
BRANCH="${BRANCH#refs/heads/}"
BRANCH="${BRANCH#refs/tags/}"

set --
if [ "$IS_PR" = "true" ]; then
  MAIN_BRANCH="${SYSTEM_PULLREQUEST_TARGETBRANCH:-}"
  set -- "$@" --main-branch="${MAIN_BRANCH#refs/heads/}"
  set -- "$@" --pr-id="${SYSTEM_PULLREQUEST_PULLREQUESTID}"
  set -- "$@" --pr-link="${ADO_BASE}/_git/${REPO_NAME_ENC}/pullrequest/${SYSTEM_PULLREQUEST_PULLREQUESTID}"
fi
set -- "$@" --pipeline-run-id="${BUILD_BUILDID:-}"
set -- "$@" --pipeline-run-link="${ADO_BASE}/_build/results?buildId=${BUILD_BUILDID:-}"

SCAN_CMD=("$SHIFTLEFT" image
  --source=AZURE_DEVOPS
  --initiator="${BUILD_REQUESTEDFOR:-azure-pipelines}"
  --pipeline-name="${BUILD_DEFINITIONNAME:-}"
  --upwind-uri="${UPWIND_URI}"
  --upwind-client-id="${CLIENT_ID}"
  --upwind-client-secret="${CLIENT_SECRET}"
  --docker-image "${DOCKER_IMAGE}"
  --commit-sha "${BUILD_SOURCEVERSION:-}"
  --branch "${BRANCH}"
  --repository "${BUILD_REPOSITORY_URI:-}"
  --output-json="${OUTPUT_JSON}"
  --block-on="${BLOCK_ON}"
  --enforce-block-policy="${ENFORCE_BLOCK_POLICY}"
  --docker-pull="${DOCKER_PULL}"
  --oci-client=docker
  "$@")

if [ "$DRY_RUN" = "1" ]; then
  # Credentials stay out of the dry-run output.
  DRY_CMD="${SCAN_CMD[*]/--upwind-client-secret=${CLIENT_SECRET}/--upwind-client-secret=***}"
  echo "DRY RUN: ${DRY_CMD/--upwind-client-id=${CLIENT_ID}/--upwind-client-id=***}"
  SCAN_EXIT=0
else
  # ---- Scan (capture exit code so the comment still posts on block) ----
  SCAN_START=$(date +%s)
  if "${SCAN_CMD[@]}"; then SCAN_EXIT=0; else SCAN_EXIT=$?; fi
  ELAPSED=$(( $(date +%s) - SCAN_START ))
  if [ "$ELAPSED" -ge 60 ]; then SCAN_DURATION_HUMAN="$((ELAPSED/60))m $((ELAPSED%60))s"; else SCAN_DURATION_HUMAN="${ELAPSED}s"; fi
fi

# ---- Sticky PR comment (never fails the build) ----
if [ "$POST_COMMENT" = "false" ]; then
  echo "Info: UPWIND_POST_COMMENT=false; skipping Upwind PR comment"
elif [ "$IS_PR" != "true" ]; then
  echo "Info: not a pull-request run; skipping Upwind PR comment"
elif [ -z "${UPWIND_COMMENT_TOKEN:-}" ]; then
  echo "Info: UPWIND_COMMENT_TOKEN not set; skipping Upwind PR comment"
elif [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: would post Upwind PR comment via ${COMMENT_SCRIPT}"
else
  export UPWIND_COMMENT_TOKEN OUTPUT_JSON UPWIND_URI SCAN_DURATION_HUMAN
  bash "$COMMENT_SCRIPT" || echo "Warning: failed to post Upwind PR comment"
fi

exit "$SCAN_EXIT"
