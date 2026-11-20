import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'admin_report_inspector.dart';
import 'admin_report_query.dart';
import 'admin_shared_widgets.dart';
import 'approval_priority.dart';
import 'cloud_service.dart';
import 'dpwh_standards.dart';
import 'web_components.dart';
import 'web_design.dart';

class AdminReviewQueueView extends StatefulWidget {
  final List<AdminReportRow> activeRows;
  final Map<String, ReportPriority> priorities;
  final AdminReportFilter filter;
  final ValueChanged<AdminReportFilter> onFilterChanged;
  final String? selectedReportId;
  final ValueChanged<String?> onSelectReportId;
  final bool isSuperAdmin;
  final LatLng? adminPosition;
  final bool isFetchingAdminPosition;
  final VoidCallback onRequestAdminPosition;
  final void Function(LatLng location, AdminReportRow row) onLocateOnMap;
  final Future<void> Function(AdminReportRow row) onSoftDelete;
  final Future<int> Function(List<AdminReportRow> targets) onBulkSoftDelete;

  const AdminReviewQueueView({
    super.key,
    required this.activeRows,
    required this.priorities,
    required this.filter,
    required this.onFilterChanged,
    required this.selectedReportId,
    required this.onSelectReportId,
    required this.isSuperAdmin,
    required this.adminPosition,
    required this.isFetchingAdminPosition,
    required this.onRequestAdminPosition,
    required this.onLocateOnMap,
    required this.onSoftDelete,
    required this.onBulkSoftDelete,
  });

  @override
  State<AdminReviewQueueView> createState() => _AdminReviewQueueViewState();
}

class _AdminReviewQueueViewState extends State<AdminReviewQueueView> {
  late final TextEditingController _searchCtrl;
  Timer? _debounce;
  final _tableHorizontal = ScrollController();
  final _tableVertical = ScrollController();
  int _pageIndex = 0;
  int _pageSize = 25;
  final Set<String> _selectedIds = <String>{};
  final Set<String> _rowBusyIds = <String>{};
  bool _bulkBusy = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: widget.filter.searchQuery);
  }

  @override
  void didUpdateWidget(covariant AdminReviewQueueView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filter.searchQuery != oldWidget.filter.searchQuery &&
        widget.filter.searchQuery != _searchCtrl.text) {
      _searchCtrl.text = widget.filter.searchQuery;
    }
    if (widget.selectedReportId != oldWidget.selectedReportId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tableHorizontal.hasClients) _tableHorizontal.jumpTo(0);
      });
    }
    if (widget.filter != oldWidget.filter) {
      _pageIndex = 0;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _tableHorizontal.dispose();
    _tableVertical.dispose();
    super.dispose();
  }

  void _onSearchChanged(String raw) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _pageIndex = 0;
      widget.onFilterChanged(widget.filter.copyWith(searchQuery: raw));
    });
  }

  Future<void> _quickApproveRow(AdminReportRow row) async {
    if (_rowBusyIds.contains(row.id)) return;
    setState(() => _rowBusyIds.add(row.id));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    try {
      await CloudService.instance.updatePotholeStatus(row.id, 'approved');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Report #${row.shortId} approved live.',
            isDark: isDark,
            tone: StatusTone.approved,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Approval failed: $e',
            isDark: isDark,
            tone: StatusTone.rejected,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _rowBusyIds.remove(row.id));
    }
  }

  Future<void> _quickRejectRow(AdminReportRow row) async {
    if (_rowBusyIds.contains(row.id)) return;
    final reason = await promptAdminRejectionReason(
      context,
      shortId: row.shortId,
    );
    if (reason == null || !mounted) return;
    setState(() => _rowBusyIds.add(row.id));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    try {
      await CloudService.instance.updatePotholeStatus(
        row.id,
        'rejected',
        rejectionReason: reason,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Report #${row.shortId} rejected with audit note.',
            isDark: isDark,
            tone: StatusTone.info,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Rejection failed: $e',
            isDark: isDark,
            tone: StatusTone.rejected,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _rowBusyIds.remove(row.id));
    }
  }

  Future<void> _handleBulkApprove(List<AdminReportRow> filteredRows) async {
    final targets = filteredRows
        .where(
          (r) =>
              _selectedIds.contains(r.id) &&
              r.status != AdminReportStatus.approved,
        )
        .toList();
    if (targets.isEmpty || _bulkBusy) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WebDesign.surface(isDark),
        title: const Text('Confirm Bulk Approval'),
        content: Text(
          'Approve and publish ${targets.length} selected report(s) to the live driver map?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: WebDesign.approveAction,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Approve ${targets.length}'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _bulkBusy = true);
    try {
      final count = await CloudService.instance.bulkApprovePotholes(
        targets.map((t) => t.id).toList(),
      );
      if (!mounted) return;
      setState(() {
        _bulkBusy = false;
        _selectedIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          'Approved $count selected report(s) live.',
          isDark: isDark,
          tone: StatusTone.approved,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _bulkBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          'Bulk approval failed cleanly: $e',
          isDark: isDark,
          tone: StatusTone.rejected,
        ),
      );
    }
  }

  Future<void> _handleBulkTrash(List<AdminReportRow> filteredRows) async {
    final targets = filteredRows
        .where((r) => _selectedIds.contains(r.id))
        .toList();
    if (targets.isEmpty || _bulkBusy) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WebDesign.surface(isDark),
        title: const Text('Move Selected to Trash?'),
        content: Text(
          'Move ${targets.length} selected report(s) to Trash? They can be restored from the Trash view.',
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
            child: Text('Move ${targets.length} to Trash'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _bulkBusy = true);
    try {
      final moved = await widget.onBulkSoftDelete(targets);
      if (!mounted) return;
      setState(() {
        _bulkBusy = false;
        _selectedIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          'Moved $moved report(s) to Trash.',
          isDark: isDark,
          tone: StatusTone.info,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _bulkBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          'Bulk trash action failed: $e',
          isDark: isDark,
          tone: StatusTone.rejected,
        ),
      );
    }
  }

  Future<void> _openExportDialog(List<AdminReportRow> filteredRows) async {
    if (filteredRows.isEmpty) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    var includeEmails = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setModalState) => AlertDialog(
          backgroundColor: WebDesign.surface(isDark),
          title: const Text('Export Filtered Reports to CSV'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Scope: ${filteredRows.length} report(s) matching current queue filters'
                  '${widget.filter.statuses.isEmpty ? ' (All active statuses)' : ' (${widget.filter.statuses.map((s) => s.label).join(', ')})'}.',
                  style: Theme.of(dialogCtx).textTheme.bodyMedium?.copyWith(
                    color: WebDesign.textPrimary(isDark),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: WebDesign.space2),
                Text(
                  'All text cells are formula-injection sanitized before download.',
                  style: Theme.of(dialogCtx).textTheme.bodySmall,
                ),
                const SizedBox(height: WebDesign.space3),
                if (widget.isSuperAdmin)
                  CheckboxListTile(
                    value: includeEmails,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      'Include reporter email addresses (PII)',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      'Leave unchecked for public/municipal sharing.',
                      style: TextStyle(fontSize: 11.5),
                    ),
                    onChanged: (v) =>
                        setModalState(() => includeEmails = v ?? false),
                  )
                else
                  Text(
                    'Reporter email columns are omitted for standard admin exports to minimize PII exposure.',
                    style: Theme.of(dialogCtx).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: WebDesign.brand(isDark),
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.download_rounded, size: 16),
              label: Text('Download CSV (${filteredRows.length})'),
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;
    final csv = AdminCsvExporter.buildReportsCsv(
      filteredRows,
      includeReporterEmail: widget.isSuperAdmin && includeEmails,
      priorities: widget.priorities,
    );
    downloadAdminCsvFile(
      csv,
      'roadsense_reports_${DateTime.now().millisecondsSinceEpoch}.csv',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      WebDesign.snack(
        'Exported ${filteredRows.length} report(s) to CSV.',
        isDark: isDark,
        tone: StatusTone.approved,
      ),
    );
  }

  void _openInspectRow(AdminReportRow row, bool useDockedInspector) {
    widget.onSelectReportId(row.id);
    if (!useDockedInspector) {
      showAdminReportInspectorModal(
        context,
        row: row,
        priority: widget.priorities[row.id],
        onLocateOnMap: widget.onLocateOnMap,
        onSoftDelete: widget.onSoftDelete,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final theme = Theme.of(context);
        final viewportWidth = constraints.maxWidth;

        final filtered = filterAndSortAdminRows(
          widget.activeRows,
          filter: widget.filter,
          priorities: widget.priorities,
          adminPosition: widget.adminPosition,
        );

        final slice = paginateAdminItems(
          filtered,
          requestedPage: _pageIndex,
          pageSize: _pageSize,
        );

        final activeRowIds = filtered.map((r) => r.id).toSet();
        final validSelectedCount = _selectedIds
            .where(activeRowIds.contains)
            .length;

        AdminReportRow? dockedSelectedRow;
        if (widget.selectedReportId != null) {
          for (final r in widget.activeRows) {
            if (r.id == widget.selectedReportId) {
              dockedSelectedRow = r;
              break;
            }
          }
        }
        final useDockedInspector = viewportWidth >= 1380;
        final showDockedPanel = useDockedInspector && dockedSelectedRow != null;
        final isDesktopTable =
            viewportWidth - (showDockedPanel ? 411 : 0) >= 1000;

        final pendingCount = widget.activeRows
            .where((r) => r.status == AdminReportStatus.pending)
            .length;
        final approvedCount = widget.activeRows
            .where((r) => r.status == AdminReportStatus.approved)
            .length;
        final rejectedCount = widget.activeRows
            .where((r) => r.status == AdminReportStatus.rejected)
            .length;

        return Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  // Filter & Toolbar Header
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                      horizontal: viewportWidth < 640
                          ? WebDesign.space4
                          : WebDesign.space6,
                      vertical: WebDesign.space3,
                    ),
                    decoration: BoxDecoration(
                      color: WebDesign.surface(isDark),
                      border: Border(
                        bottom: BorderSide(color: WebDesign.border(isDark)),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Status Segment Strip + Scope Export
                        Wrap(
                          spacing: WebDesign.space2,
                          runSpacing: WebDesign.space2,
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Wrap(
                              spacing: WebDesign.space2,
                              runSpacing: WebDesign.space2,
                              children: [
                                _StatusTabChip(
                                  label: 'Pending',
                                  count: pendingCount,
                                  selected:
                                      widget.filter.statuses.length == 1 &&
                                      widget.filter.statuses.contains(
                                        AdminReportStatus.pending,
                                      ),
                                  tone: StatusTone.pending,
                                  onTap: () => widget.onFilterChanged(
                                    widget.filter.copyWith(
                                      statuses: {AdminReportStatus.pending},
                                    ),
                                  ),
                                ),
                                _StatusTabChip(
                                  label: 'Approved',
                                  count: approvedCount,
                                  selected:
                                      widget.filter.statuses.length == 1 &&
                                      widget.filter.statuses.contains(
                                        AdminReportStatus.approved,
                                      ),
                                  tone: StatusTone.approved,
                                  onTap: () => widget.onFilterChanged(
                                    widget.filter.copyWith(
                                      statuses: {AdminReportStatus.approved},
                                    ),
                                  ),
                                ),
                                _StatusTabChip(
                                  label: 'Rejected',
                                  count: rejectedCount,
                                  selected:
                                      widget.filter.statuses.length == 1 &&
                                      widget.filter.statuses.contains(
                                        AdminReportStatus.rejected,
                                      ),
                                  tone: StatusTone.rejected,
                                  onTap: () => widget.onFilterChanged(
                                    widget.filter.copyWith(
                                      statuses: {AdminReportStatus.rejected},
                                    ),
                                  ),
                                ),
                                _StatusTabChip(
                                  label: 'All active',
                                  count: widget.activeRows.length,
                                  selected: widget.filter.statuses.isEmpty,
                                  tone: StatusTone.info,
                                  onTap: () => widget.onFilterChanged(
                                    widget.filter.copyWith(statuses: {}),
                                  ),
                                ),
                              ],
                            ),
                            OutlinedButton.icon(
                              onPressed: filtered.isEmpty
                                  ? null
                                  : () => _openExportDialog(filtered),
                              icon: const Icon(
                                Icons.download_outlined,
                                size: 16,
                              ),
                              label: Text('Export CSV (${filtered.length})'),
                            ),
                          ],
                        ),

                        const SizedBox(height: WebDesign.space3),

                        // Search, Sort, Date Preset & GPS Row
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final isNarrow = constraints.maxWidth < 760;
                            final searchField = ConstrainedBox(
                              constraints: BoxConstraints(
                                minWidth: isNarrow ? constraints.maxWidth : 240,
                                maxWidth: isNarrow ? constraints.maxWidth : 440,
                              ),
                              child: TextField(
                                controller: _searchCtrl,
                                onChanged: _onSearchChanged,
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText:
                                      'Search #ID, barangay, road, reporter, DPWH code, GPS...',
                                  prefixIcon: const Icon(
                                    Icons.search_rounded,
                                    size: 18,
                                  ),
                                  suffixIcon: _searchCtrl.text.isNotEmpty
                                      ? IconButton(
                                          tooltip: 'Clear search',
                                          icon: const Icon(
                                            Icons.close_rounded,
                                            size: 16,
                                          ),
                                          onPressed: () {
                                            _searchCtrl.clear();
                                            widget.onFilterChanged(
                                              widget.filter.copyWith(
                                                searchQuery: '',
                                              ),
                                            );
                                          },
                                        )
                                      : null,
                                ),
                              ),
                            );

                            final sortDropdown =
                                DropdownButtonFormField<AdminReportSort>(
                                  initialValue: widget.filter.sort,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    labelText: 'Sort order',
                                  ),
                                  items: [
                                    for (final s
                                        in AdminReportSort.values.where(
                                          (s) =>
                                              s !=
                                                  AdminReportSort.severityAsc &&
                                              s != AdminReportSort.severityDesc,
                                        ))
                                      DropdownMenuItem(
                                        value: s,
                                        child: Text(
                                          s.label,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (next) {
                                    if (next == null) return;
                                    widget.onFilterChanged(
                                      widget.filter.copyWith(sort: next),
                                    );
                                    if (next == AdminReportSort.proximity &&
                                        widget.adminPosition == null) {
                                      widget.onRequestAdminPosition();
                                    }
                                  },
                                );

                            final dateDropdown =
                                DropdownButtonFormField<AdminDatePreset>(
                                  initialValue: widget.filter.datePreset,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    labelText: 'Date range',
                                  ),
                                  items: [
                                    for (final d in AdminDatePreset.values)
                                      DropdownMenuItem(
                                        value: d,
                                        child: Text(
                                          d.label,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (next) {
                                    if (next != null) {
                                      widget.onFilterChanged(
                                        widget.filter.copyWith(
                                          datePreset: next,
                                        ),
                                      );
                                    }
                                  },
                                );

                            final gpsButton = OutlinedButton.icon(
                              onPressed: widget.onRequestAdminPosition,
                              icon: widget.isFetchingAdminPosition
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      widget.adminPosition != null
                                          ? Icons.gps_fixed_rounded
                                          : Icons.location_searching_rounded,
                                      size: 16,
                                      color: widget.adminPosition != null
                                          ? WebDesign.approveAction
                                          : null,
                                    ),
                              label: Text(
                                widget.adminPosition != null
                                    ? 'GPS active'
                                    : 'Use my GPS',
                              ),
                            );

                            if (isNarrow) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  searchField,
                                  const SizedBox(height: WebDesign.space2),
                                  Row(
                                    children: [
                                      Expanded(child: sortDropdown),
                                      const SizedBox(width: WebDesign.space2),
                                      Expanded(child: dateDropdown),
                                    ],
                                  ),
                                  const SizedBox(height: WebDesign.space2),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: gpsButton,
                                  ),
                                ],
                              );
                            }

                            return Row(
                              children: [
                                Expanded(flex: 3, child: searchField),
                                const SizedBox(width: WebDesign.space3),
                                SizedBox(width: 240, child: sortDropdown),
                                const SizedBox(width: WebDesign.space2),
                                SizedBox(width: 155, child: dateDropdown),
                                const SizedBox(width: WebDesign.space2),
                                gpsButton,
                              ],
                            );
                          },
                        ),

                        const SizedBox(height: WebDesign.space2),

                        // Severity, Defect Class, Barangay & SLA Facets
                        Wrap(
                          spacing: WebDesign.space2,
                          runSpacing: WebDesign.space2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final cls in DpwhStandards.allClasses)
                              FilterChip(
                                label: Text('${cls.code}: ${cls.name}'),
                                selected: widget.filter.defectClasses.contains(
                                  cls.name,
                                ),
                                onSelected: (selected) {
                                  final next = Set<String>.from(
                                    widget.filter.defectClasses,
                                  );
                                  if (selected) {
                                    next.add(cls.name);
                                  } else {
                                    next.remove(cls.name);
                                  }
                                  widget.onFilterChanged(
                                    widget.filter.copyWith(defectClasses: next),
                                  );
                                },
                              ),
                            if (widget.filter.barangayFilterKey != null &&
                                widget.filter.barangayFilterKey!.isNotEmpty)
                              InputChip(
                                label: Text(
                                  'Barangay: ${widget.filter.barangayDisplayLabel ?? widget.filter.barangayFilterKey}',
                                ),
                                onDeleted: () => widget.onFilterChanged(
                                  widget.filter.copyWith(clearBarangay: true),
                                ),
                              ),
                            if (widget.filter.hasActiveFilters)
                              TextButton.icon(
                                onPressed: () {
                                  _searchCtrl.clear();
                                  widget.onFilterChanged(
                                    widget.filter.clearRefinements(),
                                  );
                                },
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  size: 15,
                                ),
                                label: const Text('Reset filters'),
                              ),
                          ],
                        ),

                        // Bulk Selection Bar (only shown when items exist)
                        if (validSelectedCount > 0) ...[
                          const SizedBox(height: WebDesign.space3),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: WebDesign.space3,
                              vertical: WebDesign.space2,
                            ),
                            decoration: BoxDecoration(
                              color: WebDesign.brandWash(isDark),
                              borderRadius: BorderRadius.circular(
                                WebDesign.radiusMd,
                              ),
                              border: Border.all(
                                color: WebDesign.brand(
                                  isDark,
                                ).withValues(alpha: 0.35),
                              ),
                            ),
                            child: Wrap(
                              spacing: WebDesign.space3,
                              runSpacing: WebDesign.space2,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  '$validSelectedCount selected',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: WebDesign.brandOnSurface(isDark),
                                  ),
                                ),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: WebDesign.approveAction,
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: _bulkBusy
                                      ? null
                                      : () => _handleBulkApprove(filtered),
                                  icon: const Icon(
                                    Icons.done_all_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Approve selected'),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: WebDesign.danger(isDark),
                                    side: BorderSide(
                                      color: WebDesign.danger(isDark),
                                    ),
                                  ),
                                  onPressed: _bulkBusy
                                      ? null
                                      : () => _handleBulkTrash(filtered),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Move to Trash'),
                                ),
                                TextButton(
                                  onPressed: _bulkBusy
                                      ? null
                                      : () => setState(
                                          () => _selectedIds.clear(),
                                        ),
                                  child: const Text('Clear selection'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Main Paginated Content Area
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(WebDesign.space6),
                              child: EmptyState(
                                icon: widget.filter.hasActiveFilters
                                    ? Icons.filter_alt_off_rounded
                                    : Icons.check_circle_outline_rounded,
                                title: widget.filter.hasActiveFilters
                                    ? 'No matching reports'
                                    : 'No reports in this queue view',
                                message: widget.filter.hasActiveFilters
                                    ? 'Clear one or more active filters or search keywords to broaden results.'
                                    : 'Submissions matching this moderation state will appear here live.',
                                action: widget.filter.hasActiveFilters
                                    ? ElevatedButton.icon(
                                        onPressed: () {
                                          _searchCtrl.clear();
                                          widget.onFilterChanged(
                                            widget.filter.clearRefinements(),
                                          );
                                        },
                                        icon: const Icon(
                                          Icons.refresh_rounded,
                                          size: 16,
                                        ),
                                        label: const Text('Clear filters'),
                                      )
                                    : null,
                              ),
                            ),
                          )
                        : isDesktopTable
                        ? _buildDesktopTable(
                            context,
                            isDark,
                            slice,
                            useDockedInspector: useDockedInspector,
                          )
                        : _buildMobileCards(
                            context,
                            isDark,
                            slice,
                            useDockedInspector: useDockedInspector,
                          ),
                  ),

                  // Pagination Footer Bar
                  if (filtered.isNotEmpty)
                    _PaginationFooter(
                      slice: slice,
                      onPageChanged: (p) => setState(() => _pageIndex = p),
                      onPageSizeChanged: (s) => setState(() {
                        _pageSize = s;
                        _pageIndex = 0;
                      }),
                    ),
                ],
              ),
            ),

            // Docked Desktop Side-by-Side Detail Inspector
            if (showDockedPanel) ...[
              VerticalDivider(width: 1, color: WebDesign.border(isDark)),
              SizedBox(
                width: 410,
                child: Padding(
                  padding: const EdgeInsets.all(WebDesign.space4),
                  child: AdminReportInspectorPanel(
                    row: dockedSelectedRow,
                    priority: widget.priorities[dockedSelectedRow.id],
                    onClose: () => widget.onSelectReportId(null),
                    onLocateOnMap: widget.onLocateOnMap,
                    onSoftDelete: widget.onSoftDelete,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildDesktopTable(
    BuildContext context,
    bool isDark,
    AdminPageSlice<AdminReportRow> slice, {
    required bool useDockedInspector,
  }) {
    final theme = Theme.of(context);
    final pageIds = slice.items.map((r) => r.id).toSet();
    final allPageSelected =
        pageIds.isNotEmpty && pageIds.every(_selectedIds.contains);

    return Scrollbar(
      controller: _tableVertical,
      thumbVisibility: true,
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      child: SingleChildScrollView(
        controller: _tableVertical,
        padding: const EdgeInsets.all(WebDesign.space4),
        child: WebCard(
          padding: EdgeInsets.zero,
          child: Scrollbar(
            controller: _tableHorizontal,
            thumbVisibility: true,
            trackVisibility: true,
            scrollbarOrientation: ScrollbarOrientation.top,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _tableHorizontal,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(top: 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 960),
                child: DataTable(
                  showCheckboxColumn: true,
                  columnSpacing: 22,
                  horizontalMargin: 16,
                  headingRowHeight: 44,
                  dataRowMinHeight: 62,
                  dataRowMaxHeight: 74,
                  headingRowColor: WidgetStatePropertyAll(
                    WebDesign.sunken(isDark),
                  ),
                  onSelectAll: (checked) {
                    setState(() {
                      if (checked == true) {
                        _selectedIds.addAll(pageIds);
                      } else {
                        _selectedIds.removeAll(pageIds);
                      }
                    });
                  },
                  columns: [
                    DataColumn(
                      label: Text(
                        allPageSelected ? 'Report (page)' : 'Report',
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'Actions',
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'Defect & DPWH',
                        style: theme.textTheme.labelMedium,
                      ),
                    ),

                    DataColumn(
                      label: Text(
                        'AI Conf',
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'Priority',
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'Location',
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'Submitted',
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    DataColumn(
                      label: Text('Status', style: theme.textTheme.labelMedium),
                    ),
                  ],
                  rows: [
                    for (final r in slice.items)
                      _buildDataRow(
                        context,
                        isDark,
                        r,
                        useDockedInspector: useDockedInspector,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  DataRow _buildDataRow(
    BuildContext context,
    bool isDark,
    AdminReportRow r, {
    required bool useDockedInspector,
  }) {
    final theme = Theme.of(context);
    final isSelectedForInspect = widget.selectedReportId == r.id;
    final p = widget.priorities[r.id];
    final rowBusy = _rowBusyIds.contains(r.id);

    return DataRow(
      selected: _selectedIds.contains(r.id),
      color: WidgetStateProperty.resolveWith((states) {
        if (isSelectedForInspect) return WebDesign.brandWash(isDark);
        if (states.contains(WidgetState.hovered))
          return WebDesign.hover(isDark);
        return null;
      }),
      onSelectChanged: (checked) {
        setState(() {
          if (checked == true) {
            _selectedIds.add(r.id);
          } else {
            _selectedIds.remove(r.id);
          }
        });
      },
      cells: [
        DataCell(
          onTap: () => _openInspectRow(r, useDockedInspector),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                child: Container(
                  width: 44,
                  height: 44,
                  color: WebDesign.sunken(isDark),
                  child: r.hasPhoto
                      ? Image.network(
                          r.imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.broken_image_outlined, size: 16),
                        )
                      : const Icon(Icons.photo_outlined, size: 18),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '#${r.shortId}',
                    style: WebDesign.tabular(
                      theme.textTheme.titleSmall ?? const TextStyle(),
                    ),
                  ),
                  Text(
                    r.reporterName,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ],
          ),
        ),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Inspect report #${r.shortId}',
                onPressed: () => _openInspectRow(r, useDockedInspector),
                icon: const Icon(Icons.visibility_outlined, size: 18),
              ),
              if (r.status == AdminReportStatus.pending) ...[
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: WebDesign.approveAction,
                    minimumSize: const Size(0, 36),
                  ),
                  onPressed: rowBusy ? null : () => _quickApproveRow(r),
                  child: const Text('Approve'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: WebDesign.danger(isDark),
                    minimumSize: const Size(0, 36),
                  ),
                  onPressed: rowBusy ? null : () => _quickRejectRow(r),
                  child: const Text('Reject'),
                ),
              ],
            ],
          ),
        ),
        DataCell(
          onTap: () => _openInspectRow(r, useDockedInspector),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 210),
            child: AdminDefectPill(row: r, compact: true),
          ),
        ),

        DataCell(
          Text(
            r.maxConfidence != null
                ? '${(r.maxConfidence! * 100).toStringAsFixed(0)}%'
                : 'N/A',
            style: WebDesign.tabular(
              theme.textTheme.bodySmall?.copyWith(
                    color: r.maxConfidence != null
                        ? WebDesign.textPrimary(isDark)
                        : WebDesign.textMuted(isDark),
                    fontWeight: FontWeight.w600,
                  ) ??
                  const TextStyle(),
            ),
          ),
        ),
        DataCell(
          onTap: () => _openInspectRow(r, useDockedInspector),
          AdminPriorityBadge(priority: p),
        ),
        DataCell(
          onTap: () => _openInspectRow(r, useDockedInspector),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              r.displayLocation,
              style: theme.textTheme.bodySmall?.copyWith(
                color: WebDesign.textPrimary(isDark),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(
          Text(
            formatAdminRelativeTime(r.timestamp),
            style: theme.textTheme.bodySmall,
          ),
        ),
        DataCell(AdminStatusBadge(status: r.status)),
      ],
    );
  }

  Widget _buildMobileCards(
    BuildContext context,
    bool isDark,
    AdminPageSlice<AdminReportRow> slice, {
    required bool useDockedInspector,
  }) {
    final theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.all(WebDesign.space4),
      itemCount: slice.items.length,
      separatorBuilder: (_, _) => const SizedBox(height: WebDesign.space3),
      itemBuilder: (context, index) {
        final r = slice.items[index];
        final p = widget.priorities[r.id];
        final rowBusy = _rowBusyIds.contains(r.id);

        return WebCard(
          padding: const EdgeInsets.all(WebDesign.space4),
          onTap: () => _openInspectRow(r, useDockedInspector),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: _selectedIds.contains(r.id),
                    onChanged: (checked) {
                      setState(() {
                        if (checked == true) {
                          _selectedIds.add(r.id);
                        } else {
                          _selectedIds.remove(r.id);
                        }
                      });
                    },
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '#${r.shortId}',
                              style: WebDesign.tabular(
                                theme.textTheme.titleSmall ?? const TextStyle(),
                              ),
                            ),
                            AdminStatusBadge(status: r.status),
                          ],
                        ),
                        const SizedBox(height: 6),
                        AdminDefectPill(row: r, compact: true),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: WebDesign.space2),
              Text(
                r.displayLocation,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: WebDesign.textPrimary(isDark),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: WebDesign.space3,
                runSpacing: 4,
                children: [
                  Text(
                    'Submitted ${formatAdminRelativeTime(r.timestamp)} by ${r.reporterName}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    r.maxConfidence != null
                        ? 'AI conf ${(r.maxConfidence! * 100).toStringAsFixed(0)}%'
                        : 'AI conf unavailable',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (p != null) AdminPriorityBadge(priority: p),
                ],
              ),
              const SizedBox(height: WebDesign.space3),
              Wrap(
                spacing: WebDesign.space2,
                runSpacing: WebDesign.space2,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _openInspectRow(r, useDockedInspector),
                    icon: const Icon(Icons.visibility_outlined, size: 16),
                    label: const Text('Inspect'),
                  ),
                  if (r.status == AdminReportStatus.pending) ...[
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: WebDesign.approveAction,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: rowBusy ? null : () => _quickApproveRow(r),
                      icon: const Icon(
                        Icons.check_circle_outline_rounded,
                        size: 16,
                      ),
                      label: const Text('Approve'),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: WebDesign.danger(isDark),
                        side: BorderSide(color: WebDesign.danger(isDark)),
                      ),
                      onPressed: rowBusy ? null : () => _quickRejectRow(r),
                      icon: const Icon(Icons.cancel_outlined, size: 16),
                      label: const Text('Reject'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusTabChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final StatusTone tone;
  final VoidCallback onTap;

  const _StatusTabChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.tone,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final style = WebDesign.statusStyle(tone, isDark);
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => onTap(),
      label: Text('$label ($count)'),
      selectedColor: style.bg,
      labelStyle: TextStyle(
        color: selected ? style.fg : WebDesign.textPrimary(isDark),
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      side: BorderSide(
        color: selected ? style.outline : WebDesign.border(isDark),
      ),
    );
  }
}

class _PaginationFooter extends StatelessWidget {
  final AdminPageSlice<AdminReportRow> slice;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onPageSizeChanged;

  const _PaginationFooter({
    required this.slice,
    required this.onPageChanged,
    required this.onPageSizeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: WebDesign.space5,
        vertical: WebDesign.space2,
      ),
      decoration: BoxDecoration(
        color: WebDesign.surface(isDark),
        border: Border(top: BorderSide(color: WebDesign.border(isDark))),
      ),
      child: Wrap(
        spacing: WebDesign.space4,
        runSpacing: WebDesign.space2,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'Showing ${slice.startOrdinal}–${slice.endOrdinal} of ${slice.totalItems} reports',
            style: WebDesign.tabular(
              Theme.of(context).textTheme.bodySmall ?? const TextStyle(),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Rows: ', style: Theme.of(context).textTheme.bodySmall),
              DropdownButton<int>(
                value: slice.pageSize,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 25, child: Text('25')),
                  DropdownMenuItem(value: 50, child: Text('50')),
                  DropdownMenuItem(value: 100, child: Text('100')),
                ],
                onChanged: (v) {
                  if (v != null) onPageSizeChanged(v);
                },
              ),
              const SizedBox(width: WebDesign.space3),
              IconButton(
                tooltip: 'Previous page',
                onPressed: slice.pageIndex > 0
                    ? () => onPageChanged(slice.pageIndex - 1)
                    : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Text(
                'Page ${slice.pageIndex + 1} / ${slice.totalPages}',
                style: WebDesign.tabular(
                  Theme.of(context).textTheme.bodySmall ?? const TextStyle(),
                ),
              ),
              IconButton(
                tooltip: 'Next page',
                onPressed: slice.pageIndex < slice.totalPages - 1
                    ? () => onPageChanged(slice.pageIndex + 1)
                    : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
