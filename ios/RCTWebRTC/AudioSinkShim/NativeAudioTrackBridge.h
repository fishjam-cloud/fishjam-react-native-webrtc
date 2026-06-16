/*
 * =====================================================================
 * MIGRATION BOUNDARY — single entry point to the throwaway ABI shim.
 * ---------------------------------------------------------------------
 * Feature code (WebRTCModule+AudioSink.mm) includes ONLY this header to
 * reach a remote track's underlying native webrtc::AudioTrackInterface.
 * All WebRTC-private / C++-ABI access lives behind it, inside
 * AudioSinkShim/. To migrate to a properly-built WebRTC fork: delete the
 * AudioSinkShim/ folder and reimplement just this header against the
 * real framework headers — the feature code stays untouched.
 *
 * Obj-C++ only (uses webrtc:: types) — import from .mm files.
 * =====================================================================
 */

#ifndef FJ_AUDIOSINKSHIM_NATIVE_AUDIO_TRACK_BRIDGE_H_
#define FJ_AUDIOSINKSHIM_NATIVE_AUDIO_TRACK_BRIDGE_H_

#import <WebRTC/WebRTC.h>

#import "RTCMediaStreamTrack+Private.h"
#import "media_stream_interface.h"
#import "scoped_refptr.h"

// Returns the underlying native webrtc audio track for an
// RTCMediaStreamTrack of kind "audio", or nullptr if unavailable.
// The returned pointer is owned by the track; do not delete it.
static inline webrtc::AudioTrackInterface *FJNativeAudioTrack(
    RTCMediaStreamTrack *track) {
  if (track == nil) {
    return nullptr;
  }
  webrtc::scoped_refptr<webrtc::MediaStreamTrackInterface> native =
      track.nativeTrack;
  return static_cast<webrtc::AudioTrackInterface *>(native.get());
}

#endif  // FJ_AUDIOSINKSHIM_NATIVE_AUDIO_TRACK_BRIDGE_H_
