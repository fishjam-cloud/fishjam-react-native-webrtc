# Custom Video Track — concepts & flow

`createCustomVideoTrack` / `pushCustomVideoFrame` let you feed your own GPU- (or CPU-)
rendered frames into a WebRTC video track. This document explains what the primitive
is, how a frame flows through it, and where it sits relative to higher-level helpers —
using "background blur for my camera" as the running example.

> **New Architecture only.** The per-frame push goes through a JSI binding;
> `createCustomVideoTrack` rejects with a clear error on the old architecture.

## The one thing this primitive is

A **zero-copy output sink**:

> *"Give me N GPU-renderable native surfaces; I'll turn whatever you render into them
> into a WebRTC video track, synchronized by a GPU fence."*

That is the whole job. It knows nothing about cameras, blur, segmentation, or even
WebGPU. It speaks only in **platform primitives**:

- **Surfaces in** — an `IOSurface` (iOS) / `AHardwareBuffer` (Android) per pool slot.
- **A fence** — an `MTLSharedEvent` (iOS) / `sync` fd (Android) so it knows when your
  GPU work for a frame has actually finished.
- **A `MediaStream` out** — the track you publish (e.g. via `useCustomSource`).

Because it only deals in platform primitives, it is **not coupled to any GPU library**.
react-native-webgpu is just a convenient producer of those surfaces/fences; raw
Metal/Vulkan/GL, Skia's GPU surface, or any other library works equally well. It's also
not blur-specific — you can feed it CPU pixels, a decoded video, or a canvas.

## Three actors, not one

This is why a real effect feels like "so many parts": the primitive is only one of
three pieces, and your effect is the glue across all of them.

```
┌── Camera lib (VisionCamera) ─┐  ┌── GPU lib (react-native-webgpu) ─┐  ┌── THIS primitive ──────┐
│ camera → native buffer       │  │ import surfaces & camera frame    │  │ createCustomVideoTrack │
│ (frame-processor worklet)    │  │ run YOUR shaders                  │  │   → pooled surfaces     │
└──────────────────────────────┘  │ export GPU fence                  │  │   → MediaStream         │
                                   └───────────────────────────────────┘  │ pushCustomVideoFrame    │
            YOUR effect: segmentation model + blur + composite             │   → WebRTC encoder       │
                                                                           └──────────────────────────┘
```

The primitive owns only the right-hand box. The GPU library is the middle; the camera
library is the left; the effect itself is yours.

## Background blur, step by step — what *you* write

**Setup (once):**

1. `const { stream, buffers } = await createCustomVideoTrack({ width, height, poolSize: 3 })` — *primitive*
2. Publish it: `useCustomSource('blur').setStream(stream)` — *existing SDK*
3. Import each `buffers[i].surfaceHandle` into your GPU once (`importSharedTextureMemory`) → a render texture per slot — *GPU lib*
4. Load your **segmentation model** + build your **blur/composite shaders** — *you*
5. Start the camera (`useFrameOutput` frame processor) — *camera lib*

**Per frame (in the camera worklet):**

6. Get the camera buffer → import it as a GPU texture (with YUV decode + rotation handling) — *you + GPU lib*
7. Pick the next pool slot (round-robin), `beginAccess` its surface — *you + GPU lib; surface from the primitive*
8. Run the pipeline: sample camera → **segment foreground** → **blur background** → **composite** → write into the pool surface — *you (the actual "blur")*
9. `submit` → `endAccess` → export the fence `{ handle, signaledValue }` — *GPU lib*
10. `pushCustomVideoFrame({ trackId, bufferIndex, timestampNs, fence })` — *primitive*
11. Native waits on the fence (GPU finished) → wraps the surface as a frame → feeds the encoder — *primitive*

The primitive owns **1, 2, 10, 11** and the surfaces used in 3/7. Steps **6** and **8** —
camera import and the blur itself — are the hard parts, and they are entirely yours.

## One frame's lifecycle (the pool + fence, demystified)

- **Pool of surfaces.** You ask for `poolSize` surfaces up front and import each into your
  GPU once. You never re-import per frame.
- **Round-robin.** A frame you push may still be in flight (being encoded/sent) when you
  want to draw the next one. Redrawing a surface that's still being read would tear it.
  So you cycle through the pool — render into slot `(frameCount % poolSize)` — and the
  producer never overwrites a buffer still being consumed.
- **The fence.** The GPU finishes asynchronously. The fence is how native knows your draw
  for this frame is *actually done* before it reads the surface to encode it. Provide a
  fence and native waits for it; **omit the fence** to deliver immediately (CPU-filled or
  already-finished frames).

## Is the abstraction the right level?

**For what it is, yes** — it's minimal, unopinionated, composable, and reusable beyond
blur. It's the correct *foundation*.

**For "I want background blur," it is genuinely low-level** — a typical app developer
won't wire three libraries plus a segmentation model. There's a ladder:

| Level | What you write | Rough size |
|-------|----------------|------------|
| **L0 — this primitive** | everything above | ~500 lines |
| **L1 — a GPU-track helper** | the shader only (pool/fence/round-robin hidden) | ~40 lines + shader |
| **L2 — a camera-effect hook** | just the per-frame effect (capture + import + publish hidden) | ~1 shader |
| **L3 — turnkey** | `useBackgroundBlur()` | ~1 line |

L1 and L2 already exist as worked examples (the demo's `WebGPUVideoTrack` and
`useWebGPUCameraEffect`) — the copy-paste reference above this floor. Whether to promote
them into a thin optional SDK package (GPU-library-coupled) or leave them as reference is
a follow-up decision; this primitive is the foundation either way.
