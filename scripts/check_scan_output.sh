#!/usr/bin/env bash
# Post-scan guard. The shiftleft CLI creates the output file before scanning and
# exits 0 on most scan failures unless --fail-on-scan-error is set, so a file that
# exists but carries no image result means the scan did not run to completion.
#
# Usage: check_scan_output.sh <output_json> <fail_on_scan_error: true|false>
# Exit 1 when the file is missing, or when it has no result and failing is requested.
set -uo pipefail

OUTPUT_JSON="$1"
FAIL_ON_SCAN_ERROR="${2:-false}"

if [ ! -f "$OUTPUT_JSON" ]; then
  echo "::error::Upwind image scan output $OUTPUT_JSON not found"
  exit 1
fi

# Same normalisation and guard as the comment step, so both steps agree on "no result".
ARRAY="$(mktemp)"
trap 'rm -f "$ARRAY"' EXIT
jq -cs 'if type=="array" then . else [.] end' "$OUTPUT_JSON" > "$ARRAY" 2>/dev/null || echo '[]' > "$ARRAY"
RESULTS=$(jq '[.[] | select((.imageName // "") != "")] | length' "$ARRAY")

if [ "$RESULTS" -eq 0 ]; then
  echo "::error::Upwind image scan produced no result. The scan did not complete; check the shiftleft output above for the error (for example an image that could not be unpacked)."
  if [ "$FAIL_ON_SCAN_ERROR" = "true" ]; then
    exit 1
  fi
  echo "Warning: continuing because fail_on_scan_error is not set"
  exit 0
fi

echo "Info: Image scan completed"
