import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';

class _FileCache implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool? withProgress,
  }) async* {
    yield FileInfo(
      // 合成的三帧 1600×1600 WebP，不包含用户图片。
      File('test/common/widgets/image/fixtures/animated.webp').absolute,
      FileSource.Cache,
      DateTime(2100),
      url,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CancelSecondFrameCodec implements ui.Codec {
  _CancelSecondFrameCodec(this.delegate, this.cancel);
  final ui.Codec delegate;
  final void Function() cancel;
  var requests = 0;
  var completed = 0;
  var disposed = false;
  @override
  int get frameCount => delegate.frameCount;
  @override
  int get repetitionCount => delegate.repetitionCount;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    final result = delegate.getNextFrame();
    requests++;
    if (requests == 2) cancel();
    return result.then((frame) {
      completed++;
      return frame;
    });
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    delegate.dispose();
  }
}

void main() {
  testWidgets(
    'cancelling native prefetch leaves decode capacity for new images',
    (tester) async {
      final cleanups = <void Function()>[];
      final codecs = <_CancelSecondFrameCodec>[];
      var cancelled = 0;
      var freshStarted = false;
      Future<void> tick() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }

      try {
        for (var i = 0; i < 2; i++) {
          final provider = CachedImageProvider(
            'https://example.test/cancel-$i.webp',
            cacheManager: _FileCache(),
          );
          late ImageStreamCompleter stream;
          late ImageStreamCompleterHandle handle;
          final listener = ImageStreamListener((info, _) => info.dispose());
          var released = false;
          void release() {
            if (released) return;
            released = true;
            stream.removeListener(listener);
            handle.dispose();
          }

          cleanups.add(release);
          stream = provider.loadImage(provider, (
            buffer, {
            getTargetSize,
          }) async {
            final native = await ui.instantiateImageCodecWithSize(
              buffer,
              getTargetSize: getTargetSize,
            );
            final codec = _CancelSecondFrameCodec(native, () {
              release();
              cancelled++;
            });
            codecs.add(codec);
            return codec;
          });
          handle = stream.keepAlive();
          stream.addListener(listener);
        }
        for (var i = 0; i < 100 && cancelled < 2; i++) {
          await tick();
        }
        expect(cancelled, 2);
        final fresh = CachedImageProvider(
          'https://example.test/fresh.webp',
          cacheManager: _FileCache(),
        );
        final listener = ImageStreamListener((info, _) => info.dispose());
        final stream = fresh.loadImage(fresh, (buffer, {getTargetSize}) {
          freshStarted = true;
          return ui.instantiateImageCodecWithSize(
            buffer,
            getTargetSize: getTargetSize,
          );
        });
        final handle = stream.keepAlive();
        stream.addListener(listener);
        cleanups.add(() {
          stream.removeListener(listener);
          handle.dispose();
        });
        for (var i = 0; i < 100 && !freshStarted; i++) {
          await tick();
        }
        expect(freshStarted, isTrue);
        expect(codecs.every((codec) => codec.completed == 2), isTrue);
        expect(codecs.every((codec) => codec.disposed), isTrue);
      } finally {
        for (final cleanup in cleanups) {
          cleanup();
        }
        await tick();
        await tester.pumpAndSettle();
      }
    },
  );
}
