import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 维护操作只协调已连接窗口；未确认暂停的窗口文件保持原样。
class DiagnosticWindowCoordinator {
  DiagnosticWindowCoordinator({
    required this.sockets,
    required this.onSkipped,
    this.timeout = const Duration(seconds: 3),
  });
  final Map<int, WebSocket?> Function() sockets;
  final void Function(Set<int>) onSkipped;
  final Duration timeout;
  final _paused = <int, WebSocket>{};
  final _skipped = <int>{};
  final _requests = <(int, int), Completer<void>>{};
  int _sequence = 0;

  void receive(int windowId, Map<String, dynamic> message) {
    final request = _requests.remove((windowId, message['id'] as int));
    if (message['success'] == true) {
      request?.complete();
    } else {
      request?.completeError(StateError('子窗口诊断协调失败'));
    }
  }

  void _skip(int id) {
    _skipped.add(id);
    onSkipped(Set.of(_skipped));
  }

  Future<void> _control(int id, WebSocket socket, String action) async {
    if (socket.readyState != WebSocket.open) {
      _skip(id);
      return;
    }
    final sequence = ++_sequence;
    final key = (id, sequence);
    final request = _requests[key] = Completer<void>();
    try {
      socket.add(
        jsonEncode({
          'type': 'diagnosticControl',
          'id': sequence,
          'action': action,
        }),
      );
      await request.future.timeout(timeout);
    } catch (_) {
      if (socket.readyState == WebSocket.open) rethrow;
      _skip(id);
    } finally {
      _requests.remove(key);
    }
  }

  Future<void> pause() async {
    _skipped.clear();
    _paused.clear();
    onSkipped({});
    for (final entry in sockets().entries) {
      final socket = entry.value;
      if (socket?.readyState == WebSocket.open) {
        _paused[entry.key] = socket!;
      } else {
        _skip(entry.key);
      }
    }
    await Future.wait(
      _paused.entries.map((entry) => _control(entry.key, entry.value, 'pause')),
    );
  }

  Future<void> clear() => Future.wait(
    _paused.entries.map((entry) => _control(entry.key, entry.value, 'clear')),
  );

  Future<void> resume() async {
    try {
      await Future.wait(
        _paused.entries.map(
          (entry) => _control(entry.key, entry.value, 'resume'),
        ),
      );
    } finally {
      _paused.clear();
    }
  }
}
