import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'admin_forecast_metrics.dart';
import 'admin_report_query.dart';
import 'approval_priority.dart';
import 'dpwh_standards.dart';
import 'road_hazard_marker.dart';
import 'web_components.dart';
import 'web_design.dart';

/// Scoped municipal Overview answering:
/// 1. What needs review now? 2. What confirmed defects need action first?
/// 3. Where are spatial concentrations? 4. How current & reliable is data?
class AdminOverviewView extends StatefulWidget {
  final List<AdminReportRow> activeRows;
  final List<AdminReportRow> trashedRows;
  final Map<String, ReportPriority> priorities;
  final AdminBarangayInsightsResult barangayInsights;
  final bool isAutoAccept;
  final DateTime snapshotLoadedAt;
  final VoidCallback onNavigateQueuePending;
  final VoidCallback onNavigateQueueSlaBreached;
  final VoidCallback onNavigateQueueApproved;
  final VoidCallback onNavigateQueueRejected;
  final VoidCallback onNavigateQueueHighSeverity;
  final void Function(String defectClassName) onFilterByDefectClass;
  final VoidCallback onNavigateBarangayInsights;
  final VoidCallback onNavigateSettings;
  final void Function(LatLng center, AdminReportRow? leadReport)
  onInspectHotspot;

  const AdminOverviewView({
    super.key,
    required this.activeRows,
    required this.trashedRows,
    required this.priorities,
    required this.barangayInsights,
    required this.isAutoAccept,
    required this.snapshotLoadedAt,
    required this.onNavigateQueuePending,
    required this.onNavigateQueueSlaBreached,
    required this.onNavigateQueueApproved,
    required this.onNavigateQueueRejected,
    required this.onNavigateQueueHighSeverity,
    required this.onFilterByDefectClass,
    required this.onNavigateBarangayInsights,
    required this.onNavigateSettings,
    required this.onInspectHotspot,
  });

  @override
  State<AdminOverviewView> createState() => _AdminOverviewViewState();
}

class _AdminOverviewViewState extends State<AdminOverviewView> {
  bool _showActivityTable = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final width = MediaQuery.sizeOf(context).width;

    final pending = widget.activeRows
        .where((r) => r.status == AdminReportStatus.pending)
        .toList();
    final approved = widget.activeRows
        .where((r) => r.status == AdminReportStatus.approved)
        .toList();
    final rejected = widget.activeRows
        .where((r) => r.status == AdminReportStatus.rejected)
        .toList();
    final slaBreached = pending
        .where((r) => widget.priorities[r.id]?.isSlaBreached == true)
        .length;

    final hotspots = computeAdminHotspots(
      widget.activeRows,
      radiusMeters: 300.0,
    ).where((h) => h.totalCount >= 2).take(5).toList();

    final hh = widget.snapshotLoadedAt.hour.toString().padLeft(2, '0');
    final mm = widget.snapshotLoadedAt.minute.toString().padLeft(2, '0');

    return SingleChildScrollView(
      padding: WebDesign.pageInsets(width),
      child: CenteredMaxWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Data Freshness, Scope & Moderation Policy Strip
            WebCard(
              padding: const EdgeInsets.symmetric(
                horizontal: WebDesign.space5,
                vertical: WebDesign.space3,
              ),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  spacing: WebDesign.space4,
                  runSpacing: WebDesign.space2,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Icon(
                                Icons.sync_rounded,
                                size: 16,
                                color: WebDesign.statusStyle(
                                  StatusTone.approved,
                                  isDark,
                                ).fg,
                              ),
                            ),
                          ),
                          TextSpan(
                            text:
                                'Brgy. Poblacion, Santa Maria • ${widget.activeRows.length} active reports '
                                '(${widget.trashedRows.length} in Trash excluded) • Refreshed $hh:$mm',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: WebDesign.textPrimary(isDark),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                      onTap: widget.onNavigateSettings,
                      child: StatusChip(
                        tone: widget.isAutoAccept
                            ? StatusTone.pending
                            : StatusTone.info,
                        label: widget.isAutoAccept
                            ? 'Auto-Accept Active (change in Settings)'
                            : 'Manual Review Active',
                        dense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: WebDesign.space5),

            // Reconciled KPI Tiles (Pending + Approved + Rejected == Active)
            MetricGrid(
              desktopColumns: 4,
              children: [
                _ClickableKpiTile(
                  label: 'Pending Review',
                  value: '${pending.length}',
                  hint: 'Awaiting moderator decision',
                  icon: Icons.inbox_rounded,
                  accent: WebDesign.statusStyle(StatusTone.pending, isDark).fg,
                  onTap: widget.onNavigateQueuePending,
                ),
                _ClickableKpiTile(
                  label: 'Needs Urgent Review',
                  value: '$slaBreached',
                  hint: 'Pending past priority review window',
                  icon: Icons.timer_off_outlined,
                  accent: WebDesign.danger(isDark),
                  onTap: widget.onNavigateQueueSlaBreached,
                ),
                _ClickableKpiTile(
                  label: 'Approved Verified',
                  value: '${approved.length}',
                  hint: 'Published live on driver map',
                  icon: Icons.verified_outlined,
                  accent: WebDesign.approveAction,
                  onTap: widget.onNavigateQueueApproved,
                ),

                _ClickableKpiTile(
                  label: 'Rejected',
                  value: '${rejected.length}',
                  hint: 'Dismissed with audit record',
                  icon: Icons.cancel_outlined,
                  accent: WebDesign.textSecondary(isDark),
                  onTap: widget.onNavigateQueueRejected,
                ),
              ],
            ),

            const SizedBox(height: WebDesign.space6),

            // Activity Over Time + Reconciliation Panel
            LayoutBuilder(
              builder: (context, constraints) {
                final sideBySide = constraints.maxWidth >= 920;
                final activityCard = _build14DayIntakeCard(context, isDark);
                final compositionCard = _buildStatusAndSeverityCard(
                  context,
                  isDark,
                  pendingCount: pending.length,
                  approvedCount: approved.length,
                  rejectedCount: rejected.length,
                );
                if (sideBySide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: activityCard),
                      const SizedBox(width: WebDesign.space5),
                      Expanded(flex: 2, child: compositionCard),
                    ],
                  );
                }
                return Column(
                  children: [
                    activityCard,
                    const SizedBox(height: WebDesign.space5),
                    compositionCard,
                  ],
                );
              },
            ),

            const SizedBox(height: WebDesign.space6),

            // DPWH Defect Breakdown + Priority Spatial Clusters
            LayoutBuilder(
              builder: (context, constraints) {
                final sideBySide = constraints.maxWidth >= 960;
                final dpwhCard = _buildDpwhBreakdownCard(context, isDark);
                final clusterCard = _buildHotspotClustersCard(
                  context,
                  isDark,
                  hotspots,
                );
                if (sideBySide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: dpwhCard),
                      const SizedBox(width: WebDesign.space5),
                      Expanded(child: clusterCard),
                    ],
                  );
                }
                return Column(
                  children: [
                    dpwhCard,
                    const SizedBox(height: WebDesign.space5),
                    clusterCard,
                  ],
                );
              },
            ),

            const SizedBox(height: WebDesign.space6),

            // Scoped, Clearly Labeled Static Offline Benchmark Reference (Never Mixed With Live KPIs)
            WebCard(
              padding: EdgeInsets.zero,
              child: Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(
                    horizontal: WebDesign.space5,
                    vertical: WebDesign.space2,
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(
                    WebDesign.space5,
                    0,
                    WebDesign.space5,
                    WebDesign.space5,
                  ),
                  title: Row(
                    children: [
                      Icon(
                        Icons.science_outlined,
                        size: 18,
                        color: WebDesign.brandOnSurface(isDark),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Model Reference — YOLOv8s v3 Offline Test Set (Static Benchmark)',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text(
                    'Academic offline evaluation on 883 test instances (413 images) — separate from live field telemetry.',
                    style: theme.textTheme.bodySmall,
                  ),
                  children: [
                    const Divider(height: 20),
                    Wrap(
                      spacing: WebDesign.space3,
                      runSpacing: WebDesign.space3,
                      children: [
                        _RefChip(
                          label: 'Input / Classes',
                          value:
                              'YOLOv8s • ${DpwhStandards.inputResolution} • 4 trained classes',
                        ),
                        _RefChip(
                          label: 'Test Set mAP@50',
                          value:
                              '${(DpwhStandards.overallMap50 * 100).toStringAsFixed(2)}%',
                        ),
                        _RefChip(
                          label: 'Precision / Recall',
                          value:
                              '${(DpwhStandards.overallPrecision * 100).toStringAsFixed(1)}% P / ${(DpwhStandards.overallRecall * 100).toStringAsFixed(1)}% R',
                        ),
                        _RefChip(
                          label: 'Macro F1-Score',
                          value:
                              '${(DpwhStandards.overallF1Score * 100).toStringAsFixed(2)}%',
                        ),
                        _RefChip(
                          label: 'Ref. T4 GPU Benchmark (640px)',
                          value:
                              '${DpwhStandards.avgLatencyMs.toStringAsFixed(2)} ms / ${DpwhStandards.throughputFps.toStringAsFixed(1)} FPS',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _build14DayIntakeCard(BuildContext context, bool isDark) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = List<DateTime>.generate(
      14,
      (i) => today.subtract(Duration(days: 13 - i)),
    );

    final totalByDay = List<int>.filled(14, 0);
    final approvedByDay = List<int>.filled(14, 0);
    int undatedCount = 0;

    for (final r in widget.activeRows) {
      final ts = r.timestamp;
      if (ts == null) {
        undatedCount++;
        continue;
      }
      final dayOnly = DateTime(ts.year, ts.month, ts.day);
      final diff = today.difference(dayOnly).inDays;
      if (diff >= 0 && diff < 14) {
        final idx = 13 - diff;
        totalByDay[idx]++;
        if (r.status == AdminReportStatus.approved) {
          approvedByDay[idx]++;
        }
      }
    }

    final maxY = [
      ...totalByDay,
      ...approvedByDay,
      4,
    ].reduce((a, b) => a > b ? a : b).toDouble();

    return WebCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            eyebrow: '14-DAY INTAKE VS VERIFICATION',
            title: 'Daily Submission Volume',
            subtitle: undatedCount > 0
                ? 'Reported volume vs verified approved count ($undatedCount undated omitted).'
                : 'Reported volume vs verified approved count (last 14 calendar days).',
            trailing: OutlinedButton.icon(
              onPressed: () =>
                  setState(() => _showActivityTable = !_showActivityTable),
              icon: Icon(
                _showActivityTable
                    ? Icons.bar_chart_rounded
                    : Icons.table_rows_outlined,
                size: 16,
              ),
              label: Text(_showActivityTable ? 'Show Chart' : 'Data Table'),
            ),
          ),
          const SizedBox(height: WebDesign.space3),
          Wrap(
            spacing: WebDesign.space4,
            runSpacing: WebDesign.space2,
            children: [
              _LegendKey(
                color: WebDesign.brand(isDark),
                label: 'Total submitted (daily)',
              ),
              _LegendKey(
                color: WebDesign.approveAction,
                label: 'Currently approved',
              ),
            ],
          ),
          const SizedBox(height: WebDesign.space4),
          if (_showActivityTable)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 36,
                dataRowMinHeight: 34,
                dataRowMaxHeight: 38,
                columns: const [
                  DataColumn(label: Text('Date')),
                  DataColumn(numeric: true, label: Text('Submitted')),
                  DataColumn(numeric: true, label: Text('Approved')),
                ],
                rows: [
                  for (var i = days.length - 1; i >= 0; i--)
                    DataRow(
                      cells: [
                        DataCell(
                          Text(
                            '${days[i].month}/${days[i].day}/${days[i].year}',
                          ),
                        ),
                        DataCell(Text('${totalByDay[i]}')),
                        DataCell(Text('${approvedByDay[i]}')),
                      ],
                    ),
                ],
              ),
            )
          else
            SizedBox(
              height: 220,
              child: BarChart(
                BarChartData(
                  maxY: maxY + 1,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (v) =>
                        FlLine(color: WebDesign.border(isDark), strokeWidth: 1),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 32,
                        interval: maxY <= 6 ? 1 : (maxY / 4).ceilToDouble(),
                        getTitlesWidget: (val, _) => Text(
                          val.toInt().toString(),
                          style: TextStyle(
                            fontSize: 11,
                            color: WebDesign.textSecondary(isDark),
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        getTitlesWidget: (val, _) {
                          final idx = val.toInt();
                          if (idx < 0 || idx >= 14 || idx % 2 == 1) {
                            return const SizedBox.shrink();
                          }
                          final d = days[idx];
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '${d.month}/${d.day}',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: WebDesign.textSecondary(isDark),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < 14; i++)
                      BarChartGroupData(
                        x: i,
                        barsSpace: 3,
                        barRods: [
                          BarChartRodData(
                            toY: totalByDay[i].toDouble(),
                            color: WebDesign.brand(isDark),
                            width: 7,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          BarChartRodData(
                            toY: approvedByDay[i].toDouble(),
                            color: WebDesign.approveAction,
                            width: 7,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusAndSeverityCard(
    BuildContext context,
    bool isDark, {
    required int pendingCount,
    required int approvedCount,
    required int rejectedCount,
  }) {
    final activeTotal = pendingCount + approvedCount + rejectedCount;

    return WebCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading(
            eyebrow: 'QUEUE & DAMAGE COMPOSITION',
            title: 'Report Status',
            subtitle:
                'Active totals reconcile exactly: Pending + Approved + Rejected.',
          ),
          const SizedBox(height: WebDesign.space4),
          if (activeTotal == 0)
            const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'No active reports yet',
              message:
                  'Verified and pending submissions will populate here once received.',
              boxed: false,
            )
          else ...[
            _ProportionRow(
              label: 'Pending review',
              count: pendingCount,
              total: activeTotal,
              color: WebDesign.statusStyle(StatusTone.pending, isDark).fg,
            ),
            const SizedBox(height: WebDesign.space2),
            _ProportionRow(
              label: 'Approved live',
              count: approvedCount,
              total: activeTotal,
              color: WebDesign.approveAction,
            ),
            const SizedBox(height: WebDesign.space2),
            _ProportionRow(
              label: 'Rejected',
              count: rejectedCount,
              total: activeTotal,
              color: WebDesign.danger(isDark),
            ),
            const SizedBox(height: WebDesign.space4),
            Divider(height: 1, color: WebDesign.border(isDark)),
            const SizedBox(height: WebDesign.space4),
          ],
        ],
      ),
    );
  }

  Widget _buildDpwhBreakdownCard(BuildContext context, bool isDark) {
    final counts = DpwhStandards.countSupportedReports(
      widget.activeRows.map((r) => r.rawData),
    );
    final supportedSum = counts.values.fold<int>(0, (a, b) => a + b);
    final legacyCount = widget.activeRows.length - supportedSum;
    final denom = widget.activeRows.isEmpty ? 1 : widget.activeRows.length;

    return WebCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading(
            eyebrow: 'DEFECT CLASS TAXONOMY',
            title: 'Road Defect Types',
            subtitle: 'Select any defect class to filter Review Queue records.',
          ),
          const SizedBox(height: WebDesign.space4),
          for (final cls in DpwhStandards.allClasses) ...[
            InkWell(
              borderRadius: BorderRadius.circular(WebDesign.radiusSm),
              onTap: () => widget.onFilterByDefectClass(cls.name),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        RoadDefectGlyph(
                          classId: cls.classId,
                          size: 18,
                          color: cls.color,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${cls.code} • ${cls.name}',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        StatusChip(
                          tone: StatusTone.neutral,
                          label: cls.responseTime,
                          dense: true,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${counts[cls.classId] ?? 0}',
                          style: WebDesign.tabular(
                            Theme.of(context).textTheme.titleSmall ??
                                const TextStyle(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: (counts[cls.classId] ?? 0) / denom,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(999),
                      backgroundColor: WebDesign.sunken(isDark),
                      color: cls.color,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Recommended solution: ${cls.correctiveMeasure}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        color: WebDesign.textSecondary(isDark),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
          if (legacyCount > 0) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => widget.onFilterByDefectClass('legacy'),
              child: Text(
                'Older / unclassified entries: $legacyCount (click to inspect)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: WebDesign.brandOnSurface(isDark),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHotspotClustersCard(
    BuildContext context,
    bool isDark,
    List<AdminSpatialHotspot> hotspots,
  ) {
    final theme = Theme.of(context);
    return WebCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading(
            eyebrow: 'SPATIAL CONCENTRATIONS (300 M RADIUS)',
            title: 'Recurring Defect Hotspots',
            subtitle:
                'Locations with 2+ nearby reports requiring coordinated field inspection.',
          ),
          const SizedBox(height: WebDesign.space4),
          if (hotspots.isEmpty)
            const EmptyState(
              icon: Icons.scatter_plot_outlined,
              title: 'No recurring spatial clusters',
              message:
                  'Active reports are isolated beyond 300 m. Review individual reports in the Review Queue.',
              boxed: false,
            )
          else
            for (final h in hotspots)
              Container(
                margin: const EdgeInsets.only(bottom: WebDesign.space2),
                padding: const EdgeInsets.all(WebDesign.space3),
                decoration: BoxDecoration(
                  color: WebDesign.sunken(isDark),
                  borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                  border: Border.all(color: WebDesign.border(isDark)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color:
                            (h.highSeverityCount > 0
                                    ? WebDesign.danger(isDark)
                                    : WebDesign.brand(isDark))
                                .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                      ),
                      child: Text(
                        '${h.totalCount}',
                        style: WebDesign.tabular(
                          theme.textTheme.titleSmall?.copyWith(
                                color: h.highSeverityCount > 0
                                    ? WebDesign.danger(isDark)
                                    : WebDesign.brandOnSurface(isDark),
                              ) ??
                              const TextStyle(),
                        ),
                      ),
                    ),
                    const SizedBox(width: WebDesign.space3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${h.primaryDefect} cluster • ${h.locationLabel}',
                            style: theme.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${h.approvedCount} approved • ${h.pendingCount} pending',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => widget.onInspectHotspot(
                        h.center,
                        h.items.isNotEmpty ? h.items.first : null,
                      ),
                      icon: const Icon(Icons.map_outlined, size: 15),
                      label: const Text('Inspect'),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _ClickableKpiTile extends StatelessWidget {
  final String label;
  final String value;
  final String hint;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  const _ClickableKpiTile({
    required this.label,
    required this.value,
    required this.hint,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return WebCard(
      onTap: onTap,
      padding: const EdgeInsets.all(WebDesign.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(WebDesign.space2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                ),
                child: Icon(icon, color: accent, size: WebDesign.iconSm),
              ),
              const SizedBox(width: WebDesign.space2),
              Expanded(child: Eyebrow(label)),
              const Icon(Icons.chevron_right_rounded, size: 16),
            ],
          ),
          const SizedBox(height: WebDesign.space3),
          Text(
            value,
            style: WebDesign.tabular(
              Theme.of(context).textTheme.headlineMedium ?? const TextStyle(),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _LegendKey extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendKey({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ProportionRow extends StatelessWidget {
  final String label;
  final int count;
  final int total;
  final Color color;

  const _ProportionRow({
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pct = total > 0 ? ((count / total) * 100).round() : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodySmall),
            ),
            Text(
              '$count ($pct%)',
              style: WebDesign.tabular(
                Theme.of(context).textTheme.labelMedium ?? const TextStyle(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: total > 0 ? count / total : 0,
          minHeight: 6,
          borderRadius: BorderRadius.circular(999),
          backgroundColor: WebDesign.sunken(isDark),
          color: color,
        ),
      ],
    );
  }
}

class _RefChip extends StatelessWidget {
  final String label;
  final String value;

  const _RefChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: WebDesign.space3,
        vertical: WebDesign.space2,
      ),
      decoration: BoxDecoration(
        color: WebDesign.sunken(isDark),
        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
        border: Border.all(color: WebDesign.border(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Eyebrow(label),
          const SizedBox(height: 2),
          Text(
            value,
            style: WebDesign.tabular(
              Theme.of(context).textTheme.titleSmall ?? const TextStyle(),
            ),
          ),
        ],
      ),
    );
  }
}
