"""Run production sampling methods against a controllable render queue."""
from pathlib import Path
import argparse
import subprocess


def method(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


HARNESS = r"""
#include "video_frame_sampling.h"
#include <cassert>
#include <chrono>
#include <deque>
#include <mutex>
#include <optional>
#include <unordered_map>
#include <vector>
struct Queue {
  std::deque<std::function<void()>> jobs;
  void Post(std::function<void()> job) { jobs.push_back(job); }
  void Drain() { while (!jobs.empty()) { auto job = jobs.front(); jobs.pop_front(); job(); } }
};
class VideoOutput {
 public:
  std::optional<OutputOperationToken> active_token_ = OutputOperationToken{1,1,1,0};
  bool active_token_invalidated_ = false;
  bool output_prepared_ = true, resize_in_progress_ = false, renderer_reset_pending_ = false;
  bool sampling_enabled_ = false;
  int64_t sampling_generation_ = 0, sampling_sequence_ = 0, sampling_valid_after_us_ = 0;
  std::string sampling_admission_ = "blocked";
  struct TextureFrameIdentity { OutputOperationToken token; int64_t generation, rendered_at_us; };
  std::unordered_map<int64_t, TextureFrameIdentity> texture_sampling_frames_;
  std::mutex textures_mutex_;
  Queue queue;
  Queue* thread_pool_ref_ = &queue;
  std::vector<VideoFrameSamplingEvent> events;
  VideoFrameSamplingCallback frame_sampling_callback_ = [this](const auto& e) { events.push_back(e); };
  int consumed = 0;
  std::function<void(const OutputOperationToken&, int64_t)> frame_consumed_callback_ =
      [this](const auto&, int64_t) { consumed++; };
  bool IsCurrentToken(const OutputOperationToken&) const;
  void TransitionSampling(const std::string&);
  void SetFrameSampling(OutputOperationToken, bool, std::function<void(std::optional<VideoFrameSamplingEvent>)>);
  void NotifyFrameConsumed(int64_t);
  void Consume() {
    texture_sampling_frames_.insert_or_assign(7, TextureFrameIdentity{
      *active_token_, sampling_generation_, sampling_valid_after_us_ + 1});
    NotifyFrameConsumed(7);
    queue.Drain();
  }
};
METHODS
int main() {
  VideoOutput output;
  const auto token = *output.active_token_;
  std::optional<VideoFrameSamplingEvent> receipt;
  output.SetFrameSampling(token, true, [&](auto state) { receipt = state; });
  assert(!receipt.has_value());
  output.queue.Drain();
  assert(receipt->admission == "priming");
  output.Consume();
  assert(output.sampling_admission_ == "active");
  assert(output.sampling_sequence_ == 0);
  output.Consume();
  assert(output.sampling_sequence_ == 1);
  // 消费回调已入队，随后同 token 资源关闭；旧派发代次须保持失效。
  output.texture_sampling_frames_.insert_or_assign(7, VideoOutput::TextureFrameIdentity{
      token, output.sampling_generation_, output.sampling_valid_after_us_ + 1});
  output.NotifyFrameConsumed(7);
  output.TransitionSampling("blocked");
  output.queue.Drain();
  assert(output.sampling_sequence_ == 1 && output.consumed == 3);
  output.SetFrameSampling(token, false, [&](auto state) { receipt = state; });
  output.queue.Drain();
  assert(receipt->admission == "blocked");
  output.Consume();
  assert(output.sampling_sequence_ == 1 && output.consumed == 4);
  output.SetFrameSampling(token, true, [&](auto state) { receipt = state; });
  output.queue.Drain();
  output.Consume();
  output.Consume();
  assert(output.sampling_sequence_ == 2);
  output.active_token_invalidated_ = true;
  output.SetFrameSampling(token, true, [&](auto state) { receipt = state; });
  output.queue.Drain();
  assert(!receipt.has_value());
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="g++")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    native = root / "third_party/media_kit_video/windows"
    source = (native / "video_output.cc").read_text(encoding="utf-8")
    methods = "\n".join(method(source, signature) for signature in [
        "bool VideoOutput::IsCurrentToken(", "void VideoOutput::TransitionSampling(",
        "void VideoOutput::SetFrameSampling(", "void VideoOutput::NotifyFrameConsumed(",
    ])
    output = root / "build/probe-validation/windows-sampling"
    output.mkdir(parents=True, exist_ok=True)
    fixture, binary = output / "probe.cc", output / "probe.exe"
    fixture.write_text(HARNESS.replace("METHODS", methods), encoding="utf-8")
    subprocess.run([args.compiler, "-std=c++17", "-static-libgcc", "-static-libstdc++",
                    "-I", native, fixture, "-o", binary], check=True)
    subprocess.run([binary], check=True)
    print("PASS: Windows render identity, sampling receipts, revocation and sequence continuity")


if __name__ == "__main__":
    main()
