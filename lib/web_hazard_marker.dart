import 'package:flutter/material.dart';

/// Sonar-radar hazard marker from the login/register map, shared by the web
/// app maps: an expanding ripple ring + soft halo drawn behind the existing
/// pothole pin (the pin widget is passed through untouched as the core).
class PulsingHazardMarker extends StatelessWidget {
  final Animation<double> animation;
  final Color color;

  /// Rendered square size of the core pin widget.
  final double coreSize;

  /// The existing marker widget — used as-is as the core.
  final Widget child;

  const PulsingHazardMarker({
    super.key,
    required this.animation,
    required this.color,
    required this.coreSize,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final baseRadius = coreSize / 2;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final progress = MediaQuery.disableAnimationsOf(context)
            ? 0.0
            : animation.value;
        // 13 px reach keeps the max ripple inside the ~+26 px marker box.
        final rippleRadius = baseRadius + (progress * 13.0);
        final opacity = (1.0 - progress).clamp(0.0, 1.0);
        return Stack(
          alignment: Alignment.center,
          children: [
            // Outer sonar ripple ring
            IgnorePointer(
              child: Container(
                width: rippleRadius * 2,
                height: rippleRadius * 2,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: opacity * 0.65),
                    width: 2.0,
                  ),
                ),
              ),
            ),
            // Inner glowing halo
            IgnorePointer(
              child: Container(
                width: coreSize + 8,
                height: coreSize + 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.22),
                ),
              ),
            ),
            // Core pin (existing marker widget)
            child,
          ],
        );
      },
    );
  }
}
