#ifndef VIDEO_FRAME_SAMPLING_H_
#define VIDEO_FRAME_SAMPLING_H_
#include <functional>
#include <string>

#include "output_operation_token.h"

struct VideoFrameSamplingEvent {
  OutputOperationToken token;
  int64_t generation;
  std::string admission;
  int64_t timestamp_us;
  int64_t sequence;
};
using VideoFrameSamplingCallback =
    std::function<void(const VideoFrameSamplingEvent&)>;
#endif
