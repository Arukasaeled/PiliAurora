import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;

typedef _NativeAffinity = Int32 Function(Int32, Size, Pointer<Uint8>);
typedef _Affinity = int Function(int, int, Pointer<Uint8>);

/// 视频输出存续期间允许系统在应用可用 CPU 上调度 Raster。
class AndroidRasterScheduling {
  AndroidRasterScheduling._(
    this._get,
    this._set,
    this._tid,
    this._original,
    this._app,
    this._sameThread,
  );

  @visibleForTesting
  factory AndroidRasterScheduling.forTesting({
    required List<int> Function() read,
    required void Function(List<int>) write,
    required bool Function() sameThread,
    required List<int> original,
    required List<int> app,
  }) => AndroidRasterScheduling._(null, null, 0, original, app, sameThread)
    .._readTest = read
    .._writeTest = write;

  static const _maskBytes = 128;
  final _Affinity? _get, _set;
  final bool Function() _sameThread;
  List<int> Function()? _readTest;
  void Function(List<int>)? _writeTest;
  List<int>? _applied;
  final int _tid;
  final List<int> _original, _app;
  bool _expanded = false;

  static Future<AndroidRasterScheduling?> open() async {
    if (!Platform.isAndroid) return null;
    final libc = DynamicLibrary.open('libc.so');
    final get = libc.lookupFunction<_NativeAffinity, _Affinity>(
      'sched_getaffinity',
    );
    final set = libc.lookupFunction<_NativeAffinity, _Affinity>(
      'sched_setaffinity',
    );
    final tids = <int>[];
    await for (final task in Directory('/proc/self/task').list()) {
      if (task is! Directory) continue;
      try {
        final name = (await File('${task.path}/comm').readAsString()).trim();
        if (RegExp(r'^\d+\.raster$').hasMatch(name)) {
          tids.add(int.parse(task.path.split('/').last));
        }
      } on FileSystemException {
        // 读取期间退出的其它线程与本次 Raster 对照无关。
      }
    }
    if (tids.length != 1) {
      return null;
    }
    final original = _read(get, tids.single);
    final app = _read(get, pid);
    final originalCpus = _cpus(original);
    final appCpus = _cpus(app);
    if (appCpus.length <= originalCpus.length ||
        !appCpus.toSet().containsAll(originalCpus)) {
      return null;
    }
    final stat = File('/proc/self/task/${tids.single}/stat');
    String identity() {
      final text = stat.readAsStringSync();
      // stat 第 22 字段为启动时刻；comm 可含空格，先越过末尾括号。
      return text.substring(text.lastIndexOf(')') + 2).split(' ')[19];
    }

    final started = identity();
    return AndroidRasterScheduling._(get, set, tids.single, original, app, () {
      try {
        return identity() == started;
      } on FileSystemException {
        return false;
      }
    });
  }

  static List<int> _read(_Affinity get, int tid) {
    final mask = calloc<Uint8>(_maskBytes);
    try {
      if (get(tid, _maskBytes, mask) != 0) {
        throw StateError('sched_getaffinity 失败');
      }
      return mask.asTypedList(_maskBytes).toList();
    } finally {
      calloc.free(mask);
    }
  }

  static List<int> _cpus(List<int> mask) => [
    for (var cpu = 0; cpu < mask.length * 8; cpu++)
      if (mask[cpu ~/ 8] & (1 << (cpu % 8)) != 0) cpu,
  ];

  Map<String, Object> get diagnostics => {
    'originalCpus': _cpus(_original),
    'appCpus': _cpus(_app),
    'actualCpus': _cpus(_readCurrent()),
    'expanded': _expanded,
  };

  List<int> _readCurrent() => _readTest?.call() ?? _read(_get!, _tid);

  void _write(List<int> target) {
    if (_writeTest case final write?) {
      write(target);
      return;
    }
    final mask = calloc<Uint8>(_maskBytes);
    try {
      mask.asTypedList(_maskBytes).setAll(0, target);
      if (_set!(_tid, _maskBytes, mask) != 0) {
        throw StateError('sched_setaffinity 失败');
      }
    } finally {
      calloc.free(mask);
    }
  }

  void useAppCpus(bool expanded) {
    if (!_sameThread()) return;
    if (!expanded) {
      restore();
      return;
    }
    if (_expanded) return;
    _write(_app);
    _expanded = true;
    _applied = _app;
    _applied = _readCurrent();
  }

  void restore() {
    if (!_expanded) return;
    // 线程退出或亲和性被其它策略接管后，结束本次所有权。
    if (_sameThread() && listEquals(_readCurrent(), _applied)) {
      _write(_original);
    }
    _expanded = false;
  }
}
