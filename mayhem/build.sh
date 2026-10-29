#!/usr/bin/env bash
#
# mayhem/build.sh — build jansson three ways, all under build/ (gitignored upstream as /build):
#   build/san    sanitized libjansson.a (ASan+UBSan, DWARF 3) linked into the three OSS-Fuzz harnesses
#   build/tests  normal-flags build of upstream's CMake test suite, run by mayhem/test.sh
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) sanitized library; fuzzer-no-link adds libFuzzer's coverage instrumentation so the library's
#    edges (not just the harness's) are visible to the fuzzer.
cmake -S . -B build/san -G Ninja \
    -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    -DJANSSON_BUILD_SHARED_LIBS=OFF -DJANSSON_WITHOUT_TESTS=ON \
    -DJANSSON_EXAMPLES=OFF -DJANSSON_BUILD_DOCS=OFF -DJANSSON_INSTALL=OFF
cmake --build build/san -j"$MAYHEM_JOBS"

LIB="$SRC/build/san/lib/libjansson.a"
INC="-I$SRC/build/san/include -I$SRC/src"
[ -f "$LIB" ] || { echo "missing $LIB" >&2; ls -R build/san | head -40 >&2; exit 1; }

# 2) harnesses (fuzzer + standalone reproducer), upstream's OSS-Fuzz sources
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o
for h in json_load_dump_fuzzer json_pack_unpack_fuzzer json_equal_copy_fuzzer; do
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $INC \
        "$SRC/test/ossfuzz/$h.cc" build/lsan_off.o "$LIB" -o "/mayhem/$h"
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
        "$SRC/test/ossfuzz/$h.cc" build/standalone_main.o build/lsan_off.o "$LIB" -o "/mayhem/$h-standalone"
done

# 3) upstream test suite, normal flags
cmake -S . -B build/tests -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
    -DJANSSON_BUILD_SHARED_LIBS=OFF -DJANSSON_WITHOUT_TESTS=OFF \
    -DJANSSON_EXAMPLES=OFF -DJANSSON_BUILD_DOCS=OFF -DJANSSON_INSTALL=OFF
cmake --build build/tests -j"$MAYHEM_JOBS"
