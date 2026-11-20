import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serializable approved road-report snapshot cached locally so offline or
/// spotty driving sessions keep using the latest known approved hazards with
/// explicit staleness visibility.
class CachedReportRecord {
  final String docId;
  final String? canonicalDefectId;
  final double latitude;
  final double longitude;
  final String primaryDefect;
  final String primaryDpwhCode;
  final String status;
  final bool isResolved;
  final int potholeCount;
  final List<String> defectClasses;
  final String barangay;
  final String city;
  final String province;
  final String formattedAddress;
  final String? roadName;
  final double? roadBearingDeg;
  final bool roadMatched;
  final int updatedAtMs;

  const CachedReportRecord({
    required this.docId,
    this.canonicalDefectId,
    required this.latitude,
    required this.longitude,
    required this.primaryDefect,
    required this.primaryDpwhCode,
    required this.status,
    this.isResolved = false,
    this.potholeCount = 1,
    this.defectClasses = const [],
    this.barangay = '',
    this.city = '',
    this.province = '',
    this.formattedAddress = '',
    this.roadName,
    this.roadBearingDeg,
    this.roadMatched = false,
    required this.updatedAtMs,
  });

  LatLng get location => LatLng(latitude, longitude);

  Map<String, dynamic> toJson() => {
    'docId': docId,
    if (canonicalDefectId != null && canonicalDefectId!.isNotEmpty)
      'canonicalDefectId': canonicalDefectId,
    'latitude': latitude,
    'longitude': longitude,
    'primaryDefect': primaryDefect,
    'primaryDpwhCode': primaryDpwhCode,
    'status': status,
    'isResolved': isResolved,
    'potholeCount': potholeCount,
    if (defectClasses.isNotEmpty) 'defectClasses': defectClasses,
    'barangay': barangay,
    'city': city,
    'province': province,
    'formattedAddress': formattedAddress,
    if (roadName != null && roadName!.isNotEmpty) 'roadName': roadName,
    if (roadBearingDeg != null) 'roadBearingDeg': roadBearingDeg,
    if (roadMatched) 'roadMatched': roadMatched,
    'updatedAtMs': updatedAtMs,
  };

  static CachedReportRecord? fromJson(Map<String, dynamic> map) {
    final num? lat = map['latitude'] as num?;
    final num? lng = map['longitude'] as num?;
    if (lat == null || lng == null) return null;
    final List<String> parsedClasses =
        ((map['defectClasses'] as List?) ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
    return CachedReportRecord(
      docId: (map['docId'] as String? ?? '').trim(),
      canonicalDefectId: (map['canonicalDefectId'] as String?)?.trim(),
      latitude: lat.toDouble(),
      longitude: lng.toDouble(),
      primaryDefect: (map['primaryDefect'] as String? ?? 'Pothole').trim(),
      primaryDpwhCode: (map['primaryDpwhCode'] as String? ?? 'CODE 01').trim(),
      status: (map['status'] as String? ?? 'approved').trim().toLowerCase(),
      isResolved: map['isResolved'] == true,
      potholeCount: (map['potholeCount'] as num?)?.toInt() ?? 1,
      defectClasses: parsedClasses,
      barangay: (map['barangay'] as String? ?? '').trim(),
      city: (map['city'] as String? ?? '').trim(),
      province: (map['province'] as String? ?? '').trim(),
      formattedAddress: (map['formattedAddress'] as String? ?? '').trim(),
      roadName: (map['roadName'] as String?)?.trim(),
      roadBearingDeg: (map['roadBearingDeg'] as num?)?.toDouble(),
      roadMatched: map['roadMatched'] == true,
      updatedAtMs:
          (map['updatedAtMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class CachedReportsSnapshot {
  final List<CachedReportRecord> records;
  final DateTime savedAt;

  const CachedReportsSnapshot({required this.records, required this.savedAt});
}

/// Persists approved unresolved hazard reports and recent route calculations in
/// [SharedPreferences] so Web and Mobile stay functional and transparent when
/// offline or reconnecting.
class RoadReportCache {
  static const String _reportsKey = 'roadsense_cached_approved_reports_v1';
  static const String _routesKey = 'roadsense_cached_recent_routes_v1';
  static const int _maxCachedReports = 1500;
  static const int _maxCachedRoutes = 8;

  static Future<void> saveApprovedReports(
    List<CachedReportRecord> records, {
    DateTime? savedAt,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final approvedOnly = records
          .where((r) => r.status == 'approved' && !r.isResolved)
          .take(_maxCachedReports)
          .map((r) => r.toJson())
          .toList(growable: false);
      final payload = jsonEncode({
        'savedAtMs': (savedAt ?? DateTime.now()).millisecondsSinceEpoch,
        'records': approvedOnly,
      });
      await prefs.setString(_reportsKey, payload);
    } catch (_) {}
  }

  static Future<CachedReportsSnapshot?> loadApprovedReports() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_reportsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final savedAtMs = (decoded['savedAtMs'] as num?)?.toInt();
      final List items = (decoded['records'] as List?) ?? const [];
      final List<CachedReportRecord> records = [];
      for (final entry in items) {
        if (entry is Map) {
          final parsed = CachedReportRecord.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (parsed != null) records.add(parsed);
        }
      }
      if (records.isEmpty || savedAtMs == null) return null;
      return CachedReportsSnapshot(
        records: records,
        savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMs),
      );
    } catch (_) {
      return null;
    }
  }

  static String routeCacheKey({
    required LatLng origin,
    required LatLng destination,
    required String travelMode,
  }) {
    return '${travelMode}_${origin.latitude.toStringAsFixed(4)},${origin.longitude.toStringAsFixed(4)}_'
        '${destination.latitude.toStringAsFixed(4)},${destination.longitude.toStringAsFixed(4)}';
  }

  static Future<void> saveRecentRoute({
    required String routeKey,
    required List<List<LatLng>> routes,
    required List<double> durationsSeconds,
    required List<double> distancesMeters,
  }) async {
    if (routes.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingRaw = prefs.getString(_routesKey);
      final Map<String, dynamic> store =
          existingRaw != null && existingRaw.isNotEmpty
          ? Map<String, dynamic>.from(jsonDecode(existingRaw) as Map)
          : <String, dynamic>{};

      store[routeKey] = {
        'savedAtMs': DateTime.now().millisecondsSinceEpoch,
        'routes': routes
            .map((r) => r.map((p) => [p.latitude, p.longitude]).toList())
            .toList(),
        'durations': durationsSeconds,
        'distances': distancesMeters,
      };

      if (store.length > _maxCachedRoutes) {
        final entries = store.entries.toList()
          ..sort((a, b) {
            final ta = ((a.value as Map)['savedAtMs'] as num?)?.toInt() ?? 0;
            final tb = ((b.value as Map)['savedAtMs'] as num?)?.toInt() ?? 0;
            return tb.compareTo(ta);
          });
        store
          ..clear()
          ..addEntries(entries.take(_maxCachedRoutes));
      }

      await prefs.setString(_routesKey, jsonEncode(store));
    } catch (_) {}
  }

  static Future<
    ({
      List<List<LatLng>> routes,
      List<double> durations,
      List<double> distances,
      DateTime savedAt,
    })?
  >
  loadRecentRoute(String routeKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_routesKey);
      if (raw == null || raw.isEmpty) return null;
      final store = jsonDecode(raw) as Map<String, dynamic>;
      final entry = store[routeKey];
      if (entry is! Map) return null;
      final savedAtMs = (entry['savedAtMs'] as num?)?.toInt();
      final List rawRoutes = (entry['routes'] as List?) ?? const [];
      final List rawDurs = (entry['durations'] as List?) ?? const [];
      final List rawDists = (entry['distances'] as List?) ?? const [];
      final routes = rawRoutes.map((r) {
        return (r as List).map((pt) {
          final pair = pt as List;
          return LatLng(
            (pair[0] as num).toDouble(),
            (pair[1] as num).toDouble(),
          );
        }).toList();
      }).toList();
      if (routes.isEmpty) return null;
      return (
        routes: routes,
        durations: rawDurs.map((e) => (e as num).toDouble()).toList(),
        distances: rawDists.map((e) => (e as num).toDouble()).toList(),
        savedAt: DateTime.fromMillisecondsSinceEpoch(
          savedAtMs ?? DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Formats a human-readable report-freshness timestamp for Web & Mobile UIs.
  static String formatDataUpdatedLabel(
    DateTime? lastUpdatedAt, {
    bool isUsingCached = false,
    DateTime? now,
  }) {
    if (lastUpdatedAt == null) {
      return isUsingCached
          ? 'Using saved pothole data.'
          : 'Syncing report data...';
    }
    final evalNow = now ?? DateTime.now();
    final diff = evalNow.difference(lastUpdatedAt);
    final String rel;
    if (diff.inSeconds < 60) {
      rel = 'just now';
    } else if (diff.inMinutes < 60) {
      rel = '${diff.inMinutes} min ago';
    } else if (diff.inHours < 24) {
      rel = '${diff.inHours} hr ago';
    } else {
      final m = lastUpdatedAt.month.toString().padLeft(2, '0');
      final d = lastUpdatedAt.day.toString().padLeft(2, '0');
      final hh = lastUpdatedAt.hour.toString().padLeft(2, '0');
      final mm = lastUpdatedAt.minute.toString().padLeft(2, '0');
      rel = '$m/$d $hh:$mm';
    }
    return isUsingCached
        ? 'Using saved pothole data · updated $rel'
        : 'Report data updated $rel';
  }
}
