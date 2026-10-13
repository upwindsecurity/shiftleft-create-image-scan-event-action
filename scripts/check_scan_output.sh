#!/usr/bin/env bash
# Post-scan guard. The shiftleft CLI creates the output file before scanning and
# exits 0 on most scan failures unless --fail-on-scan-error is set, so a file that
# exists but carries no image result means the scan did not produce a result.
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

# A file we cannot read (for example root-owned 0600 under sudo) is not evidence
# of a failed scan, so never fail on it; the CLI's own exit code covers real failures.
if [ ! -r "$OUTPUT_JSON" ]; then
  echo "::warning::Upwind image scan output $OUTPUT_JSON is not readable, cannot verify the scan result"
  exit 0
fi

# Same normalisation and guard as the comment step, so both steps agree on "no result".
# The CLI writes one JSON object per scanned platform, so slurp them into an array.
RESULTS=$(jq -s '[.[] | objects | select((.imageName // "") != "")] | length' "$OUTPUT_JSON" 2>/dev/null) || RESULTS=0
case "$RESULTS" in
  ''|*[!0-9]*) RESULTS=0 ;;
esac

if [ "$RESULTS" -eq 0 ]; then
  MESSAGE="Upwind image scan produced no result: the scan failed or its results were not ready within the wait window. See the shiftleft output above."
  if [ "$FAIL_ON_SCAN_ERROR" = "true" ]; then
    echo "::error::$MESSAGE"
    exit 1
  fi
  echo "::warning::$MESSAGE Continuing because fail_on_scan_error is not set."
  exit 0
fi

echo "Info: Image scan completed"
