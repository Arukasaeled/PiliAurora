import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

class HorizontalWheelScroll extends StatefulWidget {
  const HorizontalWheelScroll({super.key, required this.child});

  final Widget child;

  @override
  State<HorizontalWheelScroll> createState() => _HorizontalWheelScrollState();
}

class _HorizontalWheelScrollState extends State<HorizontalWheelScroll> {
  ScrollPosition? _position;

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.horizontal) {
            _position = Scrollable.of(notification.context).position;
          }
          return false;
        },
        child: Listener(
          onPointerSignal: (event) {
            final position = _position;
            if (event is PointerScrollEvent && position != null) {
              GestureBinding.instance.pointerSignalResolver.register(event, (
                _,
              ) {
                final delta = event.scrollDelta.dx != 0
                    ? event.scrollDelta.dx
                    : event.scrollDelta.dy;
                position.pointerScroll(delta);
              });
            }
          },
          child: widget.child,
        ),
      );
}
