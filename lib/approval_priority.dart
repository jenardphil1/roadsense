import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';

/// Triage band for one pending report, most to least urgent.
enum PriorityBand { critical, high, normal, low }

/// The individual normalised factors behind one priority score, kept so the
/// dashboard can explain *why* a report ranked where it did.
class PriorityFactors {
  final double harm; // 0.21 .. 1.00
  final double credibility; // 0.15 .. 1.00
  final double exposure; // 0.40 .. 1.00
  final double aging; // 0 .. unbounded
  final double urgency; // harm * credibility * exposure

  final double modelConfidence;
  final double reporterTrust;
  final double corroboration;

  final String severity;
  final int potholeCount;
  final int witnesses; // distinct OTHER reporters within dupRadiusM
  final int nearbyReporters; // distinct reporters within exposureRadiusM
  final bool hasPhoto;
  final Duration waiting;

  const PriorityFactors({
    required this.harm,
    required this.credibility,
    required this.exposure,
    required this.aging,
    required this.urgency,
    required this.modelConfidence,
    required this.reporterTrust,
    required this.corroboration,
    required this.severity,
    required this.potholeCount,
    required this.witnesses,
    required this.nearbyReporters,
    required this.hasPhoto,
    required this.waiting,
  });
}

/// One scored report, ready to sort and render.
class ReportPriority {
  final String id;
  final double score;
  final PriorityBand band;
  final PriorityFactors factors;

  /// Short human-readable chips explaining the ranking.
  final List<String> reasons;

  /// Ids of other PENDING reports within [ApprovalPriority.dupRadiusM] — very
  /// likely the same physical pothole, so one decision should cover them all.
  final List<String> duplicateIds;

  const ReportPriority({
    required this.id,
    required this.score,
    required this.band,
    required this.factors,
    required this.reasons,
    required this.duplicateIds,
  });

  String get bandLabel => switch (band) {
        PriorityBand.critical => 'Critical',
        PriorityBand.high => 'High',
        PriorityBand.normal => 'Normal',
        PriorityBand.low => 'Low',
      };
}

/// Internal flyweight so the neighbour scan never re-casts Firestore maps.
class _Rec {
  final String id;
  final double lat;
  final double lon;
  final String uid;
  final String status;
  const _Rec(this.id, this.lat, this.lon, this.uid, this.status);
}

/// Ranks pending pothole reports by the expected cost of leaving them pending.
///
///   urgency = harm x credibility x exposure
///   score   = 100 * (0.75 * urgency + 0.25 * aging)
///
/// Multiplicative urgency because the three factors gate each other: a report
/// nobody can verify costs little to delay however severe the claim. Aging is
/// additive and uncapped so nothing can starve at the bottom of the queue.
///
/// See CALCULATION_DOCUMENTATION.md section 7 for the full derivation.
class ApprovalPriority {
  ApprovalPriority._();

  // ---- Tunables -----------------------------------------------------------
  /// Two reports this close are treated as the same physical pothole.
  static const double dupRadiusM = 25.0;

  /// Neighbourhood used as a traffic-exposure proxy.
  static const double exposureRadiusM = 300.0;

  /// Target turnaround. Aging reaches 1.0 here.
  static const double slaHours = 48.0;

  static const double agingExponent = 1.5;
  static const double urgencyWeight = 0.75;
  static const double agingWeight = 0.25;
  static const double credibilityFloor = 0.15;

  /// Band thresholds. Recalibrate once a week of real scores has been observed.
  static const double criticalAt = 45.0;
  static const double highAt = 28.0;
  static const double normalAt = 12.0;

  /// Grid cell in degrees latitude (~332 m). Must be >= [exposureRadiusM] so a
  /// 3x3 cell scan is guaranteed exhaustive.
  static const double _cellLat = 0.003;

  // ---- Geometry -----------------------------------------------------------
  /// Local-plane metres, consistent with CALCULATION_DOCUMENTATION.md 2.3.
  static double metresBetween(
    double aLat,
    double aLon,
    double bLat,
    double bLon,
  ) {
    final midLat = ((aLat + bLat) / 2) * math.pi / 180;
    final dy = (aLat - bLat) * 110540.0;
    final dx = (aLon - bLon) * 111320.0 * math.cos(midLat);
    return math.sqrt(dx * dx + dy * dy);
  }

  static int _latIdx(double lat) => (lat / _cellLat).floor();

  /// Longitude cell width for a latitude band, widened near the poles so a
  /// cell always spans at least [exposureRadiusM].
  static double _lonCellFor(int latIdx) {
    final bandLat = latIdx * _cellLat;
    final c = math.cos(bandLat * math.pi / 180).abs();
    return _cellLat / math.max(c, 0.15);
  }

  static int _lonIdx(double lon, int latIdx) =>
      (lon / _lonCellFor(latIdx)).floor();

  // ---- Public API ---------------------------------------------------------
  /// Scores every pending report in [allDocs], keyed by document id.
  /// Pass the FULL collection: approved and rejected docs are the evidence
  /// base for reporter trust, corroboration and exposure.
  static Map<String, ReportPriority> rankAll(
    List<QueryDocumentSnapshot> allDocs, {
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();

    // Pass 1: flatten, tally reporter history, bucket into the spatial grid.
    final approved = <String, int>{};
    final rejected = <String, int>{};
    final grid = <String, List<_Rec>>{};
    final pending = <QueryDocumentSnapshot>[];

    for (final doc in allDocs) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) continue;

      final status = (data['status'] as String? ?? 'pending').toLowerCase();
      final uid = data['reporterUid'] as String? ?? '';

      if (status == 'approved') {
        approved[uid] = (approved[uid] ?? 0) + 1;
      } else if (status == 'rejected') {
        rejected[uid] = (rejected[uid] ?? 0) + 1;
      }

      final lat = (data['latitude'] as num?)?.toDouble();
      final lon = (data['longitude'] as num?)?.toDouble();
      if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) continue;

      if (status == 'pending') pending.add(doc);

      // Rejected and soft-deleted reports are not evidence of anything.
      if (status == 'rejected' || status == 'deleted') continue;

      final li = _latIdx(lat);
      final key = '$li:${_lonIdx(lon, li)}';
      (grid[key] ??= <_Rec>[]).add(_Rec(doc.id, lat, lon, uid, status));
    }

    // Pass 2: score each pending report.
    final out = <String, ReportPriority>{};
    for (final doc in pending) {
      final data = doc.data() as Map<String, dynamic>;
      final lat = (data['latitude'] as num).toDouble();
      final lon = (data['longitude'] as num).toDouble();
      final uid = data['reporterUid'] as String? ?? '';

      // --- Harm: how bad if the report is real.
      final severity =
          (data['overallSeverity'] as String? ?? 'medium').toLowerCase();
      final sevW = switch (severity) {
        'high' => 1.0,
        'low' => 0.3,
        _ => 0.6,
      };
      final count =
          ((data['potholeCount'] as num?)?.toInt() ?? 1).clamp(1, 100);
      final scale = count <= 1
          ? 0.0
          : (math.log(count) / math.log(6)).clamp(0.0, 1.0);
      final harm = 0.70 * sevW + 0.30 * scale;

      // --- Credibility: will this survive review?
      final confs = <double>[];
      final dets = data['detections'];
      if (dets is List) {
        for (final d in dets) {
          if (d is Map) {
            final c = (d['confidence'] as num?)?.toDouble();
            if (c != null && c > 0) confs.add(c);
          }
        }
      }
      final modelConf = confs.isEmpty
          ? 0.5 // legacy docs carry no detections
          : 0.5 * confs.reduce(math.max) +
              0.5 * (confs.reduce((a, b) => a + b) / confs.length);

      final a = approved[uid] ?? 0;
      final r = rejected[uid] ?? 0;
      final trust = (a + 2) / (a + r + 3); // Beta(2,1) prior: new user = 0.667

      // Neighbour scan over the 3x3 cell block around this report.
      final witnesses = <String>{};
      final nearbyUids = <String>{};
      final duplicateIds = <String>[];
      final li = _latIdx(lat);
      for (var dLat = -1; dLat <= 1; dLat++) {
        final bandIdx = li + dLat;
        final lonI = _lonIdx(lon, bandIdx);
        for (var dLon = -1; dLon <= 1; dLon++) {
          final cell = grid['$bandIdx:${lonI + dLon}'];
          if (cell == null) continue;
          for (final rec in cell) {
            if (rec.id == doc.id) continue;
            final dist = metresBetween(lat, lon, rec.lat, rec.lon);
            if (dist > exposureRadiusM) continue;
            nearbyUids.add(rec.uid);
            if (dist <= dupRadiusM) {
              // Distinct UIDs only, so one user cannot self-corroborate.
              if (rec.uid != uid) witnesses.add(rec.uid);
              if (rec.status == 'pending') duplicateIds.add(rec.id);
            }
          }
        }
      }
      final corro = 1 - math.pow(0.55, witnesses.length).toDouble();

      final hasPhoto = (data['imageUrl'] as String? ?? '').trim().isNotEmpty;
      final credibility =
          ((0.42 * modelConf + 0.33 * trust + 0.25 * corro) *
                  (hasPhoto ? 1.0 : 0.5))
              .clamp(credibilityFloor, 1.0);

      // --- Exposure: how many drivers are affected (reporter density proxy).
      final exposure = 0.40 + 0.60 * math.min(1.0, nearbyUids.length / 5);

      // --- Aging: uncapped, so nothing rots at the bottom forever.
      final ts = data['timestamp'];
      DateTime? created;
      if (ts is Timestamp) {
        created = ts.toDate();
      } else if (ts is String) {
        created = DateTime.tryParse(ts);
      }
      final waiting =
          created == null ? Duration.zero : clock.difference(created);
      final waitH = math.max(0.0, waiting.inMinutes / 60.0);
      final aging = math.pow(waitH / slaHours, agingExponent).toDouble();

      final urgency = harm * credibility * exposure;
      final score = 100 * (urgencyWeight * urgency + agingWeight * aging);

      // Hard override: a corroborated high-severity hazard must never be
      // blurred into the middle of the queue by a weighted average.
      final forcedCritical = severity == 'high' && witnesses.length >= 2;
      final band = (forcedCritical || score >= criticalAt)
          ? PriorityBand.critical
          : score >= highAt
              ? PriorityBand.high
              : score >= normalAt
                  ? PriorityBand.normal
                  : PriorityBand.low;

      out[doc.id] = ReportPriority(
        id: doc.id,
        score: score,
        band: band,
        reasons: _reasons(
          severity: severity,
          count: count,
          witnesses: witnesses.length,
          trust: trust,
          modelConf: modelConf,
          hasPhoto: hasPhoto,
          nearby: nearbyUids.length,
          waitH: waitH,
        ),
        duplicateIds: duplicateIds,
        factors: PriorityFactors(
          harm: harm,
          credibility: credibility,
          exposure: exposure,
          aging: aging,
          urgency: urgency,
          modelConfidence: modelConf,
          reporterTrust: trust,
          corroboration: corro,
          severity: severity,
          potholeCount: count,
          witnesses: witnesses.length,
          nearbyReporters: nearbyUids.length,
          hasPhoto: hasPhoto,
          waiting: waiting,
        ),
      );
    }

    return out;
  }

  /// Pending reports ordered most urgent first. Ties break toward the older
  /// report so the ordering is stable across rebuilds.
  static List<ReportPriority> rankPending(
    List<QueryDocumentSnapshot> allDocs, {
    DateTime? now,
  }) {
    final ranked = rankAll(allDocs, now: now).values.toList();
    ranked.sort((x, y) {
      final c = y.score.compareTo(x.score);
      if (c != 0) return c;
      return y.factors.waiting.compareTo(x.factors.waiting);
    });
    return ranked;
  }

  static List<String> _reasons({
    required String severity,
    required int count,
    required int witnesses,
    required double trust,
    required double modelConf,
    required bool hasPhoto,
    required int nearby,
    required double waitH,
  }) {
    final out = <String>[];
    if (severity == 'high') out.add('High severity');
    if (count >= 3) out.add('$count potholes in frame');
    if (witnesses >= 1) {
      out.add('$witnesses independent report${witnesses == 1 ? '' : 's'}');
    }
    if (!hasPhoto) out.add('No photo evidence');
    if (trust >= 0.80) {
      out.add('Trusted reporter');
    } else if (trust <= 0.40) {
      out.add('Low reporter trust');
    }
    if (modelConf < 0.40) out.add('Weak detection');
    if (nearby >= 4) out.add('Busy area');
    if (waitH > 72) out.add('Waiting ${(waitH / 24).floor()} days');
    return out;
  }
}
