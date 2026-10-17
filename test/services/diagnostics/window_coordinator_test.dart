import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/window_coordinator.dart';

void main() {
  late HttpServer server;
  late WebSocket client;
  late WebSocket peer;
  late DiagnosticWindowCoordinator coordinator;
  late Map<int, WebSocket?> sockets;
  late Set<int> skipped;
  late List<String> actions;
  var respond = true;
  late Completer<void> disconnected;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final connected = Completer<WebSocket>();
    actions = [];
    respond = true;
    disconnected = Completer<void>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      connected.complete(socket);
      socket.listen((data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        actions.add(message['action'] as String);
        if (respond) {
          socket.add(jsonEncode({'id': message['id'], 'success': true}));
        }
      });
    });
    client = await WebSocket.connect('ws://127.0.0.1:${server.port}');
    peer = await connected.future;
    sockets = {0: null, 1: client};
    skipped = {};
    coordinator = DiagnosticWindowCoordinator(
      sockets: () => sockets,
      onSkipped: (ids) {
        skipped = ids;
      },
      timeout: const Duration(milliseconds: 200),
    );
    client.listen(
      (data) => coordinator.receive(
        1,
        jsonDecode(data as String) as Map<String, dynamic>,
      ),
      onDone: () {
        disconnected.complete();
      },
    );
  });

  tearDown(() async {
    await client.close();
    await peer.close();
    await server.close(force: true);
  });

  test('real socket pause clear resume skips windows still starting', () async {
    await coordinator.pause();
    await coordinator.clear();
    await coordinator.resume();
    expect(skipped, {0});
    expect(actions, ['pause', 'clear', 'resume']);
  });

  test('disconnect after pause is skipped by clear and resume', () async {
    await coordinator.pause();
    await peer.close();
    await disconnected.future;
    await coordinator.clear();
    await coordinator.resume();
    expect(skipped, {0, 1});
    expect(actions, ['pause']);
  });

  test('already disconnected socket is skipped on initial pause', () async {
    await peer.close();
    await disconnected.future;
    await coordinator.pause();
    await coordinator.clear();
    await coordinator.resume();
    expect(skipped, {0, 1});
    expect(actions, isEmpty);
  });

  test('connected but unresponsive window still reports a timeout', () async {
    respond = false;
    await expectLater(coordinator.pause(), throwsA(isA<TimeoutException>()));
    respond = true;
    await coordinator.resume();
    expect(actions, ['pause', 'resume']);
  });
}
