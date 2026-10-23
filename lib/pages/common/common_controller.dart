import 'dart:async';

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:pili_aurora/utils/rate_limiter.dart';
import 'package:flutter/widgets.dart' show ScrollController;
import 'package:get/get.dart';

mixin ScrollOrRefreshMixin {
  ScrollController get scrollController;

  void animateToTop() => scrollController.animToTop();

  Future<void> onRefresh();

  void toTopOrRefresh() {
    if (scrollController.hasClients) {
      if (scrollController.position.pixels == 0) {
        ActionThrottle.run(
          'topOrRefresh',
          const Duration(milliseconds: 500),
          onRefresh,
        );
      } else {
        animateToTop();
      }
    }
  }
}

abstract class CommonController<R, T> extends GetxController
    with ScrollOrRefreshMixin {
  @override
  final ScrollController scrollController = ScrollController();

  int _requestVersion = 0;
  bool _isLoading = false;
  bool _disposed = false;

  bool get isLoading => _isLoading;
  Rx<LoadingState<T>> get loadingState;

  /// 数据控制器默认可继续请求；列表控制器同时检查首屏数据和分页终点。
  bool get canLoadMore => true;

  Future<LoadingState<R>> customGetData();

  Future<void>? prepareQuery() => null;

  Future<void>? prepareResponse(R response, bool Function() isCurrent) => null;

  Object? get queryContext => null;

  /// 过滤后的补位需求；普通数据请求在首个响应后结束。
  int remainingItemsToLoad(int remaining) => 0;

  /// 刷新替换当前查询；加载更多串行执行，不让旧响应写回新的页面状态。
  /// 不假装取消 HTTP 请求，只取消其对当前控制器的写回资格。
  Future<void> queryData([bool isRefresh = true]) async {
    if (_disposed || (!isRefresh && (isLoading || !canLoadMore))) return;
    final version = ++_requestVersion;
    final context = queryContext;
    _isLoading = true;
    try {
      final preparation = prepareQuery();
      if (preparation != null) await preparation;
      var refresh = isRefresh;
      var remaining = 0;
      // 单次操作最多读取五页，避免来源持续返回被屏蔽内容时无休止请求。
      for (var attempt = 0; attempt < 5; attempt++) {
        if (_disposed ||
            version != _requestVersion ||
            !identical(context, queryContext)) {
          return;
        }
        final response = await customGetData();
        if (_disposed ||
            version != _requestVersion ||
            !identical(context, queryContext)) {
          return;
        }
        switch (response) {
          case Success<R>():
            final preparation = prepareResponse(
              response.response,
              () =>
                  !_disposed &&
                  version == _requestVersion &&
                  identical(context, queryContext),
            );
            if (preparation != null) {
              await preparation;
              if (_disposed ||
                  version != _requestVersion ||
                  !identical(context, queryContext)) {
                return;
              }
            }
            applyResponse(refresh, response);
            remaining = remainingItemsToLoad(remaining);
            if (remaining <= 0 || !canLoadMore) return;
            refresh = false;
          case Error(:final errMsg):
            if (refresh && !handleError(errMsg)) {
              loadingState.value = response;
            }
            return;
          case Loading():
            return;
        }
      }
    } finally {
      // 旧请求完成时不能释放后来请求的加载标记。
      if (version == _requestVersion) _isLoading = false;
    }
  }

  void applyResponse(bool isRefresh, Success<R> response);

  bool customHandleResponse(bool isRefresh, Success<R> response) {
    return false;
  }

  bool handleError(String? errMsg) {
    return false;
  }

  @override
  Future<void> onRefresh() {
    return queryData();
  }

  Future<void> onLoadMore() {
    return queryData(false);
  }

  Future<void> onReload() {
    return onRefresh();
  }

  @override
  void onClose() {
    _disposed = true;
    _requestVersion++;
    _isLoading = false;
    scrollController.dispose();
    super.onClose();
  }
}
