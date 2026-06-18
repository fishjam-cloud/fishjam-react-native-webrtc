// Phase-2 placeholder for libfishjam-webrtc-audio.
//
// This exists only to give the shared library a real exported symbol so the
// NDK/CMake toolchain + RN prefab wiring can be proven end-to-end before any
// JSI / audio logic lands. It is replaced by the fbjni HybridClass installer
// (FJAudioSinkInstaller) in Phase 3.

#include <jni.h>

extern "C" JNIEXPORT void JNICALL
Java_com_oney_WebRTCModule_FJAudioSinkInstaller_noop(JNIEnv *, jclass) {}
