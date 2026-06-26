#!/bin/bash
# Headless NAM engine tester — compiles the engine natively and runs every bundled
# example model through it (correctness + performance). No device, no simulator.
#
#   bash tools/run_tests.sh         # -O2 (Release-like, default)
#   bash tools/run_tests.sh -O0     # -O0 (Debug-like) to compare perf
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)/ThirdParty/NeuralAmpModelerCore"
OPT="${1:--O2}"

echo "compiling engine ($OPT)…"
clang++ -std=gnu++20 "$OPT" -DNAM_SAMPLE_FLOAT=1 \
  -I"$ROOT/NAM" -I"$ROOT/Dependencies/eigen" -I"$ROOT/Dependencies/nlohmann" \
  "$HERE/test_engine.cpp" "$ROOT"/NAM/*.cpp "$ROOT"/NAM/wavenet/*.cpp -o /tmp/nam_test

echo
for m in "$ROOT"/example_models/*.nam; do /tmp/nam_test "$m"; echo; done
