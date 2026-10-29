#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's CMake/ctest suite (built by mayhem/build.sh in build/tests), then
# layer direct known-answer probes on json_process driven from bash. ctest only judges exit codes,
# so under the sabotage shim (every project binary _exit(0)s) it would still pass; the probes compare
# the binary's actual output and therefore fail when the program is neutered.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/build/tests"
JP="$B/bin/json_process"
[ -x "$JP" ] || { echo "missing $JP — mayhem/build.sh must build it" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 1; }
[ -f "$B/CTestTestfile.cmake" ] || { echo "missing ctest tree $B" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 1; }

out=$(cd "$B" && ctest 2>&1); echo "$out" | tail -15
total=$(echo "$out" | sed -n 's/.*tests passed, \([0-9]*\) tests failed out of \([0-9]*\).*/\2/p')
failed=$(echo "$out" | sed -n 's/.*tests passed, \([0-9]*\) tests failed out of \([0-9]*\).*/\1/p')
if [ -z "$total" ] || [ "$total" -lt 100 ]; then
  echo "ctest ran suspiciously few tests (${total:-none})" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 1
fi
passed=$(( total - failed ))

# KAT probes: json_process must parse input and report the exact computed output / error.
kat_fail=0
kat_pass=0
probe() { # name, expected-status, expected-stderr-substring (or ""), dir
  local name="$1" want_rc="$2" want_msg="$3" dir="$4" err rc
  err=$("$JP" "$dir" 2>&1 >/dev/null); rc=$?
  if [ "$rc" -eq "$want_rc" ] && { [ -z "$want_msg" ] || [[ "$err" == *"$want_msg"* ]]; }; then
    kat_pass=$((kat_pass+1))
  else
    echo "KAT $name FAILED: rc=$rc (want $want_rc) stderr=[$err] want-substr=[$want_msg]" >&2
    kat_fail=$((kat_fail+1))
  fi
}

K=$(mktemp -d); trap 'rm -rf "$K"' EXIT
mkdir -p "$K/ok" "$K/wrong" "$K/err"
printf '{"b": [1, 2.5, true, null], "a": "x\\u00e9"}' > "$K/ok/input"
printf '{"b":[1,2.5,true,null],"a":"x\\u00E9"}' > "$K/ok/output"
printf 'JSON_PRESERVE_ORDER=1\nJSON_COMPACT=1\nJSON_ENSURE_ASCII=1\n' > "$K/ok/env"
cp "$K/ok/input" "$K/wrong/input"; printf 'nope' > "$K/wrong/output"; cp "$K/ok/env" "$K/wrong/env"
printf '[1, 2,, 3]' > "$K/err/input"
printf '1 7 7\nunexpected token near '"'"','"'"'\n' > "$K/err/error"

probe ok-roundtrip 0 "" "$K/ok"
probe wrong-output-detected 1 '=== Actual output ===
{"b":[1,2.5,true,null],"a":"x\u00E9"}' "$K/wrong"
probe parse-error-report 0 "" "$K/err"
probe upstream-valid-sorted 0 "" "$SRC/test/suites/valid/complex-array"
probe upstream-invalid-error 0 "" "$SRC/test/suites/invalid/apostrophe"

emit_ctrf "cmake-ctest+kat" $((passed + kat_pass)) $((failed + kat_fail)) 0
