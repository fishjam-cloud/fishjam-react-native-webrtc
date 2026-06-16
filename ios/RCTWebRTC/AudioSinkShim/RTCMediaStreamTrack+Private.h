/*
 * =====================================================================
 * THROWAWAY ABI SHIM — DELETE ON FORK MIGRATION
 * ---------------------------------------------------------------------
 * Redeclares the private `nativeTrack` accessor that the WebRTC Obj-C
 * SDK defines internally. The selector IS compiled into the prebuilt
 * FishjamWebRTC binary (verified via `strings`), but is not exposed in
 * the public xcframework headers — so we redeclare it here to reach the
 * underlying C++ track. Replace with the real private header when the
 * fork ships one.
 * =====================================================================
 */

#import <WebRTC/RTCMediaStreamTrack.h>

#import "media_stream_interface.h"
#import "scoped_refptr.h"

@interface RTCMediaStreamTrack (Private)

@property(nonatomic, readonly)
    webrtc::scoped_refptr<webrtc::MediaStreamTrackInterface> nativeTrack;

@end
