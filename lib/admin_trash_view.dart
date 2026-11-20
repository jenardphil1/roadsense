import 'package:flutter/material.dart';

import 'admin_report_query.dart';
import 'admin_shared_widgets.dart';
import 'cloud_service.dart';
import 'web_components.dart';
import 'web_design.dart';

/// Archived / Trashed road-defect reports with Restore & Permanent Purge controls.
class AdminTrashView extends StatefulWidget {
  final List<AdminReportRow> trashedRows;

  const AdminTrashView({super.key, required this.trashedRows});

  @override
  State<AdminTrashView> createState() => _AdminTrashViewState();
}

class _AdminTrashViewState extends State<AdminTrashView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _busy = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _restore(AdminReportRow r) async {
    if (_busy) return;
    setState(() => _busy = true);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    try {
      await CloudService.instance.restorePothole(
        r.id,
        targetStatus: r.previousStatus,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Restored #${r.shortId} back to "${r.previousStatus}".',
            isDark: isDark,
            tone: StatusTone.approved,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Restore failed: $e',
            isDark: isDark,
            tone: StatusTone.rejected,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteForever(AdminReportRow r) async {
    if (_busy) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WebDesign.surface(isDark),
        title: Text('Permanently Delete #${r.shortId}?'),
        content: const Text(
          'This removes the report document permanently from Firestore and cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: WebDesign.danger(isDark),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete Forever'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await CloudService.instance.permanentDeletePothole(r.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Permanently deleted report #${r.shortId}.',
            isDark: isDark,
            tone: StatusTone.info,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Permanent deletion failed: $e',
            isDark: isDark,
            tone: StatusTone.rejected,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _emptyTrash(List<AdminReportRow> targets) async {
    if (_busy || targets.isEmpty) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WebDesign.surface(isDark),
        title: Text('Empty Trash (${targets.length} reports)?'),
        content: Text(
          'This will permanently erase ${targets.length} archived report document(s) from Firestore. This action cannot be reversed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: WebDesign.danger(isDark),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Purge ${targets.length}'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await CloudService.instance.emptyTrashPotholes(
        targets.map((e) => e.id).toList(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Purged ${targets.length} trashed report(s).',
            isDark: isDark,
            tone: StatusTone.info,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Empty trash failed: $e',
            isDark: isDark,
            tone: StatusTone.rejected,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = Theme.of(context);
    final q = _query.trim().toLowerCase();
    final visible = widget.trashedRows.where((r) {
      if (q.isEmpty) return true;
      final hay =
          '${r.id} ${r.shortId} ${r.displayLocation} ${r.reporterName} ${r.reporterEmail}'
              .toLowerCase();
      return hay.contains(q);
    }).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final insets = WebDesign.pageInsets(width);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: insets.left,
                vertical: WebDesign.space4,
              ),
              decoration: BoxDecoration(
                color: WebDesign.surface(isDark),
                border: Border(
                  bottom: BorderSide(color: WebDesign.border(isDark)),
                ),
              ),
              child: Wrap(
                spacing: WebDesign.space4,
                runSpacing: WebDesign.space3,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: (width - insets.horizontal).clamp(0.0, 520.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _searchCtrl,
                          onChanged: (v) => setState(() => _query = v),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText:
                                'Search by report ID, location or reporter',
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 18,
                            ),
                            suffixIcon: _query.isNotEmpty
                                ? IconButton(
                                    tooltip: 'Clear search',
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                    ),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _query = '');
                                    },
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${visible.length} of ${widget.trashedRows.length} archived reports',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: WebDesign.danger(isDark),
                      side: BorderSide(color: WebDesign.danger(isDark)),
                    ),
                    onPressed: (_busy || visible.isEmpty)
                        ? null
                        : () => _emptyTrash(visible),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                    label: Text('Empty Trash (${visible.length})'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? SingleChildScrollView(
                      padding: insets,
                      child: SizedBox(
                        width: double.infinity,
                        child: EmptyState(
                          icon: Icons.delete_outline_rounded,
                          title: _query.isNotEmpty
                              ? 'No matching trashed reports'
                              : 'Trash is empty',
                          message: _query.isNotEmpty
                              ? 'Try clearing your search filter.'
                              : 'Soft-deleted reports are archived here and excluded from Overview KPIs and public maps.',
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: insets,
                      itemCount: visible.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: WebDesign.space3),
                      itemBuilder: (context, i) {
                        final r = visible[i];
                        return WebCard(
                          padding: const EdgeInsets.all(WebDesign.space4),
                          child: LayoutBuilder(
                            builder: (context, cardConstraints) {
                              final details = Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        '#${r.shortId}',
                                        style: WebDesign.tabular(
                                          theme.textTheme.titleSmall ??
                                              const TextStyle(),
                                        ),
                                      ),
                                      AdminDefectPill(row: r, compact: true),
                                      StatusChip(
                                        tone: StatusTone.neutral,
                                        label: 'Prior: ${r.previousStatus}',
                                        dense: true,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    r.displayLocation,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: WebDesign.textPrimary(isDark),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Archived ${formatAdminRelativeTime(r.deletedAt)}${r.deletedBy.isNotEmpty ? ' by ${r.deletedBy}' : ''}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              );
                              final actions = Wrap(
                                spacing: WebDesign.space2,
                                runSpacing: WebDesign.space2,
                                children: [
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: WebDesign.approveAction,
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: _busy ? null : () => _restore(r),
                                    icon: const Icon(
                                      Icons.restore_from_trash_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('Restore'),
                                  ),
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: WebDesign.danger(isDark),
                                      side: BorderSide(
                                        color: WebDesign.danger(isDark),
                                      ),
                                    ),
                                    onPressed: _busy
                                        ? null
                                        : () => _deleteForever(r),
                                    icon: const Icon(
                                      Icons.delete_forever_outlined,
                                      size: 16,
                                    ),
                                    label: const Text('Delete forever'),
                                  ),
                                ],
                              );
                              final textScale = MediaQuery.textScalerOf(
                                context,
                              ).scale(1);
                              if (cardConstraints.maxWidth < 800 * textScale) {
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    details,
                                    const SizedBox(height: WebDesign.space3),
                                    actions,
                                  ],
                                );
                              }
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: details),
                                  const SizedBox(width: WebDesign.space4),
                                  actions,
                                ],
                              );
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
