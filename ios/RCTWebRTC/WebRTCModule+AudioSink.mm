#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <React/RCTLog.h>

#import "WebRTCModule.h"
#import "WebRTCModule+RTCMediaStream.h"

// Single entry point to the throwaway WebRTC ABI shim (see AudioSinkShim/).
// This is the ONLY shim header the feature code touches.
#import "AudioSinkShim/NativeAudioTrackBridge.h"

#include <map>
#include <string>

#pragma mark - Native audio sink

namespace {

// Receives raw PCM from a remote WebRTC audio track on a WebRTC worker thread.
// Phase 1: log only. Phase 2 will batch + forward frames to JS.
class AudioFrameSink : public webrtc::AudioTrackSinkInterface {
 public:
  explicit AudioFrameSink(NSString *trackId) : trackId_(trackId) {}

  void OnData(const void *audio_data,
              int bits_per_sample,
              int sample_rate,
              size_t number_of_channels,
              size_t number_of_frames) override {
    // Throttle logging so we don't flood — print ~once per second.
    if ((++callbackCount_ % 100) == 0) {
      RCTLogInfo(@"[AudioSink] track=%@ frames=%zu channels=%zu bits=%d rate=%d "
                 @"(callbacks=%llu)",
                 trackId_, number_of_frames, number_of_channels,
                 bits_per_sample, sample_rate, callbackCount_);
    }
  }

 private:
  NSString *trackId_;
  unsigned long long callbackCount_ = 0;
};

}  // namespace

#pragma mark - WebRTCModule (AudioSink)

@implementation WebRTCModule (AudioSink)

// trackId (NSString) -> AudioFrameSink* wrapped in NSValue.
// Stored as an associated object so the category needs no ivar.
- (NSMutableDictionary<NSString *, NSValue *> *)audioSinks {
  static const void *kAudioSinksKey = &kAudioSinksKey;
  NSMutableDictionary *sinks = objc_getAssociatedObject(self, kAudioSinksKey);
  if (sinks == nil) {
    sinks = [NSMutableDictionary new];
    objc_setAssociatedObject(self, kAudioSinksKey, sinks,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return sinks;
}

RCT_EXPORT_METHOD(startAudioExtraction
                  : (nonnull NSNumber *)pcId trackId
                  : (nonnull NSString *)trackId) {
  RTCMediaStreamTrack *track = [self trackForId:trackId pcId:pcId];
  if (track == nil) {
    RCTLogWarn(@"[AudioSink] startAudioExtraction: no track for id %@ (pc %@)",
               trackId, pcId);
    return;
  }
  if (![track.kind isEqualToString:@"audio"]) {
    RCTLogWarn(@"[AudioSink] startAudioExtraction: track %@ is not audio", trackId);
    return;
  }

  NSMutableDictionary<NSString *, NSValue *> *sinks = [self audioSinks];
  if (sinks[trackId] != nil) {
    RCTLogInfo(@"[AudioSink] startAudioExtraction: already extracting %@", trackId);
    return;
  }

  webrtc::AudioTrackInterface *nativeAudioTrack = FJNativeAudioTrack(track);
  if (nativeAudioTrack == nullptr) {
    RCTLogWarn(@"[AudioSink] startAudioExtraction: no native track for %@", trackId);
    return;
  }

  AudioFrameSink *sink = new AudioFrameSink(trackId);
  nativeAudioTrack->AddSink(sink);
  sinks[trackId] = [NSValue valueWithPointer:sink];
  RCTLogInfo(@"[AudioSink] startAudioExtraction: attached sink to %@", trackId);
}

RCT_EXPORT_METHOD(stopAudioExtraction
                  : (nonnull NSNumber *)pcId trackId
                  : (nonnull NSString *)trackId) {
  NSMutableDictionary<NSString *, NSValue *> *sinks = [self audioSinks];
  NSValue *boxed = sinks[trackId];
  if (boxed == nil) {
    return;
  }
  [sinks removeObjectForKey:trackId];

  AudioFrameSink *sink = static_cast<AudioFrameSink *>([boxed pointerValue]);

  // Detach from the track before deleting to avoid a dangling sink callback.
  RTCMediaStreamTrack *track = [self trackForId:trackId pcId:pcId];
  webrtc::AudioTrackInterface *nativeAudioTrack = FJNativeAudioTrack(track);
  if (nativeAudioTrack != nullptr) {
    nativeAudioTrack->RemoveSink(sink);
  }
  delete sink;
  RCTLogInfo(@"[AudioSink] stopAudioExtraction: detached sink from %@", trackId);
}

@end
