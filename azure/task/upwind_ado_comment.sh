#!/usr/bin/env bash
# Post/update the "Upwind Image Scan Report" thread on an Azure DevOps PR.
# Port of the Bitbucket upwind_bb_comment.sh to the Azure DevOps Git
# pull-request threads API: a sticky per-PR thread with
# introduced/resolved/existing findings + a hidden scan-history blob.
#
# Azure DevOps-specific design:
#   - Markers are HTML comments (`<!-- ... -->`, as in the GitHub/GitLab
#     flavours): ADO renders them invisibly and they round-trip verbatim.
#   - <details>/<summary>/<br> render in ADO markdown, so the GitHub-style
#     collapsible layout is used. Hard comment limit is 150,000 chars.
#   - The thread list is a single GET ({count, value}); no pagination.
#   - Comment payloads are flat {content: ...}.
#   - The report thread is kept `closed` (it is informational, not a review
#     item); editing a comment reactivates a thread, so it is re-closed.
#
# Env in:
#   UPWIND_COMMENT_TOKEN  bearer token allowed to write PR threads
#   OUTPUT_JSON           path to `shiftleft image --output-json`
#   UPWIND_URI            e.g. upwind.io / upwind.dev (for the Console link)
#   SCAN_DURATION_HUMAN   optional, e.g. "38s" / "1m 4s"
#   COMMIT_SHA            optional, the commit the scan is attributed to
#                         (default BUILD_SOURCEVERSION)
#   MAIN_BRANCH           optional, the branch the scan is diffed against
#                         (default SYSTEM_PULLREQUEST_TARGETBRANCH)
#   SYSTEM_TEAMFOUNDATIONCOLLECTIONURI, SYSTEM_TEAMPROJECT,
#   BUILD_REPOSITORY_NAME, SYSTEM_PULLREQUEST_PULLREQUESTID,
#   BUILD_SOURCEVERSION, SYSTEM_PULLREQUEST_TARGETBRANCH
#     (Azure Pipelines predefined)
# Test seams:
#   UPWIND_ADO_DRY_RUN=1  print the final body to stdout, no network
#   ADO_API_BASE          default ${SYSTEM_TEAMFOUNDATIONCOLLECTIONURI%/}
#
# Exit contract: exits 0 on every non-bug path (API failures print
# "Warning:"); nonzero only when OUTPUT_JSON is missing.
set -eu

COMMENT_MARKER='<!-- upwind-image-scan-report -->'
HISTORY_PREFIX='<!-- upwind-scan-history:'
HISTORY_MAX_ENTRIES=30
MAX_ROWS=60
# ADO rejects comments over 150,000 chars; keep a ~10% margin.
ADO_SIZE_CAP=135000

MAIN_BRANCH="${MAIN_BRANCH-${SYSTEM_PULLREQUEST_TARGETBRANCH:-}}"
COMMIT_SHA="${COMMIT_SHA:-${BUILD_SOURCEVERSION:-}}"
COLLECTION="${SYSTEM_TEAMFOUNDATIONCOLLECTIONURI:-}"
COLLECTION="${COLLECTION%/}"
# Project / repository names may contain spaces; encode them for URLs.
PROJECT_ENC=$(printf '%s' "${SYSTEM_TEAMPROJECT:-}" | jq -sRr @uri)
REPO_ENC=$(printf '%s' "${BUILD_REPOSITORY_NAME:-}" | jq -sRr @uri)
COMMIT_URL="${COLLECTION}/${PROJECT_ENC}/_git/${REPO_ENC}/commit/${COMMIT_SHA}"
SCANNED_AT="$(date -u '+%Y-%m-%d %H:%M UTC')"

if [ ! -f "${OUTPUT_JSON:-}" ]; then
  echo "Error: Output file not found: ${OUTPUT_JSON:-}"
  exit 1
fi

# Normalise the scan output into a JSON array. The CLI writes one JSON object
# per result (NDJSON stream for multi-arch); a hand-fed true JSON array is
# flattened one level so both shapes work.
ARRAY="$(mktemp)"
jq -cs '[.[] | if type=="array" then .[] else . end]' "$OUTPUT_JSON" > "$ARRAY"

if [ "$(jq '[.[] | select((.imageName // "") != "")] | length' "$ARRAY")" -eq 0 ]; then
  echo "Warning: scan results not ready (empty output); skipping comment"
  rm -f "$ARRAY"
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
COMMENT+="**Image:** \`$IMAGE_NAME:$IMAGE_VERSION\`<br>"$'\n\n'

# Collapsible CVE table (capped). Each <details> tag sits on its own line with
# a blank line before the table so ADO's markdown renderer picks the table up.
# $1=cves json $2=summary $3=with_fix ("1") $4=open ("1" renders expanded)
emit_table() {
  local cves_json="$1" summary="$2" with_fix="$3" open="${4:-0}" rows total
  rows=$(echo "$cves_json" | jq -r --argjson max "$MAX_ROWS" '
    [.[]][0:$max][]
    | [ (.cveId // .cveName // "unknown"),
        (.packageName // ""),
        (.packageVersion // ""),
        (.fixedInVersion // "") ]
    | @tsv')
  total=$(echo "$cves_json" | jq 'length')
  if [ "$open" = "1" ]; then
    COMMENT+=$'<details open>\n'
  else
    COMMENT+=$'<details>\n'
  fi
  COMMENT+="<summary>${summary}</summary>"$'\n\n'
  if [ "$with_fix" = "1" ]; then
    COMMENT+=$'| CVE | Package | Version | Fix |\n|---|---|---|---|\n'
  else
    COMMENT+=$'| CVE | Package | Version |\n|---|---|---|\n'
  fi
  while IFS=$'\t' read -r CVE PKG VER FIX; do
    [ -z "${CVE}" ] && CVE="unknown"
    case "$CVE" in
      CVE-*) CVE_CELL="[${CVE}](https://nvd.nist.gov/vuln/detail/${CVE})" ;;
      *)     CVE_CELL="${CVE}" ;;
    esac
    local pkg_cell="-" ver_cell="-" fix_cell="-"
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
  COMMENT+=$'\n</details>\n\n'
}

# Introduced findings for one severity. $5=open ("1" for Critical)
emit_introduced_sev() {
  local intro_json="$1" sev="$2" emoji="$3" label="$4" open="${5:-0}" n sfx
  n=$(echo "$intro_json" | jq --arg s "$sev" '[.[] | select((.severity // "" | ascii_upcase)==$s)] | length')
  [ "$n" -eq 0 ] && return 0
  sfx="s"; if [ "$n" -eq 1 ]; then sfx=""; fi
  emit_table "$(echo "$intro_json" | jq -c --arg s "$sev" '[.[] | select((.severity // "" | ascii_upcase)==$s)]')" \
             "${emoji} ${label} · ${n} finding${sfx}" "1" "$open"
}

while IFS= read -r scan; do
  ARCH=$(echo "$scan" | jq -r '.arch? // ""')
  STATUS=$(echo "$scan" | jq -r '.scanStatus // ""')
  INTRO=$(echo "$scan" | jq -c '.introducedCves // []')
  RESOLVED=$(echo "$scan" | jq -c '.resolvedCves // []')
  PRESENT=$(echo "$scan" | jq -c '(.introducedCves // []) + (.noChangeCves // [])')
  # Empty when the base branch has never been scanned (first-seen image): the
  # scanner has no baseline, so every present CVE is tagged "introduced".
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

  # With no baseline yet, introduced/resolved aren't meaningful (everything is
  # tagged introduced) - report the full inventory instead.
  if [ -n "$MAIN_BRANCH" ] && [ -z "$COMPARE_TO" ]; then
    tvword="vulnerabilities"; if [ "$T" -eq 1 ]; then tvword="vulnerability"; fi
    COMMENT+="**${T}** total ${tvword} · no baseline scan for ${BASE_LABEL} yet - showing full inventory (introduced/resolved vs ${BASE_LABEL} will appear once it has been scanned)"$'\n'
  else
    ivword="vulnerabilities"; if [ "$N" -eq 1 ]; then ivword="vulnerability"; fi
    COMMENT+="**${N}** newly introduced ${ivword} · **${R}** resolved · **${T}** total in this PR vs ${BASE_LABEL}"$'\n'
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

  # Detail tables: introduced (by severity) + resolved only; already-present
  # CVEs are counted above, not listed. Critical opens expanded.
  emit_introduced_sev "$INTRO" "CRITICAL" "🔴" "Critical" "1"
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
  COMMENT+="[View full analysis in Upwind Console →](https://console.${UPWIND_URI:-upwind.io}/?redirectToCodeScanId=${FINGERPRINT})"$'\n\n'
fi
if [ -n "${SCAN_DURATION_HUMAN:-}" ]; then
  # Blank line after: a text line directly above the history rule's `---`
  # would render as a setext heading.
  COMMENT+="_Scan completed in ${SCAN_DURATION_HUMAN}_"$'\n\n'
fi

# --- Sticky thread + scan history (Azure DevOps Git PR threads API) ---
ADO_API_BASE="${ADO_API_BASE:-$COLLECTION}"
AUTH_HDR="Authorization: Bearer ${UPWIND_COMMENT_TOKEN:-}"
THREADS_BASE="${ADO_API_BASE}/${PROJECT_ENC}/_apis/git/repositories/${REPO_ENC}/pullRequests/${SYSTEM_PULLREQUEST_PULLREQUESTID:-}/threads"
API_VER="api-version=7.1"

EXISTING_TID=""
EXISTING_CID=""
PRIOR_HISTORY="[]"
if [ "${UPWIND_ADO_DRY_RUN:-}" != "1" ]; then
  # One GET returns every thread of the PR. Match = first non-deleted thread
  # whose first non-deleted comment carries the marker.
  # curl -f only fails on 4xx/5xx; ADO answers some bad credentials with a 2xx
  # HTML sign-in page, so also require a JSON body with a `value` array before
  # matching (comparing the printed type keeps this independent of how a given
  # jq version reports parse errors).
  MATCH=""
  if THREADS_JSON=$(curl -fsSL -H "$AUTH_HDR" "${THREADS_BASE}?${API_VER}" 2>/dev/null) \
     && [ "$(echo "$THREADS_JSON" | jq -r '.value | type' 2>/dev/null)" = "array" ]; then
    MATCH=$(echo "$THREADS_JSON" | jq -c --arg m "$COMMENT_MARKER" '
      [ .value[]
        | select((.isDeleted // false) | not)
        | . as $t
        | ([ ($t.comments // [])[] | select((.isDeleted // false) | not) ] | .[0]) as $c
        | select($c != null and (($c.content // "") | contains($m)))
        | {tid: $t.id, cid: $c.id, content: $c.content} ]
      | .[0] // empty' 2>/dev/null) || MATCH=""
  else
    echo "Warning: could not list PR threads; posting a new report thread"
  fi
  if [ -n "$MATCH" ]; then
    EXISTING_TID=$(echo "$MATCH" | jq -r '.tid')
    EXISTING_CID=$(echo "$MATCH" | jq -r '.cid')
    # Only a line consisting solely of the hidden-state blob counts, and the
    # LAST such line wins: visible content (e.g. a package name) can embed
    # the pattern mid-line but cannot forge a standalone trailing line.
    PRIOR_B64=$(echo "$MATCH" | jq -r '.content' | tr -d '\r' \
      | sed -n "s/^${HISTORY_PREFIX}\([A-Za-z0-9+/=]*\) -->\$/\1/p" | tail -n1)
    if [ -n "$PRIOR_B64" ]; then
      DECODED=$(printf '%s' "$PRIOR_B64" | base64 -d 2>/dev/null || echo "")
      if echo "$DECODED" | jq -e 'type=="array"' >/dev/null 2>&1; then
        PRIOR_HISTORY="$DECODED"
      fi
    fi
  fi
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
  "---\n\n<details>\n<summary>Scan history (\($n) \($noun))</summary>\n\n"
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
  + "\n\n</details>\n\n"
  + (.[-1] | "_Last scanned: [`\(.sha[0:7])`](\(.url)) · \(.ts)_\n")
')

COMMENT+="$HISTORY_MD"

# Hidden state blob: source of truth for the next run.
HISTORY_B64=$(printf '%s' "$HISTORY_JSON" | base64 | tr -d '\n')
HIDDEN_STATE=$'\n'"${HISTORY_PREFIX}${HISTORY_B64} -->"$'\n'

# Truncate the visible body only, keeping the hidden state intact (the next
# run reads it). Close any <details> the cut left open, or the notice and
# everything after it would be swallowed by the collapsed section.
CAP=$((ADO_SIZE_CAP - ${#HIDDEN_STATE}))
if [ "${#COMMENT}" -gt "$CAP" ]; then
  COMMENT="${COMMENT:0:$((CAP - 500))}"
  COMMENT="${COMMENT%$'\n'*}"
  OPEN_TAGS=$(grep -c '^<details' <<< "$COMMENT" || true)
  CLOSE_TAGS=$(grep -c '^</details>' <<< "$COMMENT" || true)
  while [ "$OPEN_TAGS" -gt "$CLOSE_TAGS" ]; do
    COMMENT+=$'\n</details>'
    CLOSE_TAGS=$((CLOSE_TAGS + 1))
  done
  COMMENT+=$'\n\n_Comment truncated to fit Azure DevOps\'s size limit - see the Upwind Console._'
fi
COMMENT+="$HIDDEN_STATE"

if [ "${UPWIND_ADO_DRY_RUN:-}" = "1" ]; then
  printf '%s' "$COMMENT"
  rm -f "$ARRAY"
  exit 0
fi

# Send bodies via files, never as shell arguments.
PAYLOAD_FILE="$(mktemp)"
if [ -n "$EXISTING_TID" ]; then
  echo "Updating existing PR thread ($EXISTING_TID) with new scan + history"
  printf '%s' "$COMMENT" | jq -Rs '{ content: . }' > "$PAYLOAD_FILE"
  # curl -f only catches 4xx/5xx; a 2xx HTML body (e.g. a sign-in page) must
  # not count as success, so also require a JSON body carrying an `id`.
  if RESP=$(curl -fsSL -X PATCH -H "$AUTH_HDR" -H "Content-Type: application/json" \
       --data @"$PAYLOAD_FILE" \
       "${THREADS_BASE}/${EXISTING_TID}/comments/${EXISTING_CID}?${API_VER}"); then
    if echo "$RESP" | jq -e '.id' >/dev/null 2>&1; then
      # Editing a comment reactivates its thread; keep the report closed.
      curl -fsSL -X PATCH -H "$AUTH_HDR" -H "Content-Type: application/json" \
        --data '{"status":"closed"}' \
        "${THREADS_BASE}/${EXISTING_TID}?${API_VER}" >/dev/null \
        || echo "Warning: failed to re-close Upwind PR thread ($EXISTING_TID)"
    else
      echo "Warning: unexpected response updating Upwind PR comment (thread $EXISTING_TID); the report may not have been updated"
    fi
  else
    echo "Warning: failed to update Upwind PR comment (thread $EXISTING_TID)"
  fi
else
  echo "Posting new report thread on PR #${SYSTEM_PULLREQUEST_PULLREQUESTID:-}"
  printf '%s' "$COMMENT" | jq -Rs '{ comments: [ { parentCommentId: 0, content: ., commentType: 1 } ], status: "closed" }' > "$PAYLOAD_FILE"
  if RESP=$(curl -fsSL -X POST -H "$AUTH_HDR" -H "Content-Type: application/json" \
       --data @"$PAYLOAD_FILE" "${THREADS_BASE}?${API_VER}"); then
    echo "$RESP" | jq -e '.id' >/dev/null 2>&1 \
      || echo "Warning: unexpected response posting Upwind PR comment; the report was not posted"
  else
    echo "Warning: failed to post Upwind PR comment"
  fi
fi
rm -f "$PAYLOAD_FILE" "$ARRAY"
