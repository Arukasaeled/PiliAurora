// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output_manager.h"

VideoOutputManager::VideoOutputManager(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

void VideoOutputManager::Create(
    int64_t handle,
    VideoOutputConfiguration configuration,
    std::function<void(int64_t, int64_t, int64_t)> texture_update_callback,
    std::function<void(const OutputOperationToken&, int64_t, int64_t, int64_t)>
        output_attached_callback,
    std::function<void(const OutputOperationToken&, int64_t)>
        frame_consumed_callback,
    VideoFrameSamplingCallback frame_sampling_callback) {
  control_thread_pool_->Post([this, handle, configuration,
                              texture_update_callback, output_attached_callback,
                              frame_consumed_callback,
                              frame_sampling_callback]() {
    if (video_outputs_.find(handle) != video_outputs_.end()) return;
    auto instance = std::make_unique<VideoOutput>(
        handle, configuration, registrar_, thread_pool_.get(),
        output_attached_callback, frame_consumed_callback,
        frame_sampling_callback);
    instance->SetTextureUpdateCallback(texture_update_callback);
    video_outputs_.insert(std::make_pair(handle, std::move(instance)));
  });
}

void VideoOutputManager::SetFrameSampling(
    int64_t handle, OutputOperationToken token, bool enabled,
    std::function<void(bool)> on_complete) {
  control_thread_pool_->Post([this, handle, token, enabled, on_complete]() {
    const auto output = video_outputs_.find(handle);
    if (output == video_outputs_.end()) {
      on_complete(false);
      return;
    }
    output->second->SetFrameSampling(token, enabled, on_complete);
  });
}

void VideoOutputManager::BeginOutputForLoad(
    int64_t handle,
    OutputOperationToken token,
    std::function<void(bool)> on_complete) {
  control_thread_pool_->Post([this, handle, token, on_complete]() {
    const auto output = video_outputs_.find(handle);
    if (output == video_outputs_.end()) {
      on_complete(false);
      return;
    }
    output->second->BeginOutputForLoad(token, on_complete);
  });
}

void VideoOutputManager::PrepareForLoad(
    int64_t handle,
    OutputOperationToken token,
    std::string track_id,
    int64_t width,
    int64_t height,
    std::function<void(bool, int64_t, int64_t)> on_complete) {
  control_thread_pool_->Post([this, handle, token, track_id, width, height,
                              on_complete]() {
    const auto output = video_outputs_.find(handle);
    if (output == video_outputs_.end()) {
      on_complete(false, 0, 0);
      return;
    }
    output->second->PrepareForLoad(token, track_id, width, height, on_complete);
  });
}

void VideoOutputManager::InvalidateOutputGeneration(
    int64_t handle,
    OutputOperationToken token,
    std::function<void(bool)> on_complete) {
  control_thread_pool_->Post([this, handle, token, on_complete]() {
    const auto output = video_outputs_.find(handle);
    if (output == video_outputs_.end()) {
      on_complete(false);
      return;
    }
    output->second->InvalidateOutputGeneration(token, on_complete);
  });
}

void VideoOutputManager::SetSize(
    int64_t handle,
    std::optional<int64_t> width,
    std::optional<int64_t> height,
    std::function<void(bool)> on_frame_ready) {
  control_thread_pool_->Post([this, handle, width, height, on_frame_ready]() {
    const auto output = video_outputs_.find(handle);
    if (output == video_outputs_.end()) {
      on_frame_ready(false);
      return;
    }
    output->second->SetSize(width, height, on_frame_ready);
  });
}

void VideoOutputManager::SetSourceSize(
    int64_t handle,
    int64_t width,
    int64_t height,
    std::optional<OutputOperationToken> token) {
  control_thread_pool_->Post([this, handle, width, height, token]() {
    const auto output = video_outputs_.find(handle);
    if (output != video_outputs_.end()) {
      output->second->SetSourceSize(width, height, token);
    }
  });
}

void VideoOutputManager::ResetRenderer(int64_t handle,
                                       std::function<void(bool)> on_ready) {
  control_thread_pool_->Post([this, handle, on_ready]() {
    const auto output = video_outputs_.find(handle);
    if (output == video_outputs_.end()) {
      on_ready(false);
      return;
    }
    output->second->ResetRenderer(on_ready);
  });
}

void VideoOutputManager::Dispose(int64_t handle,
                                 std::function<void()> on_released) {
  control_thread_pool_->Post([this, handle, on_released]() {
    std::unique_ptr<VideoOutput> output;
    const auto found = video_outputs_.find(handle);
    if (found != video_outputs_.end()) {
      output = std::move(found->second);
      video_outputs_.erase(found);
    }
    // Keep this handle occupied until every render task and Flutter texture
    // unregister receipt has completed in VideoOutput's destructor.
    output.reset();
    on_released();
  });
}

VideoOutputManager::~VideoOutputManager() {
  if (control_thread_pool_) {
    auto release_all = control_thread_pool_->Post([this]() {
      auto outputs = std::move(video_outputs_);
      video_outputs_.clear();
      outputs.clear();
    });
    release_all.get();
    control_thread_pool_.reset();
  }
  // Render work remains available until every VideoOutput has acknowledged
  // its texture and native resource release.
  thread_pool_.reset();
}
