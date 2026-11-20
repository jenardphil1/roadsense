import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'admin_report_query.dart';
import 'barangay_forecast_panel.dart' show barangayKey, santaMariaBarangays;
import 'lgu_forecast.dart';

/// Coverage completeness of a barangay across all reports in a municipal view.
/// Zero data is NEVER conflated with a "safe" or "clear" road assessment.
enum BarangayCoverageState {
  noReports('No reports recorded'),
  noRecentReports('No recent verified reports (8 wks)'),
  insufficientHistory('Insufficient history for forecast'),
  forecastAvailable('Forecast available');

  final String label;
  const BarangayCoverageState(this.label);
}

class AdminForecastValidation {
  final int evaluatedPoints;
  final double? modelMae;
  final double? baselineMae;
  final double? modelRmse;
  final double? baselineRmse;
  final bool beatsBaseline;
  final String summaryLabel;

  const AdminForecastValidation({
    required this.evaluatedPoints,
    required this.modelMae,
    required this.baselineMae,
    required this.modelRmse,
    required this.baselineRmse,
    required this.beatsBaseline,
    required this.summaryLabel,
  });

  const AdminForecastValidation.unvalidated({this.evaluatedPoints = 0})
    : modelMae = null,
      baselineMae = null,
      modelRmse = null,
      baselineRmse = null,
      beatsBaseline = false,
      summaryLabel =
          'Unvalidated — need >= 8 verified reports across >= 4 weeks';
}

class AdminBarangaySummary {
  final String barangay;
  final String canonicalKey;
  final String city;
  final String province;
  final bool isOfficialSantaMaria;
  final BarangayCoverageState coverageState;
  final int totalActive;
  final int pendingCount;
  final int approvedCount;
  final int rejectedCount;
  final int highSeverityCount;
  final int mediumSeverityCount;
  final int lowSeverityCount;
  final int notAssessedCount;
  final int recent14dApproved;
  final int prior14dApproved;
  final int recent8wApproved;
  final int activeWeeksIn8w;
  final List<int> weekly8wApproved;
  final double? avgConfidence;
  final int? forecast30d;
  final int? forecastLower30d;
  final int? forecastUpper30d;
  final String trend; // 'rising', 'declining', 'stable', 'insufficient'
  final List<String> dataQualityNotes;
  final LatLng? centroid;

  const AdminBarangaySummary({
    required this.barangay,
    required this.canonicalKey,
    required this.city,
    required this.province,
    required this.isOfficialSantaMaria,
    required this.coverageState,
    required this.totalActive,
    required this.pendingCount,
    required this.approvedCount,
    required this.rejectedCount,
    required this.highSeverityCount,
    required this.mediumSeverityCount,
    required this.lowSeverityCount,
    required this.notAssessedCount,
    required this.recent14dApproved,
    required this.prior14dApproved,
    required this.recent8wApproved,
    required this.activeWeeksIn8w,
    required this.weekly8wApproved,
    required this.avgConfidence,
    required this.forecast30d,
    required this.forecastLower30d,
    required this.forecastUpper30d,
    required this.trend,
    required this.dataQualityNotes,
    required this.centroid,
  });

  int get periodDelta => recent14dApproved - prior14dApproved;

  String get periodDeltaLabel {
    if (recent14dApproved == 0 && prior14dApproved == 0) {
      return '0 in last 28d';
    }
    if (prior14dApproved == 0) {
      return '+$recent14dApproved vs 0 prior 14d';
    }
    final pct = ((periodDelta / prior14dApproved) * 100).round();
    final sign = periodDelta > 0 ? '+' : '';
    return '$sign$periodDelta ($sign$pct% vs prior 14d)';
  }
}

class AdminBarangayInsightsResult {
  final List<AdminBarangaySummary> santaMariaRows;
  final List<AdminBarangaySummary> otherLguRows;
  final AdminForecastValidation validation;
  final int unassignedCount;
  final int coveredSantaMariaCount;
  final int forecastReadySantaMariaCount;
  final int risingSantaMariaCount;

  const AdminBarangayInsightsResult({
    required this.santaMariaRows,
    required this.otherLguRows,
    required this.validation,
    required this.unassignedCount,
    required this.coveredSantaMariaCount,
    required this.forecastReadySantaMariaCount,
    required this.risingSantaMariaCount,
  });
}

class AdminSpatialHotspot {
  final String id;
  final LatLng center;
  final int totalCount;
  final int approvedCount;
  final int pendingCount;
  final int highSeverityCount;
  final String primaryDefect;
  final String locationLabel;
  final List<AdminReportRow> items;

  const AdminSpatialHotspot({
    required this.id,
    required this.center,
    required this.totalCount,
    required this.approvedCount,
    required this.pendingCount,
    required this.highSeverityCount,
    required this.primaryDefect,
    required this.locationLabel,
    required this.items,
  });
}

/// Computes complete 24-barangay coverage for Santa Maria, Bulacan alongside
/// non-Santa-Maria LGU entries, explicit missing/insufficient-history states,
/// and time-ordered walk-forward forecast evaluation against a naive baseline.
AdminBarangayInsightsResult computeAdminBarangayInsights(
  List<AdminReportRow> activeRows, {
  DateTime? now,
}) {
  final clockNow = now ?? DateTime.now();
  final endOfToday = DateTime(
    clockNow.year,
    clockNow.month,
    clockNow.day,
    23,
    59,
    59,
  );
  final start8w = endOfToday.subtract(const Duration(days: 56));
  final startRecent14d = endOfToday.subtract(const Duration(days: 14));
  final startPrior14d = endOfToday.subtract(const Duration(days: 28));

  final officialByKey = <String, String>{
    for (final name in santaMariaBarangays) barangayKey(name): name,
  };

  final santaMariaBuckets = <String, List<AdminReportRow>>{
    for (final key in officialByKey.keys) key: <AdminReportRow>[],
  };
  final otherBuckets = <String, List<AdminReportRow>>{};
  int unassigned = 0;

  for (final row in activeRows) {
    if (row.status == AdminReportStatus.deleted) continue;
    final rawBrgy = row.barangay.trim();
    final rawCity = row.city.trim();
    if (rawBrgy.isEmpty ||
        rawBrgy == 'Unassigned Barangay' ||
        rawCity.isEmpty ||
        rawCity == 'Unclassified Area') {
      unassigned++;
    }

    final bKey = barangayKey(rawBrgy);
    final isSantaMariaCity =
        rawCity.isEmpty ||
        rawCity.toLowerCase().contains('santa maria') ||
        rawCity.toLowerCase().contains('sta. maria');

    if (bKey.isNotEmpty &&
        officialByKey.containsKey(bKey) &&
        isSantaMariaCity) {
      santaMariaBuckets[bKey]!.add(row);
    } else if (rawBrgy.isNotEmpty && rawBrgy != 'Unassigned Barangay') {
      final compositeKey =
          '${rawCity.isNotEmpty ? rawCity : 'Other Municipality'}::$rawBrgy';
      otherBuckets.putIfAbsent(compositeKey, () => <AdminReportRow>[]).add(row);
    } else if (rawCity.isNotEmpty && rawCity != 'Unclassified Area') {
      final compositeKey = '$rawCity::Unassigned Barangay';
      otherBuckets.putIfAbsent(compositeKey, () => <AdminReportRow>[]).add(row);
    }
  }

  // Run weighted seasonal forecast helper ONLY on approved Santa Maria reports inside 8w window.
  final santaMariaForecastSamples = <ForecastSample>[];
  for (final entry in santaMariaBuckets.entries) {
    final canonicalName = officialByKey[entry.key]!;
    for (final r in entry.value) {
      if (r.status == AdminReportStatus.approved &&
          r.timestamp != null &&
          !r.timestamp!.isBefore(start8w) &&
          !r.timestamp!.isAfter(endOfToday)) {
        santaMariaForecastSamples.add(
          ForecastSample(
            date: r.timestamp!,
            lat: r.location?.latitude ?? 14.8197,
            lng: r.location?.longitude ?? 120.9575,
            severity: r.severity == AdminSeverity.notAssessed
                ? 'medium'
                : r.severity.wireValue,
            city: 'Santa Maria',
            barangay: canonicalName,
          ),
        );
      }
    }
  }

  final forecastByKey = <String, BarangayForecast>{
    for (final f in LguForecast.compute(
      santaMariaForecastSamples,
      now: clockNow,
    ))
      barangayKey(f.barangay): f,
  };

  final santaMariaSummaries = <AdminBarangaySummary>[];
  final backtestErrorsModel = <double>[];
  final backtestErrorsNaive = <double>[];

  for (final entry in officialByKey.entries) {
    final summary = _summarizeBarangayBucket(
      barangayName: entry.value,
      canonicalKey: entry.key,
      city: 'Santa Maria',
      province: 'Bulacan',
      isOfficialSantaMaria: true,
      rows: santaMariaBuckets[entry.key]!,
      forecast: forecastByKey[entry.key],
      endOfToday: endOfToday,
      start8w: start8w,
      startRecent14d: startRecent14d,
      startPrior14d: startPrior14d,
      clockNow: clockNow,
    );
    santaMariaSummaries.add(summary);

    // Time-ordered walk-forward evaluation on weeks [5, 6, 7] using preceding weekly counts.
    if (summary.coverageState == BarangayCoverageState.forecastAvailable) {
      for (var t = 4; t < 8; t++) {
        final history = summary.weekly8wApproved.sublist(0, t);
        final actual = summary.weekly8wApproved[t].toDouble();
        final naivePred = history.last.toDouble();
        final linearPred = _predictNextWeekLinearWeighted(history);
        backtestErrorsModel.add(actual - linearPred);
        backtestErrorsNaive.add(actual - naivePred);
      }
    }
  }

  santaMariaSummaries.sort((a, b) {
    final c = b.approvedCount.compareTo(a.approvedCount);
    if (c != 0) return c;
    final p = b.pendingCount.compareTo(a.pendingCount);
    if (p != 0) return p;
    return a.barangay.compareTo(b.barangay);
  });

  final otherSummaries = <AdminBarangaySummary>[];
  for (final entry in otherBuckets.entries) {
    final parts = entry.key.split('::');
    final city = parts.first;
    final brgy = parts.length > 1 ? parts[1] : 'Unassigned Barangay';
    final province = entry.value
        .firstWhere(
          (r) => r.province.isNotEmpty,
          orElse: () => entry.value.first,
        )
        .province;
    otherSummaries.add(
      _summarizeBarangayBucket(
        barangayName: brgy,
        canonicalKey: barangayKey(brgy),
        city: city,
        province: province.isNotEmpty ? province : 'Not recorded',
        isOfficialSantaMaria: false,
        rows: entry.value,
        forecast: null,
        endOfToday: endOfToday,
        start8w: start8w,
        startRecent14d: startRecent14d,
        startPrior14d: startPrior14d,
        clockNow: clockNow,
      ),
    );
  }
  otherSummaries.sort((a, b) {
    final c = b.totalActive.compareTo(a.totalActive);
    return c != 0 ? c : a.barangay.compareTo(b.barangay);
  });

  final validation = _buildValidationSummary(
    backtestErrorsModel,
    backtestErrorsNaive,
  );

  return AdminBarangayInsightsResult(
    santaMariaRows: santaMariaSummaries,
    otherLguRows: otherSummaries,
    validation: validation,
    unassignedCount: unassigned,
    coveredSantaMariaCount: santaMariaSummaries
        .where((s) => s.totalActive > 0)
        .length,
    forecastReadySantaMariaCount: santaMariaSummaries
        .where(
          (s) => s.coverageState == BarangayCoverageState.forecastAvailable,
        )
        .length,
    risingSantaMariaCount: santaMariaSummaries
        .where(
          (s) =>
              s.coverageState == BarangayCoverageState.forecastAvailable &&
              s.trend == 'rising',
        )
        .length,
  );
}

AdminBarangaySummary _summarizeBarangayBucket({
  required String barangayName,
  required String canonicalKey,
  required String city,
  required String province,
  required bool isOfficialSantaMaria,
  required List<AdminReportRow> rows,
  required BarangayForecast? forecast,
  required DateTime endOfToday,
  required DateTime start8w,
  required DateTime startRecent14d,
  required DateTime startPrior14d,
  required DateTime clockNow,
}) {
  int pending = 0, approved = 0, rejected = 0;
  int high = 0, medium = 0, low = 0, notAssessed = 0;
  int recent14 = 0, prior14 = 0;
  double confSum = 0;
  int confCount = 0;
  double latSum = 0, lngSum = 0;
  int coordCount = 0;
  final weekly = List<int>.filled(8, 0);
  int undatedSkipped = 0;
  final seenDayBucketKeys = <String>{};
  int duplicateSignals = 0;

  for (final r in rows) {
    switch (r.status) {
      case AdminReportStatus.pending:
        pending++;
      case AdminReportStatus.approved:
        approved++;
      case AdminReportStatus.rejected:
        rejected++;
      case AdminReportStatus.deleted:
        continue;
    }

    switch (r.severity) {
      case AdminSeverity.high:
        high++;
      case AdminSeverity.medium:
        medium++;
      case AdminSeverity.low:
        low++;
      case AdminSeverity.notAssessed:
        notAssessed++;
    }

    if (r.maxConfidence != null) {
      confSum += r.maxConfidence!;
      confCount++;
    }

    if (r.hasValidCoordinates) {
      latSum += r.location!.latitude;
      lngSum += r.location!.longitude;
      coordCount++;
    }

    final ts = r.timestamp;
    if (ts == null) {
      undatedSkipped++;
      continue;
    }

    if (r.status == AdminReportStatus.approved) {
      if (!ts.isBefore(startRecent14d) && !ts.isAfter(endOfToday)) {
        recent14++;
      } else if (!ts.isBefore(startPrior14d) && ts.isBefore(startRecent14d)) {
        prior14++;
      }

      if (!ts.isBefore(start8w) && !ts.isAfter(endOfToday)) {
        final daysAgo = endOfToday.difference(ts).inDays;
        final weekIdx = 7 - (daysAgo ~/ 7).clamp(0, 7);
        // Flag potential same-day near-identical coordinate re-submissions.
        if (r.hasValidCoordinates) {
          final dupKey =
              '${ts.year}-${ts.month}-${ts.day}:${r.location!.latitude.toStringAsFixed(4)},${r.location!.longitude.toStringAsFixed(4)}';
          if (!seenDayBucketKeys.add(dupKey)) {
            duplicateSignals++;
          }
        }
        weekly[weekIdx]++;
      }
    }
  }

  final recent8wApproved = weekly.fold<int>(0, (a, b) => a + b);
  final activeWeeks = weekly.where((w) => w > 0).length;
  final hasForecastHistory =
      forecast != null && recent8wApproved >= 8 && activeWeeks >= 4;

  final BarangayCoverageState coverageState;
  if (rows.isEmpty) {
    coverageState = BarangayCoverageState.noReports;
  } else if (recent8wApproved == 0) {
    coverageState = BarangayCoverageState.noRecentReports;
  } else if (!hasForecastHistory) {
    coverageState = BarangayCoverageState.insufficientHistory;
  } else {
    coverageState = BarangayCoverageState.forecastAvailable;
  }

  final qualityNotes = <String>[];
  if (undatedSkipped > 0) {
    qualityNotes.add(
      '$undatedSkipped report(s) missing timestamps excluded from trends',
    );
  }
  if (duplicateSignals > 0) {
    qualityNotes.add(
      '$duplicateSignals possible same-day near-duplicate pin(s)',
    );
  }

  int? predicted30d;
  int? lower30d;
  int? upper30d;
  String trend = 'insufficient';
  if (hasForecastHistory) {
    final pred = forecast.predicted30.round();
    predicted30d = pred;
    // Estimate empirical weekly dispersion from observed 8-week approved series (~80% interval).
    final meanW = recent8wApproved / 8.0;
    var sqSum = 0.0;
    for (final w in weekly) {
      sqSum += (w - meanW) * (w - meanW);
    }
    final stdWeek = math.sqrt(sqSum / 8.0);
    // 30d ~= 4.28 weeks; uncertainty scales with sqrt(horizon).
    final halfBand = math.max(2, (1.28 * stdWeek * math.sqrt(4.28)).round());
    lower30d = math.max(0, pred - halfBand);
    upper30d = pred + halfBand;
    trend = forecast.trend;
  }

  return AdminBarangaySummary(
    barangay: barangayName,
    canonicalKey: canonicalKey,
    city: city,
    province: province,
    isOfficialSantaMaria: isOfficialSantaMaria,
    coverageState: coverageState,
    totalActive: rows.length,
    pendingCount: pending,
    approvedCount: approved,
    rejectedCount: rejected,
    highSeverityCount: high,
    mediumSeverityCount: medium,
    lowSeverityCount: low,
    notAssessedCount: notAssessed,
    recent14dApproved: recent14,
    prior14dApproved: prior14,
    recent8wApproved: recent8wApproved,
    activeWeeksIn8w: activeWeeks,
    weekly8wApproved: weekly,
    avgConfidence: confCount > 0 ? confSum / confCount : null,
    forecast30d: predicted30d,
    forecastLower30d: lower30d,
    forecastUpper30d: upper30d,
    trend: trend,
    dataQualityNotes: qualityNotes,
    centroid: coordCount > 0
        ? LatLng(latSum / coordCount, lngSum / coordCount)
        : null,
  );
}

double _predictNextWeekLinearWeighted(List<int> series) {
  if (series.isEmpty) return 0;
  if (series.length == 1) return series.first.toDouble();
  final k = series.length;
  var sumW = 0.0, sumWt = 0.0, sumWy = 0.0, sumWtt = 0.0, sumWty = 0.0;
  for (var i = 0; i < k; i++) {
    final w = 0.5 + 0.5 * (i / (k - 1));
    final y = series[i].toDouble();
    sumW += w;
    sumWt += w * i;
    sumWy += w * y;
    sumWtt += w * i * i;
    sumWty += w * i * y;
  }
  final denom = sumW * sumWtt - sumWt * sumWt;
  final slope = denom.abs() > 1e-6
      ? (sumW * sumWty - sumWt * sumWy) / denom
      : 0.0;
  final intercept = (sumWy - slope * sumWt) / sumW;
  return math.max(0.0, intercept + slope * k);
}

AdminForecastValidation _buildValidationSummary(
  List<double> modelErrs,
  List<double> naiveErrs,
) {
  if (modelErrs.isEmpty || naiveErrs.isEmpty) {
    return const AdminForecastValidation.unvalidated();
  }
  double absSum(List<double> errs) =>
      errs.fold<double>(0.0, (a, e) => a + e.abs()) / errs.length;
  double rmse(List<double> errs) =>
      math.sqrt(errs.fold<double>(0.0, (a, e) => a + e * e) / errs.length);

  final mMae = absSum(modelErrs);
  final bMae = absSum(naiveErrs);
  final mRmse = rmse(modelErrs);
  final bRmse = rmse(naiveErrs);
  final beats = mMae <= bMae;

  return AdminForecastValidation(
    evaluatedPoints: modelErrs.length,
    modelMae: mMae,
    baselineMae: bMae,
    modelRmse: mRmse,
    baselineRmse: bRmse,
    beatsBaseline: beats,
    summaryLabel: beats
        ? 'Validated (${modelErrs.length} weekly holdouts): MAE ${mMae.toStringAsFixed(2)} vs Naive ${bMae.toStringAsFixed(2)}'
        : 'Caution (${modelErrs.length} weekly holdouts): MAE ${mMae.toStringAsFixed(2)} worse than Naive ${bMae.toStringAsFixed(2)}',
  );
}

/// Groups active reports into honest spatial hotspot clusters within [radiusMeters]
/// (replacing misleading "weather storm" metaphors).
List<AdminSpatialHotspot> computeAdminHotspots(
  List<AdminReportRow> rows, {
  double radiusMeters = 300.0,
}) {
  final valid = rows
      .where(
        (r) => r.status != AdminReportStatus.deleted && r.hasValidCoordinates,
      )
      .toList();
  if (valid.isEmpty) return const [];

  final visited = <String>{};
  final clusters = <AdminSpatialHotspot>[];

  for (var i = 0; i < valid.length; i++) {
    final seed = valid[i];
    if (visited.contains(seed.id)) continue;

    final group = <AdminReportRow>[seed];
    visited.add(seed.id);

    for (var j = i + 1; j < valid.length; j++) {
      final candidate = valid[j];
      if (visited.contains(candidate.id)) continue;
      final dist = _metersBetween(seed.location!, candidate.location!);
      if (dist <= radiusMeters) {
        group.add(candidate);
        visited.add(candidate.id);
      }
    }

    var latSum = 0.0, lngSum = 0.0;
    var approved = 0, pending = 0, high = 0;
    final defectFreq = <String, int>{};

    for (final item in group) {
      latSum += item.location!.latitude;
      lngSum += item.location!.longitude;
      if (item.status == AdminReportStatus.approved) approved++;
      if (item.status == AdminReportStatus.pending) pending++;
      if (item.severity == AdminSeverity.high) high++;
      defectFreq[item.defectLabel] = (defectFreq[item.defectLabel] ?? 0) + 1;
    }

    final topDefect =
        (defectFreq.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .first
            .key;

    clusters.add(
      AdminSpatialHotspot(
        id: 'hotspot_${group.first.id}',
        center: LatLng(latSum / group.length, lngSum / group.length),
        totalCount: group.length,
        approvedCount: approved,
        pendingCount: pending,
        highSeverityCount: high,
        primaryDefect: topDefect,
        locationLabel: group.first.displayLocation,
        items: group,
      ),
    );
  }

  clusters.sort((a, b) {
    final countCmp = b.totalCount.compareTo(a.totalCount);
    if (countCmp != 0) return countCmp;
    return b.highSeverityCount.compareTo(a.highSeverityCount);
  });

  return clusters;
}

/// Builds a formula-injection-safe CSV summary across Barangays / LGUs.
String buildAdminBarangayCsv(List<AdminBarangaySummary> rows) {
  final data = <List<Object?>>[
    [
      'Province',
      'City / Municipality',
      'Barangay',
      'Coverage State',
      'Total Active Reports',
      'Pending Review',
      'Approved Live',
      'Rejected',
      'Verified Last 14d',
      'Verified Prior 14d',
      '14d Period Delta',
      '8-Week Approved Total',
      'Active Weeks in 8w',
      '30-Day Forecast (30d)',
      'Forecast Interval Low',
      'Forecast Interval High',
      'Trend Status',
    ],
  ];

  for (final row in rows) {
    final hasForecast =
        row.coverageState == BarangayCoverageState.forecastAvailable &&
        row.forecast30d != null;
    data.add([
      row.province,
      row.city,
      row.barangay,
      row.coverageState.label,
      row.totalActive,
      row.pendingCount,
      row.approvedCount,
      row.rejectedCount,
      row.recent14dApproved,
      row.prior14dApproved,
      row.periodDelta,
      row.recent8wApproved,
      row.activeWeeksIn8w,
      hasForecast ? row.forecast30d : 'Insufficient history',
      hasForecast ? (row.forecastLower30d ?? '') : '',
      hasForecast ? (row.forecastUpper30d ?? '') : '',
      row.trend,
    ]);
  }

  return AdminCsvExporter.encodeRows(data);
}

double _metersBetween(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = (b.latitude - a.latitude) * math.pi / 180.0;
  final dLng = (b.longitude - a.longitude) * math.pi / 180.0;
  final la1 = a.latitude * math.pi / 180.0;
  final la2 = b.latitude * math.pi / 180.0;
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(h), math.sqrt(math.max(0.0, 1.0 - h)));
}
