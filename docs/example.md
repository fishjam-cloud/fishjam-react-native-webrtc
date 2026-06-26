# Custom Video Track — a complete example

A self-contained, end-to-end example: create a custom video track, import its surface pool into
[react-native-webgpu](https://github.com/wcandillon/react-native-webgpu), run a 30 fps render loop
that draws an animated color into each pooled surface behind a GPU fence, and publish the result as
a normal video source. No camera, no model — just the primitive + a GPU. Once this works, swapping
the "draw a color" step for a real effect (a shader, a segmentation pipeline, a decoded video) is the
only thing that changes.

> **New Architecture only.** The per-frame push is a JSI binding. On the old architecture
> `createCustomVideoTrack` rejects with a clear error.

See [`custom-video-track.md`](./custom-video-track.md) for the concepts behind each step.

## What you need

- React Native **New Architecture** enabled.
- `@fishjam-cloud/react-native-webrtc` (this package) and a way to publish a `MediaStream` — the
  example uses the Fishjam SDK's `useCustomSource`, but any path that adds the stream's track to a
  peer connection works.
- `react-native-webgpu` for the GPU (any library that can import an `IOSurface`/`AHardwareBuffer` and
  export a GPU fence works; this is just the one used here).

## The track wrapper

This class owns the whole producer side: it allocates the pool, imports each surface into WebGPU
once, and exposes a `renderFrame()` you call ~30×/sec.

```ts
import { Platform } from 'react-native';
import {
  createCustomVideoTrack,
  pushCustomVideoFrame,
  type CustomVideoTrack,
} from '@fishjam-cloud/react-native-webrtc';
import {
  GPUTextureUsage,
  type GPUSharedFence,
  type GPUSharedTextureMemory,
} from 'react-native-webgpu';

// The pooled surfaces are BGRA8 on iOS (IOSurface) and RGBA8 on Android (AHardwareBuffer).
// Render into a texture whose format matches, or beginAccess will reject.
const SURFACE_FORMAT: GPUTextureFormat =
  Platform.OS === 'android' ? 'rgba8unorm' : 'bgra8unorm';

const NANOSECONDS_PER_FRAME = Math.round(1_000_000_000 / 30); // 30 fps

// One pooled surface, imported into WebGPU once and reused for every frame at that index.
interface PoolSlot {
  index: number;
  memory: GPUSharedTextureMemory;
  texture: GPUTexture;
}

export class ColorVideoTrack {
  private nextSlot = 0;
  private frameCount = 0;

  // We MUST keep each exported fence object alive until native has consumed it (its
  // GPU-completion callback fires asynchronously). A small ring buffer, a few frames deep,
  // is plenty; dropping a fence too early is a use-after-free on the native side.
  private readonly retainedFences: (GPUSharedFence | undefined)[];
  private retainCursor = 0;

  private constructor(
    private readonly device: GPUDevice,
    private readonly nativeTrack: CustomVideoTrack,
    private readonly trackId: string,
    private readonly slots: PoolSlot[],
  ) {
    this.retainedFences = new Array(slots.length * 2).fill(undefined);
  }

  static async create(device: GPUDevice, size = 480, poolSize = 3): Promise<ColorVideoTrack> {
    // 1. Allocate the native surface pool + the WebRTC track. (Rejects on the old architecture.)
    const nativeTrack = await createCustomVideoTrack({ width: size, height: size, poolSize });
    const trackId = nativeTrack.stream.getVideoTracks()[0].id;

    // 2. Import every pooled surface into WebGPU ONCE, as a render target. surfaceHandle is a
    //    bigint — pass it straight through, no conversion.
    const slots: PoolSlot[] = nativeTrack.buffers.map((buffer) => {
      const memory = device.importSharedTextureMemory({ handle: buffer.surfaceHandle });
      const texture = memory.createTexture({
        format: SURFACE_FORMAT,
        size: [buffer.width, buffer.height],
        usage: GPUTextureUsage.RENDER_ATTACHMENT,
      });
      return { index: buffer.index, memory, texture };
    });

    return new ColorVideoTrack(device, nativeTrack, trackId, slots);
  }

  /** Publish this with useCustomSource(...).setStream(track.stream). */
  get stream() {
    return this.nativeTrack.stream;
  }

  /** Render one frame into the next pool slot and push it behind a GPU fence. Call ~30×/sec. */
  renderFrame(): void {
    // Round-robin: never draw into a slot that may still be in flight to the encoder.
    const slot = this.slots[this.nextSlot];
    this.nextSlot = (this.nextSlot + 1) % this.slots.length;

    // beginAccess(initialized:false) — we fully overwrite the surface this frame.
    slot.memory.beginAccess(slot.texture, false);

    // Draw: clear the whole surface to a color that cycles over ~3s, so a remote peer sees it move.
    const t = (this.frameCount % 90) / 90;
    const encoder = this.device.createCommandEncoder();
    const pass = encoder.beginRenderPass({
      colorAttachments: [
        {
          view: slot.texture.createView(),
          clearValue: { r: t, g: 1 - t, b: 0.4, a: 1 },
          loadOp: 'clear',
          storeOp: 'store',
        },
      ],
    });
    pass.end();
    this.device.queue.submit([encoder.finish()]);

    // endAccess gives us the GPU completion fence. Pass its handle + signaledValue straight
    // through as bigints — native waits the fence before it reads the surface.
    const { fences } = slot.memory.endAccess(slot.texture);
    const fenceState = fences[0];

    let fence: { handle: bigint; signaledValue: bigint } | undefined;
    if (fenceState) {
      this.retainFence(fenceState.fence);
      fence = {
        handle: fenceState.fence.export().handle,
        signaledValue: fenceState.signaledValue,
      };
    }

    pushCustomVideoFrame({
      trackId: this.trackId,
      bufferIndex: slot.index,
      timestampNs: this.frameCount * NANOSECONDS_PER_FRAME,
      rotation: 0,
      // Omit `fence` entirely for CPU-filled / already-finished frames (delivered immediately).
      ...(fence ? { fence } : {}),
    });

    this.frameCount += 1;
  }

  dispose(): void {
    this.nativeTrack.stream.getTracks().forEach((track) => track.stop());
    this.slots.forEach((slot) => slot.texture.destroy());
    this.retainedFences.fill(undefined);
  }

  private retainFence(fence: GPUSharedFence): void {
    this.retainedFences[this.retainCursor] = fence;
    this.retainCursor = (this.retainCursor + 1) % this.retainedFences.length;
  }
}
```

## Driving it from a component

A hook that builds the track when enabled, runs the loop, publishes the stream, and tears everything
down on cleanup.

```ts
import { useEffect } from 'react';
import { useDevice } from 'react-native-webgpu';
import { useCustomSource } from '@fishjam-cloud/react-native-client';

import { ColorVideoTrack } from './ColorVideoTrack';

export function useColorVideoTrack(enabled: boolean) {
  // 'rnwebgpu/native-texture' gates the zero-copy surface-import path.
  const { device } = useDevice(undefined, {
    requiredFeatures: ['rnwebgpu/native-texture' as GPUFeatureName],
  });
  // Published as a normal custom video source (metadata.type === 'customVideo').
  const { setStream } = useCustomSource('color');

  useEffect(() => {
    if (!enabled || !device) {
      return;
    }
    let cancelled = false;
    let track: ColorVideoTrack | undefined;
    let timer: ReturnType<typeof setInterval> | undefined;

    (async () => {
      track = await ColorVideoTrack.create(device);
      if (cancelled) {
        track.dispose();
        return;
      }
      setStream(track.stream);
      timer = setInterval(() => track?.renderFrame(), 1000 / 30);
    })();

    return () => {
      cancelled = true;
      if (timer) clearInterval(timer);
      setStream(null);
      track?.dispose();
    };
  }, [enabled, device]);
}
```

That's the whole thing. A remote peer now receives a video track whose tile cycles color — produced
entirely on the GPU, zero-copy, fenced.

## Things that bite (read before you ship)

- **Match the surface format** (`SURFACE_FORMAT` above). Rendering BGRA into an Android RGBA surface
  (or vice-versa) either swaps red/blue or makes `beginAccess` reject.
- **Keep the fence alive.** The native side gets a *borrowed* reference to the fence; its completion
  callback runs later. If JS garbage-collects the fence object before then, that's a use-after-free.
  The ring buffer above (a few frames deep) is the fix — do not drop it.
- **Round-robin over the pool.** Reusing one surface every frame tears, because the encoder may still
  be reading the previous frame from it. `poolSize: 3` gives comfortable slack at 30 fps.
- **Same-runtime import.** If you render inside a worklet (e.g. a VisionCamera frame processor),
  import the surfaces *in that worklet*, not on the JS thread — the GPU library requires
  `importSharedTextureMemory` and `beginAccess`/`endAccess` to run on the same runtime.
- **Device only.** Importing camera/external textures and exporting GPU fences does not work on the
  iOS simulator's GPU; verify on a physical device.
