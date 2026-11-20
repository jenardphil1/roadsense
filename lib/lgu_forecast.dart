import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Deterministic 30-day pothole forecast for LGU analytics.
///
/// Method: weighted least-squares linear trend over 8 weekly report buckets
/// (recency-weighted), adjusted by a Philippine wet-season multiplier
/// (PAGASA wet season Jun–Nov, when potholes form/worsen fastest). A ~332 m
/// spatial grid surfaces the streets/areas where recent reports concentrate.
class ForecastSample {
  final DateTime date;
  final double lat;
  final double lng;
  final String severity;
  final String city;
  final String barangay;

  const ForecastSample({
    required this.date,
    required this.lat,
    required this.lng,
    required this.severity,
    required this.city,
    required this.barangay,
  });
}

class BarangayForecast {
  final String city;
  final String barangay;

  /// Weekly counts, oldest → newest (current week last).
  final List<int> weeklyHistory;

  /// Projected counts for the next 4 weeks (season-adjusted), oldest first.
  final List<double> forecastWeeks;
  final double predicted30;
  final double slopePerWeek;
  final String trend; // 'rising' | 'stable' | 'declining'
  final double trendPct;
  final String risk; // 'high' | 'medium' | 'low'
  final double confidence;
  final int total;
  final int highCount;

  const BarangayForecast({
    required this.city,
    required this.barangay,
    required this.weeklyHistory,
    required this.forecastWeeks,
    required this.predicted30,
    required this.slopePerWeek,
    required this.trend,
    required this.trendPct,
    required this.risk,
    required this.confidence,
    required this.total,
    required this.highCount,
  });
}

class HotspotZone {
  final String city;
  final String barangay;
  final double lat;
  final double lng;
  final int count;
  final int highCount;
  final DateTime lastSeen;

  const HotspotZone({
    required this.city,
    required this.barangay,
    required this.lat,
    required this.lng,
    required this.count,
    required this.highCount,
    required this.lastSeen,
  });
}

class LguForecast {
  static const int historyWeeks = 8;
  static const int forecastWeeks = 4;
  static const int _weekDays = 7;

  /// Grid cell in degrees latitude (~332 m), matching ApprovalPriority.
  static const double cellLat = 0.003;

  /// Wet-season multiplier keyed by calendar month (PH wet season Jun–Nov).
  static double seasonMultiplier(int month) => month >= 6 && month <= 10
      ? 1.20
      : month == 11
      ? 1.10
      : 1.0;

  /// Loose name matching for Firestore LGU strings ("Brgy. Sta. Clara",
  /// "Santa Maria, Bulacan", stray punctuation). Lowercases, strips titles
  /// and punctuation, and expands Sta./Sto. abbreviations.
  static String normalizeName(String name) {
    var s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    s = s.replaceAll(
      RegExp(r'\b(bgy|brgy|barangay|municipality of|city of)\b'),
      ' ',
    );
    s = s.replaceAll(RegExp(r'\bsta\b'), 'santa');
    s = s.replaceAll(RegExp(r'\bsto\b'), 'santo');
    return s.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static int _latIdx(double lat) => (lat / cellLat).floor();

  static double _lonCellFor(int latIdx) {
    final c = math.cos(latIdx * cellLat * math.pi / 180).abs();
    return cellLat / math.max(c, 0.15);
  }

  static int _lonIdx(double lon, int latIdx) =>
      (lon / _lonCellFor(latIdx)).floor();

  /// Per-barangay forecasts sorted by predicted 30-day count (desc).
  static List<BarangayForecast> compute(
    List<ForecastSample> samples, {
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final groups = <String, List<ForecastSample>>{};
    for (final s in samples) {
      if (!s.lat.isFinite || !s.lng.isFinite) continue;
      groups.putIfAbsent('${s.city}‖${s.barangay}', () => []).add(s);
    }

    final out = <BarangayForecast>[];
    for (final entry in groups.entries) {
      final f = _forecastGroup(entry.key.split('‖'), entry.value, clock);
      if (f != null) out.add(f);
    }
    out.sort((a, b) => b.predicted30.compareTo(a.predicted30));

    // Relative risk tiers against the strongest barangay, bumped by the
    // high-severity share — "how urgent is this barangay vs the worst one".
    final scores = out
        .map(
          (f) =>
              f.predicted30 *
              (1 + 0.4 * (f.total == 0 ? 0 : f.highCount / f.total)),
        )
        .toList();
    final maxScore = scores.fold(0.0, math.max);
    final ranked = <BarangayForecast>[];
    for (var i = 0; i < out.length; i++) {
      final score = scores[i];
      final risk = maxScore <= 0
          ? 'low'
          : score >= maxScore * 0.55
          ? 'high'
          : score >= maxScore * 0.22
          ? 'medium'
          : 'low';
      ranked.add(
        BarangayForecast(
          city: out[i].city,
          barangay: out[i].barangay,
          weeklyHistory: out[i].weeklyHistory,
          forecastWeeks: out[i].forecastWeeks,
          predicted30: out[i].predicted30,
          slopePerWeek: out[i].slopePerWeek,
          trend: out[i].trend,
          trendPct: out[i].trendPct,
          risk: risk,
          confidence: out[i].confidence,
          total: out[i].total,
          highCount: out[i].highCount,
        ),
      );
    }
    return ranked;
  }

  static BarangayForecast? _forecastGroup(
    List<String> key,
    List<ForecastSample> items,
    DateTime clock,
  ) {
    final buckets = List<int>.filled(historyWeeks, 0);
    final highBuckets = List<int>.filled(historyWeeks, 0);
    for (final s in items) {
      final daysAgo = clock.difference(s.date).inDays;
      if (daysAgo < 0) continue; // future-dated report — ignore
      final w = daysAgo ~/ _weekDays;
      if (w >= historyWeeks) continue; // older than the observation window
      final idx = historyWeeks - 1 - w;
      buckets[idx]++;
      if (s.severity == 'high') highBuckets[idx]++;
    }

    final total = buckets.fold(0, (a, b) => a + b);
    if (total == 0) return null;
    final highCount = highBuckets.fold(0, (a, b) => a + b);
    final weeksWithData = buckets.where((c) => c > 0).length;

    List<double> forecast;
    double slope;
    double confidence;
    if (weeksWithData < 3) {
      // honey: too sparse for a slope — naive 14-day→30-day extrapolation;
      // confidence drops and the row is flagged in the UI.
      final recent14 = buckets[historyWeeks - 2] + buckets[historyWeeks - 1];
      slope = 0;
      confidence = 0.25;
      forecast = List.generate(forecastWeeks, (i) {
        final day = clock.add(Duration(days: (i + 1) * _weekDays));
        return recent14 *
            forecastWeeks /
            (2.0 * historyWeeks) *
            seasonMultiplier(day.month);
      });
    } else {
      final fit = _weightedLinearFit(buckets);
      slope = fit.$1;
      confidence = math.min(1.0, weeksWithData / 6);
      forecast = List.generate(forecastWeeks, (i) {
        final t = historyWeeks + i;
        final day = clock.add(Duration(days: (i + 1) * _weekDays));
        return math.max(0, fit.$2 + fit.$1 * t) * seasonMultiplier(day.month);
      });
    }

    final predicted30 = forecast.fold(0.0, (a, b) => a + b);
    final earlyAvg = (buckets[0] + buckets[1] + buckets[2]) / 3.0;
    final lateAvg = (buckets[5] + buckets[6] + buckets[7]) / 3.0;
    final trendPct = (lateAvg - earlyAvg) / math.max(earlyAvg, 0.34) * 100;
    final trend = trendPct >= 15
        ? 'rising'
        : trendPct <= -15
        ? 'declining'
        : 'stable';

    return BarangayForecast(
      city: key[0],
      barangay: key[1],
      weeklyHistory: buckets,
      forecastWeeks: forecast,
      predicted30: predicted30,
      slopePerWeek: slope,
      trend: trend,
      trendPct: trendPct,
      risk: 'low',
      confidence: confidence,
      total: total,
      highCount: highCount,
    );
  }

  /// Recency-weighted least squares: y = a + b·t, weights 1..8 (newest = 8).
  static (double, double) _weightedLinearFit(List<int> y) {
    var sw = 0.0, swt = 0.0, swy = 0.0, swty = 0.0, swtt = 0.0;
    for (var t = 0; t < y.length; t++) {
      final w = (t + 1).toDouble();
      sw += w;
      swt += w * t;
      swy += w * y[t];
      swty += w * t * y[t];
      swtt += w * t * t;
    }
    final denom = sw * swtt - swt * swt;
    if (denom.abs() < 1e-9) return (0, swy / sw); // single week of data
    final slope = (sw * swty - swt * swy) / denom;
    final intercept = (swy - slope * swt) / sw;
    return (slope, intercept);
  }

  /// Highest-concentration areas over [withinDays], ranked by report count.
  /// ~332 m grid cells — "where in the barangay" the potholes cluster.
  static List<HotspotZone> hotspots(
    List<ForecastSample> samples, {
    DateTime? now,
    int withinDays = 60,
    int limit = 6,
  }) {
    final clock = now ?? DateTime.now();
    final cells = <String, List<ForecastSample>>{};
    for (final s in samples) {
      if (!s.lat.isFinite || !s.lng.isFinite) continue;
      if (clock.difference(s.date).inDays > withinDays) continue;
      final li = _latIdx(s.lat);
      cells.putIfAbsent('$li:${_lonIdx(s.lng, li)}', () => []).add(s);
    }

    final zones =
        cells.entries.map((e) {
          final li = int.parse(e.key.split(':')[0]);
          final items = e.value..sort((a, b) => b.date.compareTo(a.date));
          return HotspotZone(
            city: items.first.city,
            barangay: items.first.barangay,
            lat: (li + 0.5) * cellLat,
            lng: (int.parse(e.key.split(':')[1]) + 0.5) * _lonCellFor(li),
            count: items.length,
            highCount: items.where((s) => s.severity == 'high').length,
            lastSeen: items.first.date,
          );
        }).toList()..sort(
          (a, b) => b.count.compareTo(a.count) != 0
              ? b.count.compareTo(a.count)
              : b.lastSeen.compareTo(a.lastSeen),
        );
    return zones.take(limit).toList();
  }
}

/// Mini trend chart: 8 solid history bars + 4 translucent forecast bars.
class ForecastTrendChart extends StatelessWidget {
  final List<int> history;
  final List<double> forecast;
  final bool isDark;
  final double width;
  final double height;

  const ForecastTrendChart({
    super.key,
    required this.history,
    required this.forecast,
    required this.isDark,
    this.width = 132,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _ForecastTrendPainter(history, forecast, isDark),
    );
  }
}

class _ForecastTrendPainter extends CustomPainter {
  final List<int> history;
  final List<double> forecast;
  final bool isDark;

  _ForecastTrendPainter(this.history, this.forecast, this.isDark);

  @override
  void paint(Canvas canvas, Size size) {
    final maxV = [
      ...history.map((v) => v.toDouble()),
      ...forecast,
      1.0,
    ].fold(0.0, math.max);
    final n = history.length + forecast.length;
    final gap = 2.0;
    final barW = (size.width - gap * (n - 1)) / n;
    final baseY = size.height - 1;

    final histPaint = Paint()
      ..color = const Color(0xFF0284C7)
      ..style = PaintingStyle.fill;
    final fcPaint = Paint()
      ..color = const Color(0xFF0284C7).withValues(alpha: 0.4)
      ..style = PaintingStyle.fill;
    final axisPaint = Paint()
      ..color = isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)
      ..strokeWidth = 1;

    canvas.drawLine(Offset(0, baseY), Offset(size.width, baseY), axisPaint);
    final r = Radius.circular(2);
    for (var i = 0; i < n; i++) {
      final v = i < history.length
          ? history[i].toDouble()
          : forecast[i - history.length];
      final h = (v / maxV) * (size.height - 4);
      final left = i * (barW + gap);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(left, baseY - h, barW, math.max(h, 1.5)),
          topLeft: r,
          topRight: r,
        ),
        i < history.length ? histPaint : fcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_ForecastTrendPainter old) =>
      old.history != history ||
      old.forecast != forecast ||
      old.isDark != isDark;
}
