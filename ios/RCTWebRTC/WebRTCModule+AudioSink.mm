#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <React/RCTLog.h>

#import "WebRTCModule.h"
#import "WebRTCModule+RTCMediaStream.h"

// Single entry point to the throwaway WebRTC ABI shim (see AudioSinkShim/).
// This is the ONLY shim header the feature code touches.
#import "AudioSinkShim/NativeAudioTrackBridge.h"

#include <cstdint>
#include <vector>

#pragma mark - Native audio sink

namespace {

// Receives raw PCM from a remote WebRTC audio track on a WebRTC worker thread.
// Batches ~100 ms of int16 PCM, then forwards it to JS as a base64 event.
class AudioFrameSink : public webrtc::AudioTrackSinkInterface {
 public:
  AudioFrameSink(__weak WebRTCModule *module, NSNumber *pcId, NSString *trackId)
      : module_(module), pcId_(pcId), trackId_(trackId) {}

  void OnData(const void *audio_data,
              int bits_per_sample,
              int sample_rate,
              size_t number_of_channels,
              size_t number_of_frames) override {
    // POC assumes 16-bit PCM (verified: 48kHz mono int16). Skip anything else.
    if (bits_per_sample != 16 || audio_data == nullptr) {
      return;
    }

    const int16_t *samples = static_cast<const int16_t *>(audio_data);
    const size_t sampleCount = number_of_frames * number_of_channels;
    buffer_.insert(buffer_.end(), samples, samples + sampleCount);

    // Flush roughly every 100 ms of audio (sampleRate/10 frames per channel).
    const size_t framesPerFlush = static_cast<size_t>(sample_rate) / 10;
    const size_t samplesPerFlush = framesPerFlush * number_of_channels;
    if (buffer_.size() < samplesPerFlush) {
      return;
    }

    WebRTCModule *module = module_;
    if (module == nil) {
      buffer_.clear();
      return;
    }

    NSData *pcm = [NSData dataWithBytes:buffer_.data()
                                length:buffer_.size() * sizeof(int16_t)];
    buffer_.clear();

    NSString *base64 = [pcm base64EncodedStringWithOptions:0];
    [module sendEventWithName:kEventAudioTrackData
                         body:@{
                           @"pcId" : pcId_,
                           @"trackId" : trackId_,
                           @"sampleRate" : @(sample_rate),
                           @"channels" : @(number_of_channels),
                           @"data" : base64,
                         }];
  }

 private:
  __weak WebRTCModule *module_;
  NSNumber *pcId_;
  NSString *trackId_;
  std::vector<int16_t> buffer_;
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

  AudioFrameSink *sink = new AudioFrameSink(self, pcId, trackId);
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
