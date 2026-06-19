cmake_minimum_required(VERSION 3.22.1)

# Shared C++ core lives at <module-root>/common/cpp. From this file
# (android/src/main/cpp) that is four directories up: cpp -> main -> src ->
# android -> <react-native-webrtc root>.
set(FJ_COMMON_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../common/cpp")
get_filename_component(FJ_COMMON_CPP_DIR "${FJ_COMMON_CPP_DIR}" ABSOLUTE)

add_library(fishjam-webrtc-audio
    SHARED
    # Vendored miniaudio (conversion-only).
    "${FJ_COMMON_CPP_DIR}/vendor/miniaudio.c"
    # Shared JSI core (CallInvoker-driven global install + deliver).
    "${FJ_COMMON_CPP_DIR}/fishjam-audio/FJAudioSinkJSI.cpp"
    # fbjni HybridClass that installs the JS global over the CallInvoker.
    "${CMAKE_CURRENT_SOURCE_DIR}/FJAudioSinkInstaller.cpp"
)

# miniaudio must be built conversion-only. These MA_NO_* defines must be
# identical across every translation unit that includes miniaudio.h (miniaudio
# is not ABI-compatible across differing configs) — see the iOS podspec, which
# sets them globally. We therefore set them target-wide rather than per-source
# so the Phase-3 JSI core inherits the same config automatically.
target_compile_definitions(fishjam-webrtc-audio
    PRIVATE
    MA_NO_DEVICE_IO=1
    MA_NO_DECODING=1
    MA_NO_ENCODING=1
    MA_NO_GENERATION=1
    MA_NO_RESOURCE_MANAGER=1
    MA_NO_NODE_GRAPH=1
)

set_target_properties(fishjam-webrtc-audio PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

target_include_directories(fishjam-webrtc-audio
    PRIVATE
    "${FJ_COMMON_CPP_DIR}/vendor"
    "${FJ_COMMON_CPP_DIR}/fishjam-audio"
)

# RN 0.81 prefab packages.
find_package(ReactAndroid REQUIRED CONFIG)
find_package(fbjni REQUIRED CONFIG)

target_link_libraries(fishjam-webrtc-audio
    ReactAndroid::jsi
    ReactAndroid::reactnative
    fbjni::fbjni
    android
    log
)
