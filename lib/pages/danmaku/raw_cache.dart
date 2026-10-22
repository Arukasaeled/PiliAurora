import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';

/// 原始网络分段按完整段淘汰；读取不改变保留顺序。
class DanmakuRawCache {
  DanmakuRawCache({this.maxSegments = 4, this.maxBytes = 16 * 1024 * 1024})
    : assert(maxSegments > 0),
      assert(maxBytes > 0);

  final int maxSegments;
  final int maxBytes;
  final _segments = <int, ({List<DanmakuElem> elements, int bytes})>{};
  int _bytes = 0;

  int get estimatedBytes => _bytes;
  int get length => _segments.length;
  Iterable<int> get keys => _segments.keys;
  List<DanmakuElem>? operator [](int segment) => _segments[segment]?.elements;

  bool retain(int segment, List<DanmakuElem> elements) {
    final previous = _segments.remove(segment);
    if (previous != null) _bytes -= previous.bytes;
    var bytes = 64 + elements.length * 8;
    for (final element in elements) {
      bytes += estimateDanmakuElementBytes(element);
      // 超大段仍可显示，本缓存不持有；规则更新后按缺失段重新请求。
      if (bytes > maxBytes) return false;
    }
    if (bytes > maxBytes) return false;
    while (_segments.isNotEmpty &&
        (_segments.length >= maxSegments || _bytes + bytes > maxBytes)) {
      final oldest = _segments.remove(_segments.keys.first)!;
      _bytes -= oldest.bytes;
    }
    _segments[segment] = (elements: elements, bytes: bytes);
    _bytes += bytes;
    return true;
  }

  void clear() {
    _segments.clear();
    _bytes = 0;
  }
}
