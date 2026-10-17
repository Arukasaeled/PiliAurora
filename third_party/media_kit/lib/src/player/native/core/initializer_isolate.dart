/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit/src/player/native/core/native_destroy.dart';

import 'event_loop_session.dart';

/// Isolate fallback with an explicit reader-exit acknowledgement.
abstract class InitializerIsolate {
  static Future<Pointer<mpv_handle>> create(
    MPV mpv,
    FutureOr<void> Function(Pointer<mpv_event>)? callback,
    Map<String, String> options, {
    FutureOr<void> Function(int batchId)? onBatchDrained,
  }) async {
    if (callback == null) {
      return _createHandle(mpv, options, NativeLibrary.path);
    }
    final initialized = Completer<Pointer<mpv_handle>>();
    final exited = Completer<void>();
    final receiver = ReceivePort();
    final exitReceiver = ReceivePort();
    final errorReceiver = ReceivePort();
    SendPort? worker;
    EventLoopSession<Pointer<mpv_event>>? session;

    exitReceiver.listen((_) {
      if (!exited.isCompleted) exited.complete();
      if (!initialized.isCompleted) {
        initialized.completeError(
          StateError('mpv event isolate exited during initialization'),
        );
      }
      exitReceiver.close();
      errorReceiver.close();
    });
    errorReceiver.listen((message) {
      final error = StateError(
        'mpv event isolate failed: ${message is List ? message.first : message}',
      );
      if (!initialized.isCompleted) {
        initialized.completeError(error);
      } else {
        Zone.current.handleUncaughtError(error, StackTrace.current);
      }
    });
    receiver.listen((dynamic message) {
      if (message is SendPort) {
        worker = message;
        worker!.send(options);
        worker!.send(NativeLibrary.path);
      } else if (message is int && !initialized.isCompleted) {
        final handle = Pointer<mpv_handle>.fromAddress(message);
        session = EventLoopSession(
          onEvent: callback,
          onBatchDrained: onBatchDrained ?? (_) {},
          acknowledge: () => worker!.send(true),
          shutdown: () async {
            worker!.send(null);
            // A message cannot interrupt a blocking FFI wait. Wake it from
            // the owner isolate, then wait for actual exit before destruction.
            mpv.mpv_wakeup(handle);
            await exited.future;
            receiver.close();
          },
          onError: (error, stack) =>
              Zone.current.handleUncaughtError(error, stack),
        );
        _sessions[handle.address] = session!;
        initialized.complete(handle);
      } else if (message is int) {
        session?.add(Pointer<mpv_event>.fromAddress(message));
      } else if (message is Map &&
          message['batchDrained'] is int &&
          initialized.isCompleted) {
        session?.drain(message['batchDrained'] as int);
      }
    });
    try {
      await Isolate.spawn(
        _mainloop,
        receiver.sendPort,
        onExit: exitReceiver.sendPort,
        onError: errorReceiver.sendPort,
        errorsAreFatal: true,
      );
      return await initialized.future;
    } catch (_) {
      receiver.close();
      exitReceiver.close();
      errorReceiver.close();
      rethrow;
    }
  }

  static Future<Pointer<mpv_handle>> _createHandle(
    MPV mpv,
    Map<String, String> options,
    String libraryPath,
  ) async {
    final handle = mpv.mpv_create();
    if (handle == nullptr) throw StateError('mpv_create returned null');
    try {
      for (final entry in options.entries) {
        final name = entry.key.toNativeUtf8();
        final value = entry.value.toNativeUtf8();
        try {
          mpv.mpv_set_option_string(handle, name, value);
        } finally {
          calloc.free(name);
          calloc.free(value);
        }
      }
      final status = mpv.mpv_initialize(handle);
      if (status < 0) throw StateError('mpv_initialize failed ($status)');
      return handle;
    } catch (error, stack) {
      try {
        await terminateMpvOnWorker(handle.address, libraryPath);
      } catch (cleanupError) {
        throw NativeHandleCleanupFailure(
          cause: error,
          cleanupError: cleanupError,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  static Future<void> dispose(Pointer<mpv_handle> handle) async {
    final session = _sessions[handle.address];
    if (session == null) return;
    await session.stop();
    if (identical(_sessions[handle.address], session)) {
      _sessions.remove(handle.address);
    }
  }

  static Future<void> _mainloop(SendPort port) async {
    final configured = Completer<void>();
    final receiver = ReceivePort();
    port.send(receiver.sendPort);
    late Map<String, String> options;
    late String libraryPath;
    late MPV mpv;
    Completer<void>? acknowledged;
    bool disposed = false;

    receiver.listen((dynamic message) {
      if (message is Map<String, String>) {
        options = message;
      } else if (message is String) {
        libraryPath = message;
        mpv = MPV(DynamicLibrary.open(libraryPath));
        configured.complete();
      } else if (message is bool) {
        if (!(acknowledged?.isCompleted ?? true)) acknowledged!.complete();
      } else if (message == null) {
        disposed = true;
        if (!(acknowledged?.isCompleted ?? true)) acknowledged!.complete();
      }
    });
    await configured.future;
    final handle = await _createHandle(mpv, options, libraryPath);
    port.send(handle.address);
    var batchId = 0;
    try {
      while (!disposed) {
        // Let queued disposal messages run before entering another blocking
        // FFI wait. Never invalidate a borrowed event before Dart acknowledges it.
        await Future<void>.delayed(Duration.zero);
        if (disposed) break;
        var event = mpv.mpv_wait_event(handle, -1);
        if (event.ref.event_id != mpv_event_id.MPV_EVENT_NONE) {
          var batchHasEvents = false;
          while (!disposed &&
              event.ref.event_id != mpv_event_id.MPV_EVENT_NONE) {
            batchHasEvents = true;
            acknowledged = Completer<void>();
            port.send(event.address);
            await acknowledged.future;
            if (disposed) break;
            await Future<void>.delayed(Duration.zero);
            if (disposed) break;
            // This is still the only mpv_wait_event reader. Drain ready events
            // with a zero timeout and publish NONE only after every pointer
            // from this batch has been acknowledged.
            event = mpv.mpv_wait_event(handle, 0);
          }
          if (batchHasEvents && !disposed) {
            port.send({'batchDrained': ++batchId});
          }
        }
      }
    } finally {
      receiver.close();
    }
  }

  static final _sessions = <int, EventLoopSession<Pointer<mpv_event>>>{};
}
