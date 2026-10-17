import 'dart:async';

/// A borrowed mpv event remains valid until acknowledgement. Stop first drains
/// any callback already reading it, then joins the reader, then returns to the
/// handle owner. Never use a fixed timer as proof that the reader has exited.
class EventLoopSession<E> {
  EventLoopSession({
    required this.onEvent,
    required this.onBatchDrained,
    required this.acknowledge,
    required this.shutdown,
    required this.onError,
  });

  final FutureOr<void> Function(E event) onEvent;
  final FutureOr<void> Function(int batchId) onBatchDrained;
  final void Function() acknowledge;
  final FutureOr<void> Function() shutdown;
  final void Function(Object error, StackTrace stack) onError;
  Future<void> _pending = Future.value();
  Future<void>? _stop;
  bool _closing = false;
  bool _closed = false;

  bool get closing => _closing;

  void add(E event) {
    if (_closed) return;
    _pending = _pending.then((_) async {
      try {
        // The owner may still need hook and command-reply events to complete
        // teardown. The callback decides which non-teardown facts to ignore.
        await onEvent(event);
      } catch (error, stack) {
        onError(error, stack);
      } finally {
        if (!_closed) acknowledge();
      }
    });
  }

  /// Queues the reader's NONE boundary after every event posted before it.
  ///
  /// The caller must only invoke this after its sole reader has observed NONE.
  /// Keeping it on [_pending] ensures all borrowed event data has been copied
  /// and acknowledged before hook work is released.
  void drain(int batchId) {
    if (_closed) return;
    _pending = _pending.then((_) async {
      try {
        await onBatchDrained(batchId);
      } catch (error, stack) {
        onError(error, stack);
      }
    });
  }

  Future<void> stop() {
    _closing = true;
    return _stop ??= _shutdown();
  }

  Future<void> _shutdown() async {
    await _pending;
    await shutdown();
    _closed = true;
  }
}
