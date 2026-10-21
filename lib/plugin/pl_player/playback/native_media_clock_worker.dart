import 'dart:developer' show Timeline;
import 'dart:ffi';
import 'dart:isolate';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_media_clock.dart';

/// 调用方持有原生句柄，须等待返回后再销毁 Player。
Future<PlaybackMediaAnchor?> sampleNativeMediaClockOnWorker({
  required int handleAddress,
  required String libraryPath,
  required int playlistEntryId,
  required int continuity,
}) => Isolate.run(() {
  final mpv = MPV(DynamicLibrary.open(libraryPath));
  final handle = Pointer<mpv_handle>.fromAddress(handleAddress);
  String read(String property) {
    final name = property.toNativeUtf8();
    final value = mpv.mpv_get_property_string(handle, name);
    try {
      return value == nullptr ? '' : value.toDartString();
    } finally {
      calloc.free(name);
      if (value != nullptr) mpv.mpv_free(value.cast());
    }
  }

  return sampleNativeMediaClock(
    readProperty: read,
    playlistEntryId: playlistEntryId,
    continuity: continuity,
    monotonicNowUs: () => Timeline.now,
  );
});
