import 'dart:async';
import 'dart:collection';

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

  Future<T> run<T>(int estimatedBytes, FutureOr<T> Function() work) async {
    if (estimatedBytes < 0) throw ArgumentError.value(estimatedBytes);
    final ticket = (bytes: estimatedBytes, ready: Completer<void>());
    _waiting.add(ticket);
    _drain();
    await ticket.ready.future;
    try {
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
