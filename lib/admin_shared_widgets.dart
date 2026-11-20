import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:universal_html/html.dart' as html;

import 'admin_report_query.dart';
import 'approval_priority.dart';
import 'cloud_service.dart';
import 'dpwh_standards.dart';
import 'road_hazard_marker.dart';
import 'web_components.dart';
import 'web_design.dart';

/// Downloads UTF-8 CSV content via an in-memory browser Blob link.
void downloadAdminCsvFile(String csvContent, String filename) {
  final bytes = utf8.encode('\uFEFF$csvContent');
  final blob = html.Blob([bytes], 'text/csv;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}

String formatAdminRelativeTime(DateTime? dt, {DateTime? now}) {
  if (dt == null) return 'Undated';
  final ref = now ?? DateTime.now();
  final diff = ref.difference(dt);
  if (diff.isNegative) return 'Just now';
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

String formatAdminAbsoluteTimestamp(DateTime? dt) {
  if (dt == null) return 'Timestamp unavailable';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final m = months[(dt.month - 1).clamp(0, 11)];
  final h = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
  final min = dt.minute.toString().padLeft(2, '0');
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  return '$m ${dt.day}, ${dt.year} • $h:$min $ampm';
}

/// Consistent status badge across the admin workspace (Pending, Approved, Rejected, Deleted).
class AdminStatusBadge extends StatelessWidget {
  final AdminReportStatus status;
  final bool dense;

  const AdminStatusBadge({super.key, required this.status, this.dense = true});

  @override
  Widget build(BuildContext context) {
    final tone = switch (status) {
      AdminReportStatus.approved => StatusTone.approved,
      AdminReportStatus.rejected => StatusTone.rejected,
      AdminReportStatus.deleted => StatusTone.neutral,
      AdminReportStatus.pending => StatusTone.pending,
    };
    return StatusChip(tone: tone, label: status.label, dense: dense);
  }
}

/// Explicit severity badge distinguishing `Not assessed` from `Medium` so
/// missing report severity never impersonates a medium hazard.
class AdminSeverityBadge extends StatelessWidget {
  final AdminSeverity severity;
  final bool dense;

  const AdminSeverityBadge({
    super.key,
    required this.severity,
    this.dense = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (severity == AdminSeverity.notAssessed) {
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? WebDesign.space2 : WebDesign.space2 + 2,
          vertical: dense ? 3 : WebDesign.space1,
        ),
        decoration: BoxDecoration(
          color: WebDesign.sunken(isDark),
          borderRadius: BorderRadius.circular(WebDesign.radiusSm),
          border: Border.all(color: WebDesign.border(isDark)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.help_outline_rounded,
              size: dense ? WebDesign.icon2xs : WebDesign.iconXs,
              color: WebDesign.textSecondary(isDark),
            ),
            const SizedBox(width: 5),
            Text(
              'Not assessed',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: WebDesign.textSecondary(isDark),
                fontWeight: FontWeight.w600,
                fontSize: dense ? 11 : 12,
              ),
            ),
          ],
        ),
      );
    }

    final style = WebDesign.severityStyle(severity.wireValue, isDark);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? WebDesign.space2 : WebDesign.space2 + 2,
        vertical: dense ? 3 : WebDesign.space1,
      ),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        border: Border.all(color: style.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            style.icon,
            size: dense ? WebDesign.icon2xs : WebDesign.iconXs,
            color: style.fg,
          ),
          const SizedBox(width: 5),
          Text(
            severity.label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: style.fg,
              fontWeight: FontWeight.w700,
              fontSize: dense ? 11 : 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Separate Approval Priority indicator (score + band + optional SLA breach marker).
class AdminPriorityBadge extends StatelessWidget {
  final ReportPriority? priority;
  final bool dense;

  const AdminPriorityBadge({
    super.key,
    required this.priority,
    this.dense = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (priority == null) {
      return Text(
        '—',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: WebDesign.textMuted(isDark)),
      );
    }

    final p = priority!;
    final tone = switch (p.band) {
      PriorityBand.critical => StatusTone.rejected,
      PriorityBand.high => StatusTone.pending,
      PriorityBand.normal => StatusTone.info,
      PriorityBand.low => StatusTone.neutral,
    };
    final style = WebDesign.statusStyle(tone, isDark);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? WebDesign.space2 : WebDesign.space2 + 2,
        vertical: dense ? 3 : WebDesign.space1,
      ),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        border: Border.all(color: style.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            p.isSlaBreached ? Icons.timer_off_outlined : Icons.bolt_rounded,
            size: dense ? 12 : 14,
            color: style.fg,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '${p.score.round()} • ${p.bandLabel}${p.isSlaBreached ? ' (SLA)' : ''}',
              maxLines: dense ? 1 : null,
              overflow: dense ? TextOverflow.ellipsis : TextOverflow.clip,
              style: WebDesign.tabular(
                Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: style.fg,
                      fontWeight: FontWeight.w700,
                      fontSize: dense ? 11 : 12,
                    ) ??
                    const TextStyle(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// DPWH defect class pill paired with deterministic shape + color.
class AdminDefectPill extends StatelessWidget {
  final AdminReportRow row;
  final bool compact;

  const AdminDefectPill({super.key, required this.row, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cls = row.defectClass;
    final color =
        cls?.color ??
        (isDark
            ? WebDesign.textSecondary(true)
            : DpwhStandards.neutralClusterColor);
    final icon = cls != null
        ? WebDesign.defectIcon(cls)
        : Icons.category_outlined;

    if (!compact) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(WebDesign.space3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? .12 : .06),
          borderRadius: BorderRadius.circular(WebDesign.radiusMd),
          border: Border.all(color: color.withValues(alpha: .3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cls != null)
              RoadHazardMarker(primaryDefect: cls.name, size: 30)
            else
              Icon(icon, size: 30, color: color),
            const SizedBox(width: WebDesign.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.defectLabel,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: WebDesign.surface(isDark),
                      borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                      border: Border.all(color: WebDesign.border(isDark)),
                    ),
                    child: Text(
                      row.dpwhCode,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.09),
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.45 : 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 12 : 13, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              '${row.dpwhCode}: ${row.defectLabel}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: isDark ? Colors.white : WebDesign.textPrimary(false),
                fontWeight: FontWeight.w700,
                fontSize: compact ? 11 : 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Confirms before turning Auto-Accept ON (or switching back to Manual Review),
/// catching Firestore/permission errors cleanly so UI state never drifts.
Future<bool> confirmAndToggleAutoAccept(
  BuildContext context, {
  required bool currentEnabled,
}) async {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final nextEnabled = !currentEnabled;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: WebDesign.surface(isDark),
      title: Row(
        children: [
          Icon(
            nextEnabled
                ? Icons.warning_amber_rounded
                : Icons.verified_user_outlined,
            color: nextEnabled
                ? WebDesign.pendingLight
                : WebDesign.brandOnSurface(isDark),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              nextEnabled
                  ? 'Enable Auto-Accept Mode?'
                  : 'Switch Back to Manual Review?',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
        ],
      ),
      content: Text(
        nextEnabled
            ? 'New citizen submissions will bypass moderator review and publish directly to the public hazard map as "Approved". Use only during supervised field surveys.'
            : 'New submissions will enter the Pending review queue and require administrator verification before appearing on the public map.',
        style: Theme.of(ctx).textTheme.bodyMedium,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: nextEnabled
                ? WebDesign.pendingLight
                : WebDesign.brand(isDark),
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            nextEnabled ? 'Enable Auto-Accept' : 'Enable Manual Review',
          ),
        ),
      ],
    ),
  );

  if (confirmed != true) return false;
  try {
    await CloudService.instance.setAutoAcceptSetting(nextEnabled);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          nextEnabled
              ? 'Auto-Accept enabled: incoming submissions publish immediately.'
              : 'Manual Review restored: new submissions require verification.',
          isDark: isDark,
          tone: nextEnabled ? StatusTone.pending : StatusTone.approved,
        ),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          'Unable to update moderation policy: $e',
          isDark: isDark,
          tone: StatusTone.rejected,
        ),
      );
    }
    return false;
  }
}

/// Structured rejection dialog that preserves reason text for reporters and
/// properly marks `status = 'rejected'` (instead of deleting into Trash).
Future<String?> promptAdminRejectionReason(
  BuildContext context, {
  required String shortId,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _RejectReportDialog(shortId: shortId),
  );
}

class _RejectReportDialog extends StatefulWidget {
  final String shortId;
  const _RejectReportDialog({required this.shortId});

  @override
  State<_RejectReportDialog> createState() => _RejectReportDialogState();
}

class _RejectReportDialogState extends State<_RejectReportDialog> {
  static const List<String> _presets = [
    'Duplicate of existing hazard report nearby',
    'Not a structural road defect (false detection / shadow)',
    'Photo blurry, obstructed, or inconclusive',
    'GPS coordinates outside reported carriageway',
    'Issue already repaired on carriageway',
  ];

  String _selectedPreset = _presets.first;
  bool _useCustom = false;
  final TextEditingController _customCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _useCustom ? _customCtrl.text.trim() : _selectedPreset;
    if (reason.isEmpty) {
      setState(() => _error = 'Select a preset reason or enter a short note.');
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      backgroundColor: WebDesign.surface(isDark),
      title: Text(
        'Reject Report #${widget.shortId}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rejected reports remain visible in "Rejected" for audit history and display this note to the submitting reporter.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: WebDesign.space3),
              RadioGroup<String>(
                groupValue: _useCustom ? '__custom__' : _selectedPreset,
                onChanged: (val) {
                  if (val == null) return;
                  setState(() {
                    _error = null;
                    if (val == '__custom__') {
                      _useCustom = true;
                    } else {
                      _useCustom = false;
                      _selectedPreset = val;
                    }
                  });
                },
                child: Column(
                  children: [
                    for (final preset in _presets)
                      RadioListTile<String>(
                        value: preset,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          preset,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: WebDesign.textPrimary(isDark)),
                        ),
                      ),
                    RadioListTile<String>(
                      value: '__custom__',
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        'Custom rejection note',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: WebDesign.textPrimary(isDark),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_useCustom) ...[
                const SizedBox(height: WebDesign.space2),
                TextField(
                  controller: _customCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Rejection reason',
                    hintText:
                        'Explain briefly why this submission cannot be verified...',
                    errorText: _error,
                  ),
                ),
              ] else if (_error != null) ...[
                const SizedBox(height: WebDesign.space2),
                Text(
                  _error!,
                  style: TextStyle(
                    color: WebDesign.danger(isDark),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: WebDesign.danger(isDark),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.cancel_outlined, size: 16),
          label: const Text('Confirm Reject'),
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// Safe modal editor with proper controller lifecycle and inline error recovery.
Future<bool> showAdminEditReportDialog(
  BuildContext context, {
  required AdminReportRow row,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AdminEditReportDialog(row: row),
  );
  return saved == true;
}

class _AdminEditReportDialog extends StatefulWidget {
  final AdminReportRow row;
  const _AdminEditReportDialog({required this.row});

  @override
  State<_AdminEditReportDialog> createState() => _AdminEditReportDialogState();
}

class _AdminEditReportDialogState extends State<_AdminEditReportDialog> {
  late String? _defectName;
  late int _count;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _defectName =
        DpwhStandards.allClasses.any(
          (c) => c.name == widget.row.defectClass?.name,
        )
        ? widget.row.defectClass!.name
        : null;
    _count = widget.row.potholeCount.clamp(1, 100);
  }

  Future<void> _save() async {
    if (_defectName == null || _saving) return;
    final info = DpwhStandards.tryClassify(_defectName);
    if (info == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await CloudService.instance.editPothole(
        widget.row.id,

        potholeCount: _count,

        primaryDpwhCode: info.code,
        primaryDefect: info.name,
        responseTime: info.responseTime,
        correctiveMeasure: info.correctiveMeasure,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Save failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      backgroundColor: WebDesign.surface(isDark),
      title: Text(
        'Edit Classification (#${widget.row.shortId})',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'DPWH Defect Class',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _defectName,
                isExpanded: true,
                hint: const Text('Select supported defect class'),
                items: [
                  for (final std in DpwhStandards.standards)
                    DropdownMenuItem(
                      value: std.name,
                      child: Text(
                        '${std.code}: ${std.name} (${std.responseTime})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _defectName = v),
              ),
              const SizedBox(height: WebDesign.space4),

              const SizedBox(height: 6),

              const SizedBox(height: WebDesign.space4),
              Text(
                'Detected Defects in Frame',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  IconButton.outlined(
                    tooltip: 'Decrease count',
                    onPressed: (!_saving && _count > 1)
                        ? () => setState(() => _count--)
                        : null,
                    icon: const Icon(Icons.remove, size: 16),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '$_count',
                      style: WebDesign.tabular(
                        Theme.of(context).textTheme.titleMedium ??
                            const TextStyle(),
                      ),
                    ),
                  ),
                  IconButton.outlined(
                    tooltip: 'Increase count',
                    onPressed: (!_saving && _count < 100)
                        ? () => setState(() => _count++)
                        : null,
                    icon: const Icon(Icons.add, size: 16),
                  ),
                ],
              ),
              const SizedBox(height: WebDesign.space4),

              const SizedBox(height: 6),

              if (_error != null) ...[
                const SizedBox(height: WebDesign.space3),
                Container(
                  padding: const EdgeInsets.all(10),
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
                    _error!,
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
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: WebDesign.brand(isDark),
            foregroundColor: Colors.white,
          ),
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.save_rounded, size: 16),
          label: Text(_saving ? 'Saving...' : 'Save Changes'),
          onPressed: (_defectName == null || _saving) ? null : _save,
        ),
      ],
    );
  }
}
