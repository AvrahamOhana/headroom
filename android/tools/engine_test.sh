#!/bin/zsh
# Host build + run of the Android C++ engine test (no device needed).
#   android/tools/engine_test.sh [model.nam]
set -e
HERE=${0:A:h}
ROOT=$HERE/../..
NAM=$ROOT/ThirdParty/NeuralAmpModelerCore
CPP=$HERE/../app/src/main/cpp
OUT=${TMPDIR:-/tmp}/headroom_engine_test
MODEL=${1:-$ROOT/NamRig/NamRig/Models/Bugera V5.nam}
clang++ -std=c++20 -O2 -DNAM_SAMPLE_FLOAT=1 \
  -I$NAM/NAM -I$NAM/Dependencies/eigen -I$NAM/Dependencies/nlohmann -I$CPP \
  $HERE/engine_test.cpp $CPP/Engine.cpp $CPP/dsp/NamModel.cpp \
  $NAM/NAM/*.cpp $NAM/NAM/wavenet/*.cpp -o $OUT
$OUT "$MODEL"
