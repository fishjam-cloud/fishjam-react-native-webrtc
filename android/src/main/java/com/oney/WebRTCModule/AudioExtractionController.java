package com.oney.WebRTCModule;

import android.util.Log;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.turbomodule.core.CallInvokerHolderImpl;

import org.webrtc.AudioTrack;
import org.webrtc.AudioTrackSink;
import org.webrtc.MediaStreamTrack;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Audio extraction: pulls int16 PCM from local mic and remote tracks and feeds
 * it to the native converter ({@link FJAudioSinkInstaller}) for delivery to JS.
 */
final class AudioExtractionController {
    private static final String TAG = "AudioExtractionController";

    // pcId the JS side uses to mean "the local mic track", not a remote pc track.
    static final int LOCAL_TRACK_PC_ID = -1;

    // miniaudio's MA_MAX_FILTER_ORDER (high-quality resampler lpfOrder).
    private static final int MA_MAX_FILTER_ORDER = 8;

    interface TrackResolver {
        MediaStreamTrack getTrack(int pcId, String trackId);
    }

    private final ReactApplicationContext reactContext;
    private final TrackResolver trackResolver;

    private final Map<String, AudioTrackSink> audioSinks = new HashMap<>();

    // Read on the ADM capture thread, written on the RN executor thread.
    private final Set<String> localAudioSinks = ConcurrentHashMap.newKeySet();

    // Lazily built from the JS CallInvoker; null on the old architecture (no JSI).
    private FJAudioSinkInstaller audioSinkInstaller;
    private boolean audioSinkInstallerInitialized;

    AudioExtractionController(ReactApplicationContext reactContext, TrackResolver trackResolver) {
        this.reactContext = reactContext;
        this.trackResolver = trackResolver;
    }

    private synchronized FJAudioSinkInstaller getInstaller() {
        if (audioSinkInstallerInitialized) {
            return audioSinkInstaller;
        }
        audioSinkInstallerInitialized = true;
        try {
            if (reactContext.getJSCallInvokerHolder() instanceof CallInvokerHolderImpl) {
                audioSinkInstaller = new FJAudioSinkInstaller(reactContext);
            }
        } catch (Throwable t) {
            Log.w(TAG, "Audio extraction unavailable: failed to build the JSI installer", t);
        }
        return audioSinkInstaller;
    }

    void installAudioSink(Promise promise) {
        FJAudioSinkInstaller installer = getInstaller();
        if (installer == null) {
            promise.reject("E_NO_JSI", "Audio extraction requires the New Architecture.");
            return;
        }
        installer.install(promise);
    }

    void startExtraction(int pcId, String id, ReadableMap options) {
        ThreadUtils.runOnExecutor(() -> {
            if (audioSinks.containsKey(id) || localAudioSinks.contains(id)) {
                return;
            }
            // Null without a JSI CallInvoker; JS already rejected at install time.
            FJAudioSinkInstaller installer = getInstaller();
            if (installer == null) {
                return;
            }

            AudioSinkConfig config = AudioSinkConfig.fromOptions(options);
            if (pcId == LOCAL_TRACK_PC_ID) {
                startLocalExtraction(id, installer, config);
            } else {
                startRemoteExtraction(pcId, id, installer, config);
            }
        });
    }

    void stopExtraction(int pcId, String id) {
        ThreadUtils.runOnExecutor(() -> {
            if (pcId == LOCAL_TRACK_PC_ID) {
                stopLocalExtraction(id);
            } else {
                stopRemoteExtraction(pcId, id);
            }
        });
    }

    // Local: frames arrive via onLocalAudioSamplesReady, so there is no sink to attach.
    private void startLocalExtraction(String id, FJAudioSinkInstaller installer, AudioSinkConfig config) {
        config.applyTo(installer, LOCAL_TRACK_PC_ID, id);
        localAudioSinks.add(id);
    }

    private void stopLocalExtraction(String id) {
        if (!localAudioSinks.remove(id)) {
            return;
        }
        FJAudioSinkInstaller installer = getInstaller();
        if (installer != null) {
            installer.removeTrack(id);
        }
    }

    // Remote: frames arrive through an AudioTrackSink attached to the track.
    private void startRemoteExtraction(int pcId, String id, FJAudioSinkInstaller installer, AudioSinkConfig config) {
        MediaStreamTrack track = trackResolver.getTrack(pcId, id);
        if (!(track instanceof AudioTrack)) {
            Log.d(TAG, "startAudioExtraction() no audio track for " + id);
            return;
        }
        config.applyTo(installer, pcId, id);
        AudioTrackSink sink = new PcmBatchingSink(id, installer);
        ((AudioTrack) track).addSink(sink);
        audioSinks.put(id, sink);
    }

    private void stopRemoteExtraction(int pcId, String id) {
        AudioTrackSink sink = audioSinks.remove(id);
        if (sink == null) {
            return;
        }
        MediaStreamTrack track = trackResolver.getTrack(pcId, id);
        if (track instanceof AudioTrack) {
            ((AudioTrack) track).removeSink(sink);
        }
        FJAudioSinkInstaller installer = getInstaller();
        if (installer != null) {
            installer.removeTrack(id);
        }
    }

    // ADM samples-ready callback, on the capture thread. Cheap when no local sinks.
    void onLocalAudioSamplesReady(JavaAudioDeviceModule.AudioSamples samples) {
        if (localAudioSinks.isEmpty()) {
            return;
        }
        FJAudioSinkInstaller installer = getInstaller();
        if (installer == null) {
            return;
        }
        byte[] data = samples.getData();
        int frames = data.length / (samples.getChannelCount() * 2); // int16 = 2 bytes/sample
        ByteBuffer buf = ByteBuffer.allocateDirect(data.length);
        buf.put(data);
        buf.flip();
        for (String trackId : localAudioSinks) {
            buf.rewind();
            installer.onAudioData(trackId, buf, samples.getSampleRate(), samples.getChannelCount(), frames);
        }
    }

    // Output config for one request, parsed from the JS options (defaults match iOS).
    private static class AudioSinkConfig {
        final int outRate;
        final int outChannels;
        final boolean formatF32;
        final int lpfOrder;
        final double batchMs;

        private AudioSinkConfig(int outRate, int outChannels, boolean formatF32, int lpfOrder, double batchMs) {
            this.outRate = outRate;
            this.outChannels = outChannels;
            this.formatF32 = formatF32;
            this.lpfOrder = lpfOrder;
            this.batchMs = batchMs;
        }

        static AudioSinkConfig fromOptions(ReadableMap options) {
            int outRate = options != null && options.hasKey("sampleRate") ? options.getInt("sampleRate") : 16000;
            int outChannels = options != null && options.hasKey("channels") ? options.getInt("channels") : 1;
            if (outChannels < 1) {
                outChannels = 1;
            }
            boolean formatF32 =
                    !(options != null && options.hasKey("format") && "s16".equals(options.getString("format")));
            int lpfOrder = options != null && options.hasKey("resampleQuality")
                            && "high".equals(options.getString("resampleQuality"))
                    ? MA_MAX_FILTER_ORDER
                    : 1;
            double batchMs =
                    options != null && options.hasKey("batchDurationMs") ? options.getDouble("batchDurationMs") : 100.0;
            if (batchMs <= 0) {
                batchMs = 100.0;
            }
            return new AudioSinkConfig(outRate, outChannels, formatF32, lpfOrder, batchMs);
        }

        void applyTo(FJAudioSinkInstaller installer, int pcId, String trackId) {
            installer.configureTrack(pcId, trackId, outRate, outChannels, formatF32, lpfOrder, batchMs);
        }
    }

    // Thin forwarder: hands each int16 chunk to the native converter.
    private static class PcmBatchingSink implements AudioTrackSink {
        private final String trackId;
        private final FJAudioSinkInstaller installer;

        PcmBatchingSink(String trackId, FJAudioSinkInstaller installer) {
            this.trackId = trackId;
            this.installer = installer;
        }

        @Override
        public void onData(ByteBuffer audioData, int bitsPerSample, int sampleRate, int numberOfChannels,
                int numberOfFrames, long absoluteCaptureTimestampMs) {
            if (bitsPerSample != 16) {
                return;
            }
            installer.onAudioData(trackId, audioData, sampleRate, numberOfChannels, numberOfFrames);
        }
    }
}
