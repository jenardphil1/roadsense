import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dpwh_standards.dart';

/// Triage band for one pending report, most to least urgent.
enum PriorityBand { critical, high, normal, low }

/// The individual normalised factors behind one priority score according to DPWH protocol.
class PriorityFactors {
  final double harm; // 0.20 .. 1.00
  final double credibility; // 0.15 .. 1.00
  final double exposure; // 0.40 .. 1.00
  final double aging; // 0 .. unbounded
  final double urgency; // harm * credibility * exposure

  final double modelConfidence;
  final double reporterTrust;
  final double corroboration;

  final String severity;
  final String dpwhCode;
  final String responseTime;
  final double dpwhSlaHours;
  final bool isSlaBreached;
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
    required this.dpwhCode,
    required this.responseTime,
    required this.dpwhSlaHours,
    required this.isSlaBreached,
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

  /// Short human-readable chips explaining the ranking according to DPWH protocol.
  final List<String> reasons;

  /// Ids of other PENDING reports within [ApprovalPriority.dupRadiusM] - very
  /// likely the same physical pothole, so one decision covers them all.
  final List<String> duplicateIds;

  /// Whether the report has exceeded its official DPWH Response Time SLA.
  final bool isSlaBreached;

  const ReportPriority({
    required this.id,
    required this.score,
    required this.band,
    required this.factors,
    required this.reasons,
    required this.duplicateIds,
    this.isSlaBreached = false,
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

/// Ranks pending road distress reports according to official DPWH Protocol:
///
///   DPWH Urgency = Harm(DPWH Defect Class, Severity, Scale)
///                x Credibility(YOLOv8s, Reporter Bayesian Trust, Corroboration, Photo)
///                x Exposure(Traffic Density Proxy)
///
///   Score = 100 * (0.70 * DPWH Urgency + 0.30 * DPWH SLA Aging)
///
/// DPWH Statutory Response Time Standards (Department Order / Highway Maintenance Manual):
/// - CODE 01: Pothole -> 3 Days (72 Hours) max response time (Emergency safety hazard).
/// - CODE 02: Alligator Crack -> 3 Days (72 Hours) max response time (Structural base failure).
/// - CODE 05: Depression -> 30 Days (720 Hours) response time (Pavement re-blocking).
/// - CODE 12: Longitudinal / Transverse Crack -> 60 Days (1440 Hours) routine maintenance sealant.
///
/// When a report exceeds its DPWH SLA, non-compliance escalation accelerates superlinearly.
class ApprovalPriority {
  ApprovalPriority._();

  // ---- DPWH Statutory SLA Tunables (Hours) --------------------------------
  /// DPWH Code 01: Pothole - 3 days (72h) emergency repair standard.
  static const double slaCode01PotholeHours = 72.0;

  /// DPWH Code 02: Alligator Cracking - 3 days (72h) structural base repair standard.
  static const double slaCode02AlligatorHours = 72.0;

  /// DPWH Code 05: Depression - 30 days (720h) pavement re-blocking standard.
  static const double slaCode05DepressionHours = 720.0;

  /// DPWH Code 12: Longitudinal / Transverse Crack - 60 days (1440h) routine maintenance standard.
  static const double slaCode12CrackHours = 1440.0;

  /// Default baseline turnaround when defect code is unspecified.
  static const double defaultSlaHours = 72.0;

  // ---- Spatial & Weighting Constants --------------------------------------
  /// Two reports this close (25m) are treated as the same physical pothole.
  static const double dupRadiusM = 25.0;

  /// Neighbourhood used as a traffic-exposure proxy (300m).
  static const double exposureRadiusM = 300.0;

  static const double agingExponent = 1.5;
  static const double urgencyWeight = 0.70;
  static const double agingWeight = 0.30;
  static const double credibilityFloor = 0.15;

  /// Band thresholds for triage.
  static const double criticalAt = 45.0;
  static const double highAt = 28.0;
  static const double normalAt = 12.0;

  /// Grid cell in degrees latitude (~332 m) for O(N) spatial hashing.
  static const double _cellLat = 0.003;

  // ---- Geometry -----------------------------------------------------------
  /// Local-plane metres approximation.
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

  static double _lonCellFor(int latIdx) {
    final bandLat = latIdx * _cellLat;
    final c = math.cos(bandLat * math.pi / 180).abs();
    return _cellLat / math.max(c, 0.15);
  }

  static int _lonIdx(double lon, int latIdx) =>
      (lon / _lonCellFor(latIdx)).floor();

  // ---- Public API ---------------------------------------------------------
  /// Scores and ranks every pending report in [allDocs] according to DPWH Protocol.
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

    // Pass 2: score each pending report based on DPWH Protocol.
    final out = <String, ReportPriority>{};
    for (final doc in pending) {
      final data = doc.data() as Map<String, dynamic>;
      final lat = (data['latitude'] as num).toDouble();
      final lon = (data['longitude'] as num).toDouble();
      final uid = data['reporterUid'] as String? ?? '';

      // --- 1. DPWH Defect Classification & Harm Assessment ---
      final rawDpwh = (data['primaryDpwhCode'] as String? ?? '').toUpperCase().trim();
      final rawLabel = (data['primaryDefect'] as String? ?? '');
      final defectClass = rawDpwh.isNotEmpty
          ? DpwhStandards.classifyByCode(rawDpwh)
          : DpwhStandards.classify(rawLabel.isNotEmpty ? rawLabel : data['overallSeverity'] as String?);

      final String dpwhCode = defectClass.code;
      final String responseTime = data['responseTime'] as String? ?? defectClass.responseTime;
      final severity =
          (data['overallSeverity'] as String? ?? defectClass.severity).toLowerCase();

      // DPWH Statutory SLA Hours:
      final double dpwhSlaHours = switch (dpwhCode) {
        'CODE 01' => slaCode01PotholeHours,
        'CODE 02' => slaCode02AlligatorHours,
        'CODE 05' => slaCode05DepressionHours,
        'CODE 12' => slaCode12CrackHours,
        _ => defaultSlaHours,
      };

      // DPWH Defect Statutory Weight:
      // Code 01 (Pothole): 1.00 (High-impact road crash risk)
      // Code 02 (Alligator Crack): 0.90 (Base failure, rapidly collapses to potholes)
      // Code 05 (Depression): 0.55 (Ponding/hydroplaning hazard)
      // Code 12 (Joint/Crack): 0.35 (Preventative moisture ingress)
      final double dpwhWeight = switch (dpwhCode) {
        'CODE 01' => 1.00,
        'CODE 02' => 0.90,
        'CODE 05' => 0.55,
        'CODE 12' => 0.35,
        _ => 0.60,
      };

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

      // DPWH Harm: 50% statutory defect hazard + 30% reported severity + 20% count scale
      final harm = (0.50 * dpwhWeight + 0.30 * sevW + 0.20 * scale).clamp(0.20, 1.0);

      // --- 2. Credibility & Evidence Verification ---
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

      // --- 3. Traffic Exposure Proxy ---
      final exposure = 0.40 + 0.60 * math.min(1.0, nearbyUids.length / 5);

      // --- 4. DPWH SLA Aging & Statutory Escalation ---
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

      final bool isSlaBreached = waitH > dpwhSlaHours;
      final double slaRatio = waitH / dpwhSlaHours;

      // When within statutory SLA, aging curves at power 1.5.
      // Once SLA is breached, DPWH non-compliance escalation accelerates superlinearly.
      final double aging = isSlaBreached
          ? (1.0 + 2.0 * math.pow(slaRatio - 1.0, 1.25)).toDouble()
          : math.pow(slaRatio, agingExponent).toDouble();

      final urgency = harm * credibility * exposure;
      final score = 100 * (urgencyWeight * urgency + agingWeight * aging);

      // --- 5. DPWH Hard Overrides ---
      // Rule A: High severity Code 01/02 with >= 2 independent witnesses is an immediate hazard.
      final isCorroboratedHazard =
          (severity == 'high' || dpwhCode == 'CODE 01') && witnesses.length >= 2;

      // Rule B: Any Code 01 (Pothole) that has breached its 72h SLA with photo proof.
      final isOverdueEmergencyPothole =
          dpwhCode == 'CODE 01' && isSlaBreached && hasPhoto && modelConf >= 0.40;

      final bool forcedCritical = isCorroboratedHazard || isOverdueEmergencyPothole;
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
          dpwhCode: dpwhCode,
          responseTime: responseTime,
          isSlaBreached: isSlaBreached,
          isOverdueEmergencyPothole: isOverdueEmergencyPothole,
          isCorroboratedHazard: isCorroboratedHazard,
          count: count,
          witnesses: witnesses.length,
          trust: trust,
          modelConf: modelConf,
          hasPhoto: hasPhoto,
          nearby: nearbyUids.length,
          waitH: waitH,
          dpwhSlaHours: dpwhSlaHours,
        ),
        duplicateIds: duplicateIds,
        isSlaBreached: isSlaBreached,
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
          dpwhCode: dpwhCode,
          responseTime: responseTime,
          dpwhSlaHours: dpwhSlaHours,
          isSlaBreached: isSlaBreached,
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

  /// Pending reports ordered most urgent first according to DPWH Protocol.
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
    required String dpwhCode,
    required String responseTime,
    required bool isSlaBreached,
    required bool isOverdueEmergencyPothole,
    required bool isCorroboratedHazard,
    required int count,
    required int witnesses,
    required double trust,
    required double modelConf,
    required bool hasPhoto,
    required int nearby,
    required double waitH,
    required double dpwhSlaHours,
  }) {
    final out = <String>[];

    // DPWH SLA Overdue Badge
    if (isSlaBreached) {
      final days = (waitH / 24).toStringAsFixed(1);
      out.add('DPWH SLA OVERDUE (${days}d / ${(dpwhSlaHours / 24).round()}d)');
    }

    // DPWH Code & Standard SLA
    if (dpwhCode == 'CODE 01') {
      out.add('DPWH Code 01: 3-Day Emergency SLA');
    } else if (dpwhCode == 'CODE 02') {
      out.add('DPWH Code 02: 3-Day Structural SLA');
    } else if (dpwhCode == 'CODE 05') {
      out.add('DPWH Code 05: 30-Day Re-blocking');
    } else if (dpwhCode == 'CODE 12') {
      out.add('DPWH Code 12: Routine Maintenance');
    }

    if (isOverdueEmergencyPothole) {
      out.add('DPWH Critical Overdue Escalation');
    }
    if (isCorroboratedHazard) {
      out.add('Corroborated Hazard ($witnesses witnesses)');
    }
    if (severity == 'high') out.add('High severity');
    if (count >= 3) out.add('$count hazards in cluster');
    if (witnesses >= 1 && !isCorroboratedHazard) {
      out.add('$witnesses independent report${witnesses == 1 ? '' : 's'}');
    }
    if (!hasPhoto) out.add('No photo proof');
    if (trust >= 0.80) {
      out.add('Trusted surveyor');
    } else if (trust <= 0.40) {
      out.add('Low reporter trust');
    }
    if (modelConf < 0.40) out.add('Weak AI detection');
    if (nearby >= 4) out.add('High traffic area');

    return out;
  }
}
