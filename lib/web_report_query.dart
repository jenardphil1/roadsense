import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'barangay_forecast_panel.dart' show barangayKey, santaMariaBarangays;
import 'dpwh_standards.dart';

String formatBarangayLabel(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('barangay ') ||
      lower.startsWith('brgy.') ||
      lower.startsWith('brgy ')) {
    return trimmed;
  }
  return 'Barangay $trimmed';
}

/// Top-level route destinations in the public/user RoadSense web shell.
enum WebShellRoute { map, reports, account }

/// Geographic bounding box independent of Flutter widgets so filter queries
/// remain easy to unit test in headless VM runs.
class GeoBoundsBox {
  final double north;
  final double south;
  final double east;
  final double west;

  const GeoBoundsBox({
    required this.north,
    required this.south,
    required this.east,
    required this.west,
  });

  bool contains(LatLng point) {
    return point.latitude <= north &&
        point.latitude >= south &&
        point.longitude <= east &&
        point.longitude >= west;
  }

  @override
  bool operator ==(Object other) {
    return other is GeoBoundsBox &&
        (other.north - north).abs() < 1e-6 &&
        (other.south - south).abs() < 1e-6 &&
        (other.east - east).abs() < 1e-6 &&
        (other.west - west).abs() < 1e-6;
  }

  @override
  int get hashCode => Object.hash(
    north.toStringAsFixed(5),
    south.toStringAsFixed(5),
    east.toStringAsFixed(5),
    west.toStringAsFixed(5),
  );
}

/// Official Santa Maria, Bulacan barangay entry used by both the map search
/// index and the geographic filter picker.
class SantaMariaBarangayEntry {
  final String name;
  final String key;
  final double? lat;
  final double? lon;

  const SantaMariaBarangayEntry({
    required this.name,
    required this.key,
    this.lat,
    this.lon,
  });

  bool get hasCoordinates => lat != null && lon != null;
  String get fullLabel => 'Barangay $name, Santa Maria, Bulacan';
}

/// Approximate municipal coordinates known locally in the client bundle; any
/// official barangay without an entry here resolves dynamically via geocoding
/// when selected so unverified coordinates are never invented.
const Map<String, ({double lat, double lon})> _knownSantaMariaCoordinates = {
  'poblacion': (lat: 14.8197, lon: 120.9575),
  'bagbaguin': (lat: 14.8083, lon: 120.9542),
  'caypombo': (lat: 14.8427, lon: 120.9739),
  'catmon': (lat: 14.8315, lon: 120.9858),
  'guyong': (lat: 14.8236, lon: 120.9712),
  'balasing': (lat: 14.8584, lon: 121.0062),
  'pulong buhangin': (lat: 14.8633, lon: 121.0022),
  'san gabriel': (lat: 14.8251, lon: 120.9631),
  'santa clara': (lat: 14.8164, lon: 120.9501),
  'buenavista': (lat: 14.8521, lon: 120.9934),
  'camangyanan': (lat: 14.8115, lon: 120.9412),
  'caysio': (lat: 14.8458, lon: 120.9812),
  'lalakhan': (lat: 14.8123, lon: 120.9621),
  'mag asawang sapa': (lat: 14.8711, lon: 121.0189),
  'mahabang parang': (lat: 14.8654, lon: 121.0211),
  'manggahan': (lat: 14.8389, lon: 120.9689),
  'parada': (lat: 14.8012, lon: 120.9642),
  'san jose patag': (lat: 14.8091, lon: 120.9782),
  'san vicente': (lat: 14.8291, lon: 120.9521),
  'silangan': (lat: 14.8412, lon: 121.0142),
  'tumana': (lat: 14.8178, lon: 120.9712),
};

/// Deduplicated 24-barangay Santa Maria, Bulacan catalog matching
/// [santaMariaBarangays].
final List<SantaMariaBarangayEntry> santaMariaBarangayCatalog = (() {
  final seenKeys = <String>{};
  final items = <SantaMariaBarangayEntry>[];
  for (final rawName in santaMariaBarangays) {
    final key = barangayKey(rawName);
    if (key.isEmpty || !seenKeys.add(key)) continue;
    final coords = _knownSantaMariaCoordinates[key];
    items.add(
      SantaMariaBarangayEntry(
        name: rawName,
        key: key,
        lat: coords?.lat,
        lon: coords?.lon,
      ),
    );
  }
  return List<SantaMariaBarangayEntry>.unmodifiable(items);
})();

enum WebDateRangePreset { all, last24h, last7d, last30d, custom }

enum WebReportSort {
  newest,
  oldest,
  nearest,
  severityHighToLow,
  severityLowToHigh,
}

/// Filter + sort specification shared across the Map workspace and My Reports.
class WebReportFilter {
  final Set<String> defectClasses;
  final Set<String> statuses;
  final Set<String> barangayKeys;
  final Set<String> severities;
  final WebDateRangePreset datePreset;
  final DateTime? customStart;
  final DateTime? customEnd;
  final bool onlyInMapBounds;
  final WebReportSort sort;

  const WebReportFilter({
    this.defectClasses = const {},
    this.statuses = const {},
    this.barangayKeys = const {},
    this.severities = const {},
    this.datePreset = WebDateRangePreset.all,
    this.customStart,
    this.customEnd,
    this.onlyInMapBounds = false,
    this.sort = WebReportSort.newest,
  });

  int get activeFilterCount {
    int count = 0;
    count += defectClasses.length;
    count += statuses.length;
    count += barangayKeys.length;
    count += severities.length;
    if (datePreset != WebDateRangePreset.all) count++;
    if (onlyInMapBounds) count++;
    return count;
  }

  bool get hasAnyFilter => activeFilterCount > 0;

  WebReportFilter copyWith({
    Set<String>? defectClasses,
    Set<String>? statuses,
    Set<String>? barangayKeys,
    Set<String>? severities,
    WebDateRangePreset? datePreset,
    DateTime? customStart,
    DateTime? customEnd,
    bool clearCustomDates = false,
    bool? onlyInMapBounds,
    WebReportSort? sort,
  }) {
    return WebReportFilter(
      defectClasses: defectClasses ?? this.defectClasses,
      statuses: statuses ?? this.statuses,
      barangayKeys: barangayKeys ?? this.barangayKeys,
      severities: severities ?? this.severities,
      datePreset: datePreset ?? this.datePreset,
      customStart: clearCustomDates ? null : (customStart ?? this.customStart),
      customEnd: clearCustomDates ? null : (customEnd ?? this.customEnd),
      onlyInMapBounds: onlyInMapBounds ?? this.onlyInMapBounds,
      sort: sort ?? this.sort,
    );
  }

  WebReportFilter clearAll({bool keepSort = true}) {
    return WebReportFilter(sort: keepSort ? sort : WebReportSort.newest);
  }
}

/// Normalized, privacy-safe report projection used for unified search,
/// filtering, sorting, and rendering across Map and My Reports.
class WebReportItem {
  final String docId;
  final LatLng location;
  final String imageUrl;
  final DateTime timestamp;
  final String status;
  final String severity;
  final int potholeCount;
  final String primaryDefect;
  final String primaryDpwhCode;
  final String responseTime;
  final String correctiveMeasure;
  final String barangay;
  final String city;
  final String province;
  final String formattedAddress;
  final String note;
  final String rejectionReason;
  final String? reporterUid;
  final List<Map<String, dynamic>> detections;
  final DateTime? lastEditedAt;
  final DateTime? moderatedAt;

  const WebReportItem({
    required this.docId,
    required this.location,
    required this.imageUrl,
    required this.timestamp,
    required this.status,
    required this.severity,
    required this.potholeCount,
    required this.primaryDefect,
    required this.primaryDpwhCode,
    required this.responseTime,
    required this.correctiveMeasure,
    this.barangay = '',
    this.city = '',
    this.province = '',
    this.formattedAddress = '',
    this.note = '',
    this.rejectionReason = '',
    this.reporterUid,
    this.detections = const [],
    this.lastEditedAt,
    this.moderatedAt,
  });

  String get normalizedBarangayKey => barangayKey(barangay);

  String get normalizedSeverity {
    final s = severity.trim().toLowerCase();
    if (s == 'high' || s == 'medium' || s == 'low') return s;
    return 'medium';
  }

  String get normalizedStatus {
    final s = status.trim().toLowerCase();
    if (s == 'approved' ||
        s == 'pending' ||
        s == 'rejected' ||
        s == 'deleted') {
      return s;
    }
    return 'pending';
  }

  String get shortId {
    if (docId.isEmpty) return 'Unassigned';
    return docId.length <= 8 ? docId : docId.substring(0, 8);
  }

  String get locationLabel {
    final parts = <String>[];
    if (barangay.trim().isNotEmpty) {
      parts.add(formatBarangayLabel(barangay.trim()));
    }
    if (city.trim().isNotEmpty) parts.add(city.trim());
    if (province.trim().isNotEmpty &&
        province.trim().toLowerCase() != city.trim().toLowerCase()) {
      parts.add(province.trim());
    }
    if (parts.isNotEmpty) return parts.join(', ');
    if (formattedAddress.trim().isNotEmpty) return formattedAddress.trim();
    return '${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)}';
  }

  /// Highest model confidence among stored YOLOv8 detections, or `null` if no
  /// detection confidences are present. Strictly represents AI confidence, never
  /// road damage severity.
  double? get peakModelConfidence {
    double? best;
    for (final det in detections) {
      final conf = (det['confidence'] as num?)?.toDouble();
      if (conf == null || !conf.isFinite) continue;
      if (best == null || conf > best) best = conf;
    }
    return best;
  }

  /// Privacy-preserving attribution for public cards & inspect views.
  String publicAttribution(String? currentUid) {
    if (currentUid != null &&
        currentUid.isNotEmpty &&
        reporterUid == currentUid) {
      return 'Submitted by you';
    }
    return 'Verified community surveyor';
  }
}

/// Search ranking wrapper for a matching [WebReportItem].
class RankedReportMatch {
  final WebReportItem item;
  final int score;
  final String matchReason;

  const RankedReportMatch({
    required this.item,
    required this.score,
    required this.matchReason,
  });
}

class WebReportQueryResult {
  final List<WebReportItem> items;
  final int totalDatasetCount;
  final bool nearestRequestedWithoutLocation;
  final String? queryError;

  const WebReportQueryResult({
    required this.items,
    required this.totalDatasetCount,
    this.nearestRequestedWithoutLocation = false,
    this.queryError,
  });
}

/// Stateless helpers for search normalization, ranking, filtering, sorting,
/// pagination, and safe URL hash synchronization.
class WebReportQueryEngine {
  WebReportQueryEngine._();

  static const Distance _distance = Distance();

  static final RegExp _diacriticsOrPunct = RegExp(r'[^a-z0-9\s-]+');
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _prefixWords = RegExp(
    r'\b(barangay|brgy|bgy|bgry)\b',
    caseSensitive: false,
  );
  static final RegExp _saintAbbrev = RegExp(r'\bsta\b', caseSensitive: false);
  static final RegExp _santoAbbrev = RegExp(r'\bsto\b', caseSensitive: false);

  /// Normalizes free-text user queries across case, whitespace, punctuation,
  /// and common Philippine LGU abbreviations (`Brgy.`, `Sta.`, `Sto.`).
  static String normalizeSearchText(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return '';
    s = s.replaceAll(_diacriticsOrPunct, ' ');
    s = s.replaceAll(_prefixWords, ' ');
    s = s.replaceAll(_saintAbbrev, 'santa');
    s = s.replaceAll(_santoAbbrev, 'santo');
    s = s.replaceAll(_whitespace, ' ').trim();
    return s;
  }

  static List<String> tokenizeQuery(String raw) {
    final norm = normalizeSearchText(raw);
    if (norm.isEmpty) return const [];
    return norm.split(' ').where((t) => t.isNotEmpty).toList(growable: false);
  }

  /// Filters and sorts loaded reports according to [filter], optional text
  /// [query], [mapBounds] (when `filter.onlyInMapBounds` is enabled), and
  /// [referencePoint] (used only for `WebReportSort.nearest`).
  static WebReportQueryResult execute({
    required List<WebReportItem> dataset,
    required WebReportFilter filter,
    String query = '',
    GeoBoundsBox? mapBounds,
    LatLng? referencePoint,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final tokens = tokenizeQuery(query);
    final normalizedFullQuery = normalizeSearchText(query);

    final matched = <({WebReportItem item, int score})>[];
    for (final item in dataset) {
      if (!_matchesFilter(item, filter, mapBounds: mapBounds, now: clock)) {
        continue;
      }

      if (tokens.isEmpty) {
        matched.add((item: item, score: 0));
        continue;
      }

      final score = _scoreReportMatch(item, normalizedFullQuery, tokens);
      if (score > 0) {
        matched.add((item: item, score: score));
      }
    }

    bool missingRefForNearest = false;
    matched.sort((a, b) {
      // When an explicit search query is active, surface highest relevance
      // first unless user chose a strong distance/severity order; ties fall
      // back to selected sort order.
      if (tokens.isNotEmpty && filter.sort == WebReportSort.newest) {
        final rel = b.score.compareTo(a.score);
        if (rel != 0) return rel;
      }

      switch (filter.sort) {
        case WebReportSort.newest:
          final cmp = b.item.timestamp.compareTo(a.item.timestamp);
          return cmp != 0 ? cmp : a.item.docId.compareTo(b.item.docId);
        case WebReportSort.oldest:
          final cmp = a.item.timestamp.compareTo(b.item.timestamp);
          return cmp != 0 ? cmp : a.item.docId.compareTo(b.item.docId);
        case WebReportSort.nearest:
          if (referencePoint == null) {
            missingRefForNearest = true;
            return b.item.timestamp.compareTo(a.item.timestamp);
          }
          final dA = _distance.as(
            LengthUnit.Meter,
            referencePoint,
            a.item.location,
          );
          final dB = _distance.as(
            LengthUnit.Meter,
            referencePoint,
            b.item.location,
          );
          final cmp = dA.compareTo(dB);
          return cmp != 0 ? cmp : b.item.timestamp.compareTo(a.item.timestamp);
        case WebReportSort.severityHighToLow:
          final cmp = _severityRank(
            b.item.normalizedSeverity,
          ).compareTo(_severityRank(a.item.normalizedSeverity));
          if (cmp != 0) return cmp;
          return b.item.timestamp.compareTo(a.item.timestamp);
        case WebReportSort.severityLowToHigh:
          final cmp = _severityRank(
            a.item.normalizedSeverity,
          ).compareTo(_severityRank(b.item.normalizedSeverity));
          if (cmp != 0) return cmp;
          return b.item.timestamp.compareTo(a.item.timestamp);
      }
    });

    if (filter.sort == WebReportSort.nearest && referencePoint == null) {
      missingRefForNearest = true;
    }

    return WebReportQueryResult(
      items: matched.map((m) => m.item).toList(growable: false),
      totalDatasetCount: dataset.length,
      nearestRequestedWithoutLocation: missingRefForNearest,
    );
  }

  /// Ranks loaded report matches specifically for autocomplete suggestions so
  /// users searching by report ID, defect type, barangay, or notes find exact
  /// hazards alongside map locations.
  static List<RankedReportMatch> searchSuggestions({
    required List<WebReportItem> dataset,
    required String query,
    int limit = 5,
  }) {
    final full = normalizeSearchText(query);
    final tokens = tokenizeQuery(query);
    if (full.isEmpty || tokens.isEmpty) return const [];

    final scored = <RankedReportMatch>[];
    for (final item in dataset) {
      final score = _scoreReportMatch(item, full, tokens);
      if (score <= 0) continue;
      final idNorm = item.docId.toLowerCase();
      final String reason;
      if (idNorm.startsWith(full.replaceAll('#', ''))) {
        reason = 'Report #${item.shortId}';
      } else if (item.barangay.isNotEmpty &&
          normalizeSearchText(item.barangay).contains(tokens.first)) {
        reason = formatBarangayLabel(item.barangay);
      } else if (normalizeSearchText(
        item.primaryDefect,
      ).contains(tokens.first)) {
        reason = '${item.primaryDefect} (${item.primaryDpwhCode})';
      } else {
        reason = 'Notes & location match';
      }
      scored.add(
        RankedReportMatch(item: item, score: score, matchReason: reason),
      );
    }
    scored.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      return b.item.timestamp.compareTo(a.item.timestamp);
    });
    return scored.take(limit).toList(growable: false);
  }

  static bool _matchesFilter(
    WebReportItem item,
    WebReportFilter filter, {
    required GeoBoundsBox? mapBounds,
    required DateTime now,
  }) {
    if (filter.defectClasses.isNotEmpty) {
      final itemCls =
          DpwhStandards.classForReport({
            'primaryDefect': item.primaryDefect,
            'primaryDpwhCode': item.primaryDpwhCode,
          })?.name ??
          item.primaryDefect;
      final allowed = filter.defectClasses
          .map((e) => e.trim().toLowerCase())
          .toSet();
      if (!allowed.contains(itemCls.trim().toLowerCase())) {
        return false;
      }
    }

    if (filter.statuses.isNotEmpty) {
      final allowed = filter.statuses
          .map((e) => e.trim().toLowerCase())
          .toSet();
      if (!allowed.contains(item.normalizedStatus)) {
        return false;
      }
    }

    if (filter.severities.isNotEmpty) {
      final allowed = filter.severities
          .map((e) => e.trim().toLowerCase())
          .toSet();
      if (!allowed.contains(item.normalizedSeverity)) {
        return false;
      }
    }

    if (filter.barangayKeys.isNotEmpty) {
      final itemKey = item.normalizedBarangayKey;
      if (itemKey.isEmpty || !filter.barangayKeys.contains(itemKey)) {
        return false;
      }
    }

    if (filter.onlyInMapBounds && mapBounds != null) {
      if (!mapBounds.contains(item.location)) return false;
    }

    switch (filter.datePreset) {
      case WebDateRangePreset.all:
        break;
      case WebDateRangePreset.last24h:
        if (item.timestamp.isBefore(now.subtract(const Duration(hours: 24)))) {
          return false;
        }
      case WebDateRangePreset.last7d:
        if (item.timestamp.isBefore(now.subtract(const Duration(days: 7)))) {
          return false;
        }
      case WebDateRangePreset.last30d:
        if (item.timestamp.isBefore(now.subtract(const Duration(days: 30)))) {
          return false;
        }
      case WebDateRangePreset.custom:
        if (filter.customStart != null &&
            item.timestamp.isBefore(filter.customStart!)) {
          return false;
        }
        if (filter.customEnd != null &&
            item.timestamp.isAfter(filter.customEnd!)) {
          return false;
        }
    }
    return true;
  }

  static int _scoreReportMatch(
    WebReportItem item,
    String fullQuery,
    List<String> tokens,
  ) {
    final docNorm = item.docId.toLowerCase();
    final defectNorm = normalizeSearchText(item.primaryDefect);
    final codeNorm = normalizeSearchText(item.primaryDpwhCode);
    final brgyNorm = normalizeSearchText(item.barangay);
    final cityNorm = normalizeSearchText(item.city);
    final provNorm = normalizeSearchText(item.province);
    final addrNorm = normalizeSearchText(item.formattedAddress);
    final noteNorm = normalizeSearchText(item.note);
    final sevNorm = item.normalizedSeverity;
    final statusNorm = item.normalizedStatus;
    final detNames = item.detections
        .map((d) => normalizeSearchText((d['className'] ?? '').toString()))
        .join(' ');
    final coords =
        '${item.location.latitude.toStringAsFixed(5)} ${item.location.longitude.toStringAsFixed(5)}';

    final haystack = [
      docNorm,
      defectNorm,
      codeNorm,
      brgyNorm,
      cityNorm,
      provNorm,
      addrNorm,
      noteNorm,
      sevNorm,
      statusNorm,
      detNames,
      coords,
    ].join(' ');

    for (final token in tokens) {
      if (!haystack.contains(token)) return 0;
    }

    var score = 10;
    final cleanIdQuery = fullQuery.replaceFirst('#', '').trim();
    if (cleanIdQuery.isNotEmpty) {
      if (docNorm == cleanIdQuery) {
        score += 120;
      } else if (docNorm.startsWith(cleanIdQuery)) {
        score += 90;
      } else if (docNorm.contains(cleanIdQuery)) {
        score += 65;
      }
    }
    if (defectNorm.startsWith(fullQuery) || codeNorm == fullQuery) {
      score += 55;
    } else if (defectNorm.contains(fullQuery)) {
      score += 35;
    }
    if (brgyNorm.isNotEmpty && brgyNorm.startsWith(fullQuery)) {
      score += 50;
    } else if (brgyNorm.contains(fullQuery)) {
      score += 30;
    }
    if (noteNorm.contains(fullQuery)) score += 20;
    if (addrNorm.contains(fullQuery) || cityNorm.contains(fullQuery)) {
      score += 18;
    }
    return score;
  }

  static int _severityRank(String sev) {
    switch (sev.toLowerCase()) {
      case 'high':
        return 3;
      case 'medium':
        return 2;
      case 'low':
        return 1;
      default:
        return 0;
    }
  }

  static double distanceMeters(LatLng a, LatLng b) =>
      _distance.as(LengthUnit.Meter, a, b);

  static String formatDistance(double meters) {
    if (!meters.isFinite || meters < 0) return 'Distance unavailable';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  static String formatTimestamp(DateTime dt) {
    final local = dt.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final m = months[(local.month - 1).clamp(0, 11)];
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$m ${local.day}, ${local.year} • $hh:$mm';
  }

  static String formatConfidence(double confidence) {
    final pct = (confidence * 100).clamp(0.0, 100.0);
    return '${pct.toStringAsFixed(1)}%';
  }

  static int totalPages(int itemCount, int pageSize) {
    if (itemCount <= 0 || pageSize <= 0) return 1;
    return math.max(1, (itemCount / pageSize).ceil());
  }
}

/// Privacy-safe URL hash navigation model supporting browser Back/Forward
/// across `#/map`, `#/reports`, and `#/account` without exposing PII.
class WebUrlState {
  final WebShellRoute route;
  final String? selectedReportId;
  final double? lat;
  final double? lng;
  final double? zoom;

  const WebUrlState({
    this.route = WebShellRoute.map,
    this.selectedReportId,
    this.lat,
    this.lng,
    this.zoom,
  });

  static WebUrlState parseHash(String rawHash) {
    var trimmed = rawHash.trim();
    if (trimmed.isEmpty || trimmed == '#') {
      return const WebUrlState();
    }
    if (trimmed.startsWith('#')) trimmed = trimmed.substring(1);
    if (!trimmed.startsWith('/')) trimmed = '/$trimmed';

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return const WebUrlState();

    final seg = uri.pathSegments.isEmpty
        ? 'map'
        : uri.pathSegments.first.toLowerCase();
    final WebShellRoute route;
    switch (seg) {
      case 'reports':
      case 'my-reports':
        route = WebShellRoute.reports;
      case 'account':
      case 'profile':
        route = WebShellRoute.account;
      default:
        route = WebShellRoute.map;
    }

    final reportId = uri.queryParameters['report']?.trim();
    final lat = double.tryParse(uri.queryParameters['lat'] ?? '');
    final lng = double.tryParse(uri.queryParameters['lng'] ?? '');
    final zoom = double.tryParse(uri.queryParameters['z'] ?? '');

    final validLat = (lat != null && lat.isFinite && lat >= -90 && lat <= 90)
        ? lat
        : null;
    final validLng = (lng != null && lng.isFinite && lng >= -180 && lng <= 180)
        ? lng
        : null;
    final validZoom = (zoom != null && zoom.isFinite && zoom >= 2 && zoom <= 22)
        ? zoom
        : null;

    return WebUrlState(
      route: route,
      selectedReportId: (reportId != null && reportId.isNotEmpty)
          ? reportId
          : null,
      lat: (validLat != null && validLng != null) ? validLat : null,
      lng: (validLat != null && validLng != null) ? validLng : null,
      zoom: validZoom,
    );
  }

  static WebUrlState parseUri(Uri uri) {
    if (uri.fragment.trim().isNotEmpty) {
      return parseHash(uri.fragment);
    }
    return parseHash(uri.toString());
  }

  Uri toUri() {
    final path = switch (route) {
      WebShellRoute.map => '/map',
      WebShellRoute.reports => '/reports',
      WebShellRoute.account => '/account',
    };
    final params = <String, String>{};
    if (selectedReportId != null && selectedReportId!.trim().isNotEmpty) {
      params['report'] = selectedReportId!.trim();
    }
    if (lat != null && lng != null) {
      params['lat'] = lat!.toStringAsFixed(5);
      params['lng'] = lng!.toStringAsFixed(5);
    }
    if (zoom != null) {
      params['z'] = zoom!.toStringAsFixed(1);
    }
    return params.isEmpty
        ? Uri(path: path)
        : Uri(path: path, queryParameters: params);
  }

  String toHash() => '#${toUri()}';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WebUrlState &&
        other.route == route &&
        other.selectedReportId == selectedReportId &&
        other.lat?.toStringAsFixed(5) == lat?.toStringAsFixed(5) &&
        other.lng?.toStringAsFixed(5) == lng?.toStringAsFixed(5) &&
        other.zoom?.toStringAsFixed(1) == zoom?.toStringAsFixed(1);
  }

  @override
  int get hashCode => Object.hash(
    route,
    selectedReportId,
    lat?.toStringAsFixed(5),
    lng?.toStringAsFixed(5),
    zoom?.toStringAsFixed(1),
  );
}
