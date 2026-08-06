#!/usr/bin/env bash
# Compiles the real MQL5 core headers with a C++ compiler and runs the
# violation scenario suite. No MetaTrader installation required.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/propguard-tests"
mkdir -p "$OUT"
CXXFLAGS="-std=c++17 -Wall -Wextra -Wno-unused-parameter -I MQL5/Include -I tests"
echo "building..."
g++ $CXXFLAGS -o "$OUT/smoke"     tests/smoke.cpp
g++ $CXXFLAGS -o "$OUT/scenarios" tests/scenarios.cpp
"$OUT/smoke" >/dev/null
exec "$OUT/scenarios"
