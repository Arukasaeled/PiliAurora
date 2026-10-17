import 'dart:async';

import 'package:meta/meta.dart';

enum NativeHookName { onLoad, onPreloaded, onUnload, unknown }

@immutable
final class NativeHookRequest {
  const NativeHookRequest({
    required this.hookId,
    required this.name,
    required this.nativeHookName,
    required this.playlistEntryId,
    required this.teardown,
  });

  final int hookId;
  final NativeHookName name;
  final String nativeHookName;
  final int? playlistEntryId;
  final bool teardown;
}

@immutable
final class NativeVideoTrackMetadata {
  const NativeVideoTrackMetadata({
    required this.id,
    required this.type,
    required this.demuxWidth,
    required this.demuxHeight,
    required this.demuxFps,
    required this.demuxPar,
    required this.demuxRotate,
    required this.demuxCropKnownNone,
    required this.selected,
  });

  final String id;
  final String type;
  final int? demuxWidth;
  final int? demuxHeight;
  final double? demuxFps;
  final double? demuxPar;
  final int? demuxRotate;

  /// Whether the fixed bundled mpv track-list proves there is no demux crop.
  /// A partial/malformed crop field set remains unknown.
  final bool? demuxCropKnownNone;
  final bool? selected;
}

@immutable
final class NativeVideoOutputParameters {
  const NativeVideoOutputParameters({
    required this.width,
    required this.height,
    required this.displayWidth,
    required this.displayHeight,
    required this.pixelAspectRatio,
    required this.rotation,
  });

  final int? width;
  final int? height;
  final int? displayWidth;
  final int? displayHeight;
  final double? pixelAspectRatio;
  final int? rotation;
}

final class NativeVideoTrackListUnavailable implements Exception {
  const NativeVideoTrackListUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'Native video track list unavailable: $reason';
}

final class NativeVideoOutputParametersUnavailable implements Exception {
  const NativeVideoOutputParametersUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'Native video output parameters unavailable: $reason';
}

/// The narrow set of libmpv operations permitted while a lifecycle hook is held.
abstract interface class NativeHookApi {
  bool get isValid;

  List<NativeVideoTrackMetadata> readVideoTracks();

  void setOption(String name, String value);
}

typedef NativeLifecycleHookHandler =
    FutureOr<void> Function(NativeHookRequest request, NativeHookApi api);

/// Removes a lifecycle hook handler. A currently running callback is still
/// tracked and must finish or be revoked before the native player is released.
final class NativeHookRegistration {
  NativeHookRegistration(this._dispose);

  final Future<void> Function() _dispose;
  Future<void>? _disposed;

  Future<void> dispose() => _disposed ??= Future<void>.sync(_dispose);
}
