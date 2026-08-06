#!/usr/bin/env bash
# Compiles the real MQL5 core headers with a C++ compiler and runs the
# violation scenario suite, then statically checks the MetaTrader-only
# sources that cannot be compiled here. No MetaTrader install required.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/propguard-tests"
mkdir -p "$OUT"
CXXFLAGS="-std=c++17 -Wall -Wextra -Wno-unused-parameter -I MQL5/Include -I tests"

echo "== building core =="
g++ $CXXFLAGS -o "$OUT/smoke"     tests/smoke.cpp
g++ $CXXFLAGS -o "$OUT/scenarios" tests/scenarios.cpp
"$OUT/smoke" >/dev/null

echo "== linting MetaTrader sources =="
python3 tests/lint_mql5.py

"$OUT/scenarios"
