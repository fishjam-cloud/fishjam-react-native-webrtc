// Host-side unit tests for FJCameraFrameProcessorCore (run via `npm run test:cpp`).
//
// Same plain assert harness as the audio scheduler's tests: the core is
// dependency-free C++, and a gtest dependency would be the only reason this repo
// needs a C++ test framework. Everything here is deterministic — the core has no
// clock and no threads of its own — apart from one concurrency check that only
// asserts an invariant, never a timing.

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <thread>
#include <vector>

#include "FJCameraFrameProcessorCore.h"

namespace {

int failures = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                          \
        }                                                                        \
    } while (0)

#define CHECK_EQ(a, b)                                                                                        \
    do {                                                                                                      \
        auto va = (a);                                                                                        \
        auto vb = (b);                                                                                        \
        if (!(va == vb)) {                                                                                    \
            std::fprintf(stderr, "FAIL %s:%d: %s == %s (%lld vs %lld)\n", __FILE__, __LINE__, #a, #b,         \
                         (long long)va, (long long)vb);                                                       \
            failures++;                                                                                       \
        }                                                                                                     \
    } while (0)

using OfferResult = FJCameraFrameProcessorCore::OfferResult;

void detachedProcessorAcceptsNothing() {
    FJCameraFrameProcessorCore core;
    CHECK(!core.isAttached());
    CHECK(core.offer().result == OfferResult::Detached);
    CHECK_EQ(core.statistics().droppedDetached, 1u);
    CHECK_EQ(core.statistics().accepted, 0u);
}

void onlyOneFrameIsInFlight() {
    FJCameraFrameProcessorCore core;
    core.attach();

    auto first = core.offer();
    CHECK(first.result == OfferResult::Accepted);
    CHECK(core.offer().result == OfferResult::DroppedBusy);
    CHECK(core.offer().result == OfferResult::DroppedBusy);

    core.completed(first.token);
    CHECK(core.offer().result == OfferResult::Accepted);

    auto stats = core.statistics();
    CHECK_EQ(stats.offered, 4u);
    CHECK_EQ(stats.accepted, 2u);
    CHECK_EQ(stats.droppedBusy, 2u);
    CHECK_EQ(stats.completed, 1u);
}

void detachAbandonsTheFrameInFlight() {
    FJCameraFrameProcessorCore core;
    core.attach();
    auto inFlight = core.offer();
    CHECK(inFlight.result == OfferResult::Accepted);

    core.detach();
    CHECK(core.offer().result == OfferResult::Detached);

    // The abandoned frame finishes late. Crediting it would clear a `busy` flag
    // that now belongs to a different attachment.
    core.completed(inFlight.token);
    CHECK_EQ(core.statistics().completed, 0u);

    core.attach();
    CHECK(core.offer().result == OfferResult::Accepted);
}

void aStaleCompletionCannotOpenTheGateTwice() {
    FJCameraFrameProcessorCore core;
    core.attach();
    auto stale = core.offer();
    core.detach();
    core.attach();

    auto current = core.offer();
    CHECK(current.result == OfferResult::Accepted);

    // The frame from the previous attachment reports in. If it were credited,
    // the next offer would be accepted while `current` is still being processed.
    core.completed(stale.token);
    CHECK(core.offer().result == OfferResult::DroppedBusy);

    core.completed(current.token);
    CHECK(core.offer().result == OfferResult::Accepted);
}

void completingTwiceIsCountedOnce() {
    FJCameraFrameProcessorCore core;
    core.attach();
    auto offer = core.offer();

    core.completed(offer.token);
    core.completed(offer.token);

    CHECK_EQ(core.statistics().completed, 1u);
}

// The capture thread offers while the consumer thread completes. The core has no
// threads of its own, so this asserts the invariant rather than any interleaving:
// accepted frames are never more than completed frames plus the one in flight.
void concurrentOffersNeverExceedOneInFlight() {
    FJCameraFrameProcessorCore core;
    core.attach();

    std::atomic<int> completedCount{0};
    std::atomic<bool> stop{false};
    std::vector<uint64_t> pending;

    std::thread consumer([&] {
        while (!stop.load()) {
            auto offer = core.offer();
            if (offer.result == OfferResult::Accepted) {
                core.completed(offer.token);
                completedCount.fetch_add(1);
            }
        }
    });

    for (int i = 0; i < 20000; i++) {
        auto offer = core.offer();
        if (offer.result == OfferResult::Accepted) {
            core.completed(offer.token);
            completedCount.fetch_add(1);
        }
    }
    stop.store(true);
    consumer.join();

    auto stats = core.statistics();
    CHECK_EQ(stats.accepted, stats.completed);
    CHECK_EQ(stats.offered, stats.accepted + stats.droppedBusy + stats.droppedDetached);
    CHECK_EQ((uint64_t)completedCount.load(), stats.completed);
}

}  // namespace

int main() {
    detachedProcessorAcceptsNothing();
    onlyOneFrameIsInFlight();
    detachAbandonsTheFrameInFlight();
    aStaleCompletionCannotOpenTheGateTwice();
    completingTwiceIsCountedOnce();
    concurrentOffersNeverExceedOneInFlight();

    if (failures > 0) {
        std::fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    std::printf("FJCameraFrameProcessorCore: all checks passed\n");
    return 0;
}
