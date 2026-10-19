#!/usr/bin/env bash
# Post/update the "Upwind Image Scan Report" comment on a Bitbucket Cloud PR.
# Port of the GitLab component's upwind_mr_comment.sh to the Bitbucket
# Cloud 2.0 PR comments API: a sticky per-PR comment with
# introduced/resolved/existing findings + a hidden scan-history blob.
#
# Bitbucket-specific design (live-probed against the API):
#   - Markers use markdown-comment syntax `[//]: # (...)` because Bitbucket
#     HTML-escapes raw HTML in rendering (an `<!-- -->` marker would be
#     VISIBLE to PR viewers). They round-trip verbatim in content.raw.
#   - No HTML tags anywhere in the body (no <details>/<br>/<strong>).
#   - List responses are {values, next}; pagination follows .next.
#   - Payloads are {content: {raw: ...}}.
#
# Env in:
#   UPWIND_COMMENT_TOKEN  Bitbucket repository access token (pullrequest:write)
#   OUTPUT_JSON           path to `shiftleft image --output-json`
#   UPWIND_URI            e.g. upwind.io / upwind.dev (for the Console link)
#   SCAN_DURATION_HUMAN   optional, e.g. "38s" / "1m 4s"
#   BITBUCKET_WORKSPACE, BITBUCKET_REPO_SLUG, BITBUCKET_REPO_FULL_NAME,
#   BITBUCKET_PR_ID, BITBUCKET_COMMIT, BITBUCKET_PR_DESTINATION_BRANCH
#     (Bitbucket Pipelines predefined)
# Test seams:
#   UPWIND_BB_DRY_RUN=1   print the final body to stdout, no network
#   BB_API_BASE           default https://api.bitbucket.org/2.0
#
# Exit contract: exits 0 on every non-bug path (API failures print
# "Warning:"); nonzero only when OUTPUT_JSON is missing.
set -eu

COMMENT_MARKER='[//]: # (upwind-image-scan-report)'
HISTORY_PREFIX='[//]: # (upwind-scan-history:'
HISTORY_MAX_ENTRIES=30
MAX_ROWS=60
# Largest live-probed accepted body was 400,000 chars; keep a 10% margin.
BB_SIZE_CAP=360000

MAIN_BRANCH="${BITBUCKET_PR_DESTINATION_BRANCH:-}"
COMMIT_SHA="${BITBUCKET_COMMIT:-}"
COMMIT_URL="https://bitbucket.org/${BITBUCKET_REPO_FULL_NAME}/commits/${COMMIT_SHA}"
SCANNED_AT="$(date -u '+%Y-%m-%d %H:%M UTC')"

if [ ! -f "$OUTPUT_JSON" ]; then
  echo "Error: Output file not found: $OUTPUT_JSON"
  exit 1
fi

# Normalise the scan output into a JSON array. The CLI writes one JSON object
# per result (NDJSON stream for multi-arch); a hand-fed true JSON array is
# flattened one level so both shapes work.
ARRAY="$(mktemp)"
jq -cs '[.[] | if type=="array" then .[] else . end]' "$OUTPUT_JSON" > "$ARRAY"

if [ "$(jq '[.[] | select((.imageName // "") != "")] | length' "$ARRAY")" -eq 0 ]; then
  echo "Warning: scan results not ready (empty output); skipping comment"
  exit 0
fi

IMAGE_NAME=$(jq -r '.[0].imageName // "unknown"' "$ARRAY")
IMAGE_VERSION=$(jq -r '.[0].imageVersion // "unknown"' "$ARRAY")
FINGERPRINT=$(jq -r '.[0].fingerprint // ""' "$ARRAY")

if [ -n "$MAIN_BRANCH" ]; then
  BASE_LABEL="\`${MAIN_BRANCH#refs/heads/}\`"
else
  BASE_LABEL="the previous scan"
fi

TOTAL_NEW=0
TOTAL_RESOLVED=0

COMMENT="${COMMENT_MARKER}"$'\n\n'
COMMENT+="# 🏄‍♂️ Upwind Image Scan Report"$'\n'
COMMENT+="**Image:** \`$IMAGE_NAME:$IMAGE_VERSION\`"$'\n\n'

# CVE table under a bold heading (capped). Bitbucket renders no HTML, so no
# collapsible <details> - the row cap keeps long reports readable.
# $1=cves json $2=summary $3=with_fix ("1")
emit_table() {
  local cves_json="$1" summary="$2" with_fix="$3" rows total
  rows=$(echo "$cves_json" | jq -r --argjson max "$MAX_ROWS" '
    [.[]][0:$max][]
    | [ (.cveId // .cveName // "<unknown>"),
        (.packageName // ""),
        (.packageVersion // ""),
        (.fixedInVersion // "") ]
    | @tsv')
  total=$(echo "$cves_json" | jq 'length')
  COMMENT+="**${summary}**"$'\n\n'
  if [ "$with_fix" = "1" ]; then
    COMMENT+=$'| CVE | Package | Version | Fix |\n|---|---|---|---|\n'
  else
    COMMENT+=$'| CVE | Package | Version |\n|---|---|---|\n'
  fi
  while IFS=$'\t' read -r CVE PKG VER FIX; do
    [ -z "${CVE}" ] && CVE="<unknown>"
    case "$CVE" in
      CVE-*) CVE_CELL="[${CVE}](https://nvd.nist.gov/vuln/detail/${CVE})" ;;
      *)     CVE_CELL="${CVE}" ;;
    esac
    local pkg_cell="—" ver_cell="—" fix_cell="—"
    [ -n "$PKG" ] && pkg_cell="\`${PKG}\`"
    [ -n "$VER" ] && ver_cell="\`${VER}\`"
    [ -n "$FIX" ] && fix_cell="\`${FIX}\`"
    if [ "$with_fix" = "1" ]; then
      COMMENT+="| ${CVE_CELL} | ${pkg_cell} | ${ver_cell} | ${fix_cell} |"$'\n'
    else
      COMMENT+="| ${CVE_CELL} | ${pkg_cell} | ${ver_cell} |"$'\n'
    fi
  done <<< "$rows"
  if [ "$total" -gt "$MAX_ROWS" ]; then
    COMMENT+="_…and $((total - MAX_ROWS)) more._"$'\n'
  fi
  COMMENT+=$'\n'
}

# Introduced findings for one severity.
emit_introduced_sev() {
  local intro_json="$1" sev="$2" emoji="$3" label="$4" n sfx
  n=$(echo "$intro_json" | jq --arg s "$sev" '[.[] | select((.severity // "" | ascii_upcase)==$s)] | length')
  [ "$n" -eq 0 ] && return 0
  sfx="s"; if [ "$n" -eq 1 ]; then sfx=""; fi
  emit_table "$(echo "$intro_json" | jq -c --arg s "$sev" '[.[] | select((.severity // "" | ascii_upcase)==$s)]')" \
             "${emoji} ${label} · ${n} finding${sfx}" "1"
}

while IFS= read -r scan; do
  ARCH=$(echo "$scan" | jq -r '.arch? // ""')
  STATUS=$(echo "$scan" | jq -r '.scanStatus // ""')
  INTRO=$(echo "$scan" | jq -c '.introducedCves // []')
  RESOLVED=$(echo "$scan" | jq -c '.resolvedCves // []')
  PRESENT=$(echo "$scan" | jq -c '(.introducedCves // []) + (.noChangeCves // [])')
  COMPARE_TO=$(echo "$scan" | jq -r '.compareTo // ""')

  N=$(echo "$INTRO" | jq 'length')
  R=$(echo "$RESOLVED" | jq 'length')
  T=$(echo "$PRESENT" | jq 'length')
  TOTAL_NEW=$((TOTAL_NEW + N))
  TOTAL_RESOLVED=$((TOTAL_RESOLVED + R))
  cC=$(echo "$PRESENT" | jq '[.[] | select((.severity // "" | ascii_upcase)=="CRITICAL")] | length')
  cH=$(echo "$PRESENT" | jq '[.[] | select((.severity // "" | ascii_upcase)=="HIGH")] | length')
  cM=$(echo "$PRESENT" | jq '[.[] | select((.severity // "" | ascii_upcase)=="MEDIUM")] | length')
  cL=$(echo "$PRESENT" | jq '[.[] | select((.severity // "" | ascii_upcase)=="LOW")] | length')
  cU=$(echo "$PRESENT" | jq '[.[] | select((.severity // "" | ascii_upcase) as $s | ($s!="CRITICAL" and $s!="HIGH" and $s!="MEDIUM" and $s!="LOW"))] | length')

  if [ -n "$ARCH" ]; then
    COMMENT+="## $ARCH"$'\n'
  fi
  if [ -n "$STATUS" ]; then
    COMMENT+="- **Status:** \`$STATUS\`"$'\n'
  fi
  if [ -n "$ARCH" ] || [ -n "$STATUS" ]; then
    COMMENT+=$'\n'
  fi

  # Blank line instead of the GHA/GitLab trailing <br>: Bitbucket escapes raw
  # HTML, and its renderer treats a single newline as a soft break anyway.
  if [ -n "$MAIN_BRANCH" ] && [ -z "$COMPARE_TO" ]; then
    tvword="vulnerabilities"; if [ "$T" -eq 1 ]; then tvword="vulnerability"; fi
    COMMENT+="**${T}** total ${tvword} · no baseline scan for ${BASE_LABEL} yet — showing full inventory (introduced/resolved vs ${BASE_LABEL} will appear once it has been scanned)"$'\n\n'
  else
    ivword="vulnerabilities"; if [ "$N" -eq 1 ]; then ivword="vulnerability"; fi
    COMMENT+="**${N}** newly introduced ${ivword} · **${R}** resolved · **${T}** total in this PR vs ${BASE_LABEL}"$'\n\n'
  fi

  BREAK=""
  [ "$cC" -gt 0 ] && BREAK+="🔴 ${cC} Critical | "
  [ "$cH" -gt 0 ] && BREAK+="🔶 ${cH} High | "
  [ "$cM" -gt 0 ] && BREAK+="🟡 ${cM} Medium | "
  [ "$cL" -gt 0 ] && BREAK+="🟢 ${cL} Low | "
  [ "$cU" -gt 0 ] && BREAK+="⚪ ${cU} Other | "
  BREAK="${BREAK% | }"
  if [ -n "$BREAK" ]; then COMMENT+="$BREAK"$'\n'; fi
  COMMENT+=$'\n'

  emit_introduced_sev "$INTRO" "CRITICAL" "🔴" "Critical"
  emit_introduced_sev "$INTRO" "HIGH"     "🔶" "High"
  emit_introduced_sev "$INTRO" "MEDIUM"   "🟡" "Medium"
  emit_introduced_sev "$INTRO" "LOW"      "🟢" "Low"
  OTHER_FILTER='[.[] | select((.severity // "" | ascii_upcase) as $s | ($s!="CRITICAL" and $s!="HIGH" and $s!="MEDIUM" and $s!="LOW"))]'
  nO=$(echo "$INTRO" | jq "$OTHER_FILTER | length")
  if [ "$nO" -gt 0 ]; then
    osfx="s"; if [ "$nO" -eq 1 ]; then osfx=""; fi
    emit_table "$(echo "$INTRO" | jq -c "$OTHER_FILTER")" \
               "⚪ Other · ${nO} finding${osfx}" "1"
  fi
  if [ "$R" -gt 0 ]; then
    rsfx="s"; if [ "$R" -eq 1 ]; then rsfx=""; fi
    emit_table "$RESOLVED" "✅ Resolved · ${R} finding${rsfx}" "0"
  fi
done < <(jq -c '.[]' "$ARRAY")

if [ -n "$FINGERPRINT" ]; then
  # Shared regions (eu/me/ap) use the global console; dedicated deployments
  # (e.g. pdc02.upwind.io) keep their own. Mirrors the CLI's consoleScanURL.
  CONSOLE_HOST="${UPWIND_URI:-upwind.io}"
  case "$CONSOLE_HOST" in
    eu.*|me.*|ap.*) CONSOLE_HOST="${CONSOLE_HOST#*.}" ;;
  esac
  COMMENT+="[View full analysis in Upwind Console →](https://console.${CONSOLE_HOST}/?redirectToCodeScanId=${FINGERPRINT})"$'\n\n'
fi
if [ -n "${SCAN_DURATION_HUMAN:-}" ]; then
  COMMENT+="_Scan completed in ${SCAN_DURATION_HUMAN}_"$'\n'
fi

# --- Sticky comment + scan history (Bitbucket Cloud 2.0 PR comments API) ---
BB_API_BASE="${BB_API_BASE:-https://api.bitbucket.org/2.0}"
AUTH_HDR="Authorization: Bearer ${UPWIND_COMMENT_TOKEN}"
COMMENTS_API="${BB_API_BASE}/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests/${BITBUCKET_PR_ID}/comments"

EXISTING_ID=""
PRIOR_HISTORY="[]"
if [ "${UPWIND_BB_DRY_RUN:-}" != "1" ]; then
  PAGE_URL="${COMMENTS_API}?pagelen=100"
  pages=0
  while [ -n "$PAGE_URL" ] && [ "$pages" -lt 10 ]; do
    PAGE_JSON=$(curl -fsSL -H "$AUTH_HDR" "$PAGE_URL" 2>/dev/null || echo '{}')
    MATCH=$(echo "$PAGE_JSON" | jq -c --arg m "$COMMENT_MARKER" \
      '(.values // []) | map(select((.deleted // false) | not) | select((.content.raw // "") | contains($m))) | .[0] // empty')
    if [ -n "$MATCH" ]; then
      EXISTING_ID=$(echo "$MATCH" | jq -r '.id')
      PRIOR_B64=$(echo "$MATCH" | jq -r '.content.raw' \
        | sed -n 's/.*upwind-scan-history:\([A-Za-z0-9+/=]*\)).*/\1/p' | head -n1)
      if [ -n "$PRIOR_B64" ]; then
        DECODED=$(printf '%s' "$PRIOR_B64" | base64 -d 2>/dev/null || echo "")
        if echo "$DECODED" | jq -e 'type=="array"' >/dev/null 2>&1; then
          PRIOR_HISTORY="$DECODED"
        fi
      fi
      break
    fi
    PAGE_URL=$(echo "$PAGE_JSON" | jq -r '.next // empty')
    pages=$((pages + 1))
  done
fi

HISTORY_JSON=$(echo "$PRIOR_HISTORY" | jq -c \
  --arg sha "$COMMIT_SHA" \
  --arg url "$COMMIT_URL" \
  --arg ts "$SCANNED_AT" \
  --argjson new "$TOTAL_NEW" \
  --argjson resolved "$TOTAL_RESOLVED" \
  --argjson max "$HISTORY_MAX_ENTRIES" \
  '. + [{sha: $sha, url: $url, ts: $ts, new: $new, resolved: $resolved}] | .[-$max:]')

HISTORY_MD=$(echo "$HISTORY_JSON" | jq -r '
  (length) as $n |
  (if $n == 1 then "scan" else "scans" end) as $noun |
  "---\n\n**Scan history (\($n) \($noun))**\n\n"
  + "| Commit | Scanned at | New | Resolved | Net |\n"
  + "|--------|------------|-----|----------|-----|\n"
  + ([ to_entries[]
       | .key as $i | .value as $e
       | (if $i == ($n - 1) then " <" else "" end) as $latest
       | (if $e.new > 0 then "+\($e.new)" else "0" end) as $newc
       | (if $e.resolved > 0 then "-\($e.resolved)" else "0" end) as $resc
       | ($e.new - $e.resolved) as $net
       | (if $net > 0 then "+\($net)" else "\($net)" end) as $netc
       | "| [`\($e.sha[0:7])`](\($e.url))\($latest) | \($e.ts) | \($newc) | \($resc) | \($netc) |"
     ] | join("\n"))
  + "\n\n"
  + (.[-1] | "_Last scanned: [`\(.sha[0:7])`](\(.url)) · \(.ts)_\n")
')

COMMENT+="$HISTORY_MD"

HISTORY_B64=$(printf '%s' "$HISTORY_JSON" | base64 | tr -d '\n')
# Markdown-comment lines must be block-level: keep a blank line before the
# hidden state so Bitbucket's renderer swallows it.
HIDDEN_STATE=$'\n\n'"${HISTORY_PREFIX}${HISTORY_B64})"$'\n'

CAP=$((BB_SIZE_CAP - ${#HIDDEN_STATE}))
if [ "${#COMMENT}" -gt "$CAP" ]; then
  COMMENT="${COMMENT:0:$((CAP - 500))}"
  COMMENT="${COMMENT%$'\n'*}"
  COMMENT+=$'\n\n_Comment truncated to fit Bitbucket\'s size limit — see the Upwind Console._'
fi
COMMENT+="$HIDDEN_STATE"

if [ "${UPWIND_BB_DRY_RUN:-}" = "1" ]; then
  printf '%s' "$COMMENT"
  rm -f "$ARRAY"
  exit 0
fi

PAYLOAD_FILE="$(mktemp)"
printf '%s' "$COMMENT" | jq -Rs '{ content: { raw: . } }' > "$PAYLOAD_FILE"
if [ -n "$EXISTING_ID" ]; then
  echo "Updating existing PR comment ($EXISTING_ID) with new scan + history"
  curl -fsSL -X PUT -H "$AUTH_HDR" -H "Content-Type: application/json" \
    --data @"$PAYLOAD_FILE" "${COMMENTS_API}/${EXISTING_ID}" >/dev/null \
    || echo "Warning: failed to update Upwind PR comment ($EXISTING_ID)"
else
  echo "Posting new summary comment on PR #${BITBUCKET_PR_ID}"
  curl -fsSL -X POST -H "$AUTH_HDR" -H "Content-Type: application/json" \
    --data @"$PAYLOAD_FILE" "${COMMENTS_API}" >/dev/null \
    || echo "Warning: failed to post Upwind PR comment"
fi
rm -f "$PAYLOAD_FILE" "$ARRAY"
