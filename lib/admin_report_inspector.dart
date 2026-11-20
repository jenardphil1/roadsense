import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import 'admin_report_query.dart';
import 'admin_shared_widgets.dart';
import 'approval_priority.dart';
import 'cloud_service.dart';
import 'web_components.dart';
import 'web_design.dart';

/// Opens a full-screen keyboard-dismissible high-resolution image viewer.
void showAdminFullScreenPhoto(
  BuildContext context, {
  required String imageUrl,
  required String title,
  required String subtitle,
}) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.90),
    builder: (ctx) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(ctx).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Dialog.fullscreen(
          backgroundColor: const Color(0xFF090D16),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WebDesign.space5,
                    vertical: WebDesign.space3,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            if (subtitle.isNotEmpty)
                              Text(
                                subtitle,
                                style: const TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('Close (Esc)'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFF1E293B)),
                Expanded(
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 5.0,
                    child: Center(
                      child: Image.network(
                        imageUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.broken_image_outlined,
                              size: 48,
                              color: Color(0xFF64748B),
                            ),
                            SizedBox(height: 10),
                            Text(
                              'Image failed to load from storage.',
                              style: TextStyle(color: Color(0xFF94A3B8)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Modal detail dialog / sheet for narrow viewports or direct inspection from Map/Overview.
Future<void> showAdminReportInspectorModal(
  BuildContext context, {
  required AdminReportRow row,
  required ReportPriority? priority,
  required void Function(LatLng location, AdminReportRow row) onLocateOnMap,
  Future<void> Function(AdminReportRow row)? onSoftDelete,
  void Function(AdminReportRow row, AdminReportStatus nextStatus)? onMutated,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(ctx).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 20,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 820),
            child: AdminReportInspectorPanel(
              row: row,
              priority: priority,
              isModal: true,
              onClose: () => Navigator.of(ctx).pop(),
              onLocateOnMap: (loc, target) {
                Navigator.of(ctx).pop();
                onLocateOnMap(loc, target);
              },
              onSoftDelete: (target) async {
                Navigator.of(ctx).pop();
                if (onSoftDelete != null) {
                  await onSoftDelete(target);
                }
              },
              onMutated: onMutated,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Inspectable side panel (or modal body) separating reported status, physical
/// severity, AI model confidence, statutory DPWH SLA, and triage priority.
class AdminReportInspectorPanel extends StatefulWidget {
  final AdminReportRow row;
  final ReportPriority? priority;
  final bool isModal;
  final VoidCallback onClose;
  final void Function(LatLng location, AdminReportRow row) onLocateOnMap;
  final Future<void> Function(AdminReportRow row)? onSoftDelete;
  final void Function(AdminReportRow row, AdminReportStatus nextStatus)?
  onMutated;

  const AdminReportInspectorPanel({
    super.key,
    required this.row,
    required this.priority,
    required this.onClose,
    required this.onLocateOnMap,
    this.isModal = false,
    this.onSoftDelete,
    this.onMutated,
  });

  @override
  State<AdminReportInspectorPanel> createState() =>
      _AdminReportInspectorPanelState();
}

class _AdminReportInspectorPanelState extends State<AdminReportInspectorPanel> {
  bool _busy = false;
  String? _actionError;

  Future<void> _changeStatus(
    AdminReportStatus targetStatus, {
    String? rejectionReason,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });

    try {
      await CloudService.instance.updatePotholeStatus(
        widget.row.id,
        targetStatus.wireValue,
        rejectionReason: rejectionReason,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onMutated?.call(widget.row, targetStatus);
      final isDark = Theme.of(context).brightness == Brightness.dark;
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          'Report #${widget.row.shortId} marked ${targetStatus.label}.',
          isDark: isDark,
          tone: switch (targetStatus) {
            AdminReportStatus.approved => StatusTone.approved,
            AdminReportStatus.rejected => StatusTone.rejected,
            _ => StatusTone.info,
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _actionError = 'Action failed cleanly without changing cloud data: $e';
      });
    }
  }

  Future<void> _handleReject() async {
    final reason = await promptAdminRejectionReason(
      context,
      shortId: widget.row.shortId,
    );
    if (reason == null || !mounted) return;
    await _changeStatus(AdminReportStatus.rejected, rejectionReason: reason);
  }

  Future<void> _handleDelete() async {
    if (_busy) return;
    if (widget.onSoftDelete != null) {
      setState(() {
        _busy = true;
        _actionError = null;
      });
      try {
        await widget.onSoftDelete!(widget.row);
        if (mounted) setState(() => _busy = false);
      } catch (e) {
        if (mounted) {
          setState(() {
            _busy = false;
            _actionError = 'Could not move report to Trash: $e';
          });
        }
      }
    }
  }

  Future<void> _handleEdit() async {
    final saved = await showAdminEditReportDialog(context, row: widget.row);
    if (saved && mounted) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          'Updated classification for #${widget.row.shortId}.',
          isDark: isDark,
          tone: StatusTone.approved,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final r = widget.row;
    final p = widget.priority;
    final dupCount = p?.duplicateIds.length ?? 0;

    return Container(
      decoration: BoxDecoration(
        color: WebDesign.surface(isDark),
        borderRadius: BorderRadius.circular(
          widget.isModal ? WebDesign.radiusXl : WebDesign.radiusLg,
        ),
        border: Border.all(color: WebDesign.borderStrong(isDark)),
        boxShadow: widget.isModal
            ? WebDesign.shadowLg(isDark)
            : WebDesign.shadowSm(isDark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Inspector Header
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WebDesign.space4,
              WebDesign.space4,
              WebDesign.space3,
              WebDesign.space3,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '#${r.shortId}',
                            style: WebDesign.tabular(
                              theme.textTheme.titleMedium ?? const TextStyle(),
                            ),
                          ),
                          AdminStatusBadge(status: r.status),
                          if (r.autoApproved)
                            const StatusChip(
                              tone: StatusTone.info,
                              label: 'Auto-accepted',
                              dense: true,
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        r.displayLocation,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: WebDesign.textPrimary(isDark),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close details',
                  onPressed: widget.onClose,
                  constraints: const BoxConstraints(
                    minWidth: WebDesign.minTarget,
                    minHeight: WebDesign.minTarget,
                  ),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: WebDesign.border(isDark)),

          // Scrollable Inspector Body
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(WebDesign.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Photo Viewer
                  ClipRRect(
                    borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                    child: Container(
                      height: 205,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: WebDesign.sunken(isDark),
                        border: Border.all(color: WebDesign.border(isDark)),
                        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                      ),
                      child: r.hasPhoto
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.network(
                                  r.imageUrl,
                                  fit: BoxFit.cover,
                                  loadingBuilder: (_, child, progress) {
                                    if (progress == null) return child;
                                    return const Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    );
                                  },
                                  errorBuilder: (_, _, _) => Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.broken_image_outlined,
                                          size: 36,
                                          color: WebDesign.textMuted(isDark),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Evidence image could not load',
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.black.withValues(
                                        alpha: 0.72,
                                      ),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      minimumSize: const Size(0, 36),
                                    ),
                                    onPressed: () => showAdminFullScreenPhoto(
                                      context,
                                      imageUrl: r.imageUrl,
                                      title:
                                          'Report #${r.shortId} • ${r.defectLabel}',
                                      subtitle: r.displayLocation,
                                    ),
                                    icon: const Icon(
                                      Icons.zoom_in_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Inspect photo',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.image_not_supported_outlined,
                                    size: 32,
                                    color: WebDesign.textMuted(isDark),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'No photo evidence attached',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),

                  const SizedBox(height: WebDesign.space4),

                  // Nearby Duplicate Advisory (explicitly surfaced)
                  if (dupCount > 0) ...[
                    Container(
                      padding: const EdgeInsets.all(WebDesign.space3),
                      decoration: BoxDecoration(
                        color: WebDesign.statusStyle(
                          StatusTone.pending,
                          isDark,
                        ).bg,
                        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                        border: Border.all(
                          color: WebDesign.statusStyle(
                            StatusTone.pending,
                            isDark,
                          ).outline,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.layers_outlined,
                            size: 18,
                            color: WebDesign.statusStyle(
                              StatusTone.pending,
                              isDark,
                            ).fg,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$dupCount other pending report(s) lie within 25 m — check for duplicate physical defect before publishing twice.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: WebDesign.textPrimary(isDark),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: WebDesign.space3),
                  ],

                  // Rejection reason highlight if already rejected
                  if (r.status == AdminReportStatus.rejected &&
                      r.rejectionReason.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(WebDesign.space3),
                      decoration: BoxDecoration(
                        color: WebDesign.statusStyle(
                          StatusTone.rejected,
                          isDark,
                        ).bg,
                        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                        border: Border.all(
                          color: WebDesign.statusStyle(
                            StatusTone.rejected,
                            isDark,
                          ).outline,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 16,
                            color: WebDesign.danger(isDark),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Rejection note: ${r.rejectionReason}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: WebDesign.textPrimary(isDark),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: WebDesign.space3),
                  ],

                  // Keep the classification readable before the evidence facts.
                  const Eyebrow('Distress & Evidence Metrics'),
                  const SizedBox(height: WebDesign.space2),
                  AdminDefectPill(row: r),
                  const SizedBox(height: WebDesign.space3),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      final textScale = MediaQuery.textScalerOf(
                        context,
                      ).scale(1);
                      final twoCol = constraints.maxWidth >= 480 * textScale;
                      final boxWidth = twoCol
                          ? (constraints.maxWidth - WebDesign.space2) / 2
                          : constraints.maxWidth;
                      return Wrap(
                        spacing: WebDesign.space2,
                        runSpacing: WebDesign.space2,
                        children: [
                          SizedBox(
                            width: boxWidth,
                            child: _MetricFactBox(
                              title: 'AI confidence',
                              subtitle:
                                  '${r.detections.length} detection box(es)',
                              child: Text(
                                r.maxConfidence != null
                                    ? '${(r.maxConfidence! * 100).toStringAsFixed(1)}% max'
                                    : 'No telemetry',
                                style: WebDesign.tabular(
                                  theme.textTheme.titleSmall ??
                                      const TextStyle(),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: boxWidth,
                            child: _MetricFactBox(
                              title: 'DPWH response SLA',
                              subtitle: 'Statutory target for ${r.dpwhCode}',
                              child: Text(
                                r.responseTime,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: WebDesign.brandOnSurface(isDark),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: boxWidth,
                            child: _MetricFactBox(
                              title: 'Approval priority',
                              subtitle: p != null
                                  ? (p.reasons.isNotEmpty
                                        ? p.reasons.take(2).join(' • ')
                                        : 'Pending triage score')
                                  : 'Only scored for pending triage',
                              child: AdminPriorityBadge(
                                priority: p,
                                dense: false,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),

                  const SizedBox(height: WebDesign.space4),
                  const Eyebrow('Corrective Measure & Observations'),
                  const SizedBox(height: WebDesign.space2),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(WebDesign.space3),
                    decoration: BoxDecoration(
                      color: WebDesign.sunken(isDark),
                      borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                      border: Border.all(color: WebDesign.border(isDark)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.correctiveMeasure,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: WebDesign.textPrimary(isDark),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Defect instances in frame: ${r.potholeCount}'
                          '${r.defectClass != null ? ' (${r.defectClass!.unit})' : ''}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: WebDesign.space4),
                  const Eyebrow('Location, Reporter & Audit Trail'),
                  const SizedBox(height: WebDesign.space2),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(WebDesign.space3),
                    decoration: BoxDecoration(
                      color: WebDesign.sunken(isDark),
                      borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                      border: Border.all(color: WebDesign.border(isDark)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (r.hasValidCoordinates)
                          CoordinatePill(
                            latitude: r.location!.latitude,
                            longitude: r.location!.longitude,
                            onTap: () => widget.onLocateOnMap(r.location!, r),
                          )
                        else
                          Text(
                            'GPS coordinates unavailable',
                            style: theme.textTheme.bodySmall,
                          ),
                        const SizedBox(height: 8),
                        _AuditLine(
                          label: 'Barangay / LGU',
                          value: [
                            if (r.barangay.isNotEmpty) r.barangay,
                            if (r.city.isNotEmpty) r.city,
                            if (r.province.isNotEmpty) r.province,
                          ].join(', '),
                        ),
                        _AuditLine(
                          label: 'Submitted',
                          value:
                              '${formatAdminAbsoluteTimestamp(r.timestamp)} (${formatAdminRelativeTime(r.timestamp)})',
                        ),
                        _AuditLine(
                          label: 'Reporter',
                          value: r.reporterEmail.isNotEmpty
                              ? '${r.reporterName} (${r.reporterEmail})'
                              : r.reporterName,
                        ),
                        if (r.moderatedAt != null)
                          _AuditLine(
                            label: 'Last moderated',
                            value:
                                '${formatAdminAbsoluteTimestamp(r.moderatedAt)}'
                                '${r.moderatedBy.isNotEmpty ? ' • ${r.moderatedBy}' : ''}',
                          ),
                      ],
                    ),
                  ),

                  if (r.detections.isNotEmpty) ...[
                    const SizedBox(height: WebDesign.space4),
                    const Eyebrow('Raw Detection Boxes'),
                    const SizedBox(height: WebDesign.space2),
                    for (final det in r.detections.take(8))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                (det['label'] ??
                                        det['className'] ??
                                        det['tag'] ??
                                        'Road defect')
                                    .toString(),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: WebDesign.textPrimary(isDark),
                                ),
                              ),
                            ),
                            Text(
                              det['confidence'] is num
                                  ? '${(((det['confidence'] as num).toDouble() > 1 ? (det['confidence'] as num).toDouble() : (det['confidence'] as num).toDouble() * 100)).toStringAsFixed(1)}%'
                                  : '—',
                              style: WebDesign.tabular(
                                theme.textTheme.labelMedium ??
                                    const TextStyle(),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],

                  if (_actionError != null) ...[
                    const SizedBox(height: WebDesign.space3),
                    Container(
                      padding: const EdgeInsets.all(WebDesign.space3),
                      decoration: BoxDecoration(
                        color: WebDesign.statusStyle(
                          StatusTone.rejected,
                          isDark,
                        ).bg,
                        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                        border: Border.all(
                          color: WebDesign.statusStyle(
                            StatusTone.rejected,
                            isDark,
                          ).outline,
                        ),
                      ),
                      child: Text(
                        _actionError!,
                        style: TextStyle(
                          color: WebDesign.danger(isDark),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Action Footer
          Divider(height: 1, color: WebDesign.border(isDark)),
          Padding(
            padding: const EdgeInsets.all(WebDesign.space3),
            child: Wrap(
              spacing: WebDesign.space2,
              runSpacing: WebDesign.space2,
              alignment: WrapAlignment.end,
              children: [
                if (r.hasValidCoordinates)
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => widget.onLocateOnMap(r.location!, r),
                    icon: const Icon(Icons.my_location_rounded, size: 16),
                    label: const Text('Focus map'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _handleEdit,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit'),
                ),
                if (r.status != AdminReportStatus.approved)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: WebDesign.approveAction,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _busy
                        ? null
                        : () => _changeStatus(AdminReportStatus.approved),
                    icon: _busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            Icons.check_circle_outline_rounded,
                            size: 16,
                          ),
                    label: Text(
                      r.status == AdminReportStatus.rejected
                          ? 'Re-approve'
                          : 'Approve',
                    ),
                  ),
                if (r.status != AdminReportStatus.rejected)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: WebDesign.danger(isDark),
                      side: BorderSide(color: WebDesign.danger(isDark)),
                    ),
                    onPressed: _busy ? null : _handleReject,
                    icon: const Icon(Icons.cancel_outlined, size: 16),
                    label: const Text('Reject'),
                  ),
                if (r.status == AdminReportStatus.approved)
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _changeStatus(AdminReportStatus.pending),
                    icon: const Icon(Icons.undo_rounded, size: 16),
                    label: const Text('Return to pending'),
                  ),
                if (widget.onSoftDelete != null &&
                    r.status != AdminReportStatus.deleted)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: WebDesign.textSecondary(isDark),
                    ),
                    onPressed: _busy ? null : _handleDelete,
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    label: const Text('Trash'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricFactBox extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _MetricFactBox({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(WebDesign.space3),
      decoration: BoxDecoration(
        color: WebDesign.sunken(isDark),
        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
        border: Border.all(color: WebDesign.border(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Eyebrow(title),
          const SizedBox(height: 6),
          child,
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _AuditLine extends StatelessWidget {
  final String label;
  final String value;

  const _AuditLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: WebDesign.textSecondary(isDark),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: WebDesign.textPrimary(isDark),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
