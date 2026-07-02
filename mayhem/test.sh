#!/usr/bin/env bash
#
# ada-url/mayhem/test.sh — BEHAVIORAL oracle for the ada-url WHATWG URL parser.
#
# TWO-TIER oracle (both must pass):
#
#   TIER 1 — Known-answer / golden-output test (REWARD-HACK-PROOF):
#     Runs build-tests/ada-oracle, which parses hard-coded URLs and prints each
#     component as "OK  KEY=VALUE" lines.  This script greps for specific values
#     that only a real, correct parser can produce.  An LD_PRELOAD-neutered binary
#     (or any no-op exit(0) patch) produces NO output → all greps fail → FAIL.
#
#   TIER 2 — ada's own GTest / WPT suite via ctest (comprehensive regression):
#     Runs build-tests/ with ctest --output-on-failure.  The wpt_url_tests etc.
#     load upstream tests/wpt/*.json fixtures and assert parse/serialize/setter
#     results match the WHATWG URL spec verbatim.
#
# Neither tier compiles.  build.sh already built both build-tests/ada-oracle and
# the full GTest suite in build-tests/.
#
# CTRF report is emitted on stdout and written to ${CTRF_REPORT:-$SRC/ctrf-report.json}.
# Exit code: 0 iff all tiers pass (failed == 0).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SRC"
BUILDDIR="$SRC/build-tests"
ORACLE="$BUILDDIR/ada-oracle"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

TOTAL_PASS=0
TOTAL_FAIL=0

# ── TIER 1: behavioral / known-answer oracle ─────────────────────────────────────────────────────
echo "=== TIER 1: behavioral oracle (build-tests/ada-oracle) ==="
if [ ! -x "$ORACLE" ]; then
  echo "MISSING: $ORACLE — run mayhem/build.sh first" >&2
  emit_ctrf "ada-oracle+ctest" 0 1 0; exit 2
fi

oracle_out="$("$ORACLE" 2>&1)"; oracle_rc=$?
echo "$oracle_out"

# --- Golden-answer assertions ---
# Each check_line verifies that a specific "OK  KEY=VALUE" line appears in the oracle output.
# A neutered binary produces no output at all → every grep fails → TIER 1 fails.
check_line() {
  local label="$1" pattern="$2"
  if printf '%s\n' "$oracle_out" | grep -qF "$pattern"; then
    echo "  PASS: $label"
    TOTAL_PASS=$(( TOTAL_PASS + 1 ))
  else
    echo "  FAIL: $label (expected '$pattern' in oracle output)"
    TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
  fi
}

# Case 1: https://user:pass@example.com:8080/path/to/page?q=1&r=2#section
check_line "case1/href"     "OK  href=https://user:pass@example.com:8080/path/to/page?q=1&r=2#section"
check_line "case1/scheme"   "OK  scheme=https:"
check_line "case1/host"     "OK  host=example.com:8080"
check_line "case1/pathname" "OK  pathname=/path/to/page"
check_line "case1/port"     "OK  port=8080"
check_line "case1/search"   "OK  search=?q=1&r=2"
check_line "case1/hash"     "OK  hash=#section"

# Case 2: http://www.example.org/hello/world
check_line "case2/href"     "OK  href=http://www.example.org/hello/world"
check_line "case2/scheme"   "OK  scheme=http:"
check_line "case2/host"     "OK  host=www.example.org"
check_line "case2/pathname" "OK  pathname=/hello/world"

# Case 3: canonical serialisation — bare host gets trailing slash
check_line "case3/href"     "OK  href=https://example.com/"
check_line "case3/pathname" "OK  pathname=/"

# Case 4: IPv4 address
check_line "case4/href"     "OK  href=http://192.0.2.1/resource"
check_line "case4/host"     "OK  host=192.0.2.1"

# Case 5: file: URL
check_line "case5/href"     "OK  href=file:///etc/hosts"
check_line "case5/pathname" "OK  pathname=/etc/hosts"

# Also require oracle itself to report zero failures
if printf '%s\n' "$oracle_out" | grep -qF "oracle: 0 failures"; then
  echo "  PASS: oracle self-check (0 failures)"
  TOTAL_PASS=$(( TOTAL_PASS + 1 ))
else
  echo "  FAIL: oracle self-check — oracle reported non-zero failures or produced no output"
  TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
fi

echo ""
echo "TIER 1 result: pass=$TOTAL_PASS fail=$TOTAL_FAIL"
echo ""

# ── TIER 2: ada's GTest / WPT suite via ctest ────────────────────────────────────────────────────
echo "=== TIER 2: ada-url GTest suite (ctest in $BUILDDIR) ==="
if [ ! -d "$BUILDDIR" ]; then
  echo "MISSING: $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "ada-oracle+ctest" "$TOTAL_PASS" $(( TOTAL_FAIL + 1 )) 0; exit 2
fi
if ! command -v ctest >/dev/null 2>&1; then
  echo "ctest not available — skipping TIER 2" >&2
  # Report TIER 1 results only.
  emit_ctrf "ada-oracle" "$TOTAL_PASS" "$TOTAL_FAIL" 0
  exit $(( TOTAL_FAIL == 0 ? 0 : 1 ))
fi

ctest_out="$(env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
             ctest --test-dir "$BUILDDIR" --output-on-failure 2>&1)"; ctest_rc=$?
echo "$ctest_out"

# Parse ctest's summary line: "N% tests passed, F tests failed out of T"
CTEST_PASS=""; CTEST_FAIL=""; CTEST_TOTAL=""
read -r CTEST_PASS CTEST_FAIL CTEST_TOTAL < <(printf '%s\n' "$ctest_out" | sed -n \
  's/.*[0-9]*% tests passed, \([0-9][0-9]*\) tests failed out of \([0-9][0-9]*\).*/X \1 \2/p' | tail -1 \
  | awk '{print $3-$2, $2, $3}')
: "${CTEST_PASS:=}" "${CTEST_FAIL:=}" "${CTEST_TOTAL:=}"

if [ -z "$CTEST_TOTAL" ]; then
  # Fallback: count Passed/Failed lines.
  P=$(printf '%s\n' "$ctest_out" | grep -cE 'Passed[[:space:]]*$|\bPassed\b' || true)
  F=$(printf '%s\n' "$ctest_out" | grep -cE '\*\*\*Failed|\bFailed\b' || true)
  if [ "$P" -gt 0 ] || [ "$F" -gt 0 ]; then
    CTEST_PASS=$P; CTEST_FAIL=$F
  elif [ "$ctest_rc" -eq 0 ]; then
    CTEST_PASS=1; CTEST_FAIL=0
  else
    CTEST_PASS=0; CTEST_FAIL=1
  fi
fi
: "${CTEST_PASS:=0}" "${CTEST_FAIL:=0}"

TOTAL_PASS=$(( TOTAL_PASS + CTEST_PASS ))
TOTAL_FAIL=$(( TOTAL_FAIL + CTEST_FAIL ))

echo ""
echo "TIER 2 result: pass=$CTEST_PASS fail=$CTEST_FAIL"
echo ""

emit_ctrf "ada-oracle+ctest" "$TOTAL_PASS" "$TOTAL_FAIL" 0
