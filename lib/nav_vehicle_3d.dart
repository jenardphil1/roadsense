import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Available 3D navigation vehicle/avatar profiles matching Google Maps style.
enum NavVehicleType { car, motorcycle, walking }

/// Camera viewing angles cycled by the top Driving Mode HUD button.
enum DrivingCameraAngle { chase3D, topDown2D, northUp2D, overview }

extension DrivingCameraAngleX on DrivingCameraAngle {
  DrivingCameraAngle next({required bool hasRoute}) {
    switch (this) {
      case DrivingCameraAngle.chase3D:
        return DrivingCameraAngle.topDown2D;
      case DrivingCameraAngle.topDown2D:
        return DrivingCameraAngle.northUp2D;
      case DrivingCameraAngle.northUp2D:
        return hasRoute
            ? DrivingCameraAngle.overview
            : DrivingCameraAngle.chase3D;
      case DrivingCameraAngle.overview:
        return DrivingCameraAngle.chase3D;
    }
  }

  String get shortBadge {
    switch (this) {
      case DrivingCameraAngle.chase3D:
        return '3D';
      case DrivingCameraAngle.topDown2D:
        return '2D';
      case DrivingCameraAngle.northUp2D:
        return 'N';
      case DrivingCameraAngle.overview:
        return 'ALL';
    }
  }

  String get label {
    switch (this) {
      case DrivingCameraAngle.chase3D:
        return '3D Driving View';
      case DrivingCameraAngle.topDown2D:
        return '2D Overhead View';
      case DrivingCameraAngle.northUp2D:
        return 'North-Up View';
      case DrivingCameraAngle.overview:
        return 'Route Overview';
    }
  }

  bool get isHeadingUp =>
      this == DrivingCameraAngle.chase3D ||
      this == DrivingCameraAngle.topDown2D;

  double get tiltFactor => this == DrivingCameraAngle.chase3D ? 1.0 : 0.0;
}

/// Renders a sculpted rear-3/4 chase-cam 3D illustration for [type] pointing
/// straight forward (upward along -Y).
class NavVehicle3DWidget extends StatelessWidget {
  final NavVehicleType type;
  final double size;
  final bool showHeadlightGlow;

  const NavVehicle3DWidget({
    super.key,
    required this.type,
    this.size = 60.0,
    this.showHeadlightGlow = true,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(size, size),
        painter: _NavVehicle3DPainter(
          type: type,
          showHeadlightGlow: showHeadlightGlow,
        ),
      ),
    );
  }
}

class _NavVehicle3DPainter extends CustomPainter {
  final NavVehicleType type;
  final bool showHeadlightGlow;

  const _NavVehicle3DPainter({
    required this.type,
    required this.showHeadlightGlow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 64.0;
    canvas.save();
    canvas.scale(s, s);
    switch (type) {
      case NavVehicleType.car:
        _paintCar3D(canvas);
      case NavVehicleType.motorcycle:
        _paintMotorcycle3D(canvas);
      case NavVehicleType.walking:
        _paintWalking3D(canvas);
    }
    canvas.restore();
  }

  void _paintHeadlightAndShadow(
    Canvas canvas, {
    required Offset shadowCenter,
    required double shadowRx,
    required double shadowRy,
    Color glowColor = const Color(0x6680F3FF),
  }) {
    if (showHeadlightGlow) {
      final beamRect = Rect.fromCenter(
        center: const Offset(32, 16),
        width: 34,
        height: 24,
      );
      canvas.drawOval(
        beamRect,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0, 0.35),
            radius: 0.72,
            colors: [glowColor, glowColor.withValues(alpha: 0.0)],
          ).createShader(beamRect),
      );
    }

    final shadowRect = Rect.fromCenter(
      center: shadowCenter,
      width: shadowRx * 2,
      height: shadowRy * 2,
    );
    canvas.drawOval(
      shadowRect,
      Paint()
        ..color = const Color(0x6B000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0),
    );
  }

  void _paintCar3D(Canvas canvas) {
    _paintHeadlightAndShadow(
      canvas,
      shadowCenter: const Offset(32, 39),
      shadowRx: 18,
      shadowRy: 21,
    );

    // 4 dark tires protruding subtly under wheel arches
    final tirePaint = Paint()..color = const Color(0xFF111827);
    for (final r in const [
      Rect.fromLTWH(15.2, 19.0, 4.0, 8.5),
      Rect.fromLTWH(44.8, 19.0, 4.0, 8.5),
      Rect.fromLTWH(15.0, 41.5, 4.4, 9.5),
      Rect.fromLTWH(44.6, 41.5, 4.4, 9.5),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(2.0)),
        tirePaint,
      );
    }

    // Side mirrors
    final mirrorPaint = Paint()..color = const Color(0xFFD8E1EC);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(12.8, 25.0, 4.2, 2.8),
        const Radius.circular(1.3),
      ),
      mirrorPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(47.0, 25.0, 4.2, 2.8),
        const Radius.circular(1.3),
      ),
      mirrorPaint,
    );

    // Sculpted rear/side 3D chassis Skirt (extruded bottom edge for depth)
    final skirtRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(16.5, 13.0, 31.0, 43.0),
      const Radius.circular(11.5),
    );
    canvas.drawRRect(
      skirtRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFDCE4EF), Color(0xFF94A3B8)],
        ).createShader(skirtRect.outerRect),
    );

    // Main pearlescent white upper body (tapered hatchback silhouette)
    final bodyPath = Path()
      ..moveTo(21.5, 11.5)
      ..quadraticBezierTo(32.0, 9.2, 42.5, 11.5)
      ..quadraticBezierTo(46.8, 13.2, 46.8, 22.0)
      ..lineTo(46.8, 45.5)
      ..quadraticBezierTo(46.5, 52.5, 41.0, 53.5)
      ..quadraticBezierTo(32.0, 54.6, 23.0, 53.5)
      ..quadraticBezierTo(17.5, 52.5, 17.2, 45.5)
      ..lineTo(17.2, 22.0)
      ..quadraticBezierTo(17.2, 13.2, 21.5, 11.5)
      ..close();
    canvas.drawPath(
      bodyPath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment(-0.8, -1.0),
          end: Alignment(0.8, 1.0),
          colors: [Color(0xFFFFFFFF), Color(0xFFF1F5F9), Color(0xFFCBD5E1)],
        ).createShader(const Rect.fromLTWH(17, 9, 30, 46)),
    );
    canvas.drawPath(
      bodyPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = const Color(0xFFE2E8F0),
    );

    // Headlight lenses at front nose
    final headPaint = Paint()..color = const Color(0xFFE0F7FA);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(19.2, 11.8, 5.0, 2.2),
        const Radius.circular(1.1),
      ),
      headPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(39.8, 11.8, 5.0, 2.2),
        const Radius.circular(1.1),
      ),
      headPaint,
    );

    // Glossy cabin glass (windshield + rear/side glass)
    final glassPath = Path()
      ..moveTo(22.2, 19.2)
      ..quadraticBezierTo(32.0, 17.5, 41.8, 19.2)
      ..lineTo(43.8, 26.8)
      ..lineTo(43.2, 43.2)
      ..quadraticBezierTo(32.0, 45.5, 20.8, 43.2)
      ..lineTo(20.2, 26.8)
      ..close();
    canvas.drawPath(
      glassPath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF334155), Color(0xFF0F172A)],
        ).createShader(const Rect.fromLTWH(20, 17, 24, 28)),
    );

    // Diagonal glass specular sheen
    canvas.drawPath(
      Path()
        ..moveTo(23.2, 20.0)
        ..lineTo(28.5, 19.2)
        ..lineTo(23.5, 27.5)
        ..lineTo(21.2, 26.2)
        ..close(),
      Paint()..color = Colors.white.withValues(alpha: 0.22),
    );

    // Raised 3D Roof panel
    final roofRRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(22.8, 27.2, 18.4, 14.5),
      const Radius.circular(4.2),
    );
    canvas.drawRRect(
      roofRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFE2E8F0)],
        ).createShader(roofRRect.outerRect),
    );

    // Glowing Red LED Tail Lights
    final tailPaint = Paint()..color = const Color(0xFFFF3B30);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(18.6, 50.0, 5.8, 2.4),
        const Radius.circular(1.2),
      ),
      tailPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(39.6, 50.0, 5.8, 2.4),
        const Radius.circular(1.2),
      ),
      tailPaint,
    );
  }

  void _paintMotorcycle3D(Canvas canvas) {
    _paintHeadlightAndShadow(
      canvas,
      shadowCenter: const Offset(32, 37),
      shadowRx: 11,
      shadowRy: 22,
    );

    final tirePaint = Paint()..color = const Color(0xFF111827);
    // Front wheel
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(29.0, 9.0, 6.0, 13.0),
        const Radius.circular(3.0),
      ),
      tirePaint,
    );
    // Rear fat tire
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(28.0, 42.5, 8.0, 14.0),
        const Radius.circular(4.0),
      ),
      tirePaint,
    );

    // Metallic chrome exhaust pipe (right side)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(36.2, 38.0, 3.2, 13.5),
        const Radius.circular(1.6),
      ),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFE2E8F0), Color(0xFF64748B)],
        ).createShader(const Rect.fromLTWH(36.2, 38.0, 3.2, 13.5)),
    );

    // Handlebars & mirrors
    canvas.drawPath(
      Path()
        ..moveTo(19.5, 22.8)
        ..quadraticBezierTo(32.0, 18.2, 44.5, 22.8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF334155),
    );
    canvas.drawCircle(
      const Offset(20.0, 21.8),
      2.2,
      Paint()..color = const Color(0xFF94A3B8),
    );
    canvas.drawCircle(
      const Offset(44.0, 21.8),
      2.2,
      Paint()..color = const Color(0xFF94A3B8),
    );

    // Front fairing & sporty tank (metallic sky blue + white)
    final fairing = Path()
      ..moveTo(32.0, 12.5)
      ..quadraticBezierTo(39.0, 15.5, 38.2, 26.5)
      ..lineTo(36.5, 45.0)
      ..quadraticBezierTo(32.0, 48.0, 27.5, 45.0)
      ..lineTo(25.8, 26.5)
      ..quadraticBezierTo(25.0, 15.5, 32.0, 12.5)
      ..close();
    canvas.drawPath(
      fairing,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF38BDF8), Color(0xFF0284C7), Color(0xFF1E293B)],
        ).createShader(const Rect.fromLTWH(25, 12, 14, 36)),
    );

    // Tinted front windscreen
    canvas.drawPath(
      Path()
        ..moveTo(32.0, 14.5)
        ..quadraticBezierTo(36.2, 17.5, 35.6, 22.5)
        ..lineTo(28.4, 22.5)
        ..quadraticBezierTo(27.8, 17.5, 32.0, 14.5)
        ..close(),
      Paint()..color = const Color(0xFF0F172A),
    );

    // Red LED taillight
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(29.2, 46.2, 5.6, 2.2),
        const Radius.circular(1.1),
      ),
      Paint()..color = const Color(0xFFFF3B30),
    );

    // Rider jacket shoulders (3D depth)
    final riderTorso = RRect.fromRectAndRadius(
      const Rect.fromLTWH(22.2, 26.0, 19.6, 15.0),
      const Radius.circular(7.5),
    );
    canvas.drawRRect(
      riderTorso,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF334155), Color(0xFF0F172A)],
        ).createShader(riderTorso.outerRect),
    );

    // Rider arms gripping bars
    final armPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF1E293B);
    canvas.drawLine(
      const Offset(24.0, 29.5),
      const Offset(21.5, 22.5),
      armPaint,
    );
    canvas.drawLine(
      const Offset(40.0, 29.5),
      const Offset(42.5, 22.5),
      armPaint,
    );

    // 3D Glossy White Helmet with dark visor forward
    final helmetRect = const Rect.fromLTWH(25.2, 23.0, 13.6, 13.6);
    canvas.drawOval(
      helmetRect.shift(const Offset(0, 1.5)),
      Paint()..color = Colors.black38,
    );
    canvas.drawOval(
      helmetRect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.25, -0.35),
          radius: 0.75,
          colors: [Color(0xFFFFFFFF), Color(0xFFCBD5E1)],
        ).createShader(helmetRect),
    );
    // Racing stripe & specular dot on helmet
    canvas.drawArc(
      helmetRect.deflate(1.5),
      -math.pi * 0.85,
      math.pi * 0.70,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF0F172A),
    );
    canvas.drawCircle(
      const Offset(29.8, 27.6),
      1.6,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
  }

  void _paintWalking3D(Canvas canvas) {
    _paintHeadlightAndShadow(
      canvas,
      shadowCenter: const Offset(32, 37),
      shadowRx: 14,
      shadowRy: 14,
      glowColor: const Color(0x5538BDF8),
    );

    // Directional cyan ground ring under pedestrian
    canvas.drawCircle(
      const Offset(32, 34),
      17.0,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = const Color(0x8838BDF8),
    );

    // Stepping shoes / feet
    final shoePaint = Paint()..color = const Color(0xFF1E293B);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(24.0, 22.0, 5.5, 9.5),
        const Radius.circular(2.7),
      ),
      shoePaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(34.5, 36.5, 5.5, 9.5),
        const Radius.circular(2.7),
      ),
      shoePaint,
    );

    // Backpack (behind torso, at bottom edge in top-down rear view)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(24.5, 36.5, 15.0, 8.5),
        const Radius.circular(4.0),
      ),
      Paint()..color = const Color(0xFF0F172A),
    );

    // 3D Jacket shoulders & torso
    final torsoRRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(20.5, 25.0, 23.0, 14.5),
      const Radius.circular(7.2),
    );
    canvas.drawRRect(
      torsoRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF38BDF8), Color(0xFF0369A1)],
        ).createShader(torsoRRect.outerRect),
    );

    // 3D Head & Cap brim facing up
    canvas.drawOval(
      const Rect.fromLTWH(27.5, 19.5, 9.0, 7.0),
      Paint()..color = const Color(0xFF1D4ED8),
    );
    final headRect = const Rect.fromLTWH(25.2, 22.5, 13.6, 13.6);
    canvas.drawOval(
      headRect.shift(const Offset(0, 1.5)),
      Paint()..color = Colors.black38,
    );
    canvas.drawOval(
      headRect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.2, -0.35),
          radius: 0.75,
          colors: [Color(0xFF60A5FA), Color(0xFF1E40AF)],
        ).createShader(headRect),
    );
    canvas.drawCircle(
      const Offset(29.8, 27.0),
      1.6,
      Paint()..color = Colors.white.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(covariant _NavVehicle3DPainter oldDelegate) =>
      oldDelegate.type != type ||
      oldDelegate.showHeadlightGlow != showHeadlightGlow;
}

/// Compact Google Maps–style red/white compass diamond needle for driving HUD.
class NavCompassNeedleIcon extends StatelessWidget {
  final double size;
  final double angleRadians;

  const NavCompassNeedleIcon({
    super.key,
    this.size = 24.0,
    this.angleRadians = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final child = CustomPaint(
      size: Size(size, size),
      painter: const _CompassNeedlePainter(),
    );
    if (angleRadians.abs() < 1e-4) {
      return child;
    }
    return Transform.rotate(angle: angleRadians, child: child);
  }
}

class _CompassNeedlePainter extends CustomPainter {
  const _CompassNeedlePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final halfLen = size.height * 0.42;
    final halfW = size.width * 0.16;

    // North needle (red)
    canvas.drawPath(
      Path()
        ..moveTo(cx, cy - halfLen)
        ..lineTo(cx + halfW, cy)
        ..lineTo(cx - halfW, cy)
        ..close(),
      Paint()..color = const Color(0xFFEA4335),
    );
    // South needle (white/silver)
    canvas.drawPath(
      Path()
        ..moveTo(cx, cy + halfLen)
        ..lineTo(cx + halfW, cy)
        ..lineTo(cx - halfW, cy)
        ..close(),
      Paint()..color = const Color(0xFFE2E8F0),
    );
    canvas.drawCircle(
      Offset(cx, cy),
      size.width * 0.06,
      Paint()..color = const Color(0xFF0F172A),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
