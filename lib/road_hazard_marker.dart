import 'package:flutter/material.dart';
import 'dpwh_standards.dart';

/// Detailed vector road-defect glyph drawn inside circular map markers and
/// cluster badges so each DPWH class is immediately recognizable on the map.
class RoadDefectGlyph extends StatelessWidget {
  final int classId;
  final Color color;
  final double size;

  const RoadDefectGlyph({
    super.key,
    required this.classId,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RoadDefectGlyphPainter(classId: classId, color: color),
        ),
      ),
    );
  }
}

class _RoadDefectGlyphPainter extends CustomPainter {
  final int classId;
  final Color color;

  const _RoadDefectGlyphPainter({required this.classId, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    canvas.save();
    canvas.scale(s, s);

    switch (classId) {
      case 0:
        _paintPothole(canvas);
        break;
      case 1:
        _paintAlligatorCrack(canvas);
        break;
      case 3:
        _paintLongitudinalCrack(canvas);
        break;
      case 4:
        _paintTransverseCrack(canvas);
        break;
      default:
        _paintFallbackWarning(canvas);
        break;
    }

    canvas.restore();
  }

  /// CODE 01 — Pothole: jagged broken-asphalt crater with recessed depth pit,
  /// chipped edge contour, radiating micro-cracks, and loose debris specks.
  void _paintPothole(Canvas canvas) {
    final outerRim = Path()
      ..moveTo(4.2, 12.2)
      ..lineTo(6.3, 8.2)
      ..lineTo(10.6, 6.8)
      ..lineTo(15.2, 7.3)
      ..lineTo(19.0, 9.5)
      ..lineTo(20.1, 13.0)
      ..lineTo(17.9, 16.4)
      ..lineTo(13.2, 17.8)
      ..lineTo(7.8, 17.0)
      ..lineTo(4.8, 14.8)
      ..close();

    final outerFill = Paint()
      ..color = color.withValues(alpha: 0.24)
      ..style = PaintingStyle.fill;
    canvas.drawPath(outerRim, outerFill);

    // Recessed dark crater pit offset slightly for depth illusion
    final innerPit = Path()
      ..moveTo(7.4, 12.8)
      ..lineTo(9.2, 10.2)
      ..lineTo(13.4, 9.9)
      ..lineTo(16.6, 11.6)
      ..lineTo(15.9, 14.5)
      ..lineTo(12.2, 15.5)
      ..lineTo(8.5, 14.7)
      ..close();
    final pitFill = Paint()
      ..color = color.withValues(alpha: 0.72)
      ..style = PaintingStyle.fill;
    canvas.drawPath(innerPit, pitFill);

    // Chipped outer asphalt edge stroke
    final rimStroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(outerRim, rimStroke);

    // Inner depth step line along upper rim
    final stepLine = Path()
      ..moveTo(8.4, 10.6)
      ..lineTo(11.4, 9.4)
      ..lineTo(15.4, 10.2);
    canvas.drawPath(
      stepLine,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round,
    );

    // Radiating surface micro-cracks & loose asphalt fragments
    final crackPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(6.3, 8.2)
        ..lineTo(4.4, 6.2)
        ..lineTo(3.2, 5.9),
      crackPaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(19.0, 9.5)
        ..lineTo(21.0, 7.6),
      crackPaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(17.9, 16.4)
        ..lineTo(19.6, 18.6)
        ..lineTo(21.1, 18.9),
      crackPaint,
    );

    final speckPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(5.6, 19.2), 0.95, speckPaint);
    canvas.drawCircle(const Offset(14.5, 4.6), 0.85, speckPaint);
  }

  /// CODE 02 — Alligator Crack: organic interconnected polygonal asphalt web
  /// (irregular fractured plates, never a uniform spreadsheet grid).
  void _paintAlligatorCrack(Canvas canvas) {
    // Subtle shaded fractured asphalt plates for visual depth
    final plateFill = Paint()
      ..color = color.withValues(alpha: 0.16)
      ..style = PaintingStyle.fill;
    canvas.drawPath(
      Path()
        ..moveTo(8.2, 8.6)
        ..lineTo(13.8, 7.4)
        ..lineTo(16.2, 11.8)
        ..lineTo(12.2, 15.2)
        ..lineTo(7.4, 13.0)
        ..close(),
      plateFill,
    );
    canvas.drawPath(
      Path()
        ..moveTo(13.8, 7.4)
        ..lineTo(18.6, 6.4)
        ..lineTo(20.6, 10.6)
        ..lineTo(16.2, 11.8)
        ..close(),
      Paint()
        ..color = color.withValues(alpha: 0.28)
        ..style = PaintingStyle.fill,
    );

    final primaryCrack = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final secondaryCrack = Paint()
      ..color = color.withValues(alpha: 0.88)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Central irregular polygon (tilted fatigue-cracked asphalt chunk)
    final centerPoly = Path()
      ..moveTo(8.2, 8.6)
      ..lineTo(13.8, 7.4)
      ..lineTo(16.2, 11.8)
      ..lineTo(12.2, 15.2)
      ..lineTo(7.4, 13.0)
      ..close();
    canvas.drawPath(centerPoly, primaryCrack);

    // Radiating irregular polygonal branches forming crocodile-skin scales
    canvas.drawPath(
      Path()
        ..moveTo(8.2, 8.6)
        ..lineTo(5.6, 5.2)
        ..lineTo(10.6, 3.6)
        ..lineTo(13.8, 7.4),
      primaryCrack,
    );
    canvas.drawPath(
      Path()
        ..moveTo(13.8, 7.4)
        ..lineTo(18.6, 6.4)
        ..lineTo(20.6, 10.6)
        ..lineTo(16.2, 11.8),
      primaryCrack,
    );
    canvas.drawPath(
      Path()
        ..moveTo(16.2, 11.8)
        ..lineTo(19.8, 15.8)
        ..lineTo(15.2, 19.6)
        ..lineTo(12.2, 15.2),
      primaryCrack,
    );
    canvas.drawPath(
      Path()
        ..moveTo(12.2, 15.2)
        ..lineTo(8.4, 20.0)
        ..lineTo(4.2, 16.6)
        ..lineTo(7.4, 13.0),
      primaryCrack,
    );
    canvas.drawPath(
      Path()
        ..moveTo(7.4, 13.0)
        ..lineTo(3.4, 10.4)
        ..lineTo(5.6, 5.2),
      secondaryCrack,
    );

    // Outer fissure tail spurs for organic crack texture
    canvas.drawPath(
      Path()
        ..moveTo(10.6, 3.6)
        ..lineTo(11.4, 2.2),
      secondaryCrack,
    );
    canvas.drawPath(
      Path()
        ..moveTo(18.6, 6.4)
        ..lineTo(20.2, 4.4),
      secondaryCrack,
    );
    canvas.drawPath(
      Path()
        ..moveTo(15.2, 19.6)
        ..lineTo(16.4, 21.6),
      secondaryCrack,
    );
    canvas.drawPath(
      Path()
        ..moveTo(4.2, 16.6)
        ..lineTo(2.4, 17.8),
      secondaryCrack,
    );
  }

  /// CODE 12 — Longitudinal Crack: road lane edges with a bold jagged vertical
  /// pavement fissure and fine forked side branches.
  void _paintLongitudinalCrack(Canvas canvas) {
    final edgePaint = Paint()
      ..color = color.withValues(alpha: 0.36)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round;

    // Subtle road shoulder / lane borders running lengthwise
    canvas.drawLine(const Offset(4.8, 3.6), const Offset(4.8, 20.4), edgePaint);
    canvas.drawLine(const Offset(19.2, 3.6), const Offset(19.2, 20.4), edgePaint);

    // Main jagged longitudinal pavement fissure
    final mainCrack = Path()
      ..moveTo(12.4, 2.6)
      ..lineTo(10.6, 6.4)
      ..lineTo(13.6, 9.8)
      ..lineTo(10.2, 13.8)
      ..lineTo(13.4, 17.4)
      ..lineTo(11.6, 21.4);
    canvas.drawPath(
      mainCrack,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.1
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Fine forked secondary stress fissures
    final branchPaint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(13.6, 9.8)
        ..lineTo(16.4, 8.2),
      branchPaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(10.2, 13.8)
        ..lineTo(7.4, 15.6),
      branchPaint,
    );
  }

  /// CODE 12 — Transverse Crack: road lane edges with a bold jagged horizontal
  /// fissure cutting perpendicularly across the road surface.
  void _paintTransverseCrack(Canvas canvas) {
    final edgePaint = Paint()
      ..color = color.withValues(alpha: 0.36)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round;

    // Subtle road lane borders showing vertical travel direction
    canvas.drawLine(const Offset(4.6, 3.4), const Offset(4.6, 8.2), edgePaint);
    canvas.drawLine(const Offset(4.6, 15.8), const Offset(4.6, 20.6), edgePaint);
    canvas.drawLine(const Offset(19.4, 3.4), const Offset(19.4, 8.2), edgePaint);
    canvas.drawLine(const Offset(19.4, 15.8), const Offset(19.4, 20.6), edgePaint);

    // Main jagged transverse fissure cutting across the road
    final mainCrack = Path()
      ..moveTo(2.6, 12.3)
      ..lineTo(6.4, 10.4)
      ..lineTo(9.8, 13.6)
      ..lineTo(13.8, 10.2)
      ..lineTo(17.4, 13.4)
      ..lineTo(21.4, 11.6);
    canvas.drawPath(
      mainCrack,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.1
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Fine forked secondary stress fissures
    final branchPaint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(9.8, 13.6)
        ..lineTo(8.2, 16.6),
      branchPaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(13.8, 10.2)
        ..lineTo(15.6, 7.2),
      branchPaint,
    );
  }

  void _paintFallbackWarning(Canvas canvas) {
    final tri = Path()
      ..moveTo(12.0, 4.0)
      ..lineTo(20.5, 19.0)
      ..lineTo(3.5, 19.0)
      ..close();
    canvas.drawPath(
      tri,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawLine(
      const Offset(12.0, 9.6),
      const Offset(12.0, 14.0),
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      const Offset(12.0, 16.6),
      1.0,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _RoadDefectGlyphPainter oldDelegate) =>
      oldDelegate.classId != classId || oldDelegate.color != color;
}

/// Original mobile circular marker, used consistently on both maps.
class RoadHazardMarker extends StatelessWidget {
  static double sizeForZoom(double zoom) =>
      (14 + (zoom - 10) * 1.8).clamp(14.0, 30.0);
  final String primaryDefect;
  final String status;
  final int count;
  final double size;
  final bool isSelected;
  final bool compact;
  final bool showPendingOwnerBadge;

  const RoadHazardMarker({
    super.key,
    this.primaryDefect = 'Pothole',
    this.status = 'approved',
    this.count = 1,
    this.size = 38,
    this.isSelected = false,
    this.compact = false,
    this.showPendingOwnerBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cls = DpwhStandards.classify(primaryDefect);
    final classColor = switch (cls.classId) {
      0 => dark ? cls.color : const Color(0xFFB45309),
      1 => dark ? cls.color : const Color(0xFF0369A1),
      3 => dark ? cls.color : const Color(0xFF047857),
      4 => dark ? const Color(0xFFFDE047) : const Color(0xFF785A00),
      _ => cls.color,
    };
    final color = status == 'pending'
        ? const Color(0xFFF59E0B)
        : status == 'rejected'
        ? Colors.grey
        : classColor;
    final borderColor = isSelected ? const Color(0xFF10B981) : color;
    final glyphSize = (size * 0.62).clamp(10.0, 28.0);
    final glyphColor = compact ? Colors.white : color;

    final pin = Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size < 28 ? 2 : 3.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: compact ? color : Theme.of(context).colorScheme.surface,
        border: Border.all(
          color: borderColor,
          width: isSelected
              ? 3.2
              : size < 20
              ? 1.2
              : 2.4,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .35 : .20),
            blurRadius: isSelected ? 8 : 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: status == 'rejected'
            ? Icon(
                Icons.block_rounded,
                size: (size * .52).clamp(10.0, 26.0),
                color: glyphColor,
              )
            : RoadDefectGlyph(
                classId: cls.classId,
                color: glyphColor,
                size: glyphSize,
              ),
      ),
    );
    final showPending = status == 'pending' && showPendingOwnerBadge;
    if (compact || size < 24 || (!showPending && count <= 1)) return pin;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        pin,
        Positioned(
          top: -4,
          right: -6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white, width: 1.2),
            ),
            child: showPending
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.schedule_rounded,
                        size: 8,
                        color: Colors.white,
                      ),
                      SizedBox(width: 2),
                      Text(
                        'YOU',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 7.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  )
                : Text(
                    '$count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
