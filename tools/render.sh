#!/bin/zsh
# Build (cached) + run the offline rig renderer. See tools/render.swift.
#   tools/render.sh <model.nam> <in.wav> <out.wav> [--no-gate] [--legacy-level] [--drive dB]
set -e
cd "$(dirname "$0")/.."
NAM=NamRig/NamRig/Engine/NAMCore
DEP=ThirdParty/NeuralAmpModelerCore/Dependencies
OBJ=/tmp/nam_render_obj; BIN=/tmp/nam_render
mkdir -p $OBJ
newest=$(ls -t $NAM/*.cpp $NAM/wavenet/*.cpp NamRig/NamRig/Engine/NAMModel.mm NamRig/NamRig/Blocks.swift NamRig/NamRig/Wah.swift NamRig/NamRig/ReverbAlgorithms.swift tools/render.swift | head -1)
if [ ! -x $BIN ] || [ "$newest" -nt $BIN ]; then
  echo "building renderer…" >&2
  for f in $NAM/*.cpp $NAM/wavenet/*.cpp; do
    o=$OBJ/$(basename ${f%.cpp}).o
    if [ ! -f "$o" ] || [ "$f" -nt "$o" ]; then
      clang++ -std=gnu++20 -O2 -DNAM_SAMPLE_FLOAT=1 -I$NAM -I$DEP/eigen -I$DEP/nlohmann -c "$f" -o "$o"
    fi
  done
  clang++ -std=gnu++20 -O2 -fobjc-arc -DNAM_SAMPLE_FLOAT=1 -INamRig/NamRig/Engine -I$NAM -I$DEP/eigen -I$DEP/nlohmann \
    -c NamRig/NamRig/Engine/NAMModel.mm -o $OBJ/NAMModel.o
  swiftc -O -parse-as-library -default-isolation MainActor \
    -import-objc-header NamRig/NamRig/NamRig-Bridging-Header.h -INamRig/NamRig/Engine \
    tools/render.swift NamRig/NamRig/Blocks.swift NamRig/NamRig/Wah.swift NamRig/NamRig/ReverbAlgorithms.swift \
    $OBJ/*.o -lc++ -framework Foundation -framework Accelerate -framework AVFoundation -o $BIN
fi
exec $BIN "$@"
