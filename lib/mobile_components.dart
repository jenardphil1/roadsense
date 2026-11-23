import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'app_design.dart';
import 'dpwh_standards.dart';
import 'pending_report_queue.dart';
import 'road_sense_brand.dart';

/// Mobile-specific UI helpers and accessible components built on [AppDesign]
/// and [DpwhStandards]. Kept independent of web/admin components.
class RoadSenseLogo extends RoadSenseBrand {
  const RoadSenseLogo({
    super.key,
    super.size,
    super.showWordmark,
    super.subtitle,
    super.isDarkOverride,
  });
}

class MobileDefectHelper {
  MobileDefectHelper._();

  /// Returns an icon distinct per trained DPWH defect class so status/class
  /// cues never depend on color alone (aligned with WebDesign.defectIcon).
  static IconData iconForClass(DpwhDefectClass cls) {
    if (cls.classId == DpwhStandards.pothole.classId) {
      return Icons.album_rounded; // Pothole (circular crater)
    }
    if (cls.classId == DpwhStandards.alligatorCrack.classId) {
      return Icons.grid_on_rounded; // Alligator crack (mesh pattern)
    }
    if (cls.classId == DpwhStandards.longitudinalCrack.classId) {
      return Icons.swap_vert_rounded; // Longitudinal crack (vertical line)
    }
    if (cls.classId == DpwhStandards.transverseCrack.classId) {
      return Icons.swap_horiz_rounded; // Transverse crack (horizontal)
    }
    return Icons.warning_amber_rounded;
  }

  /// Adjusts [DpwhDefectClass.color] when needed so foreground text/icons keep
  /// at least ~4.5:1 contrast against both light and dark surfaces outdoors.
  static Color foregroundColor(DpwhDefectClass cls, bool isDark) {
    if (cls.classId == DpwhStandards.transverseCrack.classId) {
      // #F0E442 yellow needs darkening on light backgrounds to remain legible.
      return isDark ? const Color(0xFFFDE047) : const Color(0xFF785A00);
    }
    if (!isDark && cls.classId == DpwhStandards.alligatorCrack.classId) {
      return const Color(0xFF0369A1);
    }
    if (!isDark && cls.classId == DpwhStandards.pothole.classId) {
      return const Color(0xFFB45309);
    }
    if (!isDark && cls.classId == DpwhStandards.longitudinalCrack.classId) {
      return const Color(0xFF047857);
    }
    return cls.color;
  }

  /// Resolves user-facing defect label from a raw detection string or class id.
  static DpwhDefectClass resolveDefect({String? rawLabel, int? classId}) {
    if (classId != null) {
      final byId = DpwhStandards.getById(classId);
      if (byId != null) return byId;
    }
    return DpwhStandards.tryClassify(rawLabel) ?? DpwhStandards.pothole;
  }
}

/// Visual status metadata paired with icon + accessible label for reports and
/// device/network states (aligned with WebDesign.StatusStyle).
class MobileStatusMeta {
  final String label;
  final IconData icon;
  final Color color;
  final Color? backgroundColor;
  final Color? borderColor;

  const MobileStatusMeta({
    required this.label,
    required this.icon,
    required this.color,
    this.backgroundColor,
    this.borderColor,
  });

  static MobileStatusMeta forReportStatus(String status, bool isDark) {
    switch (status.trim().toLowerCase()) {
      case 'approved':
        final fg = isDark ? const Color(0xFF34D399) : const Color(0xFF047857);
        return MobileStatusMeta(
          label: 'Approved',
          icon: Icons.check_circle_rounded,
          color: fg,
          backgroundColor: isDark
              ? const Color(0xFF064E3B).withValues(alpha: 0.45)
              : const Color(0xFFECFDF5),
          borderColor: fg.withValues(alpha: isDark ? 0.42 : 0.34),
        );
      case 'rejected':
        final fg = isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);
        return MobileStatusMeta(
          label: 'Rejected',
          icon: Icons.cancel_rounded,
          color: fg,
          backgroundColor: isDark
              ? const Color(0xFF7F1D1D).withValues(alpha: 0.42)
              : const Color(0xFFFEF2F2),
          borderColor: fg.withValues(alpha: isDark ? 0.42 : 0.34),
        );
      case 'deleted':
        final fg = AppDesign.textSecondary(isDark);
        return MobileStatusMeta(
          label: 'In Trash',
          icon: Icons.delete_outline_rounded,
          color: fg,
          backgroundColor: AppDesign.sunken(isDark),
          borderColor: AppDesign.border(isDark),
        );
      case 'pending':
      default:
        final fg = isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
        return MobileStatusMeta(
          label: 'Pending review',
          icon: Icons.schedule_rounded,
          color: fg,
          backgroundColor: isDark
              ? const Color(0xFF78350F).withValues(alpha: 0.42)
              : const Color(0xFFFFFBEB),
          borderColor: fg.withValues(alpha: isDark ? 0.42 : 0.34),
        );
    }
  }

  static MobileStatusMeta forLocalSyncState(
    PendingSyncState state,
    bool isDark,
  ) {
    switch (state) {
      case PendingSyncState.waiting:
        final fg = isDark ? const Color(0xFF7DD3FC) : const Color(0xFF0369A1);
        return MobileStatusMeta(
          label: 'Waiting to upload',
          icon: Icons.cloud_queue_rounded,
          color: fg,
          backgroundColor: isDark
              ? const Color(0xFF0C4A6E).withValues(alpha: 0.45)
              : const Color(0xFFF0F9FF),
          borderColor: fg.withValues(alpha: isDark ? 0.45 : 0.34),
        );
      case PendingSyncState.uploading:
        final fg = isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
        return MobileStatusMeta(
          label: 'Uploading',
          icon: Icons.cloud_upload_rounded,
          color: fg,
          backgroundColor: isDark
              ? const Color(0xFF1E3A8A).withValues(alpha: 0.45)
              : const Color(0xFFEFF6FF),
          borderColor: fg.withValues(alpha: isDark ? 0.45 : 0.34),
        );
      case PendingSyncState.failed:
        final fg = isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);
        return MobileStatusMeta(
          label: 'Upload failed',
          icon: Icons.error_outline_rounded,
          color: fg,
          backgroundColor: isDark
              ? const Color(0xFF7F1D1D).withValues(alpha: 0.45)
              : const Color(0xFFFEF2F2),
          borderColor: fg.withValues(alpha: isDark ? 0.48 : 0.36),
        );
    }
  }
}

/// High-contrast status pill pairing an icon and readable text.
class MobileStatusPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final Color? backgroundColor;
  final Color? borderColor;
  final bool compact;

  const MobileStatusPill({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    this.backgroundColor,
    this.borderColor,
    this.compact = false,
  });

  factory MobileStatusPill.forReportStatus(
    String status, {
    required bool isDark,
    bool compact = false,
  }) {
    final meta = MobileStatusMeta.forReportStatus(status, isDark);
    return MobileStatusPill(
      label: meta.label,
      icon: meta.icon,
      color: meta.color,
      backgroundColor: meta.backgroundColor,
      borderColor: meta.borderColor,
      compact: compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: label,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: compact ? 4 : 5,
        ),
        decoration: BoxDecoration(
          color:
              backgroundColor ?? color.withValues(alpha: isDark ? 0.2 : 0.12),
          borderRadius: BorderRadius.circular(AppDesign.radiusPill),
          border: Border.all(
            color: borderColor ?? color.withValues(alpha: isDark ? 0.5 : 0.38),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 13 : 14, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 11 : 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// High-contrast structural severity pill separated cleanly from AI confidence
/// and report approval status (aligned with WebSeverityBadge).
class MobileSeverityPill extends StatelessWidget {
  final String severity;
  final bool compact;
  final bool? isDark;

  const MobileSeverityPill({
    super.key,
    required this.severity,
    this.compact = false,
    this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveDark =
        isDark ?? (Theme.of(context).brightness == Brightness.dark);
    final normalized = severity.trim().toLowerCase();

    final Color fg;
    final Color bg;
    final IconData icon;
    final String label;

    switch (normalized) {
      case 'high':
        fg = effectiveDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);
        bg = effectiveDark
            ? const Color(0xFF7F1D1D).withValues(alpha: 0.36)
            : const Color(0xFFFEF2F2);
        icon = Icons.priority_high_rounded;
        label = compact ? 'High' : 'High severity';
      case 'low':
        fg = effectiveDark ? const Color(0xFF34D399) : const Color(0xFF047857);
        bg = effectiveDark
            ? const Color(0xFF064E3B).withValues(alpha: 0.36)
            : const Color(0xFFECFDF5);
        icon = Icons.arrow_downward_rounded;
        label = compact ? 'Low' : 'Low severity';
      case 'medium':
      default:
        fg = effectiveDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
        bg = effectiveDark
            ? const Color(0xFF78350F).withValues(alpha: 0.36)
            : const Color(0xFFFFFBEB);
        icon = Icons.drag_handle_rounded;
        label = compact ? 'Medium' : 'Medium severity';
    }

    return MobileStatusPill(
      label: label,
      icon: icon,
      color: fg,
      backgroundColor: bg,
      borderColor: fg.withValues(alpha: effectiveDark ? 0.45 : 0.35),
      compact: compact,
    );
  }
}

/// High-contrast defect badge supporting all four trained model classes:
/// pothole, alligator crack, longitudinal crack, and transverse crack.
class MobileDefectPill extends StatelessWidget {
  final DpwhDefectClass defectClass;
  final double? confidence;
  final bool showCode;

  const MobileDefectPill({
    super.key,
    required this.defectClass,
    this.confidence,
    this.showCode = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = MobileDefectHelper.foregroundColor(defectClass, isDark);
    final pctText = confidence != null
        ? ' ${(confidence! * 100).clamp(0, 100).toStringAsFixed(0)}%'
        : '';
    final codePrefix = showCode ? '${defectClass.code} • ' : '';

    return Semantics(
      label: '${defectClass.name}$pctText',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: fg.withValues(alpha: isDark ? 0.16 : 0.10),
          borderRadius: BorderRadius.circular(AppDesign.radiusPill),
          border: Border.all(color: fg.withValues(alpha: isDark ? 0.45 : 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              MobileDefectHelper.iconForClass(defectClass),
              size: 14,
              color: fg,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                '$codePrefix${defectClass.name}$pctText',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Square/circle icon button guaranteed to occupy at least 48x48 logical
/// pixels so outdoor single-handed taps remain accurate and accessible.
class MobileTouchIconButton extends StatelessWidget {
  final Key? targetKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final Color? borderColor;
  final bool isLoading;
  final double iconSize;
  final BoxShape shape;

  const MobileTouchIconButton({
    super.key,
    this.targetKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.backgroundColor,
    this.foregroundColor,
    this.borderColor,
    this.isLoading = false,
    this.iconSize = 22,
    this.shape = BoxShape.circle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = backgroundColor ?? AppDesign.surface(isDark);
    final fg = foregroundColor ?? AppDesign.textPrimary(isDark);
    final border = borderColor ?? AppDesign.border(isDark);

    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Material(
          key: targetKey,
          color: bg,
          shape: shape == BoxShape.circle
              ? CircleBorder(side: BorderSide(color: border, width: 1.2))
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: border, width: 1.2),
                ),
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: isDark ? 0.4 : 0.16),
          child: InkWell(
            onTap: isLoading ? null : onPressed,
            customBorder: shape == BoxShape.circle
                ? const CircleBorder()
                : RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: isLoading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: fg,
                        ),
                      )
                    : Icon(icon, size: iconSize, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reusable empty, loading, offline, permission-denied, success, or error card.
class MobileStateCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final String? primaryLabel;
  final VoidCallback? onPrimaryPressed;
  final String? secondaryLabel;
  final VoidCallback? onSecondaryPressed;
  final bool isLoading;

  const MobileStateCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    this.primaryLabel,
    this.onPrimaryPressed,
    this.secondaryLabel,
    this.onSecondaryPressed,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: AppDesign.cardDecoration(
        isDark: isDark,
        radius: AppDesign.radiusLg,
        elevated: true,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: isLoading
                ? Padding(
                    padding: const EdgeInsets.all(15),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: iconColor,
                    ),
                  )
                : Icon(icon, size: 28, color: iconColor),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppDesign.textPrimary(isDark),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: AppDesign.textSecondary(isDark),
            ),
          ),
          if (primaryLabel != null && onPrimaryPressed != null) ...[
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onPrimaryPressed,
                style: AppDesign.primaryButtonStyle(
                  isDark: isDark,
                  borderRadius: AppDesign.radiusMd,
                ),
                child: Text(
                  primaryLabel!,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
          if (secondaryLabel != null && onSecondaryPressed != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: onSecondaryPressed,
                style: TextButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
                child: Text(
                  secondaryLabel!,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppDesign.textSecondary(isDark),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Visualizes the four distinct RoadSense stages so users understand that
/// local detection and frame saving do not publish publicly without submission
/// and admin approval.
class MobileReportLifecycleBanner extends StatelessWidget {
  /// Active step index from 0 (`Detected`) to 3 (`Approved`).
  final int activeStage;

  const MobileReportLifecycleBanner({super.key, required this.activeStage});

  static const List<({String label, IconData icon})> _stages = [
    (label: 'Detected', icon: Icons.center_focus_strong_rounded),
    (label: 'Saved', icon: Icons.photo_camera_rounded),
    (label: 'Submitted', icon: Icons.cloud_upload_rounded),
    (label: 'Approved', icon: Icons.verified_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = AppDesign.accent(isDark);
    final muted = AppDesign.textMuted(isDark);

    return Semantics(
      label: 'Workflow stage: ${_stages[activeStage.clamp(0, 3)].label}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppDesign.sunken(isDark),
          borderRadius: BorderRadius.circular(AppDesign.radiusLg),
          border: Border.all(color: AppDesign.border(isDark)),
        ),
        child: Row(
          children: List.generate(_stages.length, (i) {
            final stage = _stages[i];
            final reached = i <= activeStage;
            final isCurrent = i == activeStage;
            final color = reached ? accent : muted;
            return Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isCurrent
                                ? AppDesign.brand
                                : color.withValues(
                                    alpha: reached ? 0.16 : 0.08,
                                  ),
                            border: Border.all(color: color, width: 1.4),
                          ),
                          child: Icon(
                            stage.icon,
                            size: 14,
                            color: isCurrent ? Colors.white : color,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          stage.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isCurrent
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color: isCurrent
                                ? AppDesign.textPrimary(isDark)
                                : color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (i < _stages.length - 1)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: SizedBox(
                        width: 10,
                        child: Divider(
                          thickness: 1.5,
                          color: i < activeStage
                              ? accent
                              : AppDesign.border(isDark),
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// Consistent section card container for grouped mobile screens.
class MobileSectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const MobileSectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: AppDesign.cardDecoration(
        isDark: isDark,
        radius: AppDesign.radiusLg,
        elevated: true,
      ),
      child: child,
    );
  }
}

/// Safely watches connectivity without crashing when platform channels are
/// unmocked (such as headless widget tests).
StreamSubscription<List<ConnectivityResult>>? watchSafeOfflineState(
  void Function(bool isOffline) onChanged,
) {
  bool isOfflineResult(List<ConnectivityResult> results) =>
      results.isNotEmpty && results.every((r) => r == ConnectivityResult.none);

  try {
    Connectivity().checkConnectivity().then(
      (results) => onChanged(isOfflineResult(results)),
      onError: (_) {},
    );
    return Connectivity().onConnectivityChanged.listen(
      (results) => onChanged(isOfflineResult(results)),
      onError: (_) {},
    );
  } catch (_) {
    return null;
  }
}

/// Non-intrusive warning banner rendered when the device is offline.
class MobileOfflineBanner extends StatelessWidget {
  final String message;

  const MobileOfflineBanner({
    super.key,
    this.message = 'Offline: showing cached data. New reports queue locally.',
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E);
    final bg = isDark ? const Color(0xFF451A03) : const Color(0xFFFEF3C7);
    final border = isDark ? const Color(0xFFD97706) : const Color(0xFFF59E0B);

    return Semantics(
      label: message,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi_off_rounded, size: 16, color: border),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Floating 4-tab bottom navigation bar shared by the Mobile App shell.
/// Keeps Map, Scan, Reports, and Profile visually consistent.
class MobileFloatingNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final bool isDark;
  final bool disableAnimations;
  final Key? scanKey;
  final Key? reportsKey;
  final Key? profileKey;

  const MobileFloatingNavBar({
    super.key,
    required this.currentIndex,
    required this.onTabSelected,
    required this.isDark,
    this.disableAnimations = false,
    this.scanKey,
    this.reportsKey,
    this.profileKey,
  });

  @override
  Widget build(BuildContext context) {
    final Color activeColor = AppDesign.accent(isDark);
    final tabs = <({int index, IconData icon, String label, Key? key})>[
      (index: 0, icon: Icons.map_rounded, label: 'Map', key: null),
      (
        index: 1,
        icon: currentIndex == 1
            ? Icons.radar_rounded
            : Icons.document_scanner_rounded,
        label: 'Scan',
        key: scanKey,
      ),
      (
        index: 2,
        icon: Icons.fact_check_rounded,
        label: 'Reports',
        key: reportsKey,
      ),
      (index: 3, icon: Icons.person_rounded, label: 'Profile', key: profileKey),
    ];
    final media = MediaQuery.of(context);
    final bool isLandscape =
        media.size.width > media.size.height && media.size.height < 560;
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1.0,
        child: Container(
          margin: EdgeInsets.fromLTRB(12, 0, 12, isLandscape ? 4 : 12),
          constraints: BoxConstraints(
            maxWidth: isLandscape ? 400 : double.infinity,
            minHeight: isLandscape ? 40 : 68,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: isLandscape ? 6 : 8,
            vertical: isLandscape ? 2 : 6,
          ),
          decoration: BoxDecoration(
            color: AppDesign.surface(isDark),
            borderRadius: BorderRadius.circular(isLandscape ? 14 : 20),
            border: Border.all(color: AppDesign.border(isDark), width: 1),
            boxShadow: AppDesign.shadowMd(isDark),
          ),
          child: Row(
            children: [
              for (final tab in tabs)
                Expanded(
                  child: KeyedSubtree(
                    key: tab.key,
                    child: _MobileNavBarTab(
                      icon: tab.icon,
                      label: tab.label,
                      isActive: currentIndex == tab.index,
                      activeColor: activeColor,
                      isDark: isDark,
                      compact: isLandscape,
                      disableAnimations: disableAnimations,
                      onTap: () => onTabSelected(tab.index),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileNavBarTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final bool isDark;
  final bool compact;
  final bool disableAnimations;
  final VoidCallback onTap;

  const _MobileNavBarTab({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.isDark,
    this.compact = false,
    required this.disableAnimations,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final inactiveColor = AppDesign.textSecondary(isDark);
    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 48,
            minHeight: compact ? 36 : 50,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 4,
              vertical: compact ? 2 : 4,
            ),
            child: compact
                ? AnimatedContainer(
                    duration: disableAnimations
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppDesign.brandWash(isDark)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isActive
                            ? AppDesign.brandBorder(isDark)
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 18,
                          color: isActive ? activeColor : inactiveColor,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: isActive
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: isActive ? activeColor : inactiveColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedContainer(
                        duration: disableAnimations
                            ? Duration.zero
                            : const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isActive
                              ? AppDesign.brandWash(isDark)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isActive
                                ? AppDesign.brandBorder(isDark)
                                : Colors.transparent,
                          ),
                        ),
                        child: Icon(
                          icon,
                          size: 21,
                          color: isActive ? activeColor : inactiveColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isActive
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: isActive ? activeColor : inactiveColor,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
