import 'dart:ffi';
import 'dart:async';
import 'dart:isolate';

import 'package:media_kit/generated/libmpv/bindings.dart';

/// Runs the potentially blocking libmpv destroy call away from the UI isolate.
Future<void> terminateMpvOnWorker(int handleAddress, String libraryPath) =>
    Isolate.run(() {
      final mpv = MPV(DynamicLibrary.open(libraryPath));
      mpv.mpv_terminate_destroy(Pointer<mpv_handle>.fromAddress(handleAddress));
    });

/// Native initialization failed after a handle existed, and cleanup did not
/// produce a release acknowledgement. Callers must quarantine the slot.
final class NativeHandleCleanupFailure implements Exception {
  NativeHandleCleanupFailure({required this.cause, required this.cleanupError})
    : releaseBarrier = Completer<void>().future;

  final Object cause;
  final Object cleanupError;
  final Future<void> releaseBarrier;
}
