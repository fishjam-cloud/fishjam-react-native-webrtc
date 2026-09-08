// Admission gate for one camera frame processor.
//
// A camera delivers frames faster than a GPU effect can consume them, so
// something has to decide which frames go to the consumer and which are dropped
// on the capture thread. That decision is this class, kept apart from the
// platform code that owns the pixel buffers so it can be tested on a host
// toolchain rather than only on a phone.
//
// The policy is deliberately small: one frame in flight at a time. A camera
// frame that arrives while the consumer is still working on the previous one is
// dropped immediately — for live video a missing frame is invisible, whereas a
// queue would only add latency and hold native buffers the camera needs back.
//
// Detaching is the sharp edge. A frame accepted just before detach can finish
// after the processor has been re-attached, and crediting that completion would
// let two frames run at once. Every acceptance is therefore stamped with a
// token, and a completion whose token predates the current attachment is
// ignored.
//
// Pure C++20: no JSI, no platform types, no pixel data.
#pragma once

#include <cstdint>
#include <mutex>

class FJCameraFrameProcessorCore {
   public:
    enum class OfferResult {
        // Deliver this frame to the consumer, then call completed() with the token.
        Accepted,
        // The consumer is still working on the previous frame. Release this one.
        DroppedBusy,
        // Nothing is attached. Release this one.
        Detached,
    };

    struct Offer {
        OfferResult result;
        // Pass to completed(). Meaningless unless result is Accepted.
        uint64_t token;
    };

    // Invariants: offered == accepted + droppedBusy + droppedDetached, and
    // accepted == completed + droppedUndeliverable + frames in flight, except
    // that a frame in flight when detach() or attach() runs settles as a stale
    // token and is counted in neither completed nor droppedUndeliverable.
    struct Statistics {
        uint64_t offered = 0;
        uint64_t accepted = 0;
        uint64_t droppedBusy = 0;
        uint64_t droppedDetached = 0;
        uint64_t completed = 0;
        // Accepted by the gate but never reached the consumer: unsupported
        // buffer type, no free GPU slot, consumer gone.
        uint64_t droppedUndeliverable = 0;
    };

    // Starts a new attachment generation. Any frame still in flight from a
    // previous one is abandoned: its completion will be ignored, and the gate
    // opens immediately rather than waiting for a consumer that is gone.
    void attach();
    void detach();
    bool isAttached() const;

    Offer offer();
    void completed(uint64_t token);
    // Same gate effect as completed(), for an accepted frame the platform could
    // not deliver to the consumer. Counts as droppedUndeliverable.
    void abandoned(uint64_t token);

    Statistics statistics() const;

   private:
    // Clears busy_ for a token of the current generation. Caller holds mutex_.
    bool settleInFlight(uint64_t token);

    mutable std::mutex mutex_;
    bool attached_ = false;
    bool busy_ = false;
    // Incremented on every attach and detach; the low bit is not meaningful, only
    // the change is. A token carries the generation it was issued in.
    uint64_t generation_ = 0;
    Statistics statistics_;
};
