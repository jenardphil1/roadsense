import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'admin_forecast_metrics.dart';
import 'admin_shared_widgets.dart';
import 'web_components.dart';
import 'web_design.dart';
import 'web_report_query.dart' show santaMariaBarangayCatalog;

enum _BarangayScopeTab {
  santaMariaAll('All 24 Santa Maria'),
  hasReports('Has reports'),
  forecastReady('Forecast ready'),
  noOrSparse('No / sparse data'),
  otherLgus('Other LGUs & Unassigned');

  final String label;
  const _BarangayScopeTab(this.label);
}

/// Complete Santa Maria 24-barangay coverage, period-over-period comparisons,
/// honest sparse/no-data labeling, walk-forward validation vs. naive baseline,
/// and clickable drill-downs to Review Queue & Admin Map.
class AdminBarangayInsightsView extends StatefulWidget {
  final AdminBarangayInsightsResult insights;
  final bool isGeocoding;
  final int geocodedDone;
  final int geocodedTotal;
  final VoidCallback onStartGeocodeBackfill;
  final VoidCallback onStopGeocodeBackfill;
  final void Function(AdminBarangaySummary brgy) onViewReportsInBarangay;
  final void Function(LatLng target, String barangayName, String canonicalKey)
  onFocusBarangayOnMap;

  const AdminBarangayInsightsView({
    super.key,
    required this.insights,
    required this.isGeocoding,
    required this.geocodedDone,
    required this.geocodedTotal,
    required this.onStartGeocodeBackfill,
    required this.onStopGeocodeBackfill,
    required this.onViewReportsInBarangay,
    required this.onFocusBarangayOnMap,
  });

  @override
  State<AdminBarangayInsightsView> createState() =>
      _AdminBarangayInsightsViewState();
}

class _AdminBarangayInsightsViewState extends State<AdminBarangayInsightsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  _BarangayScopeTab _scope = _BarangayScopeTab.santaMariaAll;
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<AdminBarangaySummary> _filteredRows() {
    final source = _scope == _BarangayScopeTab.otherLgus
        ? widget.insights.otherLguRows
        : widget.insights.santaMariaRows;

    final q = _query.trim().toLowerCase();
    return source.where((r) {
      if (_scope == _BarangayScopeTab.hasReports && r.totalActive == 0) {
        return false;
      }
      if (_scope == _BarangayScopeTab.forecastReady &&
          r.coverageState != BarangayCoverageState.forecastAvailable) {
        return false;
      }
      if (_scope == _BarangayScopeTab.noOrSparse &&
          r.coverageState == BarangayCoverageState.forecastAvailable) {
        return false;
      }
      if (q.isNotEmpty) {
        final hay =
            '${r.barangay} ${r.city} ${r.province} ${r.coverageState.label}'
                .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  void _exportCsv(List<AdminBarangaySummary> rows) {
    final allRows = _scope == _BarangayScopeTab.otherLgus
        ? rows
        : [...widget.insights.santaMariaRows, ...widget.insights.otherLguRows];
    final csv = buildAdminBarangayCsv(allRows);
    downloadAdminCsvFile(
      csv,
      'roadsense_barangay_insights_${DateTime.now().millisecondsSinceEpoch}.csv',
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ScaffoldMessenger.of(context).showSnackBar(
      WebDesign.snack(
        'Exported ${allRows.length} barangay summary rows to CSV.',
        isDark: isDark,
        tone: StatusTone.approved,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final width = MediaQuery.sizeOf(context).width;
    final visible = _filteredRows();
    final val = widget.insights.validation;

    return SingleChildScrollView(
      padding: WebDesign.pageInsets(width),
      child: CenteredMaxWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Coverage Overview Metrics
            MetricGrid(
              desktopColumns: 4,
              children: [
                MetricTile(
                  label: 'Santa Maria Coverage',
                  value: '${widget.insights.coveredSantaMariaCount} / 24',
                  hint: 'Official barangays with >= 1 active report',
                  icon: Icons.location_city_rounded,
                  accent: WebDesign.brand(isDark),
                ),
                MetricTile(
                  label: 'Forecast Ready',
                  value: '${widget.insights.forecastReadySantaMariaCount} / 24',
                  hint: 'Meets >= 8 verified reports across >= 4 weeks',
                  icon: Icons.timeline_rounded,
                  accent: WebDesign.approveAction,
                ),
                MetricTile(
                  label: 'Rising Verified Trend',
                  value: '${widget.insights.risingSantaMariaCount}',
                  hint: 'Barangays with increasing validated reports',
                  icon: Icons.trending_up_rounded,
                  accent: WebDesign.danger(isDark),
                ),
                MetricTile(
                  label: 'Unassigned Geocodes',
                  value: '${widget.insights.unassignedCount}',
                  hint: 'Reports missing verified barangay/city tags',
                  icon: Icons.pin_drop_outlined,
                  accent: widget.insights.unassignedCount > 0
                      ? WebDesign.pendingLight
                      : WebDesign.textMuted(isDark),
                ),
              ],
            ),

            const SizedBox(height: WebDesign.space5),

            // Model Validation & Caveat Banner
            WebCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: WebDesign.space3,
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
                                  val.evaluatedPoints > 0 && val.beatsBaseline
                                      ? Icons.verified_outlined
                                      : Icons.info_outline_rounded,
                                  color:
                                      val.evaluatedPoints > 0 &&
                                          val.beatsBaseline
                                      ? WebDesign.approveAction
                                      : WebDesign.pendingLight,
                                ),
                              ),
                            ),
                            TextSpan(
                              text:
                                  'Forecast Validation vs Naive Persistence Baseline',
                              style: theme.textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                      StatusChip(
                        tone: val.evaluatedPoints == 0
                            ? StatusTone.neutral
                            : (val.beatsBaseline
                                  ? StatusTone.approved
                                  : StatusTone.pending),
                        label: val.evaluatedPoints == 0
                            ? 'Unvalidated'
                            : (val.beatsBaseline
                                  ? 'Outperforms naive baseline'
                                  : 'Does not beat naive'),
                      ),
                    ],
                  ),
                  const SizedBox(height: WebDesign.space2),
                  Text(
                    val.summaryLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: WebDesign.textPrimary(isDark),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Forecasts use approved reports over an 8-week weighted linear trend adjusted for Philippine rainy season (Jun–Nov). '
                    'Reported 30-day counts reflect expected verified report volume (not true defect incidence), and sparse barangays are explicitly marked as insufficient history rather than safe.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (val.evaluatedPoints > 0) ...[
                    const SizedBox(height: WebDesign.space3),
                    Wrap(
                      spacing: WebDesign.space4,
                      runSpacing: 6,
                      children: [
                        Text(
                          'Model RMSE: ${val.modelRmse?.toStringAsFixed(2)}',
                          style: WebDesign.tabular(
                            theme.textTheme.labelMedium ?? const TextStyle(),
                          ),
                        ),
                        Text(
                          'Naive RMSE: ${val.baselineRmse?.toStringAsFixed(2)}',
                          style: WebDesign.tabular(
                            theme.textTheme.labelMedium ?? const TextStyle(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Optional Geocode Backfill Banner
            if (widget.insights.unassignedCount > 0 || widget.isGeocoding) ...[
              const SizedBox(height: WebDesign.space4),
              WebCard(
                child: LayoutBuilder(
                  builder: (context, bannerConstraints) {
                    final infoColumn = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.isGeocoding
                              ? 'Classifying unassigned locations (${widget.geocodedDone} / ${widget.geocodedTotal})...'
                              : '${widget.insights.unassignedCount} active report(s) have incomplete Barangay / Municipality metadata.',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Run progressive reverse-geocoding backfill to assign official Barangay & City tags.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    );
                    final actionButton = widget.isGeocoding
                        ? OutlinedButton.icon(
                            onPressed: widget.onStopGeocodeBackfill,
                            icon: const Icon(
                              Icons.stop_circle_outlined,
                              size: 16,
                            ),
                            label: const Text('Stop'),
                          )
                        : ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: WebDesign.brand(isDark),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: widget.onStartGeocodeBackfill,
                            icon: const Icon(
                              Icons.travel_explore_rounded,
                              size: 16,
                            ),
                            label: const Text('Classify Unassigned'),
                          );
                    if (bannerConstraints.maxWidth >= 640) {
                      return Row(
                        children: [
                          Expanded(child: infoColumn),
                          const SizedBox(width: WebDesign.space4),
                          actionButton,
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        infoColumn,
                        const SizedBox(height: WebDesign.space3),
                        actionButton,
                      ],
                    );
                  },
                ),
              ),
            ],

            const SizedBox(height: WebDesign.space5),

            // Filter Toolbar + Export LGU CSV Button
            WebCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeading(
                    eyebrow: '24 OFFICIAL BARANGAYS & REGIONAL LGUS',
                    title: 'Barangay & LGU Comparison',
                    subtitle:
                        'Compare verified counts, pending queue load, 14-day period delta, and validated forecasts.',
                    trailing: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: WebDesign.approveAction,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => _exportCsv(visible),
                      icon: const Icon(Icons.download_rounded, size: 16),
                      label: const Text('Export LGU CSV'),
                    ),
                  ),
                  const SizedBox(height: WebDesign.space4),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final narrow = constraints.maxWidth < 700;
                      final search = ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: narrow ? double.infinity : 360,
                        ),
                        child: TextField(
                          controller: _searchCtrl,
                          onChanged: (v) => setState(() => _query = v),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Search barangay or municipality...',
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 18,
                            ),
                            suffixIcon: _query.isNotEmpty
                                ? IconButton(
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
                      );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          search,
                          const SizedBox(height: WebDesign.space3),
                          Wrap(
                            spacing: WebDesign.space2,
                            runSpacing: WebDesign.space2,
                            children: [
                              for (final tab in _BarangayScopeTab.values)
                                ChoiceChip(
                                  label: Text(
                                    tab == _BarangayScopeTab.otherLgus
                                        ? '${tab.label} (${widget.insights.otherLguRows.length})'
                                        : tab.label,
                                  ),
                                  selected: _scope == tab,
                                  onSelected: (_) =>
                                      setState(() => _scope = tab),
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: WebDesign.space4),
                  if (visible.isEmpty)
                    const EmptyState(
                      icon: Icons.location_off_outlined,
                      title: 'No matching barangays',
                      message:
                          'Try clearing search text or switching back to "All 24 Santa Maria".',
                      boxed: false,
                    )
                  else
                    for (final b in visible)
                      _buildBarangayRowCard(context, isDark, b),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBarangayRowCard(
    BuildContext context,
    bool isDark,
    AdminBarangaySummary b,
  ) {
    final theme = Theme.of(context);
    final coverageTone = switch (b.coverageState) {
      BarangayCoverageState.forecastAvailable =>
        b.trend == 'rising'
            ? StatusTone.rejected
            : (b.trend == 'declining' ? StatusTone.approved : StatusTone.info),
      BarangayCoverageState.insufficientHistory => StatusTone.pending,
      BarangayCoverageState.noRecentReports => StatusTone.neutral,
      BarangayCoverageState.noReports => StatusTone.neutral,
    };

    final mapTarget = b.centroid ?? _fallbackBarangayLatLng(b.canonicalKey);

    return Container(
      margin: const EdgeInsets.only(bottom: WebDesign.space3),
      padding: const EdgeInsets.all(WebDesign.space4),
      decoration: BoxDecoration(
        color: WebDesign.sunken(isDark),
        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
        border: Border.all(color: WebDesign.border(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: WebDesign.space2,
            runSpacing: WebDesign.space2,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: WebDesign.space2,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(b.barangay, style: theme.textTheme.titleMedium),
                  if (!b.isOfficialSantaMaria)
                    StatusChip(
                      tone: StatusTone.neutral,
                      label: '${b.city}, ${b.province}',
                      dense: true,
                    ),
                  StatusChip(
                    tone: coverageTone,
                    label:
                        b.coverageState ==
                            BarangayCoverageState.forecastAvailable
                        ? 'Forecast • ${b.trend[0].toUpperCase()}${b.trend.substring(1)}'
                        : b.coverageState.label,
                    dense: true,
                  ),
                ],
              ),
              Wrap(
                spacing: WebDesign.space2,
                runSpacing: 6,
                children: [
                  if (b.totalActive > 0)
                    OutlinedButton.icon(
                      onPressed: () => widget.onViewReportsInBarangay(b),
                      icon: const Icon(Icons.list_alt_rounded, size: 15),
                      label: const Text('View reports'),
                    ),
                  if (mapTarget != null)
                    OutlinedButton.icon(
                      onPressed: () => widget.onFocusBarangayOnMap(
                        mapTarget,
                        b.barangay,
                        b.canonicalKey,
                      ),
                      icon: const Icon(Icons.map_outlined, size: 15),
                      label: const Text('Focus map'),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: WebDesign.space3),

          // Separated metrics strip (Reported vs Verified vs Severity vs Forecast)
          Wrap(
            spacing: WebDesign.space4,
            runSpacing: WebDesign.space2,
            children: [
              _CellStat(
                label: 'Verified approved',
                value: '${b.approvedCount}',
              ),
              _CellStat(label: 'Pending review', value: '${b.pendingCount}'),
              _CellStat(label: 'Rejected', value: '${b.rejectedCount}'),

              _CellStat(label: '14d verified delta', value: b.periodDeltaLabel),
              _CellStat(
                label: 'Avg AI conf',
                value: b.avgConfidence != null
                    ? '${(b.avgConfidence! * 100).toStringAsFixed(0)}%'
                    : 'N/A',
              ),
              _CellStat(
                label: '30d forecast (P10–P90)',
                value:
                    b.coverageState ==
                            BarangayCoverageState.forecastAvailable &&
                        b.forecast30d != null
                    ? '${b.forecast30d} (${b.forecastLower30d}–${b.forecastUpper30d})'
                    : 'Need >= 8 verified across >= 4 wks (${b.recent8wApproved} in ${b.activeWeeksIn8w}w)',
              ),
            ],
          ),

          if (b.recent8wApproved > 0) ...[
            const SizedBox(height: WebDesign.space3),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '8-week verified cadence: ',
                  style: theme.textTheme.bodySmall,
                ),
                for (var i = 0; i < b.weekly8wApproved.length; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: b.weekly8wApproved[i] > 0
                          ? WebDesign.brandWash(isDark)
                          : WebDesign.surface(isDark),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: WebDesign.border(isDark)),
                    ),
                    child: Text(
                      'W${i + 1}:${b.weekly8wApproved[i]}',
                      style: WebDesign.tabular(
                        theme.textTheme.labelSmall ?? const TextStyle(),
                      ),
                    ),
                  ),
              ],
            ),
          ],

          if (b.dataQualityNotes.isNotEmpty) ...[
            const SizedBox(height: WebDesign.space2),
            Text(
              'Data notes: ${b.dataQualityNotes.join(' • ')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: WebDesign.pendingLight,
              ),
            ),
          ],
        ],
      ),
    );
  }

  LatLng? _fallbackBarangayLatLng(String canonicalKey) {
    if (canonicalKey.isEmpty) return null;
    for (final entry in santaMariaBarangayCatalog) {
      if (entry.key == canonicalKey && entry.lat != null && entry.lon != null) {
        return LatLng(entry.lat!, entry.lon!);
      }
    }
    return null;
  }
}

class _CellStat extends StatelessWidget {
  final String label;
  final String value;

  const _CellStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Eyebrow(label),
        const SizedBox(height: 2),
        Text(
          value,
          style: WebDesign.tabular(
            Theme.of(context).textTheme.labelLarge ?? const TextStyle(),
          ),
        ),
      ],
    );
  }
}
