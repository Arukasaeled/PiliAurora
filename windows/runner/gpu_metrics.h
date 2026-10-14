#ifndef RUNNER_GPU_METRICS_H_
#define RUNNER_GPU_METRICS_H_
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <condition_variable>
#include <mutex>
#include <thread>
class GpuMetrics {
 public:
  explicit GpuMetrics(flutter::FlutterEngine* engine);
  ~GpuMetrics();
 private:
  void Stop();
  void Run();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::thread worker_;
  std::mutex mutex_;
  std::condition_variable wake_;
  bool stopping_ = false;
  std::string flutter_luid_;
  flutter::EncodableMap latest_;
};
#endif
