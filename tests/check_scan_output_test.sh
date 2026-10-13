#!/usr/bin/env bash
# Exercises scripts/check_scan_output.sh: the post-scan guard that decides whether
# the CLI actually produced a result, and whether the step must fail because of it.
# Invoked through bash, as action.yml does, so the exec bit is not relied on.
set -uo pipefail
cd "$(dirname "$0")"
SCRIPT=../scripts/check_scan_output.sh

fail=0
check() {
  local name="$1" fixture="$2" fail_flag="$3" want_exit="$4" want_pattern="$5"
  local out code
  out="$(bash "$SCRIPT" "$fixture" "$fail_flag" 2>&1)"; code=$?
  if [ "$code" -ne "$want_exit" ]; then
    echo "FAIL: $name exit=$code want=$want_exit: $out"; fail=1; return
  fi
  if ! grep -q -- "$want_pattern" <<<"$out"; then
    echo "FAIL: $name output missing '$want_pattern': $out"; fail=1; return
  fi
  echo "ok: $name"
}

check "valid, fail off"          fixtures/valid.json          false 0 "Info: Image scan completed"
check "valid, fail on"           fixtures/valid.json          true  0 "Info: Image scan completed"
check "multi-platform, fail on"  fixtures/multi_platform.json true  0 "Info: Image scan completed"
check "array doc, fail on"       fixtures/array.json          true  1 "::error::"
check "empty, fail off"          fixtures/empty.json          false 0 "::warning::"
check "empty, fail on"           fixtures/empty.json          true  1 "::error::"
check "no image, fail off"       fixtures/no_image.json       false 0 "::warning::"
check "no image, fail on"        fixtures/no_image.json       true  1 "::error::"
check "garbage, fail off"        fixtures/garbage.json        false 0 "::warning::"
check "garbage, fail on"         fixtures/garbage.json        true  1 "::error::"
check "missing file, fail off"   fixtures/does_not_exist.json false 1 "not found"
check "missing file, fail on"    fixtures/does_not_exist.json true  1 "not found"

# Unreadable file: root can read anything, so this case only runs as a regular user.
if [ "$(id -u)" -ne 0 ]; then
  cp fixtures/valid.json unreadable.json && chmod 000 unreadable.json
  check "unreadable, fail on"    unreadable.json              true  0 "::warning::"
  check "unreadable, fail off"   unreadable.json              false 0 "::warning::"
  rm -f unreadable.json
fi

# mktemp-free: the guard must not depend on a writable TMPDIR.
TMPDIR=/nonexistent check "no TMPDIR, fail on" fixtures/empty.json true 1 "::error::"

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAILED"; fi
exit "$fail"
