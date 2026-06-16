/*
 *  Copyright 2012 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

// =====================================================================
// THROWAWAY ABI SHIM — DELETE ON FORK MIGRATION
// ---------------------------------------------------------------------
// Trimmed, hand-rolled copy of WebRTC's api/media_stream_interface.h.
// Only the pieces needed to attach an AudioTrackSinkInterface to a
// remote audio track are declared. The class/vtable layout MUST match
// WebRTC 124 (the FishjamWebRTC binary) — do not reorder virtuals.
// We never instantiate AudioTrackInterface/MediaStreamTrackInterface
// (we only static_cast an existing object from the binary and call
// AddSink), so the non-pure leaf virtuals here need no definitions.
// =====================================================================

#ifndef FJ_AUDIOSINKSHIM_MEDIA_STREAM_INTERFACE_H_
#define FJ_AUDIOSINKSHIM_MEDIA_STREAM_INTERFACE_H_

#include <stddef.h>
#include <stdint.h>

#include <optional>
#include <string>

#include "scoped_refptr.h"

namespace rtc {

enum class RefCountReleaseStatus { kDroppedLastRef, kOtherRefsRemained };

// Interfaces where refcounting is part of the public api should inherit
// this abstract interface.
class RefCountInterface {
 public:
  virtual void AddRef() const = 0;
  virtual RefCountReleaseStatus Release() const = 0;

 protected:
  virtual ~RefCountInterface() {}
};

}  // namespace rtc

namespace webrtc {

// Generic observer interface.
class ObserverInterface {
 public:
  virtual void OnChanged() = 0;

 protected:
  virtual ~ObserverInterface() {}
};

class NotifierInterface {
 public:
  virtual void RegisterObserver(ObserverInterface* observer) = 0;
  virtual void UnregisterObserver(ObserverInterface* observer) = 0;

  virtual ~NotifierInterface() {}
};

// Base class for sources.
class MediaSourceInterface : public rtc::RefCountInterface,
                             public NotifierInterface {
 public:
  enum SourceState { kInitializing, kLive, kEnded, kMuted };

  virtual SourceState state() const = 0;
  virtual bool remote() const = 0;

 protected:
  ~MediaSourceInterface() override = default;
};

// C++ version of MediaStreamTrack.
class MediaStreamTrackInterface : public rtc::RefCountInterface,
                                  public NotifierInterface {
 public:
  enum TrackState {
    kLive,
    kEnded,
  };

  static const char kAudioKind[];
  static const char kVideoKind[];

  virtual std::string kind() const = 0;
  virtual std::string id() const = 0;
  virtual bool enabled() const = 0;
  virtual bool set_enabled(bool enable) = 0;
  virtual TrackState state() const = 0;

 protected:
  ~MediaStreamTrackInterface() override = default;
};

// Interface for receiving audio data from an AudioTrack.
class AudioTrackSinkInterface {
 public:
  virtual void OnData(const void* audio_data,
                      int bits_per_sample,
                      int sample_rate,
                      size_t number_of_channels,
                      size_t number_of_frames) {}

  virtual void OnData(const void* audio_data,
                      int bits_per_sample,
                      int sample_rate,
                      size_t number_of_channels,
                      size_t number_of_frames,
                      std::optional<int64_t> absolute_capture_timestamp_ms) {
    return OnData(audio_data, bits_per_sample, sample_rate, number_of_channels,
                  number_of_frames);
  }

  // Number of channels encoded by the sink. -1 means unknown.
  virtual int NumPreferredChannels() const { return -1; }

 protected:
  virtual ~AudioTrackSinkInterface() {}
};

class AudioSourceInterface : public MediaSourceInterface {
 public:
  class AudioObserver {
   public:
    virtual void OnSetVolume(double volume) = 0;

   protected:
    virtual ~AudioObserver() {}
  };

  virtual void SetVolume(double volume) {}

  virtual void RegisterAudioObserver(AudioObserver* observer) {}
  virtual void UnregisterAudioObserver(AudioObserver* observer) {}

  virtual void AddSink(AudioTrackSinkInterface* sink) {}
  virtual void RemoveSink(AudioTrackSinkInterface* sink) {}
};

struct AudioProcessingStats {
  AudioProcessingStats();
  AudioProcessingStats(const AudioProcessingStats& other);
  ~AudioProcessingStats();

  std::optional<bool> voice_detected;
  std::optional<double> echo_return_loss;
  std::optional<double> echo_return_loss_enhancement;
  std::optional<double> divergent_filter_fraction;
  std::optional<int32_t> delay_median_ms;
  std::optional<int32_t> delay_standard_deviation_ms;
  std::optional<double> residual_echo_likelihood;
  std::optional<double> residual_echo_likelihood_recent_max;
  std::optional<int32_t> delay_ms;
};

// Interface of the audio processor used by the audio track to collect stats.
class AudioProcessorInterface : public rtc::RefCountInterface {
 public:
  struct AudioProcessorStatistics {
    bool typing_noise_detected = false;
    AudioProcessingStats apm_statistics;
  };

  virtual AudioProcessorStatistics GetStats(bool has_remote_tracks) = 0;

 protected:
  ~AudioProcessorInterface() override = default;
};

class AudioTrackInterface : public MediaStreamTrackInterface {
 public:
  virtual AudioSourceInterface* GetSource() const = 0;

  // Add/Remove a sink that will receive the audio data from the track.
  virtual void AddSink(AudioTrackSinkInterface* sink) = 0;
  virtual void RemoveSink(AudioTrackSinkInterface* sink) = 0;

  virtual bool GetSignalLevel(int* level);

  virtual rtc::scoped_refptr<AudioProcessorInterface> GetAudioProcessor();

 protected:
  ~AudioTrackInterface() override = default;
};

}  // namespace webrtc

#endif  // FJ_AUDIOSINKSHIM_MEDIA_STREAM_INTERFACE_H_
