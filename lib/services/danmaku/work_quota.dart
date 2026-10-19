import 'dart:async';
import 'dart:collection';

class DanmakuWorkBusy implements Exception {
  const DanmakuWorkBusy();
}

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

/// 同一批次后续阶段复用获配资格，直到结果整理结束。
class DanmakuWorkLease {
  DanmakuWorkLease._();
  bool _active = true;

  Future<T> execute<T>(FutureOr<T> Function() work) async {
    if (!_active) throw StateError('来源处理额度已归还');
    return await work();
  }
}

/// 解码与合并共用进程配额；页面失效不提前释放仍在运行的任务。
class DanmakuWorkQuota {
  DanmakuWorkQuota({
    this.maxTasks = 1,
    this.maxBytes = 64 * 1024 * 1024,
    this.maxWaitingTasks = 16,
    this.maxWaitingBytes = 8 * 1024 * 1024,
  }) : assert(maxTasks > 0),
       assert(maxBytes > 0),
       assert(maxWaitingTasks > 0),
       assert(maxWaitingBytes > 0);

  static final instance = DanmakuWorkQuota();

  final int maxTasks;
  final int maxBytes;
  final int maxWaitingTasks;
  final int maxWaitingBytes;
  final _available = StreamController<void>.broadcast();
  Stream<void> get available => _available.stream;
  final _waiting =
      Queue<({int bytes, int waitingBytes, Completer<void> ready})>();
  int _waitingBytes = 0;

  bool get hasWaitingCapacity =>
      _waiting.length < maxWaitingTasks &&
      _waitingBytes + 256 <= maxWaitingBytes;

  Map<String, int> get snapshot => {
    'runningTasks': _tasks,
    'reservedBytes': _bytes,
    'waitingTasks': _waiting.length,
    'waitingBytes': _waitingBytes,
  };
  int _tasks = 0;
  int _bytes = 0;

  Future<T> run<T>(
    int estimatedBytes,
    FutureOr<T> Function() work, {
    DanmakuWorkToken? token,
    int waitingBytes = 256,
  }) {
    return runWithLease(
      estimatedBytes,
      (_) => work(),
      token: token,
      waitingBytes: waitingBytes,
    );
  }

  Future<T> runWithLease<T>(
    int estimatedBytes,
    FutureOr<T> Function(DanmakuWorkLease) work, {
    DanmakuWorkToken? token,
    int waitingBytes = 256,
  }) async {
    if (estimatedBytes < 0) throw ArgumentError.value(estimatedBytes);
    if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
    if (waitingBytes < 0) throw ArgumentError.value(waitingBytes);
    final startsImmediately =
        _waiting.isEmpty &&
        _tasks < maxTasks &&
        (_tasks == 0 || _bytes + estimatedBytes <= maxBytes);
    if (!startsImmediately &&
        (_waiting.length >= maxWaitingTasks ||
            _waitingBytes + waitingBytes > maxWaitingBytes)) {
      throw const DanmakuWorkBusy();
    }
    final ticket = (
      bytes: estimatedBytes,
      waitingBytes: waitingBytes,
      ready: Completer<void>(),
    );
    void cancelWaiting() {
      if (_waiting.remove(ticket)) {
        _waitingBytes -= ticket.waitingBytes;
        ticket.ready.completeError(const DanmakuWorkCancelled());
        _drain();
        _available.add(null);
      }
    }

    token?._listeners.add(cancelWaiting);
    _waiting.add(ticket);
    _waitingBytes += ticket.waitingBytes;
    _drain();
    try {
      await ticket.ready.future;
    } finally {
      token?._listeners.remove(cancelWaiting);
    }
    final lease = DanmakuWorkLease._();
    try {
      if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
      return await work(lease);
    } finally {
      lease._active = false;
      _tasks--;
      _bytes -= ticket.bytes;
      _drain();
      _available.add(null);
    }
  }

  void _drain() {
    while (_waiting.isNotEmpty && _tasks < maxTasks) {
      final ticket = _waiting.first;
      // 大文件独占执行，避免超过预算的单项永久等待。
      if (_tasks > 0 && _bytes + ticket.bytes > maxBytes) return;
      _waiting.removeFirst();
      _waitingBytes -= ticket.waitingBytes;
      _tasks++;
      _bytes += ticket.bytes;
      ticket.ready.complete();
    }
  }
}
