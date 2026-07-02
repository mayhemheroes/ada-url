#!/usr/bin/env bash
#
# ada-url/mayhem/build.sh — build ada-url's eight OSS-Fuzz harnesses as sanitized libFuzzer
# targets (+ standalone reproducers), AND ada-url's own CMake/GTest test suite for mayhem/test.sh.
#
# ada is the WHATWG URL parser. The harnesses #include the amalgamated single-header build
# (build/singleheader/{ada.cpp,ada.h}) directly, so the parser code itself is compiled with
# $SANITIZER_FLAGS (ASan+UBSan, halting) — not just the harness shim.
#
#   parse              — ada::parse<ada::url> / <ada::url_aggregator> on a URL + base, then
#                        exercises every getter/setter/predicate on the parsed objects.
#   can_parse          — ada::can_parse vs ada::parse consistency (with/without a base URL).
#   idna               — ada::idna::{to_ascii,to_unicode,punycode_*,utf8<->utf32} round-trips.
#   url_search_params  — ada::url_search_params construct/get/set/append/sort/iterate.
#   url_pattern        — ada::parse_url_pattern + match/exec (std_regex_provider; UNSAFE flag set
#                        exactly as upstream's fuzz/build.sh requires for url_pattern).
#   ada_c              — the C API (ada_parse/ada_set_* …) over the amalgamated ada.cpp + fuzz/ada_c.c.
#   serializers        — ada::serializers::{ipv4,ipv6} + checkers::try_parse_ipv4_fast + percent-encode.
#   unicode            — ada::unicode / ada::checkers per-codepoint classifiers.
#
# The fuzzed input is an FDP-decoded URL/host/pattern string (plus a base URL for several harnesses).
#
# Build contract comes from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/
# STANDALONE_FUZZ_MAIN/$OUT. Outputs land in $OUT (=/mayhem). C++20 throughout.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# Ensure the compiled TUs (both the harness AND the library code they include) are instrumented
# for SanitizerCoverage so Mayhem can observe edges.  The base image ships SANITIZER_FLAGS with
# only -fsanitize=address,undefined; without -fsanitize=fuzzer-no-link the object files carry no
# __sanitizer_cov_trace_pc_guard call sites and Mayhem sees 0 edges on every run.
# Skip when SANITIZER_FLAGS is empty (the "no sanitizers at all" build-arg override).
if [ -n "${SANITIZER_FLAGS}" ] && \
   ! echo "${SANITIZER_FLAGS}" | grep -q 'fuzzer'; then
  SANITIZER_FLAGS="${SANITIZER_FLAGS} -fsanitize=fuzzer-no-link"
fi
# DEBUG_FLAGS: force DWARF ≤ 3 so Mayhem's triage can read symbols (clang-19 defaults to DWARF-5).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE OUT MAYHEM_JOBS

# SRC = the baked repo root (this script lives in $SRC/mayhem/).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SRC"
export SRC

STD="-std=c++20"
INC="-I build/singleheader"
HARNESS_DIR="$SRC/mayhem/harnesses"

# ── 1) Amalgamate the single-header build (ada.cpp / ada.h / ada_c.h) the harnesses include ───────
rm -rf build/singleheader
mkdir -p build/singleheader
AMALGAMATE_OUTPUT_PATH="$SRC/build/singleheader" python3 singleheader/amalgamate.py

# Standalone main: compiled once, linked (instead of $LIB_FUZZING_ENGINE) into each *-standalone.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD -c "$HARNESS_DIR/standalone_main.cc" -o build/standalone_main.o

# build_one <name> <objects...> : link a libFuzzer target + a standalone reproducer.
build_one() {
  local name="$1"; shift
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$@" -o "$OUT/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS build/standalone_main.o "$@" -o "$OUT/$name-standalone"
  echo "built $name (+ standalone)"
}

# ── 2) The C++ harnesses that include ada.cpp directly ─────────────────────────────────────────────
# url_pattern needs ADA_USE_UNSAFE_STD_REGEX_PROVIDER=1 (upstream fuzz/build.sh does this; the
# std_regex provider is the only one the fuzzer can drive).
#
# serializers is compiled from mayhem/harnesses/serializers.cc (NOT fuzz/serializers.cc): the
# upstream harness encodes two FALSE invariants that abort on valid inputs (0 edges + 2 spurious
# defects in Mayhem) — percent_encode∘percent_decode treated as an identity (it is not, since
# percent_decode collapses pre-existing %XX in the source) and is_normalized_windows_drive_letter
# treated as a subset of is_windows_drive_letter (they are independent predicates). Our additive
# copy drops those two false-positive aborts while still driving the same serializer/encoder/checker
# code paths. We keep upstream fuzz/serializers.cc untouched (the edit would break additive replay).
for h in parse can_parse idna url_search_params unicode; do
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC -c "fuzz/$h.cc" -o "build/$h.o"
  build_one "$h" "build/$h.o"
done

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC -c "$HARNESS_DIR/serializers.cc" -o "build/serializers.o"
build_one "serializers" "build/serializers.o"

$CXX -DADA_USE_UNSAFE_STD_REGEX_PROVIDER=1 $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC \
     -c fuzz/url_pattern.cc -o build/url_pattern.o
build_one "url_pattern" "build/url_pattern.o"

# ── 3) ada_c: the C harness over the amalgamated C++ object + the C API shim ──────────────────────
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC -c build/singleheader/ada.cpp -o build/ada.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS      $INC -c fuzz/ada_c.c               -o build/ada_c.o
build_one "ada_c" "build/ada.o" "build/ada_c.o"

# ── 4) Ship the libFuzzer dictionary alongside the targets (Mayhemfiles point at mayhem/<h>.dict). ─
#       url.dict is the upstream-curated URL keyword dictionary, shared by every harness.
echo "built all harnesses into $OUT"

# ── 5) Build ada's OWN GTest test suite with NORMAL flags (clean tree) so test.sh only RUNS it. ───
#       -DADA_TESTING=True pulls GTest + simdjson via CPM and builds the wpt-driven unit tests.
#       env -u CFLAGS/CXXFLAGS/SANITIZER_FLAGS keeps test.sh an honest patch oracle (no sanitizer
#       noise, no benign-UB halts in golden-output comparisons).
if command -v cmake >/dev/null 2>&1; then
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    cmake -S "$SRC" -B "$SRC/build-tests" -DADA_TESTING=ON -DCMAKE_BUILD_TYPE=Release
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS"
  echo "built ada-url GTest suite in build-tests/"
else
  echo "WARNING: cmake not found — test suite not built (mayhem/test.sh will fail loudly)" >&2
fi

# ── 6) Behavioral oracle binary: parses known URLs and prints components to stdout. ────────────────
#       test.sh greps the output for exact values — a neutered binary (or any parser change) fails it.
#       Compiled with NORMAL flags (no sanitizers, no fuzzer); single-header build reused from step 1.
mkdir -p "$SRC/build-tests"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  $CXX -std=c++20 -O2 -I build/singleheader \
       "$HARNESS_DIR/oracle.cpp" -o "$SRC/build-tests/ada-oracle"
echo "built behavioral oracle: build-tests/ada-oracle"

echo "build.sh complete:"
ls -la "$OUT"/parse "$OUT"/can_parse "$OUT"/idna "$OUT"/url_search_params \
       "$OUT"/url_pattern "$OUT"/ada_c "$OUT"/serializers "$OUT"/unicode 2>&1 || true
