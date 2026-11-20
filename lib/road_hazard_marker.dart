import 'package:flutter/material.dart';
import 'dpwh_standards.dart';

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
    final icon = switch (cls.classId) {
      0 => Icons.album_rounded,
      1 => Icons.grid_on_rounded,
      3 => Icons.swap_vert_rounded,
      4 => Icons.swap_horiz_rounded,
      _ => Icons.warning_amber_rounded,
    };
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
    final pin = Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size < 28 ? 2 : 4),
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
        child: Icon(
          status == 'rejected' ? Icons.block_rounded : icon,
          size: (size * .52).clamp(10.0, 26.0),
          color: compact ? Colors.white : color,
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
