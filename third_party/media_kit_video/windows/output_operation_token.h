#ifndef MEDIA_KIT_VIDEO_OUTPUT_OPERATION_TOKEN_H_
#define MEDIA_KIT_VIDEO_OUTPUT_OPERATION_TOKEN_H_

#include <cstdint>

struct OutputOperationToken {
  int64_t runtime_id;
  int64_t load_id;
  int64_t output_epoch;
  int64_t config_revision;

  bool operator==(const OutputOperationToken& other) const {
    return runtime_id == other.runtime_id && load_id == other.load_id &&
           output_epoch == other.output_epoch &&
           config_revision == other.config_revision;
  }

  bool operator!=(const OutputOperationToken& other) const {
    return !(*this == other);
  }

  bool CanReplace(const OutputOperationToken& other) const {
    if (runtime_id != other.runtime_id) return runtime_id > other.runtime_id;
    if (load_id != other.load_id) return load_id > other.load_id;
    if (output_epoch != other.output_epoch)
      return output_epoch > other.output_epoch;
    return config_revision > other.config_revision;
  }
};

#endif  // MEDIA_KIT_VIDEO_OUTPUT_OPERATION_TOKEN_H_
