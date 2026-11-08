#!/usr/bin/env bash
# Prints <value> with $NAME and ${NAME} environment-variable references expanded,
# and leading/trailing whitespace trimmed. Nothing else is expanded: $(...),
# backticks, ${NAME:-default} and other shell syntax stay literal text.
#
# Action inputs used to be pasted into the run: scripts and parsed by bash, so
# values such as `docker_image: app:${GITHUB_SHA}` worked. Inputs now reach the
# shell as data; this keeps those references working without executing anything.
#
# References to INPUT_* variables are left as-is: they hold the action's own
# inputs, including the client secret and registry password.
#
# Usage: expand_env_refs.sh <value>
set -uo pipefail

value="${1-}"
out=""
brace_re='^\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$'
bare_re='^([A-Za-z_][A-Za-z0-9_]*)(.*)$'

while [[ "$value" == *'$'* ]]; do
  out+="${value%%\$*}"
  rest="${value#*\$}"
  if [[ "$rest" =~ $brace_re ]]; then
    name="${BASH_REMATCH[1]}"; ref="\${$name}"; value="${BASH_REMATCH[2]}"
  elif [[ "$rest" =~ $bare_re ]]; then
    name="${BASH_REMATCH[1]}"; ref="\$$name"; value="${BASH_REMATCH[2]}"
  else
    out+='$'; value="$rest"
    continue
  fi
  if [[ "$name" == INPUT_* ]]; then
    out+="$ref"
  else
    out+="${!name-}"
  fi
done
out+="$value"

out="${out#"${out%%[![:space:]]*}"}"
out="${out%"${out##*[![:space:]]}"}"
printf '%s' "$out"
