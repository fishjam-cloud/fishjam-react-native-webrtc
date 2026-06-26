#import <Foundation/Foundation.h>

#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCVideoSource.h>

#import "CaptureController.h"
#import "WebRTCModule.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Capture controller for a "custom video track": an app-owned source of
 * GPU-rendered frames. Instead of capturing from a camera or the screen, the
 * app renders directly into IOSurface-backed CVPixelBuffers that this
 * controller owns, then pushes them into the WebRTC pipeline.
 *
 * Lifecycle / data flow:
 *   1. createCustomVideoTrack({width, height, poolSize}) builds this controller
 *      together with an RTCVideoSource and a fixed-size pool of
 *      CVPixelBuffers (kCVPixelFormatType_32BGRA, IOSurface-backed).
 *   2. The IOSurface handle of every buffer is handed to JS, which imports each
 *      one once (react-native-webgpu importSharedTextureMemory) and renders
 *      into it on the GPU.
 *   3. Per frame, JS renders into buffer[index], submits, and exports a Metal
 *      shared-event fence; it then pushes the frame through the JSI channel,
 *      which resolves the fence bigints and calls pushFrameForBufferIndex:...
 *      with the shared-event handle and the value the GPU will signal once the
 *      render is complete.
 *   4. This controller arms an MTLSharedEventListener on that value; when the
 *      GPU signals, the listener block wraps buffer[index] in an RTCVideoFrame
 *      and delivers it to the RTCVideoSource.
 */
@interface CustomVideoCaptureController : CaptureController

/**
 * Builds the controller. The CVPixelBufferPool and its buffers are allocated
 * here so the surface handles are available immediately for the JS resolve.
 *
 * @param videoSource the source that frames are delivered to.
 * @param width       pixel width of every buffer in the pool.
 * @param height      pixel height of every buffer in the pool.
 * @param poolSize    number of buffers to pre-allocate and keep at stable
 *                    indices (JS imports each IOSurface exactly once).
 * @param outError    populated when allocation fails (returns nil).
 */
- (nullable instancetype)initWithVideoSource:(RTCVideoSource *)videoSource
                                       width:(NSInteger)width
                                      height:(NSInteger)height
                                    poolSize:(NSInteger)poolSize
                                       error:(NSError **)outError;

/**
 * Stable index -> IOSurface handle map, exposed to JS so each surface can be
 * imported once and reused. Each entry is
 *   @{@"index": NSNumber, @"surfaceHandle": NSString (decimal uintptr_t),
 *     @"width": NSNumber, @"height": NSNumber}.
 * The handle is emitted as a decimal string to avoid losing precision through a
 * JS double (a 64-bit pointer does not fit exactly in a double).
 */
@property(nonatomic, readonly) NSArray<NSDictionary *> *bufferDescriptors;

/**
 * Pushes the frame currently rendered into buffer[bufferIndex] once the GPU
 * signals the fence. Fire-and-forget: there is no completion callback because
 * this is called once per frame and must stay cheap.
 *
 * The fence is delivered as a raw 64-bit handle plus a signaled value: the JSI
 * channel has already parsed the JS bigints, so no string parsing happens here.
 *
 * @param bufferIndex        pool index that JS rendered into.
 * @param fenceHandle        the exported MTLSharedEvent handle reinterpreted as
 *                          uint64_t. A handle of 0 means no fence was supplied
 *                          and the frame is delivered immediately.
 * @param fenceSignaledValue the value the GPU will signal on the shared event.
 * @param timestampNs        frame timestamp in nanoseconds.
 * @param rotation           frame rotation.
 */
- (void)pushFrameForBufferIndex:(NSInteger)bufferIndex
                    fenceHandle:(uint64_t)fenceHandle
             fenceSignaledValue:(uint64_t)fenceSignaledValue
                    timestampNs:(int64_t)timestampNs
                       rotation:(RTCVideoRotation)rotation;

@end

/**
 * Thread-safe registry mapping a custom-video trackId to its capture controller.
 *
 * The per-frame deliver callback runs on the JS thread; resolving the controller
 * through `self.localTracks` there raced with the RN thread mutating that
 * dictionary (unsynchronised NSMutableDictionary access). This registry decouples
 * delivery from `localTracks`: it is O(1), guarded by its own lock, and holds the
 * controller weakly, so the entry clears itself when the track and its controller
 * are released — no explicit unregister on the teardown paths is required.
 */
@interface WebRTCModule (CustomVideoRegistry)

/** Registers (or replaces) the controller for trackId. */
- (void)registerCustomVideoController:(CustomVideoCaptureController *)controller
                           forTrackId:(NSString *)trackId;

/** Looks up the live controller for trackId, or nil if none/already released. */
- (nullable CustomVideoCaptureController *)registeredCustomVideoControllerForTrackId:(NSString *)trackId;

@end

NS_ASSUME_NONNULL_END
