#!/bin/bash
# Host-side unit tests for the dependency-free C++ under common/cpp.
# FJAudioFrameScheduler and FJCameraFrameProcessorCore are pure C++20 with no
# JSI/platform includes, so they compile and run on any host toolchain — no NDK
# or Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="${TMPDIR:-/tmp}/fishjam-webrtc-cpp-tests"
mkdir -p "$BUILD_DIR"
CXX="${CXX:-c++}"

"$CXX" -std=c++20 -Wall -Wextra -pthread \
    -I common/cpp/fishjam-audio \
    common/cpp/fishjam-audio/FJAudioFrameScheduler.cpp \
    common/cpp/fishjam-audio/tests/FJAudioFrameSchedulerTest.cpp \
    -o "$BUILD_DIR/FJAudioFrameSchedulerTest"

"$CXX" -std=c++20 -Wall -Wextra -pthread \
    -I common/cpp/fishjam-video \
    common/cpp/fishjam-video/FJCameraFrameProcessorCore.cpp \
    common/cpp/fishjam-video/tests/FJCameraFrameProcessorCoreTest.cpp \
    -o "$BUILD_DIR/FJCameraFrameProcessorCoreTest"

"$BUILD_DIR/FJAudioFrameSchedulerTest"
"$BUILD_DIR/FJCameraFrameProcessorCoreTest"
