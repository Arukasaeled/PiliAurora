// Copyright 2026 The PiliAurora Authors.
// SPDX-License-Identifier: BSD-3-Clause
#ifndef FLUTTER_FLOW_FRAME_PRESENTATION_PLAN_H_
#define FLUTTER_FLOW_FRAME_PRESENTATION_PLAN_H_

#include <algorithm>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <vector>

namespace flutter {

struct FrameTimeline {
  int64_t vsync_id = 0;
  int64_t expected_ns = 0;
  int64_t deadline_ns = 0;
};

// 每个 waiter 独立反馈；UI 选择计划，Raster/GPU 完成后更新预算。
class FramePresentationFeedback {
 public:
  bool IsEnabled() const {
    std::scoped_lock lock(mutex_);
    return fallback_reason_ == nullptr;
  }

  const char* FallbackReason() const {
    std::scoped_lock lock(mutex_);
    return fallback_reason_;
  }

  void Disable(const char* reason) {
    std::scoped_lock lock(mutex_);
    if (!fallback_reason_) {
      fallback_reason_ = reason;
    }
  }

  void RecordSelection(bool valid) {
    std::scoped_lock lock(mutex_);
    if (valid) {
      failed_selections_ = 0;
    } else if (++failed_selections_ >= 3 && !fallback_reason_) {
      fallback_reason_ = "invalidFrameTimeline";
    }
  }

  int64_t Budget(int64_t period_ns) const {
    std::scoped_lock lock(mutex_);
    return std::clamp(budget_ns_, period_ns * 2, period_ns * 4);
  }

  void Observe(int64_t duration_ns) {
    if (duration_ns <= 0) {
      return;
    }
    std::scoped_lock lock(mutex_);
    // 慢速回落避免一次轻帧立刻改变后续的呈现槽位。
    budget_ns_ = std::max(duration_ns, budget_ns_ - budget_ns_ / 240);
  }

 private:
  mutable std::mutex mutex_;
  int64_t budget_ns_ = 0;
  int failed_selections_ = 0;
  // 同一引擎实例保持回退；新建引擎时再探测，避免故障设备反复切换。
  const char* fallback_reason_ = nullptr;
};

struct FramePresentationPlan {
  int64_t vsync_id = 0;
  int64_t frame_start_ns = 0;
  int64_t expected_ns = 0;
  int64_t deadline_ns = 0;
  int64_t dispatch_ns = 0;
  int64_t period_ns = 0;
  std::shared_ptr<FramePresentationFeedback> feedback;

  // 留出随 compositor deadline 变化的相位余量，且不跨入上一显示槽。
  int64_t RequestedPresentationTime() const {
    const auto margin = std::clamp((expected_ns - deadline_ns) / 2,
                                   int64_t{0}, period_ns / 4);
    return expected_ns - margin;
  }
};

inline std::optional<FramePresentationPlan> SelectFramePresentationPlan(
    int64_t frame_start_ns,
    int64_t now_ns,
    int64_t period_ns,
    const std::vector<FrameTimeline>& timelines,
    const std::shared_ptr<FramePresentationFeedback>& feedback,
    int64_t last_expected_ns = 0) {
  if (!feedback->IsEnabled()) {
    return std::nullopt;
  }
  if (period_ns <= 0 || timelines.empty()) {
    feedback->RecordSelection(false);
    return std::nullopt;
  }
  const auto ready_ns = now_ns + feedback->Budget(period_ns) + period_ns / 4;
  const FrameTimeline* selected = nullptr;
  for (const auto& timeline : timelines) {
    // 不同回调对同一显示槽位的预测可能略有抖动，需跨过半屏周期。
    if (timeline.vsync_id <= 0 ||
        timeline.expected_ns > now_ns + period_ns * 8 ||
        timeline.expected_ns <= last_expected_ns + period_ns / 2 ||
        timeline.deadline_ns <= now_ns ||
        timeline.expected_ns <= timeline.deadline_ns) {
      continue;
    }
    // 没有能覆盖预算的 timeline 时，保留最远的可达候选作 best effort。
    selected = &timeline;
    if (timeline.deadline_ns >= ready_ns) {
      break;
    }
  }
  feedback->RecordSelection(selected != nullptr);
  if (!selected) {
    return std::nullopt;
  }
  return FramePresentationPlan{selected->vsync_id, frame_start_ns,
                               selected->expected_ns, selected->deadline_ns,
                               now_ns, period_ns, feedback};
}

}  // namespace flutter
#endif  // FLUTTER_FLOW_FRAME_PRESENTATION_PLAN_H_
