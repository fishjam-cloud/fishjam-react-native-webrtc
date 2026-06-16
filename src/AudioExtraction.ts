import { NativeModules } from 'react-native';

import { addListener, removeListener } from './EventEmitter';
import type MediaStreamTrack from './MediaStreamTrack';

const { WebRTCModule } = NativeModules;

/**
 * A batch of raw PCM audio extracted from a remote WebRTC audio track.
 * `data` is a base64-encoded little-endian int16 buffer of interleaved samples.
 */
export type AudioTrackData = {
    pcId: number;
    trackId: string;
    sampleRate: number;
    channels: number;
    data: string;
};

function peerConnectionId(track: MediaStreamTrack): number {
    // Remote tracks carry the pcId; local tracks use -1 (see MediaStreamTrack).
    return track.remote ? (track as unknown as { _peerConnectionId: number })._peerConnectionId : -1;
}

/**
 * Start extracting raw audio from a remote peer's audio track. Frames are
 * delivered as `audioTrackData` events — subscribe with {@link addAudioDataListener}.
 */
export function startAudioExtraction(track: MediaStreamTrack): void {
    WebRTCModule.startAudioExtraction(peerConnectionId(track), track.id);
}

/** Stop extracting audio from a previously-started track. */
export function stopAudioExtraction(track: MediaStreamTrack): void {
    WebRTCModule.stopAudioExtraction(peerConnectionId(track), track.id);
}

/**
 * Subscribe to PCM batches for a specific track. Returns an unsubscribe fn.
 */
export function addAudioDataListener(
    track: MediaStreamTrack,
    onData: (data: AudioTrackData) => void,
): () => void {
    const listener = {};
    addListener(listener, 'audioTrackData', (event) => {
        const data = event as AudioTrackData;
        if (data.trackId === track.id) {
            onData(data);
        }
    });
    return () => removeListener(listener);
}
