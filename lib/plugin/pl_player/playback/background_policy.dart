import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';

/// 后台策略属于会话，页面卸载、切换 owner 或媒体尚未加载时仍需生效。
class PlaybackBackgroundPolicy with WidgetsBindingObserver {
  PlaybackBackgroundPolicy({
    required this.session,
    required bool continuePlaying,
  }) : _enabled = continuePlaying {
    WidgetsBinding.instance.addObserver(this);
    _state = WidgetsBinding.instance.lifecycleState;
    _update();
  }

  final PlaybackSession session;
  bool _enabled;
  set continuePlaying(bool value) {
    _enabled = value;
    _update();
  }

  AppLifecycleState? _state;
  PlaybackInhibitorToken? _token;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _state = state;
    _update();
  }

  void _update() {
    if (_enabled || _state == AppLifecycleState.resumed) {
      _release();
    } else if (_state == AppLifecycleState.paused ||
        _state == AppLifecycleState.detached) {
      _token ??= session.acquireSessionInhibitor(
        PlaybackInhibitorSource.backgroundPolicy,
      );
    }
  }

  void _release() {
    final token = _token;
    _token = null;
    if (token != null) unawaited(session.releaseSessionInhibitor(token));
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release();
  }
}
