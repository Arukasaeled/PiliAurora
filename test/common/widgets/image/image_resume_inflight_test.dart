import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';

class _FileCache implements BaseCacheManager {
  _FileCache(this.file);

  final File file;
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool? withProgress,
  }) async* {
    yield FileInfo(
      file,
      FileSource.Cache,
      DateTime(2100),
      url,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => const Duration(milliseconds: 100);
}

class _GatedCodec implements ui.Codec {
  _GatedCodec(this.source);
  final ui.Image source;
  final gates = <Completer<void>>[];
  final images = <ui.Image>[];
  var active = 0;
  var peakActive = 0;
  @override
  int get frameCount => 100;
  @override
  int get repetitionCount => -1;
  @override
  Future<ui.FrameInfo> getNextFrame() async {
    active++;
    if (active > peakActive) peakActive = active;
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    active--;
    final image = source.clone();
    images.add(image);
    return _Frame(image);
  }

  @override
  void dispose() {}
}

void main() {
  testWidgets(
    'resuming a retained stream does not duplicate an in-flight frame',
    (
      tester,
    ) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xff224466), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final source = await picture.toImage(2, 2);
      picture.dispose();
      late Directory directory;
      late File file;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('pili-image-resume-');
        final bytes = await source.toByteData(format: ui.ImageByteFormat.png);
        file = await File('${directory.path}/image.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
      final codec = _GatedCodec(source);
      final provider = CachedImageProvider(
        'https://example.test/inflight.webp',
        cacheManager: _FileCache(file),
      );
      final stream = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        return codec;
      });
      final listener = ImageStreamListener((info, _) => info.dispose());
      final handle = stream.keepAlive();
      Future<void> flush() => tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      stream.addListener(listener);
      var listening = true;
      var outstanding = 0;
      try {
        for (var i = 0; i < 100 && codec.gates.isEmpty; i++) {
          await flush();
        }
        expect(codec.gates.length, 1);
        codec.gates.first.complete();
        await flush();
        await tester.pump();
        for (var i = 0; i < 100 && codec.gates.length < 2; i++) {
          await flush();
        }
        expect(codec.gates.length, 2);
        expect(codec.active, 1);
        for (var i = 0; i < 3; i++) {
          stream
            ..removeListener(listener)
            ..addListener(listener);
          await flush();
        }
        outstanding = codec.active;
        // 所有结果在同一 Flutter 帧前返回，观察 pending frame 是否被覆盖。
        for (final gate in codec.gates.toList()) {
          if (!gate.isCompleted) gate.complete();
        }
        await flush();
        stream.removeListener(listener);
        listening = false;
        await tester.pump();
        handle.dispose();
        await flush();
        expect(outstanding, 1);
        expect(codec.peakActive, 1);
        expect(codec.gates, hasLength(2));
        expect(codec.images.every((image) => image.debugDisposed), isTrue);
      } finally {
        if (listening) {
          stream.removeListener(listener);
          handle.dispose();
        }
        for (final gate in codec.gates) {
          if (!gate.isCompleted) gate.complete();
        }
        await flush();
        for (final image in codec.images) {
          if (!image.debugDisposed) image.dispose();
        }
        source.dispose();
        await tester.pumpAndSettle();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
