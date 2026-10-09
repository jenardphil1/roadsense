import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

class MapScaleBar extends StatefulWidget {
  final MapController controller;
  final bool isDark;

  const MapScaleBar({
    super.key,
    required this.controller,
    required this.isDark,
  });

  @override
  State<MapScaleBar> createState() => _MapScaleBarState();
}

class _MapScaleBarState extends State<MapScaleBar> {
  bool _metric = true;
  static const double _barWidthPx = 80.0;

  double _niceValue(double value) {
    if (value <= 0) return 0;
    final double magnitude =
        pow(10, (log(value) / ln10).floor().toDouble()).toDouble();
    for (final double m in const [1.0, 2.0, 5.0]) {
      if (m * magnitude >= value) return m * magnitude;
    }
    return 10 * magnitude;
  }

  String _trimNum(double v) =>
      v % 1 == 0 ? v.round().toString() : v.toStringAsFixed(1);

  ({double distancePx, String label}) _computeScale() {
    final MapCamera camera = widget.controller.camera;
    final double latRad = camera.center.latitude * pi / 180.0;
    final double metersPerPixel =
        156543.03392 * cos(latRad) / pow(2.0, camera.zoom);

    if (_metric) {
      final double meters = _niceValue(metersPerPixel * _barWidthPx);
      if (meters <= 0) return (distancePx: _barWidthPx, label: '');
      final String label = meters < 1000
          ? '${meters.round()} m'
          : meters < 10000
          ? '${_trimNum(meters / 1000)} km'
          : '${(meters / 1000).round()} km';
      return (distancePx: _barWidthPx, label: label);
    }

    final double feetPerPx = metersPerPixel * 3.28084;
    final double feet = _niceValue(feetPerPx * _barWidthPx);
    if (feet < 5280) {
      return (
        distancePx: _barWidthPx,
        label: '${feet.round()} ft',
      );
    }
    final double miles =
        feetPerPx * _barWidthPx / 5280 < 10
        ? _niceValue(feetPerPx * _barWidthPx / 5280 * 10) / 10
        : _niceValue(feetPerPx * _barWidthPx / 5280);
    return (distancePx: _barWidthPx, label: '${_trimNum(miles)} mi');
  }

  @override
  Widget build(BuildContext context) {
    final Color fgColor = widget.isDark ? Colors.white70 : Colors.black54;
    final Color bgColor = widget.isDark
        ? Colors.black.withValues(alpha: 0.45)
        : Colors.white.withValues(alpha: 0.72);

    return StreamBuilder<MapEvent>(
      stream: widget.controller.mapEventStream,
      builder: (context, _) {
        final scale = _computeScale();
        final double barWidth = scale.distancePx.clamp(24.0, 140.0);
        return GestureDetector(
          onTap: () => setState(() => _metric = !_metric),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  scale.label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: fgColor,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 1),
                CustomPaint(
                  size: Size(barWidth, 6),
                  painter: _ScaleLinePainter(color: fgColor),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ScaleLinePainter extends CustomPainter {
  final Color color;

  _ScaleLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), paint);
    canvas.drawLine(Offset(0.8, 0), Offset(0.8, size.height), paint);
    canvas.drawLine(
      Offset(size.width - 0.8, 0),
      Offset(size.width - 0.8, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ScaleLinePainter oldDelegate) =>
      oldDelegate.color != color;
}
