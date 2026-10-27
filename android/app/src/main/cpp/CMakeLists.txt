cmake_minimum_required(VERSION 3.22.1)
project(headroom LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Repo root: android/app/src/main/cpp → ../../../../..
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(NAM_ROOT "${REPO_ROOT}/ThirdParty/NeuralAmpModelerCore")

file(GLOB NAM_SOURCES "${NAM_ROOT}/NAM/*.cpp" "${NAM_ROOT}/NAM/wavenet/*.cpp")

add_library(headroom SHARED
    jni.cpp
    Engine.cpp
    AudioIO.cpp
    dsp/NamModel.cpp
    ${NAM_SOURCES})

target_include_directories(headroom PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${NAM_ROOT}/NAM
    ${NAM_ROOT}/Dependencies/nlohmann)
target_include_directories(headroom SYSTEM PRIVATE ${NAM_ROOT}/Dependencies/eigen)

# NAM is ~40× slower unoptimized — always optimize, even in debug builds (same rule as iOS).
target_compile_definitions(headroom PRIVATE NAM_SAMPLE_FLOAT=1 EIGEN_MPL2_ONLY)
target_compile_options(headroom PRIVATE -O3 -fexceptions -frtti -Wno-deprecated-declarations)

find_package(oboe REQUIRED CONFIG)
target_link_libraries(headroom oboe::oboe log android)
target_link_options(headroom PRIVATE "-Wl,-z,max-page-size=16384")
