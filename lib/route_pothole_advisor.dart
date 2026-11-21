import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'dpwh_standards.dart';

/// Documents and configures the spatial corridor around a road-following
/// route polyline used when counting eligible pothole reports.
class RouteCorridorConfig {
  /// Default route corridor half-width in meters (~18 m).
  ///
  /// Chosen to cover standard two-lane Philippine urban/arterial carriageway
  /// widths plus typical 5-10 m consumer GPS uncertainty while excluding
  /// separate side streets beyond 18 m.
  static const double defaultCorridorMeters = 18.0;
  static const double minCorridorMeters = 8.0;
  static const double maxCorridorMeters = 32.0;
  static const double defaultOffRouteMeters = 55.0;
  static const double defaultMaxBearingDiffDeg = 70.0;

  final double corridorMeters;
  final double offRouteThresholdMeters;
  final double maxBearingDifferenceDeg;

  const RouteCorridorConfig({
    this.corridorMeters = defaultCorridorMeters,
    this.offRouteThresholdMeters = defaultOffRouteMeters,
    this.maxBearingDifferenceDeg = defaultMaxBearingDiffDeg,
  });

  /// Expands the corridor conservatively when horizontal GPS accuracy is poor,
  /// clamped to avoid counting unrelated parallel corridors.
  static double effectiveCorridorMeters({
    double baseCorridorMeters = defaultCorridorMeters,
    double? gpsAccuracyMeters,
  }) {
    if (gpsAccuracyMeters == null || gpsAccuracyMeters <= 12.0) {
      return baseCorridorMeters.clamp(minCorridorMeters, maxCorridorMeters);
    }
    final double expanded =
        baseCorridorMeters + ((gpsAccuracyMeters - 12.0) * 0.35);
    return expanded.clamp(minCorridorMeters, maxCorridorMeters);
  }
}

/// Configurable tolerance limits when evaluating safer alternative detours.
class RouteDetourConfig {
  /// Maximum additional travel duration ratio vs the fastest route (e.g. +35%).
  final double maxExtraDurationRatio;

  /// Minimum detour duration allowance in seconds on short urban trips
  /// (defaults to 5 minutes so short 4-minute routes still allow viable bypasses).
  final double minAllowedExtraSeconds;

  /// Maximum additional distance ratio vs the fastest route (e.g. +45%).
  final double maxExtraDistanceRatio;

  const RouteDetourConfig({
    this.maxExtraDurationRatio = 0.35,
    this.minAllowedExtraSeconds = 300.0,
    this.maxExtraDistanceRatio = 0.45,
  });

  bool isWithinAllowance({
    required double baselineDurationSeconds,
    required double candidateDurationSeconds,
    required double baselineDistanceMeters,
    required double candidateDistanceMeters,
  }) {
    final double extraSec = candidateDurationSeconds - baselineDurationSeconds;
    final double maxExtraSec = baselineDurationSeconds > 0
        ? math.max(
            minAllowedExtraSeconds,
            baselineDurationSeconds * maxExtraDurationRatio,
          )
        : minAllowedExtraSeconds;
    if (extraSec > maxExtraSec) return false;

    if (baselineDistanceMeters > 0) {
      final double maxDist =
          baselineDistanceMeters * (1.0 + maxExtraDistanceRatio);
      if (candidateDistanceMeters > maxDist &&
          (candidateDistanceMeters - baselineDistanceMeters) > 1500.0) {
        return false;
      }
    }
    return true;
  }
}

/// Lightweight input describing a hazard report for route evaluation and live
/// upcoming-pothole countdown calculation.
class RouteHazardInput {
  final LatLng location;

  /// Optional raw un-snapped report coordinates before road snapping.
  /// When provided, corridor checks ensure road snapping did not pull an
  /// off-corridor parallel street report onto the active route.
  final LatLng? rawLocation;
  final String defectName;
  final String dpwhCode;
  final String barangay;
  final int potholeCount;

  /// Optional individual class labels from the report's `detections` array
  /// when a single report captures multiple defects (e.g. a Pothole plus an
  /// Alligator crack).
  final List<String>? detectedDefects;

  /// Underlying Firestore/local report ID, if known.
  final String? reportId;

  /// Canonical physical defect ID when repeated citizen/scanner reports refer
  /// to the same pothole. Separate potholes with distinct IDs are never merged
  /// by coordinate proximity alone.
  final String? canonicalDefectId;

  /// Moderation lifecycle status (`approved`, `pending`, `rejected`, `deleted`,
  /// `resolved`).
  final String status;

  /// True when maintenance/repairs resolved the defect.
  final bool isResolved;

  /// False when the current session lacks access rights to count the report.
  final bool isAccessible;

  /// Road name associated with the hazard if road matching succeeded.
  final String? roadName;

  /// True when coordinates/street were explicitly road-matched to the route graph.
  final bool roadMatched;

  /// Direction of travel/carriageway bearing in degrees (0..360) if known.
  final double? roadBearingDeg;

  /// Optional timestamp of the latest verification/edit on the report.
  final DateTime? updatedAt;

  const RouteHazardInput({
    required this.location,
    this.rawLocation,
    required this.defectName,
    this.dpwhCode = 'CODE 01',
    this.barangay = '',
    this.potholeCount = 1,
    this.detectedDefects,
    this.reportId,
    this.canonicalDefectId,
    this.status = 'approved',
    this.isResolved = false,
    this.isAccessible = true,
    this.roadName,
    this.roadMatched = false,
    this.roadBearingDeg,
    this.updatedAt,
  });

  /// Canonical identifier used to deduplicate duplicate reports of the exact
  /// same physical pothole without conflating distinct nearby defects.
  String? get explicitCanonicalKey {
    final canon = canonicalDefectId?.trim() ?? '';
    if (canon.isNotEmpty) return 'defect:${canon.toLowerCase()}';
    final id = reportId?.trim() ?? '';
    if (id.isNotEmpty) return 'defect:${id.toLowerCase()}';
    return null;
  }

  /// True only for approved, unresolved, accessible public reports.
  bool get isEligibleForPublicRouteCount {
    if (isResolved || !isAccessible) return false;
    final normalized = status.trim().toLowerCase();
    return normalized == 'approved';
  }

  /// Strictly distinguishes `Pothole` (CODE 01, excluding `Edge break`) from
  /// cracks and legacy classes.
  bool get isPotholeClass {
    final cls = DpwhStandards.classForReport({
      'primaryDefect': defectName,
      'primaryDpwhCode': dpwhCode,
    });
    return cls == DpwhStandards.pothole;
  }

  static DpwhDefectClass? _classifyDetectionLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return null;
    return DpwhStandards.classForReport({'primaryDefect': trimmed});
  }

  /// True when the report itself is a Pothole OR its individual `detections`
  /// list contains at least one Pothole detection.
  bool get containsPotholeClass {
    if (isPotholeClass) return true;
    final list = detectedDefects;
    if (list == null || list.isEmpty) return false;
    for (final raw in list) {
      if (_classifyDetectionLabel(raw) == DpwhStandards.pothole) return true;
    }
    return false;
  }

  /// Number of individual Pothole detections represented by this report,
  /// excluding non-pothole cracks even when `potholeCount` stores all model
  /// detections combined.
  int get resolvedPotholeDetectionCount {
    final list = detectedDefects;
    if (list != null && list.isNotEmpty) {
      int count = 0;
      for (final raw in list) {
        if (_classifyDetectionLabel(raw) == DpwhStandards.pothole) {
          count++;
        }
      }
      return count;
    }
    if (!isPotholeClass) return 0;
    return potholeCount > 0 ? potholeCount : 1;
  }

  /// Distinct non-pothole DPWH defect labels carried by this report (either as
  /// its primary class or alongside a pothole in mixed-detection reports).
  Set<String> get nonPotholeDefectLabels {
    final labels = <String>{};
    if (!isPotholeClass) {
      labels.add(normalizedDefectLabel);
    }
    final list = detectedDefects;
    if (list != null) {
      for (final raw in list) {
        final cls = _classifyDetectionLabel(raw);
        if (cls == null) {
          final trimmed = raw.trim();
          if (trimmed.isNotEmpty) labels.add(trimmed);
        } else if (cls != DpwhStandards.pothole) {
          labels.add(cls.name);
        }
      }
    }
    return labels;
  }

  /// Canonical DPWH defect class name for separate non-pothole accounting.
  String get normalizedDefectLabel {
    final cls = DpwhStandards.classForReport({
      'primaryDefect': defectName,
      'primaryDpwhCode': dpwhCode,
    });
    if (cls != null) return cls.name;
    final trimmed = defectName.trim();
    return trimmed.isNotEmpty ? trimmed : 'Other road defect';
  }
}

/// Axis-aligned geographic bounding box buffered in meters for fast O(1)
/// rejection of out-of-corridor reports.
class RouteBoundingBox {
  /// ~2.2 km degree buffer around visible camera bounds when culling markers so
  /// short pans do not cause pin pop-in.
  static const double defaultViewportMarkerMarginDeg = 0.02;

  /// Refresh threshold smaller than [defaultViewportMarkerMarginDeg] so moving
  /// or zooming out (e.g., fitting a Point A to B route) rebuilds culled
  /// markers before they can enter the visible screen area.
  static const double defaultViewportRefreshPaddingDeg = 0.012;

  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;

  const RouteBoundingBox({
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
  });

  factory RouteBoundingBox.fromPoints(
    List<LatLng> points, {
    double bufferMeters = RouteCorridorConfig.defaultCorridorMeters,
  }) {
    if (points.isEmpty) {
      return const RouteBoundingBox(minLat: 0, maxLat: 0, minLon: 0, maxLon: 0);
    }
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLon = points.first.longitude;
    double maxLon = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    // Use max(|minLat|, |maxLat|) so longitude padding never under-covers the
    // higher-latitude end of a long north-south route, plus a small safety pad.
    final double maxAbsLatRad = RoutePotholeAdvisor._toRad(
      math.max(minLat.abs(), maxLat.abs()).clamp(0.0, 89.0),
    );
    final double safeBuffer = math.max(0.0, bufferMeters) + 2.0;
    final double latPad = safeBuffer / 110540.0;
    final double lonDenom = math.max(1e-4, 111320.0 * math.cos(maxAbsLatRad));
    final double lonPad = safeBuffer / lonDenom;
    return RouteBoundingBox(
      minLat: minLat - latPad,
      maxLat: maxLat + latPad,
      minLon: minLon - lonPad,
      maxLon: maxLon + lonPad,
    );
  }

  bool contains(LatLng point) {
    return point.latitude >= minLat &&
        point.latitude <= maxLat &&
        point.longitude >= minLon &&
        point.longitude <= maxLon;
  }

  /// Whether [point] lies inside this box expanded by [marginDeg].
  bool containsWithMargin(
    LatLng point, {
    double marginDeg = defaultViewportMarkerMarginDeg,
  }) {
    return point.latitude >= minLat - marginDeg &&
        point.latitude <= maxLat + marginDeg &&
        point.longitude >= minLon - marginDeg &&
        point.longitude <= maxLon + marginDeg;
  }

  /// Whether [currentViewport] has moved or zoomed beyond this previously
  /// rendered box padded by [paddingDeg], requiring a marker cull refresh.
  bool needsViewportRefresh(
    RouteBoundingBox currentViewport, {
    double paddingDeg = defaultViewportRefreshPaddingDeg,
  }) {
    return currentViewport.minLat < minLat - paddingDeg ||
        currentViewport.maxLat > maxLat + paddingDeg ||
        currentViewport.minLon < minLon - paddingDeg ||
        currentViewport.maxLon > maxLon + paddingDeg;
  }
}

/// Single step maneuver metadata used to tag route segments with road names
/// when supplied by routing providers like OSRM/ORS.
class RouteStepRoadSpan {
  final String roadName;
  final LatLng location;

  const RouteStepRoadSpan({required this.roadName, required this.location});
}

/// A specific along-route traversal encounter with a verified pothole report.
///
/// Loop routes passing the same pothole twice generate two encounters with
/// distinct [encounterId] and [chainDistanceMeters] values so ahead warnings
/// stay accurate on every pass while distinct route totals count the defect once.
class RouteHazardEncounter {
  final String encounterId;
  final String canonicalKey;
  final RouteHazardInput hazard;
  final int segmentIndex;
  final double chainDistanceMeters;
  final double perpendicularDistanceMeters;
  final LatLng projectedPoint;
  final double segmentBearingDeg;
  final bool roadMatched;

  const RouteHazardEncounter({
    required this.encounterId,
    required this.canonicalKey,
    required this.hazard,
    required this.segmentIndex,
    required this.chainDistanceMeters,
    required this.perpendicularDistanceMeters,
    required this.projectedPoint,
    required this.segmentBearingDeg,
    required this.roadMatched,
  });
}

/// Summary metrics computed for a single road-following candidate route.
class RouteHazardSummary {
  final int routeIndex;
  final double distanceMeters;
  final double durationSeconds;
  final int distinctPotholeCount;

  /// Deduplicated sum of individual pothole detections across distinct sites
  /// along this route (excluding non-pothole cracks even when stored alongside
  /// potholes in a multi-defect report).
  final int reportedPotholeDetectionCount;
  final List<RouteHazardEncounter> potholeEncounters;
  final Map<String, int> otherDefectCounts;
  final double corridorMeters;

  /// True whenever carriageway-level or verified road-segment matching cannot
  /// rule out nearby service roads, flyovers, or opposite lanes.
  final bool isApproximate;
  final String roadMatchNote;

  const RouteHazardSummary({
    required this.routeIndex,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.distinctPotholeCount,
    this.reportedPotholeDetectionCount = 0,
    required this.potholeEncounters,
    required this.otherDefectCounts,
    required this.corridorMeters,
    required this.isApproximate,
    required this.roadMatchNote,
  });

  int get totalOtherDefectsCount =>
      otherDefectCounts.values.fold(0, (sum, c) => sum + c);

  String? get multiDetectionNote {
    if (reportedPotholeDetectionCount <= distinctPotholeCount) return null;
    return '$reportedPotholeDetectionCount pothole detections across '
        '$distinctPotholeCount reported '
        '${distinctPotholeCount == 1 ? 'location' : 'locations'}';
  }

  String get potholePhrase {
    if (distinctPotholeCount == 0)
      return 'No reported potholes along this route';
    return '$distinctPotholeCount reported '
        '${distinctPotholeCount == 1 ? 'pothole' : 'potholes'}';
  }

  String get shortPotholePhrase {
    if (distinctPotholeCount == 0) return '0 reported potholes';
    return '$distinctPotholeCount reported '
        '${distinctPotholeCount == 1 ? 'pothole' : 'potholes'}';
  }

  String formattedSummaryLine({String? formattedEta}) {
    final String km = RoutePotholeAdvisor.formatRouteDistance(distanceMeters);
    final String eta =
        formattedEta ?? RoutePotholeAdvisor.formatEtaMinutes(durationSeconds);
    final String potholePart = distinctPotholeCount == 0
        ? 'No reported potholes'
        : shortPotholePhrase;
    final String approxSuffix = isApproximate ? ' (approx.)' : '';
    return '$km · $eta · $potholePart$approxSuffix';
  }

  String get otherDefectsSummary {
    if (otherDefectCounts.isEmpty) return '';
    return otherDefectCounts.entries
        .map((e) => '${e.value} ${e.key}${e.value == 1 ? '' : 's'}')
        .join(', ');
  }
}

/// Precomputed spatial index built once per route update so live GPS fixes
/// perform fast windowed projections rather than re-scanning every report.
class PrecomputedRouteIndex {
  final int routeIndex;
  final List<LatLng> points;
  final List<double> cumulativeMeters;
  final List<double> segmentBearingsDeg;
  final List<String> segmentRoadNames;
  final RouteBoundingBox boundingBox;
  final RouteHazardSummary summary;

  const PrecomputedRouteIndex({
    required this.routeIndex,
    required this.points,
    required this.cumulativeMeters,
    required this.segmentBearingsDeg,
    required this.segmentRoadNames,
    required this.boundingBox,
    required this.summary,
  });

  double get totalLengthMeters =>
      cumulativeMeters.isEmpty ? 0.0 : cumulativeMeters.last;

  factory PrecomputedRouteIndex.build({
    required List<LatLng> route,
    required List<RouteHazardInput> hazards,
    int routeIndex = 0,
    double? routeDistanceMeters,
    double durationSeconds = 0.0,
    RouteCorridorConfig config = const RouteCorridorConfig(),
    List<RouteStepRoadSpan> steps = const [],
    bool assumeVerifiedRoadNetwork = false,
  }) {
    if (route.length < 2) {
      final double d = routeDistanceMeters ?? 0.0;
      return PrecomputedRouteIndex(
        routeIndex: routeIndex,
        points: route,
        cumulativeMeters: route.isEmpty ? const [] : const [0.0],
        segmentBearingsDeg: const [],
        segmentRoadNames: const [],
        boundingBox: RouteBoundingBox.fromPoints(
          route,
          bufferMeters: config.corridorMeters + 5.0,
        ),
        summary: RouteHazardSummary(
          routeIndex: routeIndex,
          distanceMeters: d,
          durationSeconds: durationSeconds,
          distinctPotholeCount: 0,
          reportedPotholeDetectionCount: 0,
          potholeEncounters: const [],
          otherDefectCounts: const {},
          corridorMeters: config.corridorMeters,
          isApproximate: !assumeVerifiedRoadNetwork,
          roadMatchNote: assumeVerifiedRoadNetwork
              ? 'Matched to road geometry'
              : 'Approximate (${config.corridorMeters.round()} m route corridor)',
        ),
      );
    }

    final cum = RoutePotholeAdvisor._cumulativeDistances(route);
    final double actualLength = routeDistanceMeters ?? cum.last;
    final bearings = List<double>.generate(
      route.length - 1,
      (i) => RoutePotholeAdvisor._bearingDeg(route[i], route[i + 1]),
      growable: false,
    );
    final segRoadNames = RoutePotholeAdvisor._mapStepsToSegments(route, steps);
    final box = RouteBoundingBox.fromPoints(
      route,
      bufferMeters: config.corridorMeters + 5.0,
    );

    final Set<String> distinctPotholeKeys = <String>{};
    final Map<String, int> potholeDetectionsByCanonical = <String, int>{};
    final Map<String, List<RouteHazardEncounter>> encountersByCanonical =
        <String, List<RouteHazardEncounter>>{};
    final Map<String, Set<String>> otherDefectKeysByType =
        <String, Set<String>>{};

    for (int hIdx = 0; hIdx < hazards.length; hIdx++) {
      final h = hazards[hIdx];
      if (!h.isEligibleForPublicRouteCount) continue;
      if (!box.contains(h.location) &&
          (h.rawLocation == null || !box.contains(h.rawLocation!))) {
        continue;
      }

      final String canonicalKey = h.explicitCanonicalKey ?? 'row:$hIdx';
      final _SegmentMatchCollection matches =
          RoutePotholeAdvisor._findRoutePassMatches(
            hazard: h,
            route: route,
            cumDist: cum,
            segmentBearings: bearings,
            segmentRoadNames: segRoadNames,
            config: config,
          );

      if (matches.passEncounters.isEmpty) continue;

      if (h.containsPotholeClass) {
        distinctPotholeKeys.add(canonicalKey);
        final int prevCount = potholeDetectionsByCanonical[canonicalKey] ?? 0;
        potholeDetectionsByCanonical[canonicalKey] = math.max(
          prevCount,
          h.resolvedPotholeDetectionCount,
        );
        final List<RouteHazardEncounter> passList = encountersByCanonical
            .putIfAbsent(canonicalKey, () => <RouteHazardEncounter>[]);
        for (final m in matches.passEncounters) {
          final cand = RouteHazardEncounter(
            encounterId:
                '$canonicalKey@${m.segmentIndex}:${m.chainDistanceMeters.round()}',
            canonicalKey: canonicalKey,
            hazard: h,
            segmentIndex: m.segmentIndex,
            chainDistanceMeters: m.chainDistanceMeters,
            perpendicularDistanceMeters: m.perpendicularDistanceMeters,
            projectedPoint: m.projectedPoint,
            segmentBearingDeg: m.segmentBearingDeg,
            roadMatched: m.roadMatched,
          );
          final int mergeIdx = passList.indexWhere(
            (e) =>
                (e.chainDistanceMeters - cand.chainDistanceMeters).abs() <=
                65.0,
          );
          if (mergeIdx >= 0) {
            final existing = passList[mergeIdx];
            final bool candBetter =
                (cand.roadMatched && !existing.roadMatched) ||
                (cand.roadMatched == existing.roadMatched &&
                    cand.perpendicularDistanceMeters <
                        existing.perpendicularDistanceMeters);
            if (candBetter) {
              passList[mergeIdx] = cand;
            }
          } else {
            passList.add(cand);
          }
        }
      }

      for (final defectLabel in h.nonPotholeDefectLabels) {
        otherDefectKeysByType
            .putIfAbsent(defectLabel, () => <String>{})
            .add(canonicalKey);
      }
    }

    final List<RouteHazardEncounter> encounters = encountersByCanonical.values
        .expand((list) => list)
        .toList();
    encounters.sort(
      (a, b) => a.chainDistanceMeters.compareTo(b.chainDistanceMeters),
    );
    final int matchedWithRoadVerifyCount = encounters
        .where((e) => e.roadMatched)
        .length;

    final Map<String, int> otherCounts = <String, int>{};
    for (final entry in otherDefectKeysByType.entries) {
      otherCounts[entry.key] = entry.value.length;
    }

    final bool allEncountersVerified =
        assumeVerifiedRoadNetwork ||
        (encounters.isNotEmpty &&
            matchedWithRoadVerifyCount == encounters.length) ||
        (encounters.isEmpty &&
            assumeVerifiedRoadNetwork &&
            segRoadNames.any((s) => s.isNotEmpty));

    final String matchNote = allEncountersVerified
        ? 'Matched to road geometry'
        : 'Approximate count (${config.corridorMeters.round()} m route corridor; nearby side roads or carriageways may require confirmation)';

    final int totalPotholeDetections = potholeDetectionsByCanonical.values.fold(
      0,
      (sum, c) => sum + c,
    );

    return PrecomputedRouteIndex(
      routeIndex: routeIndex,
      points: route,
      cumulativeMeters: cum,
      segmentBearingsDeg: bearings,
      segmentRoadNames: segRoadNames,
      boundingBox: box,
      summary: RouteHazardSummary(
        routeIndex: routeIndex,
        distanceMeters: actualLength,
        durationSeconds: durationSeconds,
        distinctPotholeCount: distinctPotholeKeys.length,
        reportedPotholeDetectionCount: totalPotholeDetections,
        potholeEncounters: List.unmodifiable(encounters),
        otherDefectCounts: Map.unmodifiable(otherCounts),
        corridorMeters: config.corridorMeters,
        isApproximate: !allEncountersVerified,
        roadMatchNote: matchNote,
      ),
    );
  }
}

/// Option row in route comparison tables and bottom sheets (up to 3 rows:
/// Fastest, Fewer reported potholes, Alternative).
class RouteComparisonOption {
  final int routeIndex;
  final String roleLabel;
  final String? viaSummary;
  final RouteHazardSummary summary;
  final int fewerPotholesThanFastest;
  final double extraSecondsVsFastest;
  final double extraMetersVsFastest;
  final bool withinDetourAllowance;
  final String tradeoffExplanation;

  const RouteComparisonOption({
    required this.routeIndex,
    required this.roleLabel,
    required this.viaSummary,
    required this.summary,
    required this.fewerPotholesThanFastest,
    required this.extraSecondsVsFastest,
    required this.extraMetersVsFastest,
    required this.withinDetourAllowance,
    required this.tradeoffExplanation,
  });
}

/// Complete alternative comparison evaluation for a destination query.
class RouteComparisonResult {
  final List<RouteComparisonOption> options;
  final RouteComparisonOption? fastestOption;
  final RouteComparisonOption? preferredSaferOption;
  final bool providerReturnedAlternatives;
  final String? statusMessage;
  final List<PrecomputedRouteIndex> routeIndices;

  const RouteComparisonResult({
    required this.options,
    required this.fastestOption,
    required this.preferredSaferOption,
    required this.providerReturnedAlternatives,
    this.statusMessage,
    this.routeIndices = const [],
  });

  bool get hasFewerPotholesOption => preferredSaferOption != null;
}

/// Recommendation to switch from the active route to an alternative route with
/// fewer calculated potholes along its path.
class RouteSwitchSuggestion {
  final int currentRouteIndex;
  final int recommendedRouteIndex;
  final int currentHazards;
  final int recommendedHazards;
  final int hazardsAvoided;
  final int extraMinutes;
  final double extraDistanceMeters;
  final bool withinDetourAllowance;

  const RouteSwitchSuggestion({
    required this.currentRouteIndex,
    required this.recommendedRouteIndex,
    required this.currentHazards,
    required this.recommendedHazards,
    required this.hazardsAvoided,
    required this.extraMinutes,
    required this.extraDistanceMeters,
    this.withinDetourAllowance = true,
  });

  String get routeLabel => 'Route ${recommendedRouteIndex + 1}';

  String get headline =>
      'Try $routeLabel • Avoids $hazardsAvoided hazard${hazardsAvoided == 1 ? '' : 's'}';

  String get tradeoffExplanation =>
      RoutePotholeAdvisor.buildTradeoffExplanation(
        fewerPotholes: hazardsAvoided,
        extraSeconds: extraMinutes * 60.0,
        extraMeters: extraDistanceMeters,
        withinAllowance: withinDetourAllowance,
      );

  String get detail {
    final String altSummary = recommendedHazards == 0
        ? '0 reported potholes'
        : '$recommendedHazards reported pothole${recommendedHazards == 1 ? '' : 's'}';
    final String curSummary =
        '$currentHazards on Route ${currentRouteIndex + 1}';
    final List<String> deltas = [];
    if (extraMinutes > 0) {
      deltas.add('+$extraMinutes min');
    } else if (extraMinutes < 0) {
      deltas.add('${extraMinutes.abs()} min faster');
    } else {
      deltas.add('same ETA');
    }
    if (extraDistanceMeters.abs() >= 100) {
      final km = extraDistanceMeters / 1000.0;
      deltas.add(
        km >= 0
            ? '+${km.toStringAsFixed(1)} km'
            : '-${km.abs().toStringAsFixed(1)} km',
      );
    }
    return '$routeLabel has $altSummary vs $curSummary (${deltas.join(', ')})';
  }
}

/// Live countdown state describing the nearest hazard ahead of the user.
class UpcomingHazardCountdown {
  final double distanceMeters;
  final String defectName;
  final String dpwhCode;
  final String barangay;
  final int potholeCount;
  final bool isOnActiveRoute;
  final LatLng location;
  final String? encounterId;
  final int remainingOnRoute;
  final int totalOnRoute;

  const UpcomingHazardCountdown({
    required this.distanceMeters,
    required this.defectName,
    required this.dpwhCode,
    required this.barangay,
    required this.potholeCount,
    required this.isOnActiveRoute,
    required this.location,
    this.encounterId,
    this.remainingOnRoute = 0,
    this.totalOnRoute = 0,
  });

  int get roundedMeters => distanceMeters.round().clamp(0, 99999);

  String get formattedAhead =>
      RoutePotholeAdvisor.formatDistanceAhead(distanceMeters);
}

enum NavigationHazardStatus {
  waitingForLocation,
  offRoute,
  hazardAhead,
  clearAhead,
}

/// Snapshot emitted on each GPS / simulation tick during active navigation.
class NavigationHazardState {
  final NavigationHazardStatus status;
  final double userChainMeters;
  final double distanceFromRouteMeters;
  final RouteHazardEncounter? nextEncounter;
  final double? distanceToNextMeters;
  final int remainingPotholeCount;
  final int totalRoutePotholeCount;
  final int remainingEncounterCount;
  final int totalRouteEncounterCount;
  final bool isLowAccuracy;
  final bool isStaleLocation;

  /// Non-null only on the exact update where the driver enters the alert
  /// trigger radius for a pothole encounter not yet announced this approach.
  final RouteHazardEncounter? alertTriggerToSpeak;
  final double? alertTriggerDistanceMeters;

  const NavigationHazardState({
    required this.status,
    required this.userChainMeters,
    required this.distanceFromRouteMeters,
    this.nextEncounter,
    this.distanceToNextMeters,
    required this.remainingPotholeCount,
    required this.totalRoutePotholeCount,
    this.remainingEncounterCount = 0,
    this.totalRouteEncounterCount = 0,
    this.isLowAccuracy = false,
    this.isStaleLocation = false,
    this.alertTriggerToSpeak,
    this.alertTriggerDistanceMeters,
  });

  String? get formattedDistanceAhead => distanceToNextMeters == null
      ? null
      : RoutePotholeAdvisor.formatDistanceAhead(distanceToNextMeters!);

  String get remainingBannerSubtitle {
    if (status == NavigationHazardStatus.offRoute) {
      return 'Updating route...';
    }
    if (status == NavigationHazardStatus.waitingForLocation) {
      return 'Waiting for location...';
    }
    if (remainingPotholeCount <= 0) {
      return 'No reported potholes ahead on this route.';
    }
    return '$remainingPotholeCount reported '
        '${remainingPotholeCount == 1 ? 'pothole' : 'potholes'} '
        'remaining on your route';
  }
}

/// Stateful tracker operating on a [PrecomputedRouteIndex] for smooth,
/// loop-safe, hysteresis-protected along-route hazard warnings and voice cues.
class NavigationHazardTracker {
  PrecomputedRouteIndex _index;
  double _smoothedChainMeters = 0.0;
  bool _hasLock = false;
  LatLng? _lastPosition;
  DateTime? _lastFixTimestamp;
  final Set<String> _passedEncounterIds = <String>{};
  final Set<String> _alertedEncounterIds = <String>{};

  NavigationHazardTracker(this._index);

  PrecomputedRouteIndex get index => _index;

  static bool _sameRouteGeometry(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length || a.isEmpty) return false;
    final int len = a.length;
    final List<int> probeIndices = <int>{
      0,
      len ~/ 4,
      len ~/ 2,
      (3 * len) ~/ 4,
      len - 1,
    }.toList(growable: false);
    for (final i in probeIndices) {
      if ((a[i].latitude - b[i].latitude).abs() > 5e-5 ||
          (a[i].longitude - b[i].longitude).abs() > 5e-5) {
        return false;
      }
    }
    return true;
  }

  void replaceRouteIndex(
    PrecomputedRouteIndex nextIndex, {
    bool keepAlerts = false,
    bool? preserveProgress,
  }) {
    final bool retainProgress =
        preserveProgress ?? _sameRouteGeometry(_index.points, nextIndex.points);
    if (retainProgress && _hasLock) {
      final prevEncountersById = <String, RouteHazardEncounter>{
        for (final e in _index.summary.potholeEncounters) e.encounterId: e,
      };
      final List<({String canonicalKey, double chainMeters})> prevPassedMeta = [
        for (final id in _passedEncounterIds)
          if (prevEncountersById[id] != null)
            (
              canonicalKey: prevEncountersById[id]!.canonicalKey,
              chainMeters: prevEncountersById[id]!.chainDistanceMeters,
            ),
      ];
      final Set<String> nextPassed = <String>{};
      for (final e in nextIndex.summary.potholeEncounters) {
        if (_passedEncounterIds.contains(e.encounterId) ||
            prevPassedMeta.any(
              (m) =>
                  m.canonicalKey == e.canonicalKey &&
                  (m.chainMeters - e.chainDistanceMeters).abs() <= 25.0,
            )) {
          nextPassed.add(e.encounterId);
        }
      }
      _index = nextIndex;
      _passedEncounterIds
        ..clear()
        ..addAll(nextPassed);
      if (!keepAlerts) {
        _alertedEncounterIds.clear();
      }
      return;
    }

    _index = nextIndex;
    _smoothedChainMeters = 0.0;
    _hasLock = false;
    _lastPosition = null;
    _lastFixTimestamp = null;
    _passedEncounterIds.clear();
    if (!keepAlerts) {
      _alertedEncounterIds.clear();
    }
  }

  void reset() {
    _smoothedChainMeters = 0.0;
    _hasLock = false;
    _lastPosition = null;
    _lastFixTimestamp = null;
    _passedEncounterIds.clear();
    _alertedEncounterIds.clear();
  }

  NavigationHazardState update({
    required LatLng? position,
    DateTime? timestamp,
    double? gpsAccuracyMeters,
    double? headingDeg,
    double? speedMps,
    double baseVoiceAlertMeters = 250.0,
    double offRouteThresholdMeters = RouteCorridorConfig.defaultOffRouteMeters,
    DateTime? now,
  }) {
    final int totalCount = _index.summary.distinctPotholeCount;
    final int totalEncounters = _index.summary.potholeEncounters.length;
    if (position == null) {
      return NavigationHazardState(
        status: NavigationHazardStatus.waitingForLocation,
        userChainMeters: _smoothedChainMeters,
        distanceFromRouteMeters: double.infinity,
        remainingPotholeCount: totalCount,
        totalRoutePotholeCount: totalCount,
        remainingEncounterCount: totalEncounters,
        totalRouteEncounterCount: totalEncounters,
      );
    }

    final DateTime evalNow = now ?? DateTime.now();
    final DateTime fixTime = timestamp ?? evalNow;
    final bool isStale = evalNow.difference(fixTime).inSeconds > 15;
    final double accuracy = gpsAccuracyMeters ?? 10.0;
    final bool isLowAcc = isStale || accuracy > 35.0;

    if (_index.points.length < 2) {
      return NavigationHazardState(
        status: NavigationHazardStatus.clearAhead,
        userChainMeters: 0.0,
        distanceFromRouteMeters: 0.0,
        remainingPotholeCount: 0,
        totalRoutePotholeCount: 0,
        remainingEncounterCount: 0,
        totalRouteEncounterCount: 0,
        isLowAccuracy: isLowAcc,
        isStaleLocation: isStale,
      );
    }

    final double dtSeconds = _lastFixTimestamp == null
        ? 1.0
        : math.max(
            0.25,
            fixTime.difference(_lastFixTimestamp!).inMilliseconds / 1000.0,
          );
    final double maxForwardStep = math.max(
      260.0,
      ((speedMps ?? 15.0) * dtSeconds * 2.5) + accuracy * 2.0,
    );

    final _PolylineProjection proj = _projectWithContinuity(
      position: position,
      headingDeg: headingDeg,
      speedMps: speedMps,
      maxForwardWindowMeters: maxForwardStep,
      corridorMeters: _index.summary.corridorMeters,
    );

    final double offRouteLimit = math.max(
      offRouteThresholdMeters,
      _index.summary.corridorMeters + math.min(accuracy, 40.0) * 1.1,
    );

    if (proj.perpDistanceMeters > offRouteLimit) {
      return NavigationHazardState(
        status: NavigationHazardStatus.offRoute,
        userChainMeters: _smoothedChainMeters,
        distanceFromRouteMeters: proj.perpDistanceMeters,
        remainingPotholeCount: _countUnpassedRemainingDistinct(),
        totalRoutePotholeCount: totalCount,
        remainingEncounterCount: _countUnpassedRemainingEncounters(),
        totalRouteEncounterCount: totalEncounters,
        isLowAccuracy: isLowAcc,
        isStaleLocation: isStale,
      );
    }

    // Jitter damping: ignore tiny backward/noisy hops while nearly stationary.
    final double movedMeters = _lastPosition == null
        ? 999.0
        : RoutePotholeAdvisor.distanceMetersBetween(_lastPosition!, position);
    final double deadbandMeters = math.max(
      3.0,
      math.min(12.0, accuracy * 0.25),
    );
    double candidateChain = proj.chainDistanceMeters;

    if (!_hasLock) {
      _smoothedChainMeters = candidateChain;
      _hasLock = true;
    } else {
      final double delta = candidateChain - _smoothedChainMeters;
      final bool isLowSpeedStationary =
          (speedMps != null && speedMps < 1.2) && movedMeters < deadbandMeters;
      if (isLowSpeedStationary && delta.abs() < 18.0) {
        candidateChain = _smoothedChainMeters;
      } else if (delta < 0 && delta.abs() <= 14.0) {
        // Prevent minor GPS back-jitter from rolling chainage backward.
        candidateChain = _smoothedChainMeters;
      } else if (delta.abs() < 45.0) {
        // Gentle exponential smoothing reduces visual flicker without lag.
        _smoothedChainMeters =
            _smoothedChainMeters * 0.25 + candidateChain * 0.75;
      } else {
        _smoothedChainMeters = candidateChain;
      }
    }

    _lastPosition = position;
    _lastFixTimestamp = fixTime;

    // Hysteresis prevents passed hazards from flipping back on minor drift.
    final double passHysteresis = math.max(
      15.0,
      math.min(28.0, accuracy * 0.6),
    );
    for (final e in _index.summary.potholeEncounters) {
      if (_smoothedChainMeters - e.chainDistanceMeters > passHysteresis) {
        _passedEncounterIds.add(e.encounterId);
      }
    }

    final List<RouteHazardEncounter> remainingEncounters = _index
        .summary
        .potholeEncounters
        .where(
          (e) =>
              !_passedEncounterIds.contains(e.encounterId) &&
              (e.chainDistanceMeters - _smoothedChainMeters) >= -3.0,
        )
        .toList(growable: false);

    if (remainingEncounters.isEmpty) {
      return NavigationHazardState(
        status: NavigationHazardStatus.clearAhead,
        userChainMeters: _smoothedChainMeters,
        distanceFromRouteMeters: proj.perpDistanceMeters,
        remainingPotholeCount: 0,
        totalRoutePotholeCount: totalCount,
        remainingEncounterCount: 0,
        totalRouteEncounterCount: totalEncounters,
        isLowAccuracy: isLowAcc,
        isStaleLocation: isStale,
      );
    }

    final int remainingDistinct = remainingEncounters
        .map((e) => e.canonicalKey)
        .toSet()
        .length;
    final RouteHazardEncounter next = remainingEncounters.first;
    final double distAhead = math.max(
      0.0,
      next.chainDistanceMeters - _smoothedChainMeters,
    );

    final double triggerRadius = RoutePotholeAdvisor.computeAlertTriggerMeters(
      baseTriggerMeters: baseVoiceAlertMeters,
      speedMps: speedMps,
      gpsAccuracyMeters: gpsAccuracyMeters,
    );

    RouteHazardEncounter? triggerToSpeak;
    if (distAhead <= triggerRadius &&
        !_alertedEncounterIds.contains(next.encounterId)) {
      _alertedEncounterIds.add(next.encounterId);
      triggerToSpeak = next;
    }

    return NavigationHazardState(
      status: NavigationHazardStatus.hazardAhead,
      userChainMeters: _smoothedChainMeters,
      distanceFromRouteMeters: proj.perpDistanceMeters,
      nextEncounter: next,
      distanceToNextMeters: distAhead,
      remainingPotholeCount: remainingDistinct,
      totalRoutePotholeCount: totalCount,
      remainingEncounterCount: remainingEncounters.length,
      totalRouteEncounterCount: totalEncounters,
      isLowAccuracy: isLowAcc,
      isStaleLocation: isStale,
      alertTriggerToSpeak: triggerToSpeak,
      alertTriggerDistanceMeters: triggerToSpeak == null ? null : distAhead,
    );
  }

  int _countUnpassedRemainingDistinct() {
    return _index.summary.potholeEncounters
        .where((e) => !_passedEncounterIds.contains(e.encounterId))
        .map((e) => e.canonicalKey)
        .toSet()
        .length;
  }

  int _countUnpassedRemainingEncounters() {
    return _index.summary.potholeEncounters
        .where((e) => !_passedEncounterIds.contains(e.encounterId))
        .length;
  }

  _PolylineProjection _projectWithContinuity({
    required LatLng position,
    required double? headingDeg,
    required double? speedMps,
    required double maxForwardWindowMeters,
    required double corridorMeters,
  }) {
    final points = _index.points;
    final cum = _index.cumulativeMeters;
    final bearings = _index.segmentBearingsDeg;
    final bool useHeading =
        headingDeg != null &&
        headingDeg >= 0 &&
        (speedMps == null || speedMps >= 2.0);

    _PolylineProjection evaluateSubset({required bool windowed}) {
      double bestScore = double.infinity;
      double bestPerp = double.infinity;
      int bestSeg = 0;
      LatLng bestPt = points.first;
      double bestChain = 0.0;

      for (int i = 0; i < points.length - 1; i++) {
        if (windowed && _hasLock) {
          final double segStartChain = cum[i];
          final double segEndChain = cum[i + 1];
          if (segEndChain < _smoothedChainMeters - 45.0 ||
              segStartChain > _smoothedChainMeters + maxForwardWindowMeters) {
            continue;
          }
        }
        final proj = RoutePotholeAdvisor._projectPointOnSegment(
          position,
          points[i],
          points[i + 1],
        );
        final double perp = RoutePotholeAdvisor.distanceMetersBetween(
          position,
          proj.point,
        );
        double score = perp;
        if (useHeading && i < bearings.length) {
          final double diff = RoutePotholeAdvisor._angularDiffDeg(
            headingDeg,
            bearings[i],
          );
          if (diff > 75.0) {
            // Discourage snapping onto opposite/crossed loop leg.
            score += 45.0 + (diff - 75.0) * 0.5;
          }
        }
        if (score < bestScore) {
          bestScore = score;
          bestPerp = perp;
          bestSeg = i;
          bestPt = proj.point;
          bestChain = cum[i] + (cum[i + 1] - cum[i]) * proj.t;
        }
      }

      return _PolylineProjection(
        segmentIndex: bestSeg,
        point: bestPt,
        perpDistanceMeters: bestPerp,
        chainDistanceMeters: bestChain,
      );
    }

    if (_hasLock) {
      final local = evaluateSubset(windowed: true);
      if (local.perpDistanceMeters <= math.max(corridorMeters, 28.0)) {
        return local;
      }
    }
    return evaluateSubset(windowed: false);
  }
}

/// Pure-Dart spatial calculations, route pothole counting, alternative trade-off
/// evaluation, and live hazard countdown logic shared between Web and Mobile.
class RoutePotholeAdvisor {
  static const double _earthRadiusMeters = 6371000.0;

  /// Great-circle distance in meters using the haversine formula.
  static double distanceMetersBetween(LatLng a, LatLng b) {
    final dLat = _toRad(b.latitude - a.latitude);
    final dLon = _toRad(b.longitude - a.longitude);
    final lat1 = _toRad(a.latitude);
    final lat2 = _toRad(b.latitude);
    final sinDLat = math.sin(dLat / 2.0);
    final sinDLon = math.sin(dLon / 2.0);
    final h =
        sinDLat * sinDLat + math.cos(lat1) * math.cos(lat2) * sinDLon * sinDLon;
    return 2.0 *
        _earthRadiusMeters *
        math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  /// Closest perpendicular distance in meters from [p] to segment [a]-[b].
  static double distancePointToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    final proj = _projectPointOnSegment(p, a, b);
    return distanceMetersBetween(p, proj.point);
  }

  /// True when [point] lies within [toleranceMeters] of any segment in [route].
  static bool isPointOnRoute(
    LatLng point,
    List<LatLng> route,
    double toleranceMeters,
  ) {
    if (route.length < 2) return false;
    final box = RouteBoundingBox.fromPoints(
      route,
      bufferMeters: toleranceMeters + 5.0,
    );
    if (!box.contains(point)) return false;
    for (int i = 0; i < route.length - 1; i++) {
      if (distancePointToSegmentMeters(point, route[i], route[i + 1]) <=
          toleranceMeters) {
        return true;
      }
    }
    return false;
  }

  /// Counts how many hazard locations lie within [toleranceMeters] of each route.
  static List<int> countHazardsPerRoute({
    required List<List<LatLng>> routes,
    required List<LatLng> hazards,
    double toleranceMeters = RouteCorridorConfig.defaultCorridorMeters,
  }) {
    return routes
        .map((route) {
          final box = RouteBoundingBox.fromPoints(
            route,
            bufferMeters: toleranceMeters + 5.0,
          );
          int count = 0;
          for (final h in hazards) {
            if (!box.contains(h)) continue;
            if (isPointOnRoute(h, route, toleranceMeters)) {
              count++;
            }
          }
          return count;
        })
        .toList(growable: false);
  }

  /// Evaluates distinct, approved, unresolved pothole counts (plus separated
  /// non-pothole defects) across candidate routes and ranks up to 3 comparison
  /// options (`Fastest`, `Fewer reported potholes`, `Alternative`).
  static RouteComparisonResult evaluateAlternatives({
    required List<List<LatLng>> routes,
    required List<double> distancesMeters,
    required List<double> durationsSeconds,
    required List<RouteHazardInput> hazards,
    List<String?> viaSummaries = const [],
    List<List<RouteStepRoadSpan>> stepsByRoute = const [],
    RouteCorridorConfig corridorConfig = const RouteCorridorConfig(),
    RouteDetourConfig detourConfig = const RouteDetourConfig(),
    bool assumeVerifiedRoadNetwork = false,
  }) {
    if (routes.isEmpty) {
      return const RouteComparisonResult(
        options: [],
        fastestOption: null,
        preferredSaferOption: null,
        providerReturnedAlternatives: false,
        statusMessage: 'No route available.',
      );
    }

    final List<PrecomputedRouteIndex> builtIndices = <PrecomputedRouteIndex>[];
    final List<RouteHazardSummary> summaries = <RouteHazardSummary>[];
    for (int i = 0; i < routes.length; i++) {
      final index = PrecomputedRouteIndex.build(
        route: routes[i],
        hazards: hazards,
        routeIndex: i,
        routeDistanceMeters: i < distancesMeters.length
            ? distancesMeters[i]
            : null,
        durationSeconds: i < durationsSeconds.length
            ? durationsSeconds[i]
            : 0.0,
        config: corridorConfig,
        steps: i < stepsByRoute.length ? stepsByRoute[i] : const [],
        assumeVerifiedRoadNetwork: assumeVerifiedRoadNetwork,
      );
      builtIndices.add(index);
      summaries.add(index.summary);
    }

    // Identify the fastest candidate as baseline.
    int fastestIdx = 0;
    double bestDur = summaries.first.durationSeconds;
    for (int i = 1; i < summaries.length; i++) {
      if (summaries[i].durationSeconds < bestDur) {
        bestDur = summaries[i].durationSeconds;
        fastestIdx = i;
      }
    }
    final fastest = summaries[fastestIdx];

    // Identify best candidate within detour allowance with strictly fewer potholes.
    int? saferWithinAllowanceIdx;
    int lowestCountAllowed = fastest.distinctPotholeCount;
    double bestSaferDur = double.infinity;
    for (int i = 0; i < summaries.length; i++) {
      if (i == fastestIdx) continue;
      final s = summaries[i];
      if (s.distinctPotholeCount >= fastest.distinctPotholeCount) continue;
      final bool allowed = detourConfig.isWithinAllowance(
        baselineDurationSeconds: fastest.durationSeconds,
        candidateDurationSeconds: s.durationSeconds,
        baselineDistanceMeters: fastest.distanceMeters,
        candidateDistanceMeters: s.distanceMeters,
      );
      if (!allowed) continue;
      if (s.distinctPotholeCount < lowestCountAllowed ||
          (s.distinctPotholeCount == lowestCountAllowed &&
              s.durationSeconds < bestSaferDur)) {
        lowestCountAllowed = s.distinctPotholeCount;
        bestSaferDur = s.durationSeconds;
        saferWithinAllowanceIdx = i;
      }
    }

    // Build ordered indices (up to 3 useful options): Fastest -> Fewer potholes -> Alternative.
    final List<int> orderedIndices = <int>[fastestIdx];
    if (saferWithinAllowanceIdx != null) {
      orderedIndices.add(saferWithinAllowanceIdx);
    }
    final List<int> remaining = [
      for (int i = 0; i < summaries.length; i++)
        if (!orderedIndices.contains(i)) i,
    ];
    remaining.sort((a, b) {
      final int cmpCount = summaries[a].distinctPotholeCount.compareTo(
        summaries[b].distinctPotholeCount,
      );
      if (cmpCount != 0) return cmpCount;
      return summaries[a].durationSeconds.compareTo(
        summaries[b].durationSeconds,
      );
    });
    for (final idx in remaining) {
      if (orderedIndices.length >= 3) break;
      orderedIndices.add(idx);
    }

    final List<RouteComparisonOption> options = <RouteComparisonOption>[];
    RouteComparisonOption? fastestOpt;
    RouteComparisonOption? saferOpt;

    for (final idx in orderedIndices) {
      final s = summaries[idx];
      final int fewer = fastest.distinctPotholeCount - s.distinctPotholeCount;
      final double extraSec = s.durationSeconds - fastest.durationSeconds;
      final double extraMeters = s.distanceMeters - fastest.distanceMeters;
      final bool withinAllowance = idx == fastestIdx
          ? true
          : detourConfig.isWithinAllowance(
              baselineDurationSeconds: fastest.durationSeconds,
              candidateDurationSeconds: s.durationSeconds,
              baselineDistanceMeters: fastest.distanceMeters,
              candidateDistanceMeters: s.distanceMeters,
            );

      final String roleLabel = idx == fastestIdx
          ? 'Fastest'
          : (idx == saferWithinAllowanceIdx
                ? 'Fewer reported potholes'
                : 'Alternative');

      final String tradeoff = idx == fastestIdx
          ? 'Fastest route by estimated travel time'
          : buildTradeoffExplanation(
              fewerPotholes: fewer,
              extraSeconds: extraSec,
              extraMeters: extraMeters,
              withinAllowance: withinAllowance,
            );

      final opt = RouteComparisonOption(
        routeIndex: idx,
        roleLabel: roleLabel,
        viaSummary: idx < viaSummaries.length ? viaSummaries[idx] : null,
        summary: s,
        fewerPotholesThanFastest: fewer,
        extraSecondsVsFastest: extraSec,
        extraMetersVsFastest: extraMeters,
        withinDetourAllowance: withinAllowance,
        tradeoffExplanation: tradeoff,
      );
      options.add(opt);
      if (idx == fastestIdx) fastestOpt = opt;
      if (idx == saferWithinAllowanceIdx) saferOpt = opt;
    }

    String? message;
    if (saferOpt == null) {
      if (routes.length <= 1) {
        message =
            'No route with fewer reported potholes was found (only one drivable route returned by provider).';
      } else if (summaries.any(
        (s) => s.distinctPotholeCount < fastest.distinctPotholeCount,
      )) {
        message =
            'No route with fewer reported potholes was found within the detour limit.';
      } else {
        message = 'No route with fewer reported potholes was found.';
      }
    }

    return RouteComparisonResult(
      options: List.unmodifiable(options),
      fastestOption: fastestOpt,
      preferredSaferOption: saferOpt,
      providerReturnedAlternatives: routes.length > 1,
      statusMessage: message,
      routeIndices: List.unmodifiable(builtIndices),
    );
  }

  /// Generates readable tradeoff text such as
  /// `"4 fewer reported potholes · approximately 3 minutes longer"`.
  static String buildTradeoffExplanation({
    required int fewerPotholes,
    required double extraSeconds,
    double extraMeters = 0.0,
    bool withinAllowance = true,
  }) {
    final String potholePart;
    if (fewerPotholes > 0) {
      potholePart =
          '$fewerPotholes fewer reported ${fewerPotholes == 1 ? 'pothole' : 'potholes'}';
    } else if (fewerPotholes == 0) {
      potholePart = 'Same number of reported potholes';
    } else {
      final int more = fewerPotholes.abs();
      potholePart = '$more more reported ${more == 1 ? 'pothole' : 'potholes'}';
    }

    final int extraMin = (extraSeconds / 60.0).round();
    final String timePart;
    if (extraMin > 0) {
      timePart =
          'approximately $extraMin ${extraMin == 1 ? 'minute' : 'minutes'} longer';
    } else if (extraMin < 0) {
      final int saved = extraMin.abs();
      timePart =
          'approximately $saved ${saved == 1 ? 'minute' : 'minutes'} faster';
    } else if (extraMeters.abs() >= 150.0) {
      final String km = (extraMeters.abs() / 1000.0).toStringAsFixed(1);
      timePart = extraMeters >= 0 ? '+$km km' : '-$km km';
    } else {
      timePart = 'similar travel time';
    }

    if (!withinAllowance && fewerPotholes > 0) {
      return '$potholePart · $timePart (long detour)';
    }
    return '$potholePart · $timePart';
  }

  /// Formats route distance cleanly in meters or kilometers.
  static String formatRouteDistance(double distanceMeters) {
    if (distanceMeters <= 0) return '0.0 km';
    if (distanceMeters < 950) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000.0).toStringAsFixed(1)} km';
  }

  /// Formats estimated travel time concisely (e.g., `14 min`, `1 hr 5 min`).
  static String formatEtaMinutes(double durationSeconds) {
    final int totalMins = (durationSeconds / 60.0).round().clamp(1, 9999);
    if (totalMins < 60) return '$totalMins min';
    final int hrs = totalMins ~/ 60;
    final int mins = totalMins % 60;
    return mins == 0 ? '$hrs hr' : '$hrs hr $mins min';
  }

  /// Formats live distance ahead (`350 m ahead` for <1 km, `1.2 km ahead` for >=1 km).
  static String formatDistanceAhead(double meters) {
    final double clamped = math.max(0.0, meters);
    if (clamped < 1000.0) {
      final int m = clamped.round();
      if (m < 10) return 'At pothole';
      return '$m m ahead';
    }
    return '${(clamped / 1000.0).toStringAsFixed(1)} km ahead';
  }

  /// Computes a speed- and GPS-accuracy-adapted voice/alert trigger threshold.
  static double computeAlertTriggerMeters({
    double baseTriggerMeters = 250.0,
    double? speedMps,
    double? gpsAccuracyMeters,
  }) {
    double distance = baseTriggerMeters;
    if (speedMps != null && speedMps > 0.5) {
      // ~12-15 s lookahead scaled between slow urban streets and fast highways.
      if (speedMps >= 14.0) {
        distance = math.max(baseTriggerMeters, 350.0);
      } else if (speedMps >= 7.0) {
        distance = math.max(baseTriggerMeters, 250.0);
      } else {
        distance = math.min(baseTriggerMeters, 180.0);
      }
    }
    if (gpsAccuracyMeters != null && gpsAccuracyMeters > 15.0) {
      distance += math.min(60.0, (gpsAccuracyMeters - 15.0) * 0.75);
    }
    return distance.clamp(90.0, 500.0);
  }

  /// Formats natural spoken announcement (e.g. `"Reported pothole ahead in 300 meters."`).
  static String formatVoiceAlertAnnouncement(double distanceMeters) {
    final double clamped = math.max(10.0, distanceMeters);
    if (clamped < 1000.0) {
      int spokenMeters;
      if (clamped >= 100.0) {
        spokenMeters = ((clamped / 50.0).round() * 50).clamp(50, 950);
      } else {
        spokenMeters = ((clamped / 10.0).round() * 10).clamp(10, 90);
      }
      return 'Reported pothole ahead in $spokenMeters meters.';
    }
    final String km = (clamped / 1000.0).toStringAsFixed(1);
    return 'Reported pothole ahead in $km kilometers.';
  }

  /// Suggests an alternate route when another candidate path has strictly fewer
  /// potholes than [currentRouteIndex] within [detourConfig] allowance.
  static RouteSwitchSuggestion? buildSwitchSuggestion({
    required int currentRouteIndex,
    required List<int> hazardCounts,
    required List<double> distancesMeters,
    required List<double> durationsSeconds,
    RouteDetourConfig detourConfig = const RouteDetourConfig(),
  }) {
    if (hazardCounts.length <= 1 ||
        currentRouteIndex < 0 ||
        currentRouteIndex >= hazardCounts.length) {
      return null;
    }

    final int currentHazards = hazardCounts[currentRouteIndex];
    if (currentHazards <= 0) return null;

    final double curDur = currentRouteIndex < durationsSeconds.length
        ? durationsSeconds[currentRouteIndex]
        : 0.0;
    final double curDist = currentRouteIndex < distancesMeters.length
        ? distancesMeters[currentRouteIndex]
        : 0.0;

    int? bestAllowedIdx;
    int lowestAllowedHazards = currentHazards;
    double bestAllowedDuration = double.infinity;

    for (int i = 0; i < hazardCounts.length; i++) {
      if (i == currentRouteIndex) continue;
      final int c = hazardCounts[i];
      if (c >= currentHazards) continue;
      final double dur = i < durationsSeconds.length
          ? durationsSeconds[i]
          : double.infinity;
      final double dist = i < distancesMeters.length
          ? distancesMeters[i]
          : curDist;
      final bool withinAllowance = curDur <= 0
          ? true
          : detourConfig.isWithinAllowance(
              baselineDurationSeconds: curDur,
              candidateDurationSeconds: dur,
              baselineDistanceMeters: curDist,
              candidateDistanceMeters: dist,
            );
      if (!withinAllowance) continue;

      if (c < lowestAllowedHazards ||
          (c == lowestAllowedHazards && dur < bestAllowedDuration)) {
        lowestAllowedHazards = c;
        bestAllowedIdx = i;
        bestAllowedDuration = dur;
      }
    }

    if (bestAllowedIdx == null || lowestAllowedHazards >= currentHazards) {
      return null;
    }

    final double recDur = bestAllowedIdx < durationsSeconds.length
        ? durationsSeconds[bestAllowedIdx]
        : curDur;
    final double recDist = bestAllowedIdx < distancesMeters.length
        ? distancesMeters[bestAllowedIdx]
        : curDist;

    return RouteSwitchSuggestion(
      currentRouteIndex: currentRouteIndex,
      recommendedRouteIndex: bestAllowedIdx,
      currentHazards: currentHazards,
      recommendedHazards: lowestAllowedHazards,
      hazardsAvoided: currentHazards - lowestAllowedHazards,
      extraMinutes: ((recDur - curDur) / 60.0).round(),
      extraDistanceMeters: recDist - curDist,
      withinDetourAllowance: true,
    );
  }

  /// Computes cumulative polyline chain distance from [userPos] forward along
  /// [activeRoute] to the nearest upcoming pothole hazard, or falls back to
  /// nearby hazards within [roamingRadiusMeters] when no active route is supplied.
  static UpcomingHazardCountdown? findUpcomingHazard({
    required LatLng userPos,
    required List<RouteHazardInput> hazards,
    List<LatLng>? activeRoute,
    bool forceFromRouteStart = false,
    double routeToleranceMeters = RouteCorridorConfig.defaultCorridorMeters,
    double roamingRadiusMeters = 600.0,
    double offRouteUserThresholdMeters =
        RouteCorridorConfig.defaultOffRouteMeters,
  }) {
    final List<RouteHazardInput> eligible = hazards
        .where((h) => h.isEligibleForPublicRouteCount && h.containsPotholeClass)
        .toList(growable: false);
    if (eligible.isEmpty) return null;

    if (activeRoute != null && activeRoute.length >= 2) {
      final PrecomputedRouteIndex index = PrecomputedRouteIndex.build(
        route: activeRoute,
        hazards: eligible,
        config: RouteCorridorConfig(corridorMeters: routeToleranceMeters),
      );
      double userChainDist = 0.0;

      if (!forceFromRouteStart) {
        final userProj = _projectOntoPolyline(
          userPos,
          activeRoute,
          index.cumulativeMeters,
        );
        if (userProj.perpDistanceMeters <= offRouteUserThresholdMeters) {
          userChainDist = userProj.chainDistanceMeters;
        }
      }

      final List<RouteHazardEncounter> ahead = index.summary.potholeEncounters
          .where((e) => (e.chainDistanceMeters - userChainDist) >= -3.0)
          .toList(growable: false);
      if (ahead.isEmpty) return null;

      final first = ahead.first;
      final double aheadMeters = math.max(
        0.0,
        first.chainDistanceMeters - userChainDist,
      );
      return UpcomingHazardCountdown(
        distanceMeters: aheadMeters,
        defectName: first.hazard.defectName,
        dpwhCode: first.hazard.dpwhCode,
        barangay: first.hazard.barangay,
        potholeCount: first.hazard.resolvedPotholeDetectionCount > 0
            ? first.hazard.resolvedPotholeDetectionCount
            : first.hazard.potholeCount,
        isOnActiveRoute: true,
        location: first.hazard.location,
        encounterId: first.encounterId,
        remainingOnRoute: ahead.map((e) => e.canonicalKey).toSet().length,
        totalOnRoute: index.summary.distinctPotholeCount,
      );
    }

    // Free-roaming mode: notify when a pothole hazard sits within radius.
    UpcomingHazardCountdown? nearest;
    double minDist = double.infinity;
    for (final h in eligible) {
      final d = distanceMetersBetween(userPos, h.location);
      if (d <= roamingRadiusMeters && d < minDist) {
        minDist = d;
        nearest = UpcomingHazardCountdown(
          distanceMeters: d,
          defectName: h.defectName,
          dpwhCode: h.dpwhCode,
          barangay: h.barangay,
          potholeCount: h.potholeCount,
          isOnActiveRoute: false,
          location: h.location,
        );
      }
    }
    return nearest;
  }

  /// Generates perpendicular bypass `via` waypoints around the first hazard
  /// lying on [primaryRoute] so routing engines can discover an alternate street
  /// when default `alternatives=3` only emits one path.
  static List<LatLng> buildAvoidanceWaypoints({
    required List<LatLng> primaryRoute,
    required List<LatLng> hazards,
    double routeToleranceMeters = RouteCorridorConfig.defaultCorridorMeters,
    double lateralOffsetMeters = 420.0,
  }) {
    if (primaryRoute.length < 3 || hazards.isEmpty) return const [];
    final cum = _cumulativeDistances(primaryRoute);
    final totalDist = cum.last;
    if (totalDist < 800.0) return const [];

    _PolylineProjection? chosenProj;
    for (final h in hazards) {
      final proj = _projectOntoPolyline(h, primaryRoute, cum);
      if (proj.perpDistanceMeters > routeToleranceMeters) continue;
      if (proj.chainDistanceMeters < 200.0 ||
          totalDist - proj.chainDistanceMeters < 200.0) {
        continue;
      }
      if (chosenProj == null ||
          proj.chainDistanceMeters < chosenProj.chainDistanceMeters) {
        chosenProj = proj;
      }
    }
    if (chosenProj == null) return const [];

    final segStart = primaryRoute[chosenProj.segmentIndex];
    final segEnd = primaryRoute[chosenProj.segmentIndex + 1];
    final latRefRad = _toRad((segStart.latitude + segEnd.latitude) / 2.0);
    const metersPerDegLat = 110540.0;
    final metersPerDegLon = 111320.0 * math.cos(latRefRad);
    if (metersPerDegLon.abs() < 1e-6) return const [];

    final dx = (segEnd.longitude - segStart.longitude) * metersPerDegLon;
    final dy = (segEnd.latitude - segStart.latitude) * metersPerDegLat;
    final segLen = math.sqrt(dx * dx + dy * dy);
    if (segLen < 1e-3) return const [];

    final ux = -dy / segLen;
    final uy = dx / segLen;

    LatLng offsetBy(double signedMeters) {
      return LatLng(
        chosenProj!.point.latitude + (uy * signedMeters) / metersPerDegLat,
        chosenProj.point.longitude + (ux * signedMeters) / metersPerDegLon,
      );
    }

    return [offsetBy(lateralOffsetMeters), offsetBy(-lateralOffsetMeters)];
  }

  /// Checks whether [candidate] follows a genuinely different road corridor than
  /// every route already in [existing] without taking an excessive detour.
  static bool isDistinctAlternateRoute(
    List<LatLng> candidate,
    List<List<LatLng>> existing, {
    double maxLengthRatioVsFirst = 1.50,
    double minMidpointSeparationMeters = 85.0,
  }) {
    if (candidate.length < 2) return false;
    if (existing.isEmpty) return true;

    final double baseLen = _cumulativeDistances(existing.first).last;
    final double candLen = _cumulativeDistances(candidate).last;
    if (baseLen > 0 && candLen > baseLen * maxLengthRatioVsFirst) {
      return false;
    }

    final int midIdx = candidate.length ~/ 2;
    final LatLng candMid = candidate[midIdx];
    final LatLng candQ1 = candidate[(candidate.length * 0.3).floor()];
    final LatLng candQ3 = candidate[(candidate.length * 0.7).floor()];

    for (final route in existing) {
      if (route.length < 2) continue;
      final double midSep = _minPointToPolylineDist(candMid, route);
      final double q1Sep = _minPointToPolylineDist(candQ1, route);
      final double q3Sep = _minPointToPolylineDist(candQ3, route);
      final double maxSep = math.max(midSep, math.max(q1Sep, q3Sep));
      if (maxSep < minMidpointSeparationMeters) {
        return false;
      }
    }
    return true;
  }

  static _SegmentMatchCollection _findRoutePassMatches({
    required RouteHazardInput hazard,
    required List<LatLng> route,
    required List<double> cumDist,
    required List<double> segmentBearings,
    required List<String> segmentRoadNames,
    required RouteCorridorConfig config,
  }) {
    final String hazardRoad = _normalizeRoadName(hazard.roadName);
    final List<_SegmentMatch> candidates = <_SegmentMatch>[];

    for (int i = 0; i < route.length - 1; i++) {
      final proj = _projectPointOnSegment(
        hazard.location,
        route[i],
        route[i + 1],
      );
      final double perp = distanceMetersBetween(hazard.location, proj.point);
      if (perp > config.corridorMeters) continue;

      if (hazard.rawLocation != null) {
        final rawProj = _projectPointOnSegment(
          hazard.rawLocation!,
          route[i],
          route[i + 1],
        );
        final double rawPerp = distanceMetersBetween(
          hazard.rawLocation!,
          rawProj.point,
        );
        if (rawPerp > config.corridorMeters + 2.0) {
          continue;
        }
      }

      if (hazard.roadBearingDeg != null && i < segmentBearings.length) {
        final double diff = _angularDiffDeg(
          hazard.roadBearingDeg!,
          segmentBearings[i],
        );
        if (diff > config.maxBearingDifferenceDeg) {
          continue;
        }
      }

      final String segRoad = i < segmentRoadNames.length
          ? _normalizeRoadName(segmentRoadNames[i])
          : '';
      bool segRoadMatched = false;
      if (hazardRoad.isNotEmpty && segRoad.isNotEmpty) {
        if (!_roadNamesCompatible(hazardRoad, segRoad)) {
          continue;
        }
        segRoadMatched = true;
      }

      final double chain = cumDist[i] + (cumDist[i + 1] - cumDist[i]) * proj.t;
      candidates.add(
        _SegmentMatch(
          segmentIndex: i,
          chainDistanceMeters: chain,
          perpendicularDistanceMeters: perp,
          projectedPoint: proj.point,
          segmentBearingDeg: i < segmentBearings.length
              ? segmentBearings[i]
              : 0.0,
          roadMatched:
              hazard.roadMatched &&
              (hazardRoad.isEmpty || segRoad.isEmpty || segRoadMatched),
        ),
      );
    }

    if (candidates.isEmpty) {
      return const _SegmentMatchCollection(passEncounters: []);
    }

    // Group contiguous segment hits along the same pass into their closest
    // projection, while keeping distinct passes (separated by >65 m of chain
    // distance, e.g. loop/cloverleaf traversals) as separate encounters.
    final List<_SegmentMatch> passEncounters = <_SegmentMatch>[];
    _SegmentMatch currentBest = candidates.first;
    double groupMaxChain = candidates.first.chainDistanceMeters;

    for (int i = 1; i < candidates.length; i++) {
      final cand = candidates[i];
      if ((cand.chainDistanceMeters - groupMaxChain) <= 65.0) {
        groupMaxChain = cand.chainDistanceMeters;
        if (cand.perpendicularDistanceMeters <
            currentBest.perpendicularDistanceMeters) {
          currentBest = cand;
        }
      } else {
        passEncounters.add(currentBest);
        currentBest = cand;
        groupMaxChain = cand.chainDistanceMeters;
      }
    }
    passEncounters.add(currentBest);

    return _SegmentMatchCollection(passEncounters: passEncounters);
  }

  static const Set<String> _distinctFacilityQualifiers = <String>{
    'service',
    'frontage',
    'flyover',
    'overpass',
    'viaduct',
    'underpass',
    'tunnel',
    'skyway',
    'ramp',
    'slip',
    'exit',
    'entry',
    'access',
    'connector',
    'spur',
    'bypass',
    'link',
    'nb',
    'sb',
    'eb',
    'wb',
    'northbound',
    'southbound',
    'eastbound',
    'westbound',
    'inner',
    'outer',
    'upper',
    'lower',
    'elevated',
    'ground',
  };

  static List<String> _mapStepsToSegments(
    List<LatLng> route,
    List<RouteStepRoadSpan> steps,
  ) {
    final int segCount = math.max(0, route.length - 1);
    final result = List<String>.filled(segCount, '');
    if (segCount == 0 || steps.isEmpty) return result;

    // Steps follow the route monotonically, so a cumulative distance bailout
    // prevents long multi-hundred-vertex segments from truncating early while
    // keeping revisited loop intersections from stealing earlier step matches.
    final List<int> stepVertexIndices = <int>[];
    int cursor = 0;
    for (final step in steps) {
      int bestIdx = cursor;
      double bestDist = double.infinity;
      double chainSinceBest = 0.0;
      for (int idx = cursor; idx < route.length; idx++) {
        if (idx > bestIdx) {
          chainSinceBest += distanceMetersBetween(route[idx - 1], route[idx]);
          if (bestDist <= 35.0 && chainSinceBest > 150.0) {
            break;
          }
        }
        final d = distanceMetersBetween(step.location, route[idx]);
        if (d < bestDist) {
          bestDist = d;
          bestIdx = idx;
          chainSinceBest = 0.0;
        }
      }
      stepVertexIndices.add(bestIdx);
      cursor = bestIdx;
    }

    for (int s = 0; s < steps.length; s++) {
      final String name = steps[s].roadName.trim();
      if (name.isEmpty) continue;
      final int startSeg = stepVertexIndices[s].clamp(0, segCount - 1);
      final int endSeg = (s + 1 < steps.length)
          ? stepVertexIndices[s + 1].clamp(startSeg + 1, segCount)
          : segCount;
      for (int seg = startSeg; seg < endSeg; seg++) {
        result[seg] = name;
      }
    }
    return result;
  }

  static String _normalizeRoadName(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    return raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\bsta\b'), 'santa')
        .replaceAll(RegExp(r'\bsto\b'), 'santo')
        .replaceAll(RegExp(r'\bbrgy\b'), 'barangay')
        .replaceAll(RegExp(r'\bgov\b'), 'governor')
        .replaceAll(RegExp(r'\bgen\b'), 'general')
        .replaceAll(RegExp(r'\bstreet\b'), 'st')
        .replaceAll(RegExp(r'\broad\b'), 'rd')
        .replaceAll(RegExp(r'\bavenue\b'), 'ave')
        .replaceAll(RegExp(r'\bhighway\b'), 'hwy')
        .replaceAll(RegExp(r'\bboulevard\b'), 'blvd')
        .replaceAll(RegExp(r'\bdrive\b'), 'dr')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _roadNamesCompatible(String a, String b) {
    if (a.isEmpty || b.isEmpty) return true;
    if (a == b) return true;
    final tokensA = a.split(' ').where((t) => t.isNotEmpty).toSet();
    final tokensB = b.split(' ').where((t) => t.isNotEmpty).toSet();
    final diff = tokensA.difference(tokensB).union(tokensB.difference(tokensA));
    if (diff.any(_distinctFacilityQualifiers.contains)) {
      return false;
    }
    final String shorter = a.length <= b.length ? a : b;
    final String longer = a.length <= b.length ? b : a;
    return RegExp('(^| )${RegExp.escape(shorter)}( |\$)').hasMatch(longer);
  }

  static double _bearingDeg(LatLng a, LatLng b) {
    final lat1 = _toRad(a.latitude);
    final lat2 = _toRad(b.latitude);
    final dLon = _toRad(b.longitude - a.longitude);
    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final brng = math.atan2(y, x) * 180.0 / math.pi;
    return (brng + 360.0) % 360.0;
  }

  static double _angularDiffDeg(double a, double b) {
    final diff = ((a - b + 540.0) % 360.0) - 180.0;
    return diff.abs();
  }

  static double _minPointToPolylineDist(LatLng p, List<LatLng> route) {
    double best = double.infinity;
    for (int i = 0; i < route.length - 1; i++) {
      final d = distancePointToSegmentMeters(p, route[i], route[i + 1]);
      if (d < best) best = d;
    }
    return best;
  }

  static List<double> _cumulativeDistances(List<LatLng> route) {
    final cum = List<double>.filled(route.length, 0.0);
    for (int i = 1; i < route.length; i++) {
      cum[i] = cum[i - 1] + distanceMetersBetween(route[i - 1], route[i]);
    }
    return cum;
  }

  static _PolylineProjection _projectOntoPolyline(
    LatLng p,
    List<LatLng> route,
    List<double> cumDist,
  ) {
    double bestPerp = double.infinity;
    int bestSeg = 0;
    LatLng bestPoint = route.first;
    double bestChain = 0.0;

    for (int i = 0; i < route.length - 1; i++) {
      final proj = _projectPointOnSegment(p, route[i], route[i + 1]);
      final perp = distanceMetersBetween(p, proj.point);
      if (perp < bestPerp) {
        bestPerp = perp;
        bestSeg = i;
        bestPoint = proj.point;
        bestChain = cumDist[i] + (cumDist[i + 1] - cumDist[i]) * proj.t;
      }
    }

    return _PolylineProjection(
      segmentIndex: bestSeg,
      point: bestPoint,
      perpDistanceMeters: bestPerp,
      chainDistanceMeters: bestChain,
    );
  }

  static ({LatLng point, double t}) _projectPointOnSegment(
    LatLng p,
    LatLng a,
    LatLng b,
  ) {
    final latRefRad = _toRad((a.latitude + b.latitude) / 2.0);
    const metersPerDegLat = 110540.0;
    final metersPerDegLon = 111320.0 * math.cos(latRefRad);
    if (metersPerDegLon.abs() < 1e-6) return (point: a, t: 0.0);

    final bx = (b.longitude - a.longitude) * metersPerDegLon;
    final by = (b.latitude - a.latitude) * metersPerDegLat;
    final px = (p.longitude - a.longitude) * metersPerDegLon;
    final py = (p.latitude - a.latitude) * metersPerDegLat;
    final abLen2 = bx * bx + by * by;
    if (abLen2 <= 1e-6) return (point: a, t: 0.0);

    final double t = ((px * bx + py * by) / abLen2).clamp(0.0, 1.0);
    return (
      point: LatLng(
        a.latitude + t * (b.latitude - a.latitude),
        a.longitude + t * (b.longitude - a.longitude),
      ),
      t: t,
    );
  }

  static double _toRad(double deg) => deg * (math.pi / 180.0);
}

class _PolylineProjection {
  final int segmentIndex;
  final LatLng point;
  final double perpDistanceMeters;
  final double chainDistanceMeters;

  const _PolylineProjection({
    required this.segmentIndex,
    required this.point,
    required this.perpDistanceMeters,
    required this.chainDistanceMeters,
  });
}

class _SegmentMatch {
  final int segmentIndex;
  final double chainDistanceMeters;
  final double perpendicularDistanceMeters;
  final LatLng projectedPoint;
  final double segmentBearingDeg;
  final bool roadMatched;

  const _SegmentMatch({
    required this.segmentIndex,
    required this.chainDistanceMeters,
    required this.perpendicularDistanceMeters,
    required this.projectedPoint,
    required this.segmentBearingDeg,
    required this.roadMatched,
  });
}

class _SegmentMatchCollection {
  final List<_SegmentMatch> passEncounters;
  const _SegmentMatchCollection({required this.passEncounters});
}

/// Immutable payload for offloading [RoutePotholeAdvisor.evaluateAlternatives]
/// onto a background Dart isolate via `compute(...)`.
class RouteAlternativesEvalRequest {
  final List<List<LatLng>> routes;
  final List<double> distancesMeters;
  final List<double> durationsSeconds;
  final List<RouteHazardInput> hazards;
  final List<String> viaSummaries;
  final List<List<RouteStepRoadSpan>> stepsByRoute;
  final RouteCorridorConfig corridorConfig;

  const RouteAlternativesEvalRequest({
    required this.routes,
    required this.distancesMeters,
    required this.durationsSeconds,
    required this.hazards,
    required this.viaSummaries,
    required this.stepsByRoute,
    required this.corridorConfig,
  });
}

/// Top-level worker entry point for `compute(...)`.
RouteComparisonResult evaluateRouteAlternativesWorker(
  RouteAlternativesEvalRequest req,
) {
  return RoutePotholeAdvisor.evaluateAlternatives(
    routes: req.routes,
    distancesMeters: req.distancesMeters,
    durationsSeconds: req.durationsSeconds,
    hazards: req.hazards,
    viaSummaries: req.viaSummaries,
    stepsByRoute: req.stepsByRoute,
    corridorConfig: req.corridorConfig,
  );
}
