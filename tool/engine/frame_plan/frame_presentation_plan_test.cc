#include "frame_presentation_plan.h"

#include <cassert>
#include <iostream>

int main() {
  constexpr int64_t period = 8'000'000;
  const auto feedback = std::make_shared<flutter::FramePresentationFeedback>();
  const std::vector<flutter::FrameTimeline> timelines{
      {10, period * 2, period},
      {11, period * 3, period * 2},
      {12, period * 4, period * 3},
      {13, period * 5, period * 4}};
  const auto first = flutter::SelectFramePresentationPlan(
      0, 1'000'000, period, timelines, feedback);
  assert(first && first->vsync_id == 12);
  assert(first->RequestedPresentationTime() == period * 4 - period / 4);
  feedback->Observe(period * 3);
  const auto next = flutter::SelectFramePresentationPlan(
      0, 1'000'000, period, timelines, feedback);
  assert(next && next->vsync_id == 13);
  // 反馈与后续选择不能改写已生成的帧身份。
  assert(first->vsync_id == 12 && first->expected_ns == period * 4);
  const auto exhausted = flutter::SelectFramePresentationPlan(
      0, period * 6, period, timelines, feedback);
  assert(!exhausted);
  const auto short_horizon = flutter::SelectFramePresentationPlan(
      0, 0, period, {{1, period * 2, period}}, feedback);
  assert(short_horizon && short_horizon->vsync_id == 1);
  assert(!flutter::SelectFramePresentationPlan(0, 0, 0, timelines, feedback));
  assert(!flutter::SelectFramePresentationPlan(0, 0, period, {}, feedback));
  const auto monotonic = flutter::SelectFramePresentationPlan(
      0, 0, period, timelines, feedback, period * 5);
  assert(!monotonic);
  // 实机中两次预测抖动 14us，仍属于同一显示槽位。
  const auto next_slot = flutter::SelectFramePresentationPlan(
      0, 0, period,
      {{20, period * 4 + 14'000, period * 3 + 14'000},
       {21, period * 5, period * 4}},
      std::make_shared<flutter::FramePresentationFeedback>(), period * 4);
  assert(next_slot && next_slot->vsync_id == 21);
  std::cout << "frame presentation plan: passed\n";
}
