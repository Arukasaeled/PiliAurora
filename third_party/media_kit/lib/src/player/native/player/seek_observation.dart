/// 同一原生事件读取器内的 seek 关联记录。
/// 命令回执建立边界，随后 SEEK 与 PLAYBACK_RESTART 共同结清记录。
class NativeSeekObservation {
  NativeSeekObservation({
    required this.requestId,
    required this.observationId,
    required this.playlistEntryId,
  });

  final int requestId;
  final int observationId;
  final int playlistEntryId;
  bool _acknowledged = false;
  bool _started = false;

  void acknowledge(int requestId, int error) {
    if (requestId == this.requestId && error >= 0) {
      _acknowledged = true;
    }
  }

  void start(int? playlistEntryId) {
    if (_acknowledged && playlistEntryId == this.playlistEntryId) {
      _started = true;
    }
  }

  bool completes(int? playlistEntryId) =>
      _started && playlistEntryId == this.playlistEntryId;
}
