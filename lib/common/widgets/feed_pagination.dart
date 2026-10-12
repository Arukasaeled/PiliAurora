import 'dart:async';

import 'package:flutter/widgets.dart';

/// 按实际滚动范围分页，避免预加载区构建末项时连续请求。
class FeedPagination extends StatefulWidget {
  const FeedPagination({
    super.key,
    required this.controller,
    required this.dataChanges,
    required this.canLoadMore,
    required this.onLoadMore,
    required this.child,
  });

  final ScrollController controller;
  final Stream<Object?> dataChanges;
  final bool Function() canLoadMore;
  final Future<void> Function() onLoadMore;
  final Widget child;

  @override
  State<FeedPagination> createState() => _FeedPaginationState();
}

class _FeedPaginationState extends State<FeedPagination> {
  bool _scheduled = false;
  bool _loading = false;
  late StreamSubscription<Object?> _subscription;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_schedule);
    _subscription = widget.dataChanges.listen((_) => _schedule());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(FeedPagination oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(_schedule);
      widget.controller.addListener(_schedule);
    }
    if (widget.dataChanges != oldWidget.dataChanges) {
      _subscription.cancel();
      _subscription = widget.dataChanges.listen((_) => _schedule());
    }
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_check());
    });
  }

  Future<void> _check() async {
    if (_loading ||
        !TickerMode.valuesOf(context).enabled ||
        widget.controller.positions.length != 1 ||
        !widget.canLoadMore()) {
      return;
    }
    final position = widget.controller.position;
    if (!position.hasContentDimensions || position.viewportDimension <= 0) {
      return;
    }
    // 首屏仅补足可视区；用户滚动后提前四分之一屏请求下一页。
    final threshold = position.pixels > position.minScrollExtent
        ? position.viewportDimension / 4
        : 0.0;
    if (position.extentAfter > threshold) return;
    final extent = position.maxScrollExtent;
    _loading = true;
    try {
      await widget.onLoadMore();
    } finally {
      _loading = false;
    }
    // 无增长（错误或终点）不自行重试，增长后的布局由 metrics 通知检查。
    if (mounted && position.hasPixels && position.maxScrollExtent != extent) {
      _schedule();
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical) {
          _schedule();
        }
        return false;
      },
      child: widget.child,
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    widget.controller.removeListener(_schedule);
    super.dispose();
  }
}
