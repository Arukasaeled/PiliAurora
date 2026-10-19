import 'dart:async';
import 'dart:collection';

class DanmakuWorkCancelled implements Exception {
  const DanmakuWorkCancelled();
}

/// 取消等待任务；已启动任务仍由配额跟踪到实际结束。
class DanmakuWorkToken {
  bool _cancelled = false;
  final _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

/// 解码与合并共用进程配额；页面失效不提前释放仍在运行的任务。
class DanmakuWorkQuota {
  DanmakuWorkQuota({this.maxTasks = 2, this.maxBytes = 64 * 1024 * 1024})
    : assert(maxTasks > 0),
      assert(maxBytes > 0);

  static final instance = DanmakuWorkQuota();

  final int maxTasks;
  final int maxBytes;
  final _waiting = Queue<({int bytes, Completer<void> ready})>();
  int _tasks = 0;
  int _bytes = 0;

  Future<T> run<T>(
    int estimatedBytes,
    FutureOr<T> Function() work, {
    DanmakuWorkToken? token,
  }) async {
    if (estimatedBytes < 0) throw ArgumentError.value(estimatedBytes);
    if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
    final ticket = (bytes: estimatedBytes, ready: Completer<void>());
    void cancelWaiting() {
      if (_waiting.remove(ticket)) {
        ticket.ready.completeError(const DanmakuWorkCancelled());
        _drain();
      }
    }

    token?._listeners.add(cancelWaiting);
    _waiting.add(ticket);
    _drain();
    try {
      await ticket.ready.future;
    } finally {
      token?._listeners.remove(cancelWaiting);
    }
    try {
      if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
      return await work();
    } finally {
      _tasks--;
      _bytes -= ticket.bytes;
      _drain();
    }
  }

  void _drain() {
    while (_waiting.isNotEmpty && _tasks < maxTasks) {
      final ticket = _waiting.first;
      // 大文件独占执行，避免超过预算的单项永久等待。
      if (_tasks > 0 && _bytes + ticket.bytes > maxBytes) return;
      _waiting.removeFirst();
      _tasks++;
      _bytes += ticket.bytes;
      ticket.ready.complete();
    }
  }
}
