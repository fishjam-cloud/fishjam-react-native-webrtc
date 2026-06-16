/*
 *  Copyright 2011 The WebRTC project authors. All Rights Reserved.
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
// Minimal hand-rolled copy of WebRTC's rtc::scoped_refptr so we can talk
// to the prebuilt FishjamWebRTC binary, which ships only public Obj-C
// headers (no C++ api/ headers). When the WebRTC fork exposes real
// headers, delete the whole AudioSinkShim/ folder and repoint
// NativeAudioTrackBridge.h. See plan: "Migration boundary".
// =====================================================================

#ifndef FJ_AUDIOSINKSHIM_SCOPED_REFPTR_H_
#define FJ_AUDIOSINKSHIM_SCOPED_REFPTR_H_

#include <memory>
#include <utility>

namespace webrtc {

template <class T>
class scoped_refptr {
 public:
  typedef T element_type;

  scoped_refptr() : ptr_(nullptr) {}
  scoped_refptr(std::nullptr_t) : ptr_(nullptr) {}  // NOLINT(runtime/explicit)

  explicit scoped_refptr(T* p) : ptr_(p) {
    if (ptr_)
      ptr_->AddRef();
  }

  scoped_refptr(const scoped_refptr<T>& r) : ptr_(r.ptr_) {
    if (ptr_)
      ptr_->AddRef();
  }

  template <typename U>
  scoped_refptr(const scoped_refptr<U>& r) : ptr_(r.get()) {
    if (ptr_)
      ptr_->AddRef();
  }

  // Move constructors.
  scoped_refptr(scoped_refptr<T>&& r) noexcept : ptr_(r.release()) {}

  template <typename U>
  scoped_refptr(scoped_refptr<U>&& r) noexcept : ptr_(r.release()) {}

  ~scoped_refptr() {
    if (ptr_)
      ptr_->Release();
  }

  T* get() const { return ptr_; }
  explicit operator bool() const { return ptr_ != nullptr; }
  T& operator*() const { return *ptr_; }
  T* operator->() const { return ptr_; }

  T* release() {
    T* retVal = ptr_;
    ptr_ = nullptr;
    return retVal;
  }

  scoped_refptr<T>& operator=(T* p) {
    // AddRef first so that self assignment should work
    if (p)
      p->AddRef();
    if (ptr_)
      ptr_->Release();
    ptr_ = p;
    return *this;
  }

  scoped_refptr<T>& operator=(const scoped_refptr<T>& r) {
    return *this = r.ptr_;
  }

  template <typename U>
  scoped_refptr<T>& operator=(const scoped_refptr<U>& r) {
    return *this = r.get();
  }

  scoped_refptr<T>& operator=(scoped_refptr<T>&& r) noexcept {
    scoped_refptr<T>(std::move(r)).swap(*this);
    return *this;
  }

  template <typename U>
  scoped_refptr<T>& operator=(scoped_refptr<U>&& r) noexcept {
    scoped_refptr<T>(std::move(r)).swap(*this);
    return *this;
  }

  void swap(T** pp) noexcept {
    T* p = ptr_;
    ptr_ = *pp;
    *pp = p;
  }

  void swap(scoped_refptr<T>& r) noexcept { swap(&r.ptr_); }

 protected:
  T* ptr_;
};

}  // namespace webrtc

namespace rtc {
// Backwards compatible alias.
template <typename T>
using scoped_refptr = webrtc::scoped_refptr<T>;
}  // namespace rtc

#endif  // FJ_AUDIOSINKSHIM_SCOPED_REFPTR_H_
