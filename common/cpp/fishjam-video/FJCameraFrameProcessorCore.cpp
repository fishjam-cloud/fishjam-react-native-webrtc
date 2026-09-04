#include "FJCameraFrameProcessorCore.h"

void FJCameraFrameProcessorCore::attach() {
    std::lock_guard<std::mutex> lock(mutex_);
    generation_++;
    attached_ = true;
    busy_ = false;
}

void FJCameraFrameProcessorCore::detach() {
    std::lock_guard<std::mutex> lock(mutex_);
    generation_++;
    attached_ = false;
    busy_ = false;
}

bool FJCameraFrameProcessorCore::isAttached() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return attached_;
}

FJCameraFrameProcessorCore::Offer FJCameraFrameProcessorCore::offer() {
    std::lock_guard<std::mutex> lock(mutex_);
    statistics_.offered++;

    if (!attached_) {
        statistics_.droppedDetached++;
        return {OfferResult::Detached, 0};
    }
    if (busy_) {
        statistics_.droppedBusy++;
        return {OfferResult::DroppedBusy, 0};
    }

    busy_ = true;
    statistics_.accepted++;
    return {OfferResult::Accepted, generation_};
}

void FJCameraFrameProcessorCore::completed(uint64_t token) {
    std::lock_guard<std::mutex> lock(mutex_);
    // A completion from a previous attachment says nothing about the frame the
    // current one may already have in flight.
    if (token != generation_) {
        return;
    }
    if (!busy_) {
        return;
    }
    busy_ = false;
    statistics_.completed++;
}

FJCameraFrameProcessorCore::Statistics FJCameraFrameProcessorCore::statistics() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return statistics_;
}
