#!/usr/bin/env bash
#
# mayhem/build.sh — builds the QtPass libFuzzer harnesses (sanitized static library + harness) and the
# project's own Qt Test suites (normal flags). Runs in the commit image as `mayhem` in /mayhem.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${QMAKE:=qmake6}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Test names: every suite here is headless and deterministic (no gpg/pass binary, no network).
TESTS="base32 totp filecontent gpgidgeneration gpgkeystate userinfo"

# 1) The sanitized static library (src/src.pro), built in the gitignored build/ tree. -O1 keeps the
#    fuzzers fast; CONFIG+=debug keeps Q_ASSERT live while fuzzing.
fz="$SRC/build/fuzz"
mkdir -p "$fz"
(
	cd "$fz"
	# $SANITIZER_FLAGS / $DEBUG_FLAGS are flag lists, split on purpose.
	"$QMAKE" "$SRC/src/src.pro" -spec linux-clang \
		QMAKE_CC="$CC" QMAKE_CXX="$CXX" QMAKE_LINK="$CXX" \
		QMAKE_CXXFLAGS+="$SANITIZER_FLAGS -O1 $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
		QMAKE_LFLAGS+="$SANITIZER_FLAGS" CONFIG+=debug
	make -j"$MAYHEM_JOBS"
)
lib="$(find "$fz" -name libqtpass.a -print -quit)"

qt_headers="$("$QMAKE" -query QT_INSTALL_HEADERS)"
qt_libs="$("$QMAKE" -query QT_INSTALL_LIBS)"

# Leak detection off at build time (ASan stays on): a one-symbol TU linked into every binary.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$fz/lsan_off.o"
# The run-once driver is C: compile it as C so its LLVMFuzzerTestOneInput reference isn't mangled.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$fz/standalone_main.o"

for name in fuzz_filecontent fuzz_gpgcolon fuzz_gpgid fuzz_totp; do
	harness="$SRC/tests/fuzz/$name.cpp"
	common=(-std=c++17 -fPIC -I"$SRC/src" -I"$fz" -I"$qt_headers" -I"$qt_headers/QtCore")
	libs=(-Wl,--as-needed -L"$qt_libs" -lQt6Core -Wl,-rpath,"$qt_libs")
	# shellcheck disable=SC2086
	$CXX $SANITIZER_FLAGS -O1 $DEBUG_FLAGS "${common[@]}" "$harness" "$fz/lsan_off.o" "$lib" \
		$LIB_FUZZING_ENGINE "${libs[@]}" -o "$SRC/$name"
	# shellcheck disable=SC2086
	$CXX $SANITIZER_FLAGS -O1 $DEBUG_FLAGS "${common[@]}" "$harness" "$fz/lsan_off.o" "$fz/standalone_main.o" \
		"$lib" "${libs[@]}" -o "$SRC/$name-standalone"
done

# 2) The project's own Qt Test suites with NORMAL flags (clean, independent build; no sanitizers).
tb="$SRC/build/tests"
mkdir -p "$tb"
(
	cd "$tb"
	"$QMAKE" "$SRC/qtpass.pro" -spec linux-clang CONFIG+=debug \
		QMAKE_CXXFLAGS+="$COVERAGE_FLAGS" QMAKE_LFLAGS+="$COVERAGE_FLAGS"
	make qmake_all
	make -j"$MAYHEM_JOBS" -C src
	for t in $TESTS; do
		make -j"$MAYHEM_JOBS" -C "tests/auto/$t"
	done
)
