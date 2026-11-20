import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'lgu_forecast.dart';
import 'web_components.dart';
import 'web_design.dart';

// Registry: Santa Maria Water District, 2025 annual report.
const santaMariaBarangays = [
  'Bagbaguin',
  'Balasing',
  'Buenavista',
  'Bulac',
  'Camangyanan',
  'Catmon',
  'Caypombo',
  'Caysio',
  'Guyong',
  'Lalakhan',
  'Mag-asawang Sapa',
  'Mahabang Parang',
  'Manggahan',
  'Parada',
  'Poblacion',
  'Pulong Buhangin',
  'San Gabriel',
  'San Jose Patag',
  'San Vicente',
  'Silangan',
  'Santa Clara',
  'Santa Cruz',
  'Santo Tomas',
  'Tumana',
];
String barangayKey(String value) => LguForecast.normalizeName(
  value,
).replaceAll('camangayanan', 'camangyanan').replaceAll(' ', '');

class BarangayForecastPanel extends StatefulWidget {
  final List<Map<String, dynamic>> reports;
  const BarangayForecastPanel({super.key, required this.reports});
  @override
  State<BarangayForecastPanel> createState() => _BarangayForecastPanelState();
}

class _BarangayForecastPanelState extends State<BarangayForecastPanel> {
  String _query = '', _coverage = 'all', _sort = 'name';
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final samples = <ForecastSample>[];
    var unassigned = 0;
    for (final data in widget.reports) {
      final city = LguForecast.normalizeName('${data['city'] ?? ''}');
      final province = LguForecast.normalizeName('${data['province'] ?? ''}');
      if (!(city == 'santa maria' || city == 'santa maria bulacan') ||
          (province.isNotEmpty && province != 'bulacan') ||
          data['status'] != 'approved') {
        continue;
      }
      final stamp = data['timestamp'];
      if (stamp is! Timestamp) continue;
      final date = stamp.toDate();
      if (date.isAfter(now) || now.difference(date).inDays >= 56) continue;
      final matches = santaMariaBarangays.where(
        (b) => barangayKey(b) == barangayKey('${data['barangay'] ?? ''}'),
      );
      if (matches.isEmpty) {
        unassigned++;
        continue;
      }
      final lat = data['latitude'], lng = data['longitude'];
      if (lat is! num || lng is! num || !lat.isFinite || !lng.isFinite) {
        continue;
      }
      samples.add(
        ForecastSample(
          date: date,
          lat: lat.toDouble(),
          lng: lng.toDouble(),
          severity: '${data['overallSeverity']}',
          city: 'Santa Maria',
          barangay: matches.first,
        ),
      );
    }
    final forecasts = {
      for (final f in LguForecast.compute(samples, now: now)) f.barangay: f,
    };
    bool ready(String name) {
      final f = forecasts[name];
      return f != null &&
          f.total >= 8 &&
          f.weeklyHistory.where((n) => n > 0).length >= 4;
    }

    final names = santaMariaBarangays
        .where(
          (name) =>
              barangayKey(name).contains(barangayKey(_query)) &&
              (_coverage == 'all' ||
                  (_coverage == 'ready' ? ready(name) : !ready(name))),
        )
        .toList();
    names.sort((a, b) {
      final cmp = _sort == 'severity'
          ? (forecasts[b]?.highCount ?? 0).compareTo(
              forecasts[a]?.highCount ?? 0,
            )
          : _sort == 'forecast'
          ? (ready(b) ? forecasts[b]!.predicted30 : -1).compareTo(
              ready(a) ? forecasts[a]!.predicted30 : -1,
            )
          : 0;
      return cmp == 0 ? a.compareTo(b) : cmp;
    });
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final readyCount = santaMariaBarangays.where(ready).length;
    final limitedCount = santaMariaBarangays.length - readyCount;

    void resetFilters() => setState(() {
      _search.clear();
      _query = '';
      _coverage = 'all';
      _sort = 'name';
    });

    return WebCard(
      padding: const EdgeInsets.all(WebDesign.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            eyebrow: '8-WEEK BARANGAY COVERAGE',
            title: 'Santa Maria: Barangay planning',
            subtitle:
                '$readyCount of 24 barangays have enough history. $unassigned recent approved reports need a recognized barangay.',
          ),
          const SizedBox(height: WebDesign.space2),
          Text(
            'Approved reports from the last 8 weeks. Estimates describe reporting trends, not confirmed future damage. At least 8 reports across 4 weeks are required. This coverage rule does not guarantee accuracy.',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: WebDesign.textSecondary(isDark),
            ),
          ),
          const SizedBox(height: WebDesign.space3),
          Wrap(
            spacing: WebDesign.space2,
            runSpacing: WebDesign.space2,
            children: [
              _SummaryStatPill(
                icon: Icons.verified_rounded,
                label: 'Trend available',
                value: '$readyCount / 24',
                accent: WebDesign.approveAction,
                isDark: isDark,
              ),
              _SummaryStatPill(
                icon: Icons.hourglass_bottom_rounded,
                label: 'Needs inspection',
                value: '$limitedCount',
                accent: WebDesign.brandOnSurface(isDark),
                isDark: isDark,
              ),
              _SummaryStatPill(
                icon: Icons.location_searching_rounded,
                label: 'Unassigned barangay',
                value: '$unassigned',
                accent: unassigned > 0
                    ? WebDesign.statusStyle(StatusTone.pending, isDark).fg
                    : WebDesign.textSecondary(isDark),
                isDark: isDark,
              ),
            ],
          ),
          const SizedBox(height: WebDesign.space3),
          TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              isDense: true,
              labelText: 'Find a Santa Maria barangay',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    )
                  : null,
              filled: true,
              fillColor: WebDesign.sunken(isDark),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(WebDesign.radiusMd),
              ),
            ),
          ),
          const SizedBox(height: WebDesign.space3),
          Wrap(
            spacing: WebDesign.space2,
            runSpacing: WebDesign.space2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in {
                'all': 'All 24 barangays',
                'ready': 'Trend available',
                'limited': 'Needs more data',
              }.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: _coverage == entry.key,
                  onSelected: (_) => setState(() => _coverage = entry.key),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: WebDesign.space3,
                ),
                decoration: BoxDecoration(
                  color: WebDesign.sunken(isDark),
                  borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                  border: Border.all(color: WebDesign.border(isDark)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _sort,
                    dropdownColor: WebDesign.surface(isDark),
                    items: const [
                      DropdownMenuItem(
                        value: 'name',
                        child: Text('Barangay: A to Z'),
                      ),

                      DropdownMenuItem(
                        value: 'forecast',
                        child: Text('Projection: highest first'),
                      ),
                    ],
                    onChanged: (v) => setState(() => _sort = v!),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: resetFilters,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('Reset filters'),
              ),
            ],
          ),
          const SizedBox(height: WebDesign.space3),
          Text(
            '${names.length} barangays shown',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: WebDesign.textSecondary(isDark),
            ),
          ),
          const SizedBox(height: WebDesign.space3),
          if (names.isEmpty)
            EmptyState(
              icon: Icons.filter_alt_off_rounded,
              title: 'No matching barangays',
              message: 'No matches. Clear the search or reset filters.',
              action: OutlinedButton.icon(
                onPressed: resetFilters,
                icon: const Icon(Icons.clear_all_rounded, size: 18),
                label: const Text('Clear search & filters'),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final cols = constraints.maxWidth >= 1040
                    ? 3
                    : constraints.maxWidth >= 640
                    ? 2
                    : 1;
                final rows = <Widget>[];
                for (var i = 0; i < names.length; i += cols) {
                  final slice = names.sublist(
                    i,
                    (i + cols).clamp(0, names.length),
                  );
                  rows.add(
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var j = 0; j < cols; j++) ...[
                            if (j > 0) const SizedBox(width: WebDesign.space3),
                            Expanded(
                              child: j < slice.length
                                  ? _BarangayCard(
                                      name: slice[j],
                                      forecast: forecasts[slice[j]],
                                      isReady: ready(slice[j]),
                                      isDark: isDark,
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                  if (i + cols < names.length) {
                    rows.add(const SizedBox(height: WebDesign.space3));
                  }
                }
                return Column(children: rows);
              },
            ),
        ],
      ),
    );
  }
}

class _SummaryStatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final bool isDark;

  const _SummaryStatPill({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: accent),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: WebDesign.textSecondary(isDark),
            ),
          ),
          Text(
            value,
            style: WebDesign.tabular(
              TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: WebDesign.textPrimary(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarangayCard extends StatelessWidget {
  final String name;
  final BarangayForecast? forecast;
  final bool isReady;
  final bool isDark;

  const _BarangayCard({
    required this.name,
    required this.forecast,
    required this.isReady,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final total = forecast?.total ?? 0;
    final history = forecast?.weeklyHistory ?? const [0, 0, 0, 0, 0, 0, 0, 0];
    final maxWeek = history.fold<int>(1, (a, b) => a > b ? a : b);

    final (StatusTone tone, String chipLabel) = !isReady
        ? (StatusTone.neutral, 'Limited history')
        : switch (forecast!.trend) {
            'rising' => (StatusTone.rejected, 'Rising trend'),
            'declining' => (StatusTone.approved, 'Declining'),
            _ => (StatusTone.info, 'Stable trend'),
          };
    final barColor = isReady
        ? WebDesign.statusStyle(tone, isDark).fg
        : WebDesign.textMuted(isDark);

    return Container(
      padding: const EdgeInsets.all(WebDesign.space4),
      decoration: BoxDecoration(
        color: WebDesign.sunken(isDark),
        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
        border: Border.all(color: WebDesign.border(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: WebDesign.textPrimary(isDark),
                  ),
                ),
              ),
              const SizedBox(width: WebDesign.space2),
              StatusChip(label: chipLabel, tone: tone),
            ],
          ),
          const SizedBox(height: WebDesign.space2),
          Text(
            '$total approved reports in 8 weeks',
            style: WebDesign.tabular(
              TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: WebDesign.textSecondary(isDark),
              ),
            ),
          ),
          const SizedBox(height: WebDesign.space2),
          SizedBox(
            height: 18,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var w = 0; w < history.length; w++) ...[
                  if (w > 0) const SizedBox(width: 3),
                  Expanded(
                    child: Container(
                      height: history[w] == 0
                          ? 3
                          : (4 + (history[w] / maxWeek) * 14).clamp(4.0, 18.0),
                      decoration: BoxDecoration(
                        color: history[w] == 0
                            ? WebDesign.border(isDark)
                            : barColor.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: WebDesign.space2),
          Text(
            isReady
                ? 'Trend: ${forecast!.trend}. Approx. ${forecast!.predicted30.toStringAsFixed(1)} reports in the next 30 days.'
                : 'Insufficient history. Prioritize inspection and reporting; no risk level assigned.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: WebDesign.textSecondary(isDark),
            ),
          ),
        ],
      ),
    );
  }
}
