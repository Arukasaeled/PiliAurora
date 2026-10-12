import 'dart:async';
import 'dart:ui' as ui;

/// 缓存持有原始句柄；显示组件通过 acquire 获取独立句柄。
class PreviewImageCache {
  PreviewImageCache({this.maxEntries = 3, this.maxBytes = 24 << 20})
    : assert(maxEntries > 0),
      assert(maxBytes > 0);

  final int maxEntries;
  final int maxBytes;
  final _cache = <String, ui.Image>{};
  final _pending = <String, _PreviewLoad>{};
  int _generation = 0;
  int _sizeBytes = 0;

  int get generation => _generation;
  int get sizeBytes => _sizeBytes;

  ui.Image? acquire(String key) {
    final image = _cache.remove(key);
    if (image == null) return null;
    _cache[key] = image;
    return image.clone();
  }

  /// 同一代缓存共享在途解码，每个调用者仍取得独立的显示句柄。
  Future<ui.Image?> acquireOrLoad(
    String key,
    Future<ui.Image?> Function() load,
  ) async {
    final cached = acquire(key);
    if (cached != null) return cached;
    final generation = _generation;
    final pending = _pending.putIfAbsent(key, () {
      final request = _PreviewLoad();
      request.future = Future<ui.Image?>.sync(load).then((image) {
        request.image = image;
        if (image != null && generation == _generation) {
          put(key, image.clone());
        }
        return image;
      });
      return request;
    });
    pending.users++;
    try {
      final image = await pending.future;
      return generation == _generation ? image?.clone() : null;
    } finally {
      if (--pending.users == 0) {
        if (identical(_pending[key], pending)) _pending.remove(key);
        pending.image?.dispose();
      }
    }
  }

  /// 接管 image 的所有权。单张超限时不缓存，调用者应先取得自己的句柄。
  void put(String key, ui.Image image) {
    if (identical(_cache[key], image)) return;
    final previous = _cache.remove(key);
    if (previous != null) {
      _sizeBytes -= previous.width * previous.height * 4;
      previous.dispose();
    }
    final bytes = image.width * image.height * 4;
    if (bytes > maxBytes) {
      image.dispose();
      return;
    }
    _cache[key] = image;
    _sizeBytes += bytes;
    while (_cache.length > maxEntries || _sizeBytes > maxBytes) {
      final oldest = _cache.remove(_cache.keys.first)!;
      _sizeBytes -= oldest.width * oldest.height * 4;
      oldest.dispose();
    }
  }

  void clear() {
    _generation++;
    _pending.clear();
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    _sizeBytes = 0;
  }
}

class _PreviewLoad {
  late final Future<ui.Image?> future;
  ui.Image? image;
  int users = 0;
}
