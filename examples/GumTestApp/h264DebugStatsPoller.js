/**
 * Temporary instrumentation for RCA of "H264 encoder stuck after background".
 *
 * Polls the video outbound-rtp every second and logs key encoder counters so
 * you can cross-reference them with the native [H264-DEBUG] logs emitted by
 * WebRTCModule / VideoCaptureController / H264DebugFrameCounter.
 *
 * Usage:
 *   import { startH264DebugStatsPoller } from './h264DebugStatsPoller';
 *
 *   const stop = startH264DebugStatsPoller(peerConnection);
 *   // ...later, when done debugging:
 *   stop();
 *
 * Classification cheat-sheet (match native frame counter vs framesEncoded):
 *   - framesEncoded flat + native fps=0  => capturer-side stall (H2)
 *   - framesEncoded flat + native fps>0  => encoder-side stall (H1 or H3)
 *   - both increment                     => not actually stuck; check renderer/PIP
 */

export function startH264DebugStatsPoller(peerConnection, intervalMs = 1000) {
    if (!peerConnection || typeof peerConnection.getStats !== 'function') {
        console.warn('[H264-DEBUG-JS] Invalid peer connection');
        return () => {};
    }

    let prevByStreamId = new Map();

    const tick = async () => {
        try {
            const report = await peerConnection.getStats();
            const now = Date.now();
            report.forEach((stat) => {
                if (stat.type !== 'outbound-rtp' || stat.kind !== 'video') {
                    return;
                }
                const prev = prevByStreamId.get(stat.id);
                const framesEncoded = stat.framesEncoded ?? 0;
                const keyFramesEncoded = stat.keyFramesEncoded ?? 0;
                const bytesSent = stat.bytesSent ?? 0;
                const qualityLimitationReason = stat.qualityLimitationReason ?? 'none';
                const encoderImplementation = stat.encoderImplementation ?? 'unknown';
                const deltaFrames = prev ? framesEncoded - prev.framesEncoded : framesEncoded;
                const deltaBytes = prev ? bytesSent - prev.bytesSent : bytesSent;
                const dtSec = prev ? (now - prev.ts) / 1000 : intervalMs / 1000;
                const fps = dtSec > 0 ? deltaFrames / dtSec : 0;
                const kbps = dtSec > 0 ? (deltaBytes * 8) / 1000 / dtSec : 0;

                console.log(
                    `[H264-DEBUG-JS] outbound-rtp ` +
                        `t=${(now / 1000).toFixed(3)} ` +
                        `codec=${stat.codecId ?? '?'} ` +
                        `impl=${encoderImplementation} ` +
                        `framesEncoded=${framesEncoded} (+${deltaFrames}, ${fps.toFixed(2)} fps) ` +
                        `keyFrames=${keyFramesEncoded} ` +
                        `bytesSent=${bytesSent} (+${deltaBytes}, ${kbps.toFixed(1)} kbps) ` +
                        `qualityLimit=${qualityLimitationReason}`,
                );
                prevByStreamId.set(stat.id, { framesEncoded, bytesSent, ts: now });
            });
        } catch (err) {
            console.warn('[H264-DEBUG-JS] getStats() failed:', err);
        }
    };

    const handle = setInterval(tick, intervalMs);
    console.log('[H264-DEBUG-JS] started stats poller');
    return () => {
        clearInterval(handle);
        prevByStreamId.clear();
        console.log('[H264-DEBUG-JS] stopped stats poller');
    };
}
