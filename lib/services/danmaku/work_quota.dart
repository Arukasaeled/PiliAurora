import 'dart:async';
import 'dart:collection';

import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

class DanmakuWorkBusy implements Exception {
  const DanmakuWorkBusy();
}

class DanmakuWorkCancelled implements Exception {
  const DanmakuWorkCancelled();
}

/// 调用方须缩小批次后重新申请；此错误不进入等待队列。
class DanmakuWorkTooLarge implements Exception {
  const DanmakuWorkTooLarge(this.requestedBytes, this.maxBytes);

  final int requestedBytes;
  final int maxBytes;
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
  DanmakuWorkLease._(this.reservedBytes, [this._parent]);
  final int reservedBytes;
  final DanmakuWorkLease? _parent;
  bool _active = true;

  /// 后续阶段在建立副本前复核同一批次的预留。
  void requireBytes(int bytes) {
    _parent?.requireBytes(0);
    if (!_active) throw StateError('来源处理额度已归还');
    if (bytes < 0) throw ArgumentError.value(bytes);
    if (bytes > reservedBytes) {
      throw DanmakuWorkTooLarge(bytes, reservedBytes);
    }
  }

  /// 前一阶段仍持有的输入/解析结果从下一阶段的可用额度中扣除。
  DanmakuWorkLease retaining(int bytes) {
    requireBytes(bytes);
    return DanmakuWorkLease._(reservedBytes - bytes, this);
  }

  Future<T> execute<T>(FutureOr<T> Function() work) async {
    requireBytes(0);
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

  static final instance = _createProcessQuota();

  static DanmakuWorkQuota _createProcessQuota() {
    final quota = DanmakuWorkQuota();
    Diagnostics.instance.register(
      'danmaku.processWorkQuota',
      () => quota.snapshot,
    );
    return quota;
  }

  final int maxTasks;
  final int maxBytes;
  final int maxWaitingTasks;
  final int maxWaitingBytes;
  final _available = StreamController<void>.broadcast();
  Stream<void> get available => _available.stream;
  final _waiting =
      Queue<({int bytes, int waitingBytes, Completer<void> ready})>();
  int _waitingBytes = 0;
  final _running = <DanmakuWorkLease, ({DanmakuWorkToken? token, int bytes})>{};

  bool get hasWaitingCapacity =>
      _waiting.length < maxWaitingTasks &&
      _waitingBytes + 256 <= maxWaitingBytes;

  Map<String, int> get snapshot {
    var obsoleteTasks = 0;
    var obsoleteBytes = 0;
    // 预约绑定的 token 已取消，任务实际结束前继续保留在途记录。
    for (final task in _running.values) {
      if (task.token?.isCancelled ?? false) {
        obsoleteTasks++;
        obsoleteBytes += task.bytes;
      }
    }
    return {
      'runningTasks': _tasks,
      'reservedBytes': _bytes,
      'waitingTasks': _waiting.length,
      'waitingBytes': _waitingBytes,
      'obsoleteRunningTasks': obsoleteTasks,
      'obsoleteReservedBytes': obsoleteBytes,
    };
  }

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
    if (estimatedBytes > maxBytes) {
      throw DanmakuWorkTooLarge(estimatedBytes, maxBytes);
    }
    if (waitingBytes < 0) throw ArgumentError.value(waitingBytes);
    final startsImmediately =
        _waiting.isEmpty &&
        _tasks < maxTasks &&
        _bytes + estimatedBytes <= maxBytes;
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
    final lease = DanmakuWorkLease._(ticket.bytes);
    _running[lease] = (token: token, bytes: ticket.bytes);
    try {
      if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
      return await work(lease);
    } finally {
      lease._active = false;
      _running.remove(lease);
      _tasks--;
      _bytes -= ticket.bytes;
      _drain();
      _available.add(null);
    }
  }

  void _drain() {
    while (_waiting.isNotEmpty && _tasks < maxTasks) {
      final ticket = _waiting.first;
      if (_bytes + ticket.bytes > maxBytes) return;
      _waiting.removeFirst();
      _waitingBytes -= ticket.waitingBytes;
      _tasks++;
      _bytes += ticket.bytes;
      ticket.ready.complete();
    }
  }
}
