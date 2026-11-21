import 'dart:math' as math;
import 'dart:math' show cos, sin, sqrt, atan2;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart'
    show
        DragStartBehavior,
        PanGestureRecognizer,
        GestureDisposition,
        GestureRecognizer;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, compute, defaultTargetPlatform, kIsWeb;
import 'app_settings.dart';
import 'app_design.dart';
import 'dpwh_standards.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:flutter_compass/flutter_compass.dart'
    if (dart.library.html) 'stub_compass.dart';
import 'dart:io' as io;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_service.dart';
import 'settings_dialog.dart';
import 'pothole_notifier.dart';
import 'map_scale_bar.dart';
import 'mobile_components.dart';
import 'road_hazard_marker.dart';
import 'developer_markers.dart';
import 'mobile_tour.dart';
import 'sta_maria_sample_potholes.dart';
import 'route_pothole_advisor.dart';
import 'road_report_cache.dart';
import 'resilient_tile_provider.dart';
import 'gps_tracker_smoother.dart';
import 'nav_vehicle_3d.dart';

enum FollowMode { none, location, compass }

/// 3 Travel Modes supported by Project-OSRM & OpenStreetMap
enum OsrmTravelMode { car, bike, foot }

class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  @override
  void addPointer(PointerDownEvent event) {
    super.addPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// Custom painter for sleek 3D teardrop map pins with ground shadow and gloss
class _ModernPinPainter extends CustomPainter {
  final List<Color> gradientColors;
  final Color borderColor;
  final bool isLifted;

  _ModernPinPainter({
    required this.gradientColors,
    this.borderColor = Colors.white,
    this.isLifted = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = w / 2;

    // 1. Realistic ground shadow at the base
    final shadowWidth = isLifted ? w * 0.58 : w * 0.46;
    final shadowHeight = isLifted ? 5.0 : 6.0;
    final shadowAlpha = isLifted ? 0.20 : 0.38;
    final shadowRect = Rect.fromCenter(
      center: Offset(w / 2, h - 2),
      width: shadowWidth,
      height: shadowHeight,
    );
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: shadowAlpha)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isLifted ? 4.0 : 2.5);
    canvas.drawOval(shadowRect, shadowPaint);

    // 2. Teardrop pin path
    final pinH = h - 6;
    final path = Path();
    path.moveTo(w / 2, pinH);
    path.cubicTo(w * 0.08, pinH * 0.58, 0, r * 1.25, 0, r);
    path.arcTo(
      Rect.fromCircle(center: Offset(r, r), radius: r),
      math.pi,
      math.pi,
      false,
    );
    path.cubicTo(w, r * 1.25, w * 0.92, pinH * 0.58, w / 2, pinH);
    path.close();

    // 3. Pin drop shadow
    final pinShadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: isLifted ? 0.38 : 0.26)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isLifted ? 6.0 : 3.5);
    canvas.drawPath(path.shift(Offset(0, isLifted ? 4 : 2)), pinShadowPaint);

    // 4. Gradient Fill
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: gradientColors,
      ).createShader(Rect.fromLTWH(0, 0, w, pinH));
    canvas.drawPath(path, fillPaint);

    // 5. Crisp Outer Bevel Border
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    canvas.drawPath(path, borderPaint);

    // 6. Gloss Reflection Highlight Arc on top-left
    final glossPath = Path()
      ..addArc(
        Rect.fromCircle(center: Offset(r, r), radius: r - 3.2),
        math.pi * 1.05,
        math.pi * 0.72,
      );
    final glossPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(glossPath, glossPaint);
  }

  @override
  bool shouldRepaint(covariant _ModernPinPainter oldDelegate) =>
      oldDelegate.gradientColors != gradientColors ||
      oldDelegate.borderColor != borderColor ||
      oldDelegate.isLifted != isLifted;
}

bool _isTrustedRemoteImageUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'potholestorage2026.blob.core.windows.net' &&
      uri.path.startsWith('/photos/');
}

/// Turn-by-turn routing maneuver step returned by Project-OSRM
class RouteStep {
  final String instruction;
  final String roadName;
  final double distanceMeters;
  final double durationSeconds;
  final String
  maneuverType; // 'depart', 'turn', 'continue', 'arrive', 'fork', 'roundabout', etc.
  final String?
  modifier; // 'left', 'right', 'straight', 'slight left', 'sharp right', etc.
  final LatLng location;

  const RouteStep({
    required this.instruction,
    required this.roadName,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.maneuverType,
    this.modifier,
    required this.location,
  });
}

/// Represents a detected pothole with its GPS location, photo, severity, and cluster count.
class PotholeMarker {
  final int? id;
  final String? docId;
  final LatLng location;
  final String imagePath;
  final DateTime timestamp;
  final String status; // 'pending', 'approved', 'rejected'
  final String overallSeverity; // 'low', 'medium', 'high'
  final int potholeCount;
  final String? reporterEmail;
  final String? reporterUid;
  final String primaryDpwhCode;
  final String primaryDefect;
  final String responseTime;
  final String correctiveMeasure;
  final List<Map<String, dynamic>>? detections;
  final String barangay;
  final String city;
  final String province;
  final String formattedAddress;
  final bool isResolved;
  final String? canonicalDefectId;
  final String? roadName;
  final bool isAccessible;
  final double? roadBearingDeg;
  final bool roadMatched;

  PotholeMarker({
    this.id,
    this.docId,
    required this.location,
    required this.imagePath,
    required this.timestamp,
    this.status = 'approved',
    this.overallSeverity = 'medium',
    this.potholeCount = 1,
    this.reporterEmail,
    this.reporterUid,
    this.primaryDpwhCode = 'CODE 01',
    this.primaryDefect = 'Pothole',
    this.responseTime = '3 Days',
    this.correctiveMeasure =
        'Bituminous premix (hot) or penetration patching; add base material if needed.',
    this.detections,
    this.barangay = '',
    this.city = '',
    this.province = '',
    this.formattedAddress = '',
    this.isResolved = false,
    this.canonicalDefectId,
    this.roadName,
    this.isAccessible = true,
    this.roadBearingDeg,
    this.roadMatched = false,
  });
}

/// Represents a grouped cluster of potholes located within a 10-meter barrier radius
class PotholeCluster {
  final String id;
  final LatLng center;
  final List<PotholeMarker> items;

  PotholeCluster({required this.id, required this.center, required this.items});

  bool get isSingle => items.length <= 1;
  PotholeMarker get singleItem => items.first;
}

/// Custom painter for the radial spider tree connecting stems
class SpiderLinesPainter extends CustomPainter {
  final List<Offset> childOffsets;
  final bool isDark;

  SpiderLinesPainter({required this.childOffsets, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final linePaint = Paint()
      ..color = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final shadowPaint = Paint()
      ..color = Colors.black38
      ..strokeWidth = 3.8
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

    for (final offset in childOffsets) {
      final target = center + offset;
      canvas.drawLine(center, target, shadowPaint);
      canvas.drawLine(center, target, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant SpiderLinesPainter oldDelegate) {
    return oldDelegate.childOffsets != childOffsets ||
        oldDelegate.isDark != isDark;
  }
}

typedef CorridorReportFetcher =
    Future<List<PotholeMarker>> Function({
      required double minLat,
      required double maxLat,
      required double minLon,
      required double maxLon,
    });

enum _MapSubPageTour { none, search, directions, routePreview, driving }

class MapScreen extends StatefulWidget {
  final List<PotholeMarker> detectedPotholes;
  final Future<void> Function(PotholeMarker pothole)? onDeleteDetectedPothole;
  final Future<void> Function(LatLng location)? onAddDetectedPothole;
  final CorridorReportFetcher? corridorReportFetcher;
  final VoidCallback? onOpenProfile;
  final VoidCallback? onOpenScanner;
  final VoidCallback? onReplayTour;
  final MobileTourController? tourController;
  final GlobalKey? tourSearchBarKey;
  final GlobalKey? tourLayersFilterKey;
  final GlobalKey? tourLocationButtonKey;
  final bool isTourActive;
  final bool isMapActive;
  final DateTime? reportsLastUpdatedAt;
  final bool isUsingCachedData;
  final double routeCorridorMeters;

  const MapScreen({
    super.key,
    required this.detectedPotholes,
    this.onDeleteDetectedPothole,
    this.onAddDetectedPothole,
    this.corridorReportFetcher,
    this.onOpenProfile,
    this.onOpenScanner,
    this.onReplayTour,
    this.tourController,
    this.tourSearchBarKey,
    this.tourLayersFilterKey,
    this.tourLocationButtonKey,
    this.isTourActive = false,
    this.isMapActive = true,
    this.reportsLastUpdatedAt,
    this.isUsingCachedData = false,
    this.routeCorridorMeters = RouteCorridorConfig.defaultCorridorMeters,
  });

  @override
  State<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends State<MapScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  static LatLng? _cachedGlobalPosition;

  @override
  bool get wantKeepAlive => true;

  final _directionsGuideKey = GlobalKey();
  final _compassGuideKey = GlobalKey();
  final _zoomGuideKey = GlobalKey();
  final _freeDriveGuideKey = GlobalKey();
  final _locationGuideKey = GlobalKey();
  final _searchInputGuideKey = GlobalKey();
  final _searchQuickPicksGuideKey = GlobalKey();
  final _routeEndpointsGuideKey = GlobalKey();
  final _routeSwapGuideKey = GlobalKey();
  final _routeTravelModeGuideKey = GlobalKey();
  final _routeStartDrivingGuideKey = GlobalKey();
  final _routeAvoidGuideKey = GlobalKey();
  final _routeCompareGuideKey = GlobalKey();
  final _drivingAngleGuideKey = GlobalKey();
  final _drivingSearchGuideKey = GlobalKey();
  final _drivingVoiceGuideKey = GlobalKey();
  final _drivingRerouteGuideKey = GlobalKey();
  final _drivingBottomSheetGuideKey = GlobalKey();

  Timer? _subPageTourTimer;
  _MapSubPageTour _lastScheduledSubPage = _MapSubPageTour.none;
  int _subPageTourSeq = 0;

  bool get isDrivingActive => _isNavigating;
  bool get isSearchOrDirectionsActive => _isSearchPageActive;
  bool get isRoutePreviewActive =>
      _routePoints.isNotEmpty &&
      !_isNavigating &&
      !_isSearchPageActive &&
      _selectedPothole == null &&
      _searchedPlace == null;

  _MapSubPageTour get _currentSubPageTour {
    if (kIsWeb || !widget.isMapActive || _isChoosingLocationOnMap) {
      return _MapSubPageTour.none;
    }
    if (_isSearchPageActive) {
      return _isRoutePlanningMode
          ? _MapSubPageTour.directions
          : _MapSubPageTour.search;
    }
    if (_isNavigating) {
      return _MapSubPageTour.driving;
    }
    if (_routePoints.isNotEmpty &&
        _selectedPothole == null &&
        _searchedPlace == null) {
      return _MapSubPageTour.routePreview;
    }
    return _MapSubPageTour.none;
  }

  List<TourStepSpec> get mapControlGuideSteps => [
    TourStepSpec(
      id: 'map_directions',
      targetKey: _directionsGuideKey,
      title: 'Choose Point A and Point B',
      description:
          'Plan a route here. Drag A or B to adjust it, compare travel time and reported potholes, then choose Start driving.',
    ),
    TourStepSpec(
      id: 'map_compass',
      targetKey: _compassGuideKey,
      title: 'Map direction',
      description:
          'Follow your heading or return the map to north. You can also rotate the map with two fingers.',
    ),
    TourStepSpec(
      id: 'map_zoom',
      targetKey: _zoomGuideKey,
      title: 'See more or less detail',
      description:
          'Use + and - or pinch the map. Tap a hazard for its class and report details; tap a numbered cluster to separate nearby reports.',
    ),
    TourStepSpec(
      id: 'map_free_drive',
      targetKey: _freeDriveGuideKey,
      title: 'Free Drive radar mode',
      description:
          'Enter 3D Free Drive anytime without a destination to hear ahead pothole alerts while driving.',
    ),
    TourStepSpec(
      id: 'map_location',
      targetKey: widget.tourLocationButtonKey ?? _locationGuideKey,
      title: 'Return to your location',
      description:
          'Center the map on your GPS location and re-lock follow mode.',
    ),
  ];

  List<TourStepSpec> _buildSearchPageGuideSteps() => [
    TourStepSpec(
      id: 'search_input',
      targetKey: _searchInputGuideKey,
      title: 'Search Bulacan places & reports',
      description:
          'Type a barangay, street, landmark, or defect class to jump straight to that location.',
    ),
    TourStepSpec(
      id: 'search_quick_picks',
      targetKey: _searchQuickPicksGuideKey,
      title: 'Quick picks & pin drop',
      description:
          'Tap Choose on map to drop a pin manually, switch to Directions A -> B, or pick a nearby barangay.',
    ),
  ];

  List<TourStepSpec> _buildDirectionsPageGuideSteps() => [
    TourStepSpec(
      id: 'directions_endpoints',
      targetKey: _routeEndpointsGuideKey,
      title: 'Set Point A & Point B',
      description:
          'Enter your start and destination, or tap Choose on map below to place either pin manually.',
    ),
    TourStepSpec(
      id: 'directions_swap',
      targetKey: _routeSwapGuideKey,
      title: 'Swap A & B',
      description: 'Flip your starting point and destination with one tap.',
    ),
    TourStepSpec(
      id: 'directions_mode',
      targetKey: _routeTravelModeGuideKey,
      title: 'Choose Car, Motorcycle, or Walk',
      description:
          'Switch travel mode to tailor routing and travel time estimates.',
    ),
  ];

  List<TourStepSpec> _buildRoutePreviewGuideSteps() => [
    TourStepSpec(
      id: 'route_start',
      targetKey: _routeStartDrivingGuideKey,
      title: 'Start 3D driving navigation',
      description:
          'Launch turn-by-turn navigation with 100m ahead pothole alerts. Drag A or B on the map anytime to adjust endpoints.',
    ),
    TourStepSpec(
      id: 'route_avoid',
      targetKey: _routeAvoidGuideKey,
      title: 'Find fewer potholes',
      description:
          'Look for safer alternative routes that detour around reported severe road hazards.',
    ),
    TourStepSpec(
      id: 'route_compare',
      targetKey: _routeCompareGuideKey,
      title: 'Compare route options',
      description:
          'Compare travel duration and reported potholes side by side across available routes.',
    ),
  ];

  List<TourStepSpec> _buildDrivingModeGuideSteps() => [
    TourStepSpec(
      id: 'driving_angle',
      targetKey: _drivingAngleGuideKey,
      borderRadius: 24,
      title: 'Switch camera angles',
      description:
          'Cycle between 3D Chase View, 2D Heading, North Up, and Full Route Overview.',
    ),
    TourStepSpec(
      id: 'driving_search',
      targetKey: _drivingSearchGuideKey,
      borderRadius: 24,
      title: 'Search along drive',
      description: 'Search a destination or new stop while navigating.',
    ),
    TourStepSpec(
      id: 'driving_voice',
      targetKey: _drivingVoiceGuideKey,
      borderRadius: 24,
      title: 'Voice hazard alerts',
      description:
          'Mute or unmute spoken turn prompts and 100m ahead pothole warnings.',
    ),
    TourStepSpec(
      id: 'driving_reroute',
      targetKey: _drivingRerouteGuideKey,
      borderRadius: 24,
      title: 'Live reroute',
      description:
          'Switch to an alternate route near the start or recalculate from your current GPS position.',
    ),
    TourStepSpec(
      id: 'driving_sheet',
      targetKey: _drivingBottomSheetGuideKey,
      borderRadius: 24,
      title: '3D vehicle & drive drawer',
      description:
          'Swipe up or tap here to choose your 3D Car, Motorcycle, or Walker, view turn steps, or tap × to End navigation.',
    ),
  ];

  void _syncSubPageTourIfNeeded() {
    if (widget.tourController == null || kIsWeb) return;
    final mode = _currentSubPageTour;
    if (mode != _lastScheduledSubPage) {
      _lastScheduledSubPage = mode;
      _onSubPageTourChanged(mode);
    }
  }

  void _onSubPageTourChanged(_MapSubPageTour mode) {
    final tc = widget.tourController;
    if (tc == null || kIsWeb) return;
    _subPageTourTimer?.cancel();
    final seq = ++_subPageTourSeq;

    final MobileTourId? targetId = switch (mode) {
      _MapSubPageTour.search => MobileTourId.search,
      _MapSubPageTour.directions => MobileTourId.directions,
      _MapSubPageTour.routePreview => MobileTourId.routePreview,
      _MapSubPageTour.driving => MobileTourId.driving,
      _MapSubPageTour.none => null,
    };

    if (tc.isRunning &&
        tc.activeTour != targetId &&
        tc.activeTour != MobileTourId.main) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            tc.isRunning &&
            tc.activeTour != targetId &&
            tc.activeTour != MobileTourId.main) {
          tc.cancelWithoutCompleting();
        }
      });
    }

    if (targetId == null) return;

    _subPageTourTimer = Timer(const Duration(milliseconds: 420), () async {
      if (!mounted || seq != _subPageTourSeq) return;
      await tc.ensureLoaded();
      if (!mounted || seq != _subPageTourSeq || _currentSubPageTour != mode) {
        return;
      }
      if (!tc.isCompleted(targetId) &&
          tc.isRunning &&
          tc.activeTour != targetId) {
        tc.cancelWithoutCompleting();
      }
      _startSubPageTour(mode);
    });
  }

  bool _startSubPageTour(_MapSubPageTour mode, {bool force = false}) {
    final tc = widget.tourController;
    if (tc == null || kIsWeb || !mounted) return false;
    switch (mode) {
      case _MapSubPageTour.none:
        return false;
      case _MapSubPageTour.search:
        return tc.startTour(
          MobileTourId.search,
          _buildSearchPageGuideSteps(),
          force: force,
        );
      case _MapSubPageTour.directions:
        return tc.startTour(
          MobileTourId.directions,
          _buildDirectionsPageGuideSteps(),
          force: force,
        );
      case _MapSubPageTour.routePreview:
        return tc.startTour(
          MobileTourId.routePreview,
          _buildRoutePreviewGuideSteps(),
          force: force,
        );
      case _MapSubPageTour.driving:
        return tc.startTour(
          MobileTourId.driving,
          _buildDrivingModeGuideSteps(),
          force: force,
        );
    }
  }

  bool startSearchOrDirectionsGuide({bool force = false}) => _startSubPageTour(
    _isRoutePlanningMode ? _MapSubPageTour.directions : _MapSubPageTour.search,
    force: force,
  );

  bool startRoutePreviewGuide({bool force = false}) =>
      _startSubPageTour(_MapSubPageTour.routePreview, force: force);

  bool startDrivingGuide({bool force = false}) =>
      _startSubPageTour(_MapSubPageTour.driving, force: force);

  final MapController _mapController = MapController();
  double _lastMarkerZoom = 15;
  final GlobalKey _mapViewportKey = GlobalKey();
  LatLng? _currentPosition;
  double _currentMapRotation = 0.0;
  String? _expandedClusterId;
  bool _isLoadingLocation = true;
  bool _isLocationDisabled = false;
  bool _isPermissionDenied = false;
  bool _dismissedLocationPrompt = false;
  PotholeMarker? _selectedPothole;

  final http.Client _httpClient = http.Client();
  final StreamController<void> _tileLayerResetController =
      StreamController<void>.broadcast();
  bool _hasPartialTileFallback = false;
  late final ResilientTileProvider _tileProvider = ResilientTileProvider(
    httpClient: _httpClient,
    isOfflineCheck: () => _isOffline,
    onFallbackStateChanged: _onTileFallbackStateChanged,
  );

  void _onTileFallbackStateChanged() {
    if (!mounted) return;
    final hasFallback = _tileProvider.hasFallbackTiles;
    if (hasFallback == _hasPartialTileFallback) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nowFallback = _tileProvider.hasFallbackTiles;
      if (nowFallback != _hasPartialTileFallback) {
        setState(() => _hasPartialTileFallback = nowFallback);
      }
    });
  }

  void _refreshMapTiles() {
    _tileProvider.evictFallbackTiles();
    if (!_tileLayerResetController.isClosed) {
      _tileLayerResetController.add(null);
    }
    if (mounted && _hasPartialTileFallback) {
      setState(() => _hasPartialTileFallback = false);
    }
  }
  List<PotholeMarker>? _cachedEffectivePotholes;
  List<PotholeMarker>? _cachedDetectedPotholesRef;
  int _cachedDetectedPotholesLen = -1;
  bool? _cachedDevMockEnabled;
  int _cachedEffectiveVersion = -1;
  List<RouteHazardInput>? _cachedHazardInputs;
  int _cachedHazardInputsVersion = -1;
  int _potholeDerivedVersion = 0;

  void _invalidatePotholeDerivedCaches() {
    _potholeDerivedVersion++;
    _cachedEffectivePotholes = null;
    _cachedHazardInputs = null;
    _cachedPotholeClusters = null;
  }

  late final AnimationController _puckPulseController;
  final GpsTrackerSmoother _gpsSmoother = GpsTrackerSmoother();
  Ticker? _puckTicker;
  Duration _lastPuckTickElapsed = Duration.zero;
  AnimationController? _mapMoveController;
  final ValueNotifier<LatLng?> _animatedPuckPositionNotifier =
      ValueNotifier<LatLng?>(null);

  void _ensurePuckTickerRunning() {
    if (!mounted || !widget.isMapActive) return;
    _puckTicker ??= createTicker(_onPuckTick);
    if (!_puckTicker!.isActive) {
      _lastPuckTickElapsed = Duration.zero;
      _puckTicker!.start();
    }
  }

  void _stopPuckTicker() {
    _puckTicker?.stop();
    _lastPuckTickElapsed = Duration.zero;
  }

  void _onPuckTick(Duration elapsed) {
    if (!mounted || !widget.isMapActive) {
      _stopPuckTicker();
      return;
    }
    final double dtSeconds = _lastPuckTickElapsed == Duration.zero
        ? (1.0 / 60.0)
        : ((elapsed - _lastPuckTickElapsed).inMicroseconds / 1e6).clamp(
            0.001,
            0.05,
          );
    _lastPuckTickElapsed = elapsed;

    final frame = _gpsSmoother.advanceFrame(
      now: DateTime.now(),
      dtSeconds: dtSeconds,
    );

    if (frame.headingDeg != null) {
      final prevHeading = _lastHeadingNotifier.value;
      if (prevHeading == null ||
          GpsTrackerSmoother.shortestAngleDeltaDeg(
                prevHeading,
                frame.headingDeg!,
              ).abs() >=
              0.08) {
        _lastHeadingNotifier.value = frame.headingDeg;
      }
    }

    if (_followMode == FollowMode.compass &&
        !_isDraggingEndpoint &&
        _lastHeadingNotifier.value != null) {
      final double targetRot =
          (360.0 - _lastHeadingNotifier.value!) % 360.0;
      if (GpsTrackerSmoother.shortestAngleDeltaDeg(
            _currentMapRotation,
            targetRot,
          ).abs() >=
          0.25) {
        _currentMapRotation = targetRot;
        _mapRotationNotifier.value = targetRot;
        _mapController.rotate(targetRot);
      }
    }

    if (frame.position != null) {
      final prevPos = _animatedPuckPositionNotifier.value;
      if (prevPos == null ||
          prevPos.latitude != frame.position!.latitude ||
          prevPos.longitude != frame.position!.longitude) {
        _animatedPuckPositionNotifier.value = frame.position;
      }

      if (_followMode != FollowMode.none &&
          !_isDraggingEndpoint &&
          (_mapMoveController == null || !_mapMoveController!.isAnimating)) {
        double nextZoom = _mapController.camera.zoom;
        if (_isNavigating &&
            !_isNavOverview &&
            _followMode == FollowMode.compass) {
          final double spd = _gpsSmoother.speedMps;
          final double targetZoom =
              _drivingCameraAngle == DrivingCameraAngle.chase3D
              ? (spd < 4.0
                    ? 17.8
                    : (spd < 12.0 ? 17.3 : (spd < 20.0 ? 16.8 : 16.3)))
              : (spd < 4.0
                    ? 17.0
                    : (spd < 12.0 ? 16.6 : (spd < 20.0 ? 16.2 : 15.8)));
          nextZoom =
              nextZoom +
              (targetZoom - nextZoom) * (dtSeconds * 1.4).clamp(0.0, 0.25);
        }
        final cameraCenter = _getVisibleMapOffsetCameraCenter(
          frame.position!,
          nextZoom,
          rotationDeg: _currentMapRotation,
        );
        final curCam = _mapController.camera;
        final bool centerMoved =
            (curCam.center.latitude - cameraCenter.latitude).abs() >= 2e-6 ||
            (curCam.center.longitude - cameraCenter.longitude).abs() >= 2e-6;
        final bool zoomMoved = (curCam.zoom - nextZoom).abs() >= 0.015;
        if (centerMoved || zoomMoved) {
          _mapController.move(cameraCenter, nextZoom);
        }
      }
    }

    if (frame.isSettled) {
      _stopPuckTicker();
    }
  }

  void _snapPuckImmediately(LatLng targetPos, {double? headingDeg}) {
    _stopPuckTicker();
    _gpsSmoother.reset(position: targetPos, headingDeg: headingDeg);
    _animatedPuckPositionNotifier.value = targetPos;
    if (headingDeg != null && headingDeg.isFinite) {
      _lastHeadingNotifier.value = GpsTrackerSmoother.normalizeAngleDeg(
        headingDeg,
      );
    }
    if (_followMode != FollowMode.none && !_isDraggingEndpoint) {
      final cameraCenter = _getVisibleMapOffsetCameraCenter(
        targetPos,
        _mapController.camera.zoom,
      );
      _mapController.move(cameraCenter, _mapController.camera.zoom);
    }
  }

  /// Smoothly interpolates the user location marker between GPS fixes (60 FPS
  /// continuous velocity-aware motion without start-stop lunging).
  void _animatePuckTo(
    LatLng targetPos, {
    DateTime? timestamp,
    double speedMps = 0.0,
    double? headingDeg,
    bool isMock = false,
  }) {
    final result = _gpsSmoother.ingestFix(
      GpsFixSample(
        position: targetPos,
        timestamp: timestamp ?? DateTime.now(),
        speedMps: speedMps,
        headingDeg: headingDeg,
        isMock: isMock,
      ),
    );
    if (!result.accepted || result.filteredPosition == null) return;
    if (result.shouldSnapImmediately) {
      _animatedPuckPositionNotifier.value = result.filteredPosition;
      if (_followMode != FollowMode.none && !_isDraggingEndpoint) {
        final cameraCenter = _getVisibleMapOffsetCameraCenter(
          result.filteredPosition!,
          _mapController.camera.zoom,
        );
        _mapController.move(cameraCenter, _mapController.camera.zoom);
      }
      return;
    }
    _ensurePuckTickerRunning();
  }

  /// Smoothly glides the GIS map camera to a target location and zoom level
  void _animatedMapMove(LatLng destLocation, double destZoom) {
    try {
      final startLat = _mapController.camera.center.latitude;
      final startLng = _mapController.camera.center.longitude;
      final startZoom = _mapController.camera.zoom;

      final latTween = Tween<double>(
        begin: startLat,
        end: destLocation.latitude,
      );
      final lngTween = Tween<double>(
        begin: startLng,
        end: destLocation.longitude,
      );
      final zoomTween = Tween<double>(begin: startZoom, end: destZoom);

      final prevMoveController = _mapMoveController;
      _mapMoveController = null;
      prevMoveController?.stop();
      prevMoveController?.dispose();

      final controller = AnimationController(
        duration: const Duration(milliseconds: 550),
        vsync: this,
      );
      _mapMoveController = controller;

      final Animation<double> animation = CurvedAnimation(
        parent: controller,
        curve: Curves.fastOutSlowIn,
      );

      controller.addListener(() {
        if (!mounted) return;
        try {
          _mapController.move(
            LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
            zoomTween.evaluate(animation),
          );
        } catch (_) {}
      });

      animation.addStatusListener((status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          if (identical(_mapMoveController, controller)) {
            _mapMoveController = null;
          }
          controller.dispose();
        }
      });

      controller.forward();
    } catch (_) {
      try {
        _mapController.move(destLocation, destZoom);
      } catch (_) {}
    }
  }

  /// Programmatically locates a scanned hazard on the map and focuses the camera
  void locatePothole(
    LatLng location,
    String? docId, [
    Map<String, dynamic>? data,
  ]) {
    PotholeMarker? target;
    if (docId != null && docId.isNotEmpty) {
      try {
        target = _effectivePotholes.firstWhere((p) => p.docId == docId);
      } catch (_) {}
    }
    if (target == null) {
      try {
        target = _effectivePotholes.firstWhere(
          (p) =>
              (p.location.latitude - location.latitude).abs() < 0.0001 &&
              (p.location.longitude - location.longitude).abs() < 0.0001,
        );
      } catch (_) {}
    }
    if (target == null && data != null) {
      DateTime markerDate = DateTime.now();
      try {
        if (data['timestamp'] != null) {
          final raw = data['timestamp'];
          if (raw is DateTime) {
            markerDate = raw;
          } else if (raw is String) {
            markerDate = DateTime.tryParse(raw) ?? DateTime.now();
          } else {
            markerDate = (raw as dynamic).toDate() as DateTime;
          }
        }
      } catch (_) {}

      final dpwhCode = data['primaryDpwhCode'] as String? ?? 'CODE 01';
      final defectClass =
          DpwhStandards.classForReport(data) ??
          DpwhStandards.classifyByCode(dpwhCode);
      target = PotholeMarker(
        docId: docId ?? '',
        location: location,
        imagePath: data['imageUrl'] as String? ?? '',
        timestamp: markerDate,
        status: data['status'] as String? ?? 'pending',
        overallSeverity:
            data['overallSeverity'] as String? ?? defectClass.severity,
        reporterEmail: data['reporterEmail'] as String? ?? '',
        potholeCount: (data['potholeCount'] as num?)?.toInt() ?? 1,
        primaryDpwhCode: dpwhCode,
        primaryDefect: DpwhStandards.reportDefectName(data),
        responseTime:
            data['responseTime'] as String? ?? defectClass.responseTime,
        correctiveMeasure:
            data['correctiveMeasure'] as String? ??
            defectClass.correctiveMeasure,
        detections: (data['detections'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        barangay: data['barangay'] as String? ?? '',
        city: data['city'] as String? ?? '',
        province: data['province'] as String? ?? '',
        formattedAddress: data['formattedAddress'] as String? ?? '',
      );
    } else {
      target ??= PotholeMarker(
        docId: docId ?? '',
        location: location,
        imagePath: '',
        timestamp: DateTime.now(),
        status: 'pending',
      );
    }

    setState(() {
      _selectedPothole = target;
      _destination = null;
      _routePoints = [];
      _alternativeRoutes = [];
      _isRoutePlanningMode = false;
      _searchController.text =
          'Hazard (${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)})';
    });

    Future.delayed(const Duration(milliseconds: 250), () {
      _animatedMapMove(location, 17.5);
    });
  }

  /// Bounds the map camera to encompass all specified report locations
  void locateAllPotholes(List<LatLng> locations, {String filterLabel = 'all'}) {
    if (locations.isEmpty) return;

    setState(() {
      _selectedPothole = null;
      _destination = null;
      _routePoints = [];
      _alternativeRoutes = [];
      _isRoutePlanningMode = false;
    });

    if (locations.length == 1) {
      _animatedMapMove(locations.first, 17.0);
    } else {
      double minLat = locations.first.latitude;
      double maxLat = locations.first.latitude;
      double minLng = locations.first.longitude;
      double maxLng = locations.first.longitude;

      for (final p in locations) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }

      final bounds = LatLngBounds(
        LatLng(minLat, minLng),
        LatLng(maxLat, maxLng),
      );

      try {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 120),
            maxZoom: 17.0,
          ),
        );
      } catch (_) {
        _animatedMapMove(locations.first, 15.0);
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF00796B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        content: Row(
          children: [
            const Icon(Icons.pin_drop_rounded, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Locating ${locations.length} $filterLabel report hazard${locations.length == 1 ? '' : 's'} on map.',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Calculates the adjusted camera center so that [targetLocation] is rendered
  /// right in the middle of the unobstructed visible map area (or anchored near
  /// the bottom of the screen during active driving navigation).
  LatLng _getVisibleMapOffsetCameraCenter(
    LatLng targetLocation,
    double zoom, {
    bool? isExpandedSheet,
    double? rotationDeg,
  }) {
    try {
      final Size screenSize = MediaQuery.sizeOf(context);
      final double screenHeight = screenSize.height;
      final double topInset = MediaQuery.paddingOf(context).top;
      final double bottomInset = MediaQuery.paddingOf(context).bottom;

      final bool expanded = isExpandedSheet ?? _isRouteSheetExpanded;

      // Top obstruction (top navigation header or active route card + status bar)
      final double topObstruction = (_isNavigating || _routePoints.isNotEmpty)
          ? (topInset + 84.0)
          : (topInset + 56.0);

      // Bottom obstruction (expanded drawer, sleek 96dp driving ETA bar, or route preview dock)
      final double bottomObstruction = expanded
          ? (screenHeight * 0.50)
          : ((_isNavigating && !_isNavOverview)
                ? (96.0 + bottomInset)
                : (_routePoints.isNotEmpty ? (190.0 + bottomInset) : 96.0));

      final double bottomSheetTop = screenHeight - bottomObstruction;
      // Anchor vehicle puck according to the active driving camera angle.
      final double visibleCenterY;
      if (_isNavigating && !expanded && !_isNavOverview) {
        switch (_drivingCameraAngle) {
          case DrivingCameraAngle.chase3D:
            visibleCenterY = (bottomSheetTop - 58.0).clamp(
              topObstruction + 90.0,
              screenHeight * 0.72,
            );
          case DrivingCameraAngle.topDown2D:
            visibleCenterY =
                topObstruction + (bottomSheetTop - topObstruction) * 0.62;
          case DrivingCameraAngle.northUp2D:
          case DrivingCameraAngle.overview:
            visibleCenterY = (topObstruction + bottomSheetTop) / 2.0;
        }
      } else {
        visibleCenterY = (topObstruction + bottomSheetTop) / 2.0;
      }
      final double screenCenterY = screenHeight / 2.0;

      // Pixel shift needed to move the target into the desired screen Y position
      final double pixelShiftUp = screenCenterY - visibleCenterY;

      if (pixelShiftUp.abs() < 1.0) return targetLocation;

      final double metersPerPixel =
          (156543.03392 * math.cos(targetLocation.latitude * math.pi / 180.0)) /
          math.pow(2.0, zoom);
      final double aheadMeters = -pixelShiftUp * metersPerPixel;
      final double effectiveRotation = rotationDeg ?? _currentMapRotation;
      final double upHeadingRad = (-effectiveRotation) * math.pi / 180.0;
      final double dLat = (aheadMeters * math.cos(upHeadingRad)) / 111139.0;
      final double metersPerLng =
          (111320.0 * math.cos(targetLocation.latitude * math.pi / 180.0))
              .clamp(1.0, 111320.0);
      final double dLng = (aheadMeters * math.sin(upHeadingRad)) / metersPerLng;

      return LatLng(
        targetLocation.latitude + dLat,
        targetLocation.longitude + dLng,
      );
    } catch (_) {
      return targetLocation;
    }
  }

  void _animatedMapMoveToVisible(
    LatLng targetLocation,
    double destZoom, {
    bool? isExpandedSheet,
    double? rotationDeg,
  }) {
    final center = _getVisibleMapOffsetCameraCenter(
      targetLocation,
      destZoom,
      isExpandedSheet: isExpandedSheet,
      rotationDeg: rotationDeg ?? _currentMapRotation,
    );
    _animatedMapMove(center, destZoom);
  }

  void _setRouteSheetExpanded(bool expanded) {
    setState(() {
      _isRouteSheetExpanded = expanded;
      if (expanded) {
        _isRouteDockMinimized = false;
      }
    });

    final LatLng? focusPoint =
        (_selectedStepIndex != null &&
            _routeSteps.isNotEmpty &&
            _selectedStepIndex! < _routeSteps.length)
        ? _routeSteps[_selectedStepIndex!].location
        : _currentPosition;

    if (focusPoint != null) {
      _animatedMapMoveToVisible(
        focusPoint,
        _mapController.camera.zoom,
        isExpandedSheet: expanded,
      );
    }
  }

  // Navigation state
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _originController = TextEditingController(
    text: 'Your location',
  );
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _originFocusNode = FocusNode();
  final FocusNode _destinationFocusNode = FocusNode();
  bool _isRouteSheetExpanded = false;
  bool _isRouteDockMinimized = false;
  List<Map<String, dynamic>> _searchHistory = [];
  LatLng? _customOrigin;
  bool _isRoutePlanningMode = false;
  bool _isEditingOrigin = false;
  List<LatLng> _routePoints = [];
  List<List<LatLng>> _alternativeRoutes = [];
  List<int> _routePotholeCounts = [];
  List<double> _routeDurations = [];
  int _selectedRouteIndex = 0;
  int _lastMatchedSegmentIndex = 0;
  OsrmTravelMode _travelMode = OsrmTravelMode.car;
  List<RouteStep> _routeSteps = [];
  List<List<RouteStep>> _alternativeRouteSteps = [];
  int? _selectedStepIndex;
  bool _isRouting = false;
  int _routingRequestSeq = 0;
  int _hazardRefreshSeq = 0;
  List<PotholeMarker> _corridorSupplementPotholes = const [];
  String? _lastCorridorFetchKey;
  bool _silentRouting = false;
  bool _isDraggingEndpoint = false;
  int _draggingEndpointKind = 0; // 1 = Point A (origin), 2 = Point B (dest)
  Offset? _endpointDragScreenBase;
  Offset? _endpointDragPointerOffset;
  double _endpointDragDistance = 0.0;
  DateTime _endpointPressStart = DateTime.now();
  Timer? _liveRerouteTimer;
  int _endpointDragRevision = 0;
  bool _isNavigating = false;
  bool _isNavOverview = false;
  DrivingCameraAngle _drivingCameraAngle = DrivingCameraAngle.chase3D;
  bool _isManualRerouting = false;
  String? _drivingHudNotice;
  Timer? _drivingHudNoticeTimer;
  final ValueNotifier<double> _mapRotationNotifier = ValueNotifier<double>(0.0);
  Timer? _navAutoRecenterTimer;
  bool _isAutoRerouting = false;
  DateTime? _lastAutoRerouteAt;
  bool _useMockLocation = false;
  LatLng? _lastRealGpsPosition;
  bool _isEditingDevLocation = false;
  LatLng? _pendingDevLocation;
  bool _isMapDragging = false;
  RouteBoundingBox? _lastMarkerViewportBounds;
  bool _pendingPostFrameViewportRebuild = false;
  Timer? _viewportRebuildTimer;

  final bool _showMarkers = true;
  final Map<String, LatLng> _snappedPotholeCache = {};
  final Map<String, bool> _snappedWasVerified = {};
  final Set<String> _selectedDefectNames = {
    for (final cls in DpwhStandards.allClasses) cls.name,
  };
  bool _includePendingLayer = true;
  bool _isOffline = false;
  StreamSubscription<dynamic>? _connectivitySubscription;

  bool get _hasActiveDefectFilter =>
      _selectedDefectNames.length < DpwhStandards.allClasses.length ||
      !_includePendingLayer;

  void _resetMapFilters() {
    setState(() {
      _selectedDefectNames
        ..clear()
        ..addAll(DpwhStandards.allClasses.map((c) => c.name));
      _includePendingLayer = true;
      _cachedPotholeClusters = null;
      _expandedClusterId = null;
    });
  }

  List<dynamic> _suggestions = [];
  bool _isLoadingSuggestions = false;
  Timer? _debounceTimer;
  Map<String, dynamic>? _searchedPlace;

  bool get _isSearchingActive {
    return _isSearchPageActive ||
        _isChoosingLocationOnMap ||
        _searchFocusNode.hasFocus ||
        _originFocusNode.hasFocus ||
        _destinationFocusNode.hasFocus ||
        _suggestions.isNotEmpty;
  }

  // Navigation / Follow Mode state
  FollowMode _followMode = FollowMode.location;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  LatLng? _destination;
  double? _lastGpsAccuracyMeters;
  double? _lastGpsSpeedMps;
  DateTime? _lastGpsTimestamp;
  LatLng? _lastProximityCheckPos;
  DateTime? _lastProximityCheckAt;
  final ValueNotifier<double?> _lastHeadingNotifier = ValueNotifier(null);
  List<LatLng> _potholesOnRoute = [];
  RouteComparisonResult? _routeComparison;
  PrecomputedRouteIndex? _activeRouteIndex;
  NavigationHazardTracker? _navigationTracker;
  NavigationHazardState? _navHazardState;
  bool _isSearchingAlternatives = false;
  bool _hasEvaluatedFewerPotholes = false;
  String? _routeErrorMessage;
  bool _routeUsingCachedGeometry = false;
  final Set<String> _spokenEncounterIds = {};

  // Decouple static route-corridor inclusion from transient driver GPS jitter;
  // driver uncertainty is handled inside NavigationHazardTracker instead.
  RouteCorridorConfig get _corridorConfig => RouteCorridorConfig(
    corridorMeters: RouteCorridorConfig.effectiveCorridorMeters(
      baseCorridorMeters: widget.routeCorridorMeters,
    ),
  );

  // Pothole Proximity Alert & Route Advisor
  late final FlutterTts _tts = FlutterTts();
  static const String _locationPrimerPrefKey = 'gps_primer_shown';
  String _nearestPotholeInfo = '';
  String? _nextPotholeEta;
  bool _inProximityWarning = false;
  final Set<String> _alertedAt50m = {};
  final Set<String> _alertedAtPreWarning = {};
  bool _isInitialStartup = true;
  // Warning changes must not rebuild the map's tiles, routes and markers.
  final _warningBanner =
      ValueNotifier<({bool highlighted, String? dismissedEncounterId})>((
        highlighted: false,
        dismissedEncounterId: null,
      ));
  Timer? _warningBannerTimer;
  final Set<String> _dismissedSampleIds = {};
  RouteSwitchSuggestion? _routeSwitchSuggestion;
  UpcomingHazardCountdown? _upcomingHazard;
  Timer? _simulationTimer;
  bool _isSimulatingRoute = false;
  double _simulatedChainMeters = 0.0;
  bool _isSearchVisible = true;
  bool _isSearchPageActive = false;
  bool _isChoosingLocationOnMap = false;
  bool _isChoosingOriginOnMap = false;
  bool _isPlacingMarker = false;
  bool _isSavingPlacedMarker = false;
  LatLng? _pendingMarkerLocation;

  static const double _snapRadiusMeters =
      RouteCorridorConfig.defaultCorridorMeters;
  static const double _proximityCircleRadiusMeters = 22.0;
  static const double _offRouteRerouteThresholdMeters = 55.0;
  static const Duration _autoRerouteCooldown = Duration(seconds: 12);

  bool _isReportExcluded(PotholeMarker p) {
    final normalizedStatus = p.status.trim().toLowerCase();
    return !p.isAccessible ||
        p.isResolved ||
        normalizedStatus == 'deleted' ||
        normalizedStatus == 'rejected' ||
        normalizedStatus == 'resolved' ||
        normalizedStatus == 'fixed' ||
        normalizedStatus == 'closed';
  }

  List<String> _extractDefectClassNames(PotholeMarker p) =>
      DpwhStandards.extractDetectionClassNames(p.detections);

  List<PotholeMarker> get _localDeveloperMarkers =>
      !AppSettings.instance.devMockModeEnabled
      ? []
      : [
          for (final marker in DeveloperMarkers.instance.items)
            PotholeMarker(
              docId: marker.id,
              location: marker.location,
              imagePath: '',
              timestamp: DateTime.now(),
              status: 'approved',
              primaryDefect: marker.defect,
              primaryDpwhCode: DpwhStandards.classify(marker.defect).code,
              reporterUid: 'developer_local',
              formattedAddress: 'Developer marker (local only)',
            ),
        ];

  void _onDeveloperMarkersChanged() {
    if (!mounted) return;
    setState(() {
      _snappedPotholeCache.clear();
      _expandedClusterId = null;
      _invalidatePotholeDerivedCaches();
      if (DeveloperMarkers.owns(_selectedPothole?.docId)) {
        final matching = _localDeveloperMarkers.where(
          (p) => p.docId == _selectedPothole!.docId,
        );
        _selectedPothole = matching.isEmpty ? null : matching.first;
      }
    });
    unawaited(_refreshRouteAwarePotholeState());
  }

  List<PotholeMarker> get _effectivePotholes {
    final bool devMockEnabled = AppSettings.instance.devMockModeEnabled;
    if (_cachedEffectivePotholes != null &&
        identical(widget.detectedPotholes, _cachedDetectedPotholesRef) &&
        _cachedDetectedPotholesLen == widget.detectedPotholes.length &&
        _cachedDevMockEnabled == devMockEnabled &&
        _cachedEffectiveVersion == _potholeDerivedVersion) {
      return _cachedEffectivePotholes!;
    }
    final reports = [
      ...widget.detectedPotholes.where(
        (p) => !isSampleStaMariaMarkerId(p.docId),
      ),
      ..._localDeveloperMarkers,
    ];
    List<PotholeMarker> resolved;
    if (_corridorSupplementPotholes.isEmpty) {
      resolved = reports;
    } else {
      final existingIds = <String>{};
      final existingKeys = <String>{};
      final suppressedIds = <String>{..._dismissedSampleIds};
      for (final p in reports) {
        final docId = p.docId?.trim();
        if (docId != null && docId.isNotEmpty) {
          existingIds.add(docId);
          if (_isReportExcluded(p)) {
            suppressedIds.add(docId);
          }
        } else {
          existingKeys.add(_potholeKey(p.location));
        }
      }
      final merged = List<PotholeMarker>.from(reports);
      for (final c in _corridorSupplementPotholes) {
        if (isSampleStaMariaMarkerId(c.docId)) continue;
        if (_isReportExcluded(c)) continue;
        final docId = c.docId?.trim();
        if (docId != null && docId.isNotEmpty) {
          if (suppressedIds.contains(docId) || existingIds.contains(docId)) {
            continue;
          }
          existingIds.add(docId);
        } else {
          final key = _potholeKey(c.location);
          if (existingKeys.contains(key)) continue;
          existingKeys.add(key);
        }
        merged.add(c);
      }
      resolved = merged;
    }
    _cachedDetectedPotholesRef = widget.detectedPotholes;
    _cachedDetectedPotholesLen = widget.detectedPotholes.length;
    _cachedDevMockEnabled = devMockEnabled;
    _cachedEffectiveVersion = _potholeDerivedVersion;
    _cachedEffectivePotholes = resolved;
    return resolved;
  }

  List<RouteHazardInput> _buildHazardInputs() {
    final bool devMockEnabled = AppSettings.instance.devMockModeEnabled;
    if (_cachedHazardInputs != null &&
        identical(widget.detectedPotholes, _cachedDetectedPotholesRef) &&
        _cachedDetectedPotholesLen == widget.detectedPotholes.length &&
        _cachedDevMockEnabled == devMockEnabled &&
        _cachedHazardInputsVersion == _potholeDerivedVersion) {
      return _cachedHazardInputs!;
    }
    final List<RouteHazardInput> inputs = [];
    for (final p in _effectivePotholes) {
      if (_isReportExcluded(p)) {
        continue;
      }
      final normalizedStatus = p.status.trim().toLowerCase();
      final canonical = DpwhStandards.classify(p.primaryDefect).name;
      final detectedDefects = _extractDefectClassNames(p);
      final key = _potholeKey(p.location);
      final snapped = _snappedPotholeCache[key] ?? p.location;
      final String? docId = p.docId?.trim();
      final String? reportId = (docId != null && docId.isNotEmpty)
          ? docId
          : (p.id != null ? 'local_${p.id}' : null);
      inputs.add(
        RouteHazardInput(
          location: snapped,
          rawLocation: p.location,
          defectName: canonical,
          dpwhCode: p.primaryDpwhCode,
          barangay: p.barangay,
          potholeCount: p.potholeCount > 0 ? p.potholeCount : 1,
          detectedDefects: detectedDefects,
          reportId: reportId,
          canonicalDefectId: p.canonicalDefectId,
          status: normalizedStatus,
          isResolved: p.isResolved,
          isAccessible: p.isAccessible,
          roadName: p.roadName,
          roadBearingDeg: p.roadBearingDeg,
          roadMatched: (_snappedWasVerified[key] ?? false) || p.roadMatched,
          updatedAt: p.timestamp,
        ),
      );
    }
    _cachedDetectedPotholesRef = widget.detectedPotholes;
    _cachedDetectedPotholesLen = widget.detectedPotholes.length;
    _cachedDevMockEnabled = devMockEnabled;
    _cachedHazardInputsVersion = _potholeDerivedVersion;
    _cachedHazardInputs = inputs;
    return inputs;
  }

  static const double _lookAheadOffset = 0.0018;

  static const String _orsApiKey = String.fromEnvironment('ORS_API_KEY');

  @override
  void initState() {
    super.initState();
    DeveloperMarkers.instance.addListener(_onDeveloperMarkersChanged);
    AppSettings.instance.devMockModeNotifier.addListener(
      _onDeveloperMarkersChanged,
    );
    unawaited(DeveloperMarkers.instance.load().catchError((Object _) {}));

    _puckPulseController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    );
    if (widget.isMapActive) {
      _puckPulseController.repeat();
    }
    if (_cachedGlobalPosition != null) {
      _currentPosition = _cachedGlobalPosition;
      _gpsSmoother.reset(position: _cachedGlobalPosition);
      _animatedPuckPositionNotifier.value = _cachedGlobalPosition;
      _isLoadingLocation = false;
    }
    _determinePosition(requestPermission: false);
    if (!kIsWeb) {
      _tts.setLanguage('en-US');
      _tts.setSpeechRate(0.5);
      _tts.setVolume(1.0);
    }
    _searchFocusNode.addListener(_onSearchFocusChanged);
    _originFocusNode.addListener(_onSearchFocusChanged);
    _destinationFocusNode.addListener(_onSearchFocusChanged);
    _loadSearchHistory();
    AppSettings.instance.devMockModeNotifier.addListener(
      _onDevMockModeSettingChanged,
    );
    AppSettings.instance.manualPotholePlacementNotifier.addListener(
      _onManualPotholePlacementSettingChanged,
    );
    AppSettings.instance.devEditLocationNotifier.addListener(
      _onDevEditLocationSettingChanged,
    );
    _travelMode = _travelModeFromSetting(
      AppSettings.instance.mobileNavVehicleModeNotifier.value,
    );
    AppSettings.instance.mobileNavVehicleModeNotifier.addListener(
      _onNavVehicleModeChanged,
    );
    _connectivitySubscription = watchSafeOfflineState((offline) {
      final wasOffline = _isOffline;
      if (mounted && _isOffline != offline) {
        setState(() => _isOffline = offline);
      }
      if (!offline && (wasOffline || _tileProvider.hasFallbackTiles)) {
        _refreshMapTiles();
      }
      if (!offline) {
        unawaited(
          _tileProvider.prewarmArea(
            center: _currentPosition ?? _bulacanCenter,
          ),
        );
      }
    });
  }

  void _onSearchFocusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSearchHistory() async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = io.File('${dir.path}/map_search_history.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final List decoded = jsonDecode(content) as List;
        if (mounted) {
          setState(() {
            _searchHistory = decoded
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveSearchHistory() async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = io.File('${dir.path}/map_search_history.json');
      await file.writeAsString(jsonEncode(_searchHistory));
    } catch (_) {}
  }

  void _addToSearchHistory({
    required String name,
    required String address,
    required double lat,
    required double lon,
  }) {
    _searchHistory.removeWhere(
      (item) =>
          item['name'] == name ||
          ((item['lat'] as num?)?.toDouble() == lat &&
              (item['lon'] as num?)?.toDouble() == lon),
    );
    _searchHistory.insert(0, {
      'name': name,
      'address': address,
      'lat': lat,
      'lon': lon,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (_searchHistory.length > 12) {
      _searchHistory = _searchHistory.sublist(0, 12);
    }
    if (mounted) setState(() {});
    _saveSearchHistory();
  }

  void _removeFromSearchHistory(int index) {
    if (index >= 0 && index < _searchHistory.length) {
      setState(() {
        _searchHistory.removeAt(index);
      });
      _saveSearchHistory();
    }
  }

  void _clearSearchHistory() {
    setState(() {
      _searchHistory.clear();
    });
    _saveSearchHistory();
  }

  void _onDevMockModeSettingChanged() {
    if (!mounted) return;
    setState(() {
      if (!AppSettings.instance.devMockModeNotifier.value &&
          !AppSettings.instance.mobileDevMockLocationEnabled) {
        if (_isPlacingMarker) _cancelMarkerPlacement();
        if (_isEditingDevLocation) _cancelDevLocationEdit();
      }
    });
  }

  void _onManualPotholePlacementSettingChanged() {
    if (!mounted) return;
    final bool placing =
        AppSettings.instance.manualPotholePlacementNotifier.value;
    if (placing && !_isPlacingMarker) {
      _startMarkerPlacement();
    } else if (!placing && _isPlacingMarker) {
      _cancelMarkerPlacement();
    }
  }

  void _onDevEditLocationSettingChanged() {
    if (!mounted) return;
    final bool devLoc = AppSettings.instance.devEditLocationNotifier.value;
    if (devLoc && !_isEditingDevLocation) {
      _startDevLocationEdit();
    } else if (!devLoc && _isEditingDevLocation) {
      _cancelDevLocationEdit();
    }
  }

  @override
  void didUpdateWidget(covariant MapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isMapActive != widget.isMapActive) {
      if (widget.isMapActive) {
        if (!_isNavigating && !_puckPulseController.isAnimating) {
          _puckPulseController.repeat();
        }
        _startFollowing();
      } else {
        _puckPulseController.stop();
        _positionSubscription?.cancel();
        _compassSubscription?.cancel();
        _stopPuckTicker();
      }
    }
    final oldSig = _potholeListSignature(oldWidget.detectedPotholes);
    final newSig = _potholeListSignature(widget.detectedPotholes);
    if (oldSig != newSig ||
        oldWidget.routeCorridorMeters != widget.routeCorridorMeters) {
      _snappedPotholeCache.clear();
      _snappedWasVerified.clear();
      _corridorSupplementPotholes = const [];
      _lastCorridorFetchKey = null;
      _invalidatePotholeDerivedCaches();
      unawaited(_refreshRouteAwarePotholeState(refetchCorridor: true));
    }
  }

  @override
  void dispose() {
    DeveloperMarkers.instance.removeListener(_onDeveloperMarkersChanged);
    AppSettings.instance.devMockModeNotifier.removeListener(
      _onDeveloperMarkersChanged,
    );

    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _originFocusNode.removeListener(_onSearchFocusChanged);
    _destinationFocusNode.removeListener(_onSearchFocusChanged);
    _searchFocusNode.dispose();
    _originFocusNode.dispose();
    _destinationFocusNode.dispose();
    AppSettings.instance.devMockModeNotifier.removeListener(
      _onDevMockModeSettingChanged,
    );
    AppSettings.instance.manualPotholePlacementNotifier.removeListener(
      _onManualPotholePlacementSettingChanged,
    );
    AppSettings.instance.devEditLocationNotifier.removeListener(
      _onDevEditLocationSettingChanged,
    );
    AppSettings.instance.mobileNavVehicleModeNotifier.removeListener(
      _onNavVehicleModeChanged,
    );
    _subPageTourTimer?.cancel();
    _navAutoRecenterTimer?.cancel();
    _drivingHudNoticeTimer?.cancel();
    _simulationTimer?.cancel();
    _searchController.dispose();
    _originController.dispose();
    _debounceTimer?.cancel();
    _liveRerouteTimer?.cancel();
    _connectivitySubscription?.cancel();
    _viewportRebuildTimer?.cancel();
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();
    _navigationTracker?.reset();
    _spokenEncounterIds.clear();
    _puckPulseController.dispose();
    _warningBannerTimer?.cancel();
    _warningBanner.dispose();
    _puckTicker?.stop();
    _puckTicker?.dispose();
    _puckTicker = null;
    final prevMapMoveController = _mapMoveController;
    _mapMoveController = null;
    prevMapMoveController?.stop();
    prevMapMoveController?.dispose();
    _animatedPuckPositionNotifier.dispose();
    _lastHeadingNotifier.dispose();
    _mapRotationNotifier.dispose();
    _tileLayerResetController.close();
    _httpClient.close();
    if (!kIsWeb) _tts.stop();
    AppSettings.instance.setRouteActive(false);
    super.dispose();
  }

  void _toggleFollowMode() {
    setState(() {
      if (_followMode == FollowMode.location) {
        _followMode = FollowMode.compass;
      } else {
        _followMode = FollowMode.location;
      }
    });

    if (_currentPosition != null) {
      if (_destination != null) {
        final next = _getNextRoutePoint(_currentPosition!);
        if (next != null) {
          final bearing = Geolocator.bearingBetween(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
            next.latitude,
            next.longitude,
          );
          if (_followMode == FollowMode.compass) {
            _mapController.rotate((360 - bearing) % 360);
          } else {
            _mapController.rotate(0);
          }
          final lookahead = _lookAheadPoint(
            _currentPosition!,
            bearing,
            _lookAheadOffset,
          );
          _mapController.move(lookahead, 16.5);
        } else {
          _mapController.move(_currentPosition!, 16.5);
        }
      } else {
        _mapController.move(_currentPosition!, 16.5);
        _mapController.rotate(0);
      }
    }
    _startFollowing();
  }

  LatLng _projectPointToSegment(LatLng p, LatLng a, LatLng b) {
    final double latRefRad =
        ((a.latitude + b.latitude) / 2.0) * (3.141592653589793 / 180.0);
    final double metersPerDegLat = 110540.0;
    final double metersPerDegLon = 111320.0 * cos(latRefRad);

    if (metersPerDegLon.abs() < 1e-6) return a;

    final double bx = (b.longitude - a.longitude) * metersPerDegLon;
    final double by = (b.latitude - a.latitude) * metersPerDegLat;
    final double px = (p.longitude - a.longitude) * metersPerDegLon;
    final double py = (p.latitude - a.latitude) * metersPerDegLat;

    final double abLen2 = bx * bx + by * by;
    if (abLen2 <= 1e-6) return a;

    double t = (px * bx + py * by) / abLen2;
    if (t <= 0) return a;
    if (t >= 1) return b;

    final double projLon = a.longitude + (t * (b.longitude - a.longitude));
    final double projLat = a.latitude + (t * (b.latitude - a.latitude));
    return LatLng(projLat, projLon);
  }

  int _findBestRouteSegmentIndex(List<LatLng> route, LatLng userPos) {
    if (route.length < 2) return 0;

    int bestSegmentIdx = 0;
    double minDistance = double.infinity;

    // 1. Check local forward window around _lastMatchedSegmentIndex first
    int startWin = (_lastMatchedSegmentIndex - 2).clamp(0, route.length - 2);
    int endWin = (_lastMatchedSegmentIndex + 20).clamp(0, route.length - 2);

    for (int i = startWin; i <= endWin; i++) {
      final dist = _distancePointToSegmentMeters(
        userPos,
        route[i],
        route[i + 1],
      );
      if (dist < minDistance) {
        minDistance = dist;
        bestSegmentIdx = i;
      }
    }

    // If within reasonable tracking tolerance (40m), accept this forward window match!
    if (minDistance <= 40.0) {
      _lastMatchedSegmentIndex = bestSegmentIdx;
      return bestSegmentIdx;
    }

    // 2. Otherwise (user off-route or fresh start), scan all segments
    minDistance = double.infinity;
    for (int i = 0; i < route.length - 1; i++) {
      final dist = _distancePointToSegmentMeters(
        userPos,
        route[i],
        route[i + 1],
      );
      if (dist < minDistance) {
        minDistance = dist;
      }
    }

    // Collect all candidate segments within (minDistance + 15m)
    final List<int> candidateIndices = [];
    for (int i = 0; i < route.length - 1; i++) {
      final dist = _distancePointToSegmentMeters(
        userPos,
        route[i],
        route[i + 1],
      );
      if (dist <= minDistance + 15.0) {
        candidateIndices.add(i);
      }
    }

    if (candidateIndices.isNotEmpty) {
      bestSegmentIdx = candidateIndices.first;
    } else {
      bestSegmentIdx = 0;
    }

    _lastMatchedSegmentIndex = bestSegmentIdx;
    return bestSegmentIdx;
  }

  LatLng? _getNextRoutePoint(LatLng userPos) {
    if (_routePoints.isEmpty) return _destination;
    final int segIdx = _findBestRouteSegmentIndex(_routePoints, userPos);
    final aheadIdx = (segIdx + 4).clamp(0, _routePoints.length - 1);
    return _routePoints[aheadIdx];
  }

  List<LatLng> _remainingRouteFromUser(List<LatLng> route, LatLng userPos) {
    if (route.length < 2) return route;

    final int segIdx = _findBestRouteSegmentIndex(route, userPos);
    final LatLng projPoint = _projectPointToSegment(
      userPos,
      route[segIdx],
      route[segIdx + 1],
    );

    final double distToProj = Geolocator.distanceBetween(
      userPos.latitude,
      userPos.longitude,
      projPoint.latitude,
      projPoint.longitude,
    );
    if (distToProj > _offRouteRerouteThresholdMeters) {
      // Avoid drawing an off-road diagonal segment while waiting for OSRM reroute.
      return route;
    }

    final List<LatLng> remaining = [userPos];
    if (distToProj > 1.0) {
      remaining.add(projPoint);
    }

    for (int i = segIdx + 1; i < route.length; i++) {
      remaining.add(route[i]);
    }

    return remaining;
  }

  double _distancePointToRouteMeters(LatLng point, List<LatLng> route) {
    if (route.isEmpty) return double.infinity;
    if (route.length == 1) {
      return Geolocator.distanceBetween(
        point.latitude,
        point.longitude,
        route.first.latitude,
        route.first.longitude,
      );
    }

    double minDist = double.infinity;
    for (int i = 0; i < route.length - 1; i++) {
      final d = _distancePointToSegmentMeters(point, route[i], route[i + 1]);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  Future<void> _autoAdjustRouteToCurrentPath(LatLng userPos) async {
    final bool isUsingCustomOrigin =
        _customOrigin != null && _originController.text != 'Your location';
    if (_destination == null ||
        _alternativeRoutes.isEmpty ||
        _isRouting ||
        _isAutoRerouting ||
        isUsingCustomOrigin) {
      return;
    }

    final int safeActiveIndex = _selectedRouteIndex < _alternativeRoutes.length
        ? _selectedRouteIndex
        : 0;
    final double activeDist = _distancePointToRouteMeters(
      userPos,
      _alternativeRoutes[safeActiveIndex],
    );

    final bool shouldReroute =
        activeDist > _corridorConfig.offRouteThresholdMeters;
    final now = DateTime.now();
    final bool cooldownActive =
        _lastAutoRerouteAt != null &&
        now.difference(_lastAutoRerouteAt!) < _autoRerouteCooldown;

    if (!shouldReroute || cooldownActive) return;

    _isAutoRerouting = true;
    _lastAutoRerouteAt = now;
    try {
      await _calculateRoute(_destination!, fitCamera: false, silent: true);
    } finally {
      _isAutoRerouting = false;
    }
  }

  double _calculatePolylineDistanceMeters(List<LatLng> points) {
    double distance = 0;
    for (int i = 0; i < points.length - 1; i++) {
      distance += Geolocator.distanceBetween(
        points[i].latitude,
        points[i].longitude,
        points[i + 1].latitude,
        points[i + 1].longitude,
      );
    }
    return distance;
  }

  LatLng _lookAheadPoint(LatLng origin, double headingDeg, double distance) {
    final double rad = headingDeg * (3.141592653589793 / 180.0);
    return LatLng(
      origin.latitude + distance * cos(rad),
      origin.longitude + distance * sin(rad),
    );
  }

  LocationSettings _buildTrackingLocationSettings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 500),
      );
    }
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  List<LatLng>? _activeRouteForPuckSnap() {
    if (_destination == null || _alternativeRoutes.isEmpty) return null;
    final bool isUsingCustomOrigin =
        _customOrigin != null && _originController.text != 'Your location';
    if (isUsingCustomOrigin && !_isSimulatingRoute) return null;
    final int activeIndex = _selectedRouteIndex < _alternativeRoutes.length
        ? _selectedRouteIndex
        : 0;
    final route = _alternativeRoutes[activeIndex];
    return route.length >= 2 ? route : null;
  }

  void _startFollowing() {
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();

    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: _buildTrackingLocationSettings(),
        ).listen(
          (Position position) {
            if (!widget.isMapActive || !mounted) return;
            final gpsPos = LatLng(position.latitude, position.longitude);
            _lastRealGpsPosition = gpsPos;
            _lastGpsAccuracyMeters = position.accuracy;
            _lastGpsSpeedMps = position.speed;
            _lastGpsTimestamp = position.timestamp;

            if (_useMockLocation) {
              return;
            }

            final result = _gpsSmoother.ingestFix(
              GpsFixSample(
                position: gpsPos,
                timestamp: position.timestamp,
                accuracyMeters: position.accuracy,
                speedMps: position.speed,
                headingDeg: position.heading >= 0 ? position.heading : null,
              ),
              activeRoute: _activeRouteForPuckSnap(),
              isNavigating: _isNavigating,
            );
            if (!result.accepted || result.filteredPosition == null) {
              return;
            }

            final newPos = result.filteredPosition!;
            _currentPosition = newPos;
            final now = DateTime.now();
            final shouldCheckProximity =
                _lastProximityCheckPos == null ||
                _lastProximityCheckAt == null ||
                now.difference(_lastProximityCheckAt!).inMilliseconds >= 1200 ||
                GpsTrackerSmoother.distanceMeters(
                      _lastProximityCheckPos!,
                      newPos,
                    ) >=
                    1.8;
            if (shouldCheckProximity) {
              _lastProximityCheckPos = newPos;
              _lastProximityCheckAt = now;
              _checkPotholeProximity(newPos);
            }
            unawaited(_autoAdjustRouteToCurrentPath(newPos));

            if (result.shouldSnapImmediately) {
              _animatedPuckPositionNotifier.value = newPos;
              if (result.fusedHeadingDeg != null) {
                _lastHeadingNotifier.value = result.fusedHeadingDeg;
              }
              if (_followMode != FollowMode.none && !_isDraggingEndpoint) {
                final cameraCenter = _getVisibleMapOffsetCameraCenter(
                  newPos,
                  _mapController.camera.zoom,
                );
                _mapController.move(cameraCenter, _mapController.camera.zoom);
              }
            } else {
              _ensurePuckTickerRunning();
            }
          },
          onError: (_) {
            if (!mounted) return;
            if (_navigationTracker != null && _isNavigating) {
              setState(() {
                _navHazardState = _navigationTracker!.update(
                  position: null,
                  gpsAccuracyMeters: _lastGpsAccuracyMeters,
                );
              });
            }
          },
        );

    if (!kIsWeb) {
      _compassSubscription = FlutterCompass.events?.listen((
        CompassEvent event,
      ) {
        if (!widget.isMapActive || !mounted) return;
        if (event.heading == null) return;

        // Fused heading: compass drives orientation when stationary/slow,
        // while steady GPS course / route bearing takes priority during nav.
        _gpsSmoother.ingestCompassHeading(
          event.heading!,
          now: DateTime.now(),
          isNavigating: _isNavigating,
        );
        if (!_isNavigating || _lastHeadingNotifier.value == null) {
          _ensurePuckTickerRunning();
        }
      });
    }
  }

  void _checkPotholeProximity(LatLng userPos) {
    if (!widget.isMapActive) return;
    List<LatLng> routeForChecks = _routePoints;
    List<LatLng> warningCandidates;

    final bool isUsingCustomOrigin =
        _customOrigin != null && _originController.text != 'Your location';
    List<LatLng>? activeFullRoute;
    NavigationHazardState? navState;
    List<RouteHazardInput> roamingEligiblePotholes = const [];
    if (_destination != null && _alternativeRoutes.isNotEmpty) {
      final int activeIndex = _selectedRouteIndex < _alternativeRoutes.length
          ? _selectedRouteIndex
          : 0;
      activeFullRoute = _alternativeRoutes[activeIndex];
      routeForChecks = (isUsingCustomOrigin && !_isSimulatingRoute)
          ? activeFullRoute
          : _remainingRouteFromUser(activeFullRoute, userPos);

      _activeRouteIndex ??= PrecomputedRouteIndex.build(
        route: activeFullRoute,
        hazards: _buildHazardInputs(),
        routeIndex: activeIndex,
        routeDistanceMeters: activeIndex < _routeDistances.length
            ? _routeDistances[activeIndex]
            : null,
        durationSeconds: activeIndex < _routeDurations.length
            ? _routeDurations[activeIndex]
            : 0.0,
        config: _corridorConfig,
        steps: activeIndex < _alternativeRouteSteps.length
            ? _alternativeRouteSteps[activeIndex]
                  .map(
                    (s) => RouteStepRoadSpan(
                      roadName: s.roadName,
                      location: s.location,
                    ),
                  )
                  .toList(growable: false)
            : const [],
      );
      _navigationTracker ??= NavigationHazardTracker(_activeRouteIndex!);
      final LatLng trackingPos = (isUsingCustomOrigin && !_isSimulatingRoute)
          ? activeFullRoute.first
          : userPos;
      navState = _navigationTracker!.update(
        position: trackingPos,
        timestamp: _lastGpsTimestamp,
        gpsAccuracyMeters: _lastGpsAccuracyMeters,
        headingDeg: _lastHeadingNotifier.value,
        speedMps: _lastGpsSpeedMps,
        offRouteThresholdMeters: _corridorConfig.offRouteThresholdMeters,
      );
      warningCandidates = _activeRouteIndex!.summary.potholeEncounters
          .map((e) => e.hazard.location)
          .toList(growable: false);
    } else {
      final List<RouteHazardInput> activeHazardInputs = _buildHazardInputs();
      roamingEligiblePotholes = activeHazardInputs
          .where(
            (h) => h.isEligibleForPublicRouteCount && h.containsPotholeClass,
          )
          .toList(growable: false);
      navState = null;
      warningCandidates = roamingEligiblePotholes
          .map((h) => h.location)
          .toList(growable: false);
    }

    double absoluteMin = double.infinity;
    String? closestPotholeKey;
    LatLng? closestPotholeLoc;

    for (final pothole in warningCandidates) {
      final dist = Geolocator.distanceBetween(
        userPos.latitude,
        userPos.longitude,
        pothole.latitude,
        pothole.longitude,
      );
      if (dist < absoluteMin) {
        absoluteMin = dist;
        closestPotholeLoc = pothole;
        closestPotholeKey =
            '${pothole.latitude.toStringAsFixed(5)},${pothole.longitude.toStringAsFixed(5)}';
      }
    }

    if (absoluteMin == double.infinity) {
      absoluteMin = 9999.0;
    }

    final bool inProximity = absoluteMin <= _proximityCircleRadiusMeters;

    final List<LatLng> pendingPotholes = warningCandidates.where((p) {
      final d = Geolocator.distanceBetween(
        userPos.latitude,
        userPos.longitude,
        p.latitude,
        p.longitude,
      );
      return d > _proximityCircleRadiusMeters;
    }).toList();

    UpcomingHazardCountdown? upcoming;
    if (navState != null &&
        navState.status == NavigationHazardStatus.hazardAhead &&
        navState.nextEncounter != null &&
        navState.distanceToNextMeters != null) {
      final nextEnc = navState.nextEncounter!;
      upcoming = UpcomingHazardCountdown(
        distanceMeters: navState.distanceToNextMeters!,
        defectName: nextEnc.hazard.defectName,
        dpwhCode: nextEnc.hazard.dpwhCode,
        barangay: nextEnc.hazard.barangay,
        potholeCount: nextEnc.hazard.resolvedPotholeDetectionCount,
        isOnActiveRoute: true,
        location: nextEnc.hazard.location,
        encounterId: nextEnc.encounterId,
        remainingOnRoute: navState.remainingPotholeCount,
        totalOnRoute: navState.totalRoutePotholeCount,
      );
    } else if (navState == null) {
      upcoming = RoutePotholeAdvisor.findUpcomingHazard(
        userPos: userPos,
        hazards: roamingEligiblePotholes,
        activeRoute: activeFullRoute,
        forceFromRouteStart: isUsingCustomOrigin && !_isSimulatingRoute,
        routeToleranceMeters: _corridorConfig.corridorMeters,
        roamingRadiusMeters: 600.0,
        offRouteUserThresholdMeters: _corridorConfig.offRouteThresholdMeters,
      );
    } else {
      upcoming = null;
    }

    if (upcoming == null && inProximity && closestPotholeLoc != null) {
      RouteHazardInput? matchedHazard;
      for (final h in roamingEligiblePotholes) {
        if ((h.location.latitude - closestPotholeLoc.latitude).abs() < 1e-6 &&
            (h.location.longitude - closestPotholeLoc.longitude).abs() <
                1e-6) {
          matchedHazard = h;
          break;
        }
      }
      upcoming = UpcomingHazardCountdown(
        distanceMeters: absoluteMin,
        defectName: matchedHazard?.defectName ?? 'Pothole',
        dpwhCode: matchedHazard?.dpwhCode ?? 'POTH',
        barangay: matchedHazard?.barangay ?? '',
        potholeCount: matchedHazard?.resolvedPotholeDetectionCount ?? 1,
        isOnActiveRoute: activeFullRoute != null,
        location: closestPotholeLoc,
        encounterId: 'prox_${closestPotholeKey ?? ''}',
        remainingOnRoute: 1,
        totalOnRoute: 1,
      );
    }

    String nearestInfo = 'Clear ahead';
    String? nextPotholeEta;
    double nearestDistMeters = upcoming?.distanceMeters ?? double.infinity;

    if (upcoming != null) {
      nearestInfo = RoutePotholeAdvisor.formatDistanceAhead(
        upcoming.distanceMeters,
      );
      if (_destination != null && routeForChecks.length >= 2) {
        final int activeIndex = _selectedRouteIndex < _routeDurations.length
            ? _selectedRouteIndex
            : 0;
        final double totalDur =
            (_routeDurations.isNotEmpty && activeIndex < _routeDurations.length)
            ? _routeDurations[activeIndex]
            : 0.0;
        final double totalDist =
            (_routeDistances.isNotEmpty && activeIndex < _routeDistances.length)
            ? _routeDistances[activeIndex]
            : _calculatePolylineDistanceMeters(
                activeFullRoute ?? routeForChecks,
              );

        double etaSeconds = (totalDist > 0 && totalDur > 0)
            ? (nearestDistMeters / totalDist) * totalDur
            : nearestDistMeters / 9.72;

        if (etaSeconds < 60) {
          nextPotholeEta = '${etaSeconds.clamp(1, 59).round()}s';
        } else if (etaSeconds < 3600) {
          final mins = (etaSeconds / 60).floor();
          final secs = (etaSeconds % 60).round();
          nextPotholeEta = secs > 0 ? '${mins}m ${secs}s' : '$mins min';
        } else {
          final hrs = (etaSeconds / 3600).floor();
          final mins = ((etaSeconds % 3600) / 60).round();
          nextPotholeEta = '${hrs}h ${mins}m';
        }
      }
    }

    final nextRoutePoints = (_destination != null && !_isDraggingEndpoint)
        ? routeForChecks
        : _routePoints;
    final nextPotholesOnRoute = (_destination != null && !_isDraggingEndpoint)
        ? (pendingPotholes.isNotEmpty ? pendingPotholes : warningCandidates)
        : _potholesOnRoute;

    final bool hudChanged =
        _inProximityWarning != inProximity ||
        _nearestPotholeInfo != nearestInfo ||
        _nextPotholeEta != nextPotholeEta ||
        _upcomingHazard?.encounterId != upcoming?.encounterId ||
        _upcomingHazard?.distanceMeters.round() !=
            upcoming?.distanceMeters.round() ||
        _navHazardState?.status != navState?.status ||
        _navHazardState?.remainingPotholeCount !=
            navState?.remainingPotholeCount ||
        _navHazardState?.distanceToNextMeters?.round() !=
            navState?.distanceToNextMeters?.round() ||
        _routePoints.length != nextRoutePoints.length ||
        _potholesOnRoute.length != nextPotholesOnRoute.length;

    _currentPosition = userPos;
    if (hudChanged) {
      setState(() {
        _inProximityWarning = inProximity;
        _navHazardState = navState;
        _upcomingHazard = upcoming;
        _nearestPotholeInfo = nearestInfo;
        _nextPotholeEta = nextPotholeEta;
        if (_destination != null && !_isDraggingEndpoint) {
          _routePoints = nextRoutePoints;
          _potholesOnRoute = nextPotholesOnRoute;
        }
      });
    } else {
      _navHazardState = navState;
      _upcomingHazard = upcoming;
      if (_destination != null && !_isDraggingEndpoint) {
        _routePoints = nextRoutePoints;
        _potholesOnRoute = nextPotholesOnRoute;
      }
    }

    final bool allowAlerts =
        _showMarkers &&
        !_isInitialStartup &&
        !kIsWeb &&
        AppSettings.instance.mobileVoiceAlertsEnabled;

    // One-shot speed & accuracy adaptive voice alert along active route
    if (navState != null &&
        navState.alertTriggerToSpeak != null &&
        navState.alertTriggerDistanceMeters != null &&
        (_isNavigating || _isSimulatingRoute)) {
      final enc = navState.alertTriggerToSpeak!;
      if (!_spokenEncounterIds.contains(enc.encounterId)) {
        _spokenEncounterIds.add(enc.encounterId);
        if (allowAlerts) {
          HapticFeedback.lightImpact();
          final spoken = RoutePotholeAdvisor.formatVoiceAlertAnnouncement(
            navState.alertTriggerDistanceMeters!,
          );
          _tts.speak(spoken);
          PotholeNotifier.instance.showPotholeAlert(
            RoutePotholeAdvisor.formatDistanceAhead(
              navState.alertTriggerDistanceMeters!,
            ),
          );
        }
      }
    }

    if (inProximity && closestPotholeKey != null) {
      if (!_alertedAt50m.contains(closestPotholeKey)) {
        _alertedAt50m.add(closestPotholeKey);

        if (_showMarkers) {
          HapticFeedback.lightImpact();
          _triggerWarningBannerCountdown();
          if (allowAlerts &&
              (navState == null || navState.alertTriggerToSpeak == null)) {
            final int meters = absoluteMin.round().clamp(1, 999);
            _tts.speak('Caution, pothole in proximity, $meters meters away.');
            PotholeNotifier.instance.showPotholeAlert(
              'Pothole in proximity (${meters}m)',
            );
          }
        }
      }
    } else if (absoluteMin > 60) {
      _alertedAt50m.clear();
      _alertedAtPreWarning.clear();
      _warningBannerTimer?.cancel();
      _warningBanner.value = (highlighted: false, dismissedEncounterId: null);
    }

    _isInitialStartup = false;
  }

  void _triggerWarningBannerCountdown() {
    _warningBannerTimer?.cancel();
    _warningBanner.value = (
      highlighted: true,
      dismissedEncounterId: _warningBanner.value.dismissedEncounterId,
    );
    // Only the highlight expires; the distance-based warning remains dismissible.
    _warningBannerTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) {
        _warningBanner.value = (
          highlighted: false,
          dismissedEncounterId: _warningBanner.value.dismissedEncounterId,
        );
      }
    });
  }

  void _dismissWarningBanner() {
    if (!mounted) return;
    _warningBannerTimer?.cancel();
    final encounterId =
        _navHazardState?.nextEncounter?.encounterId ??
        _upcomingHazard?.encounterId ??
        (_upcomingHazard == null
            ? null
            : '${_upcomingHazard!.location.latitude},${_upcomingHazard!.location.longitude}');
    _warningBanner.value = (
      highlighted: false,
      dismissedEncounterId: encounterId,
    );
  }

  void _takeDetourAroundHazard(int betterIndex) {
    HapticFeedback.heavyImpact();
    _selectActiveRoute(betterIndex);
    _dismissWarningBanner();
    if (!kIsWeb) {
      _tts.speak(
        'Rerouting to bypass pothole hazard ahead. Alternate path selected.',
      );
    }
  }

  Future<void> _submitHazardFeedback(
    PotholeMarker pothole,
    bool stillThere,
  ) async {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
    if (pothole.docId != null) {
      try {
        await CloudService.instance.submitHazardFeedback(
          pothole.docId!,
          stillThere,
        );
      } catch (_) {}
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                stillThere
                    ? Icons.thumb_up_alt_rounded
                    : Icons.thumb_down_alt_rounded,
                color: stillThere
                    ? const Color(0xFF10B981)
                    : const Color(0xFFEF4444),
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  stillThere
                      ? 'Thanks! Hazard freshness verified for all drivers.'
                      : 'Thanks! Report logged — hazard marked for decay.',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF0F172A),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _onMapPositionChanged(MapCamera camera, bool hasGesture) {
    bool needsRebuild = false;
    final double zoomThreshold = _isNavigating ? 0.60 : 0.05;
    if ((camera.zoom - _lastMarkerZoom).abs() >= zoomThreshold) {
      _lastMarkerZoom = camera.zoom;
      needsRebuild = true;
    }

    if ((_currentMapRotation - camera.rotation).abs() > 0.1) {
      // Only the compass button's north/reset state needs a parent rebuild.
      // FlutterMap handles the actual rotation independently.
      needsRebuild =
          needsRebuild ||
          ((_currentMapRotation.abs() > 1.0) != (camera.rotation.abs() > 1.0));
      _currentMapRotation = camera.rotation;
      _mapRotationNotifier.value = camera.rotation;
    }

    if (hasGesture && _followMode != FollowMode.none) {
      _followMode = FollowMode.none;
      needsRebuild = true;
      if (_isNavigating && !_isNavOverview) {
        _navAutoRecenterTimer?.cancel();
        _navAutoRecenterTimer = Timer(const Duration(seconds: 4), () {
          if (!mounted || !_isNavigating || _isNavOverview) return;
          _applyDrivingCameraAngle(_drivingCameraAngle, showNotice: false);
        });
      }
    }

    if (_isPlacingMarker && hasGesture) {
      _pendingMarkerLocation = camera.center;
      needsRebuild = true;
    }

    if (_isEditingDevLocation && hasGesture) {
      _pendingDevLocation = camera.center;
      needsRebuild = true;
    }

    // Refresh viewport-culled marker clusters when the camera pans or zooms
    // beyond the buffered region (e.g., fitting a long Point A to B route).
    try {
      final currentViewport = _boundingBoxFromBounds(camera.visibleBounds);
      final prevViewport = _lastMarkerViewportBounds;
      if (prevViewport == null ||
          prevViewport.needsViewportRefresh(currentViewport)) {
        _lastMarkerViewportBounds = currentViewport;
        needsRebuild = true;
      }
    } catch (_) {}

    if (needsRebuild) {
      _scheduleViewportMarkerRebuild();
    }
  }

  Future<void> _startMarkerPlacement([PotholeMarker? marker]) async {
    AppSettings.instance.toggleDevMockMode(true);
    try {
      await showDeveloperMarkerEditor(
        context,
        location: marker?.location ?? _mapController.camera.center,
        markerId: marker?.docId,
      );
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open local developer markers.'),
          ),
        );
    } finally {
      if (mounted) _cancelMarkerPlacement();
    }
  }

  void _cancelMarkerPlacement() {
    setState(() {
      _isPlacingMarker = false;
      _isSavingPlacedMarker = false;
      _pendingMarkerLocation = null;
    });
    if (AppSettings.instance.manualPotholePlacementNotifier.value) {
      AppSettings.instance.manualPotholePlacementNotifier.value = false;
    }
  }

  void _startDevLocationEdit() {
    final startPoint = _currentPosition ?? _mapController.camera.center;
    setState(() {
      _isEditingDevLocation = true;
      _pendingDevLocation = startPoint;
      _followMode = FollowMode.none;
      _isPlacingMarker = false;
      _isSavingPlacedMarker = false;
      _pendingMarkerLocation = null;
    });
  }

  void _cancelDevLocationEdit() {
    setState(() {
      _isEditingDevLocation = false;
      _pendingDevLocation = null;
    });
    if (AppSettings.instance.devEditLocationNotifier.value) {
      AppSettings.instance.devEditLocationNotifier.value = false;
    }
  }

  Future<void> _applyDevLocationEdit() async {
    final location = _pendingDevLocation;
    if (location == null) return;

    setState(() {
      _useMockLocation = true;
      _isEditingDevLocation = false;
      _pendingDevLocation = null;
      _currentPosition = location;
      _followMode = FollowMode.location;
    });
    _snapPuckImmediately(location);

    if (AppSettings.instance.devEditLocationNotifier.value) {
      AppSettings.instance.devEditLocationNotifier.value = false;
    }

    _checkPotholeProximity(location);
    final bool usingYourLocation =
        _customOrigin == null ||
        _originController.text.trim() == 'Your location';
    _lastAutoRerouteAt = null;
    if (usingYourLocation && _destination != null) {
      setState(() {
        _rubberBandActiveRoute(newStart: location);
      });
      unawaited(
        _calculateRoute(
          _destination!,
          customOrigin: location,
          fitCamera: false,
          silent: true,
        ),
      );
    } else {
      await _autoAdjustRouteToCurrentPath(location);
    }
    _mapController.move(location, _mapController.camera.zoom);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Dev mock location applied.'),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _resetToRealLocation() {
    if (!_useMockLocation && _lastRealGpsPosition == null) return;
    final livePosition = _lastRealGpsPosition;

    setState(() {
      _useMockLocation = false;
      _isEditingDevLocation = false;
      _pendingDevLocation = null;
      if (livePosition != null) {
        _currentPosition = livePosition;
      }
      _followMode = FollowMode.location;
    });

    if (_currentPosition != null) {
      final LatLng pos = _currentPosition!;
      _snapPuckImmediately(pos);
      _checkPotholeProximity(pos);
      final bool usingYourLocation =
          _customOrigin == null ||
          _originController.text.trim() == 'Your location';
      _lastAutoRerouteAt = null;
      if (usingYourLocation && _destination != null) {
        setState(() {
          _rubberBandActiveRoute(newStart: pos);
        });
        unawaited(
          _calculateRoute(
            _destination!,
            customOrigin: pos,
            fitCamera: false,
            silent: true,
          ),
        );
      } else {
        unawaited(_autoAdjustRouteToCurrentPath(pos));
      }
      _mapController.move(pos, _mapController.camera.zoom);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Returned to real GPS location.')),
    );
  }

  Future<void> _confirmMarkerPlacement() async {
    final location = _pendingMarkerLocation;
    if (location == null) return;
    await showDeveloperMarkerEditor(context, location: location);
    if (mounted) _cancelMarkerPlacement();
  }

  void _onSearchChanged(String query) {
    if (_debounceTimer?.isActive ?? false) _debounceTimer?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _suggestions = [];
        _isLoadingSuggestions = false;
      });
      return;
    }
    setState(() => _isLoadingSuggestions = true);
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (trimmed.isNotEmpty) {
        _fetchSuggestions(trimmed);
      } else {
        setState(() {
          _suggestions = [];
          _isLoadingSuggestions = false;
        });
      }
    });
  }

  String _potholeKey(LatLng p) =>
      '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}';

  String _potholeListSignature(List<PotholeMarker> potholes) {
    return potholes
        .map((p) {
          final detSig = p.detections == null || p.detections!.isEmpty
              ? ''
              : p.detections!
                    .map(
                      (d) =>
                          '${d['className'] ?? d['defectType'] ?? d['rawTag'] ?? d['tag'] ?? d['classId'] ?? ''}',
                    )
                    .join(',');
          return '${p.docId ?? ''}|${p.id ?? -1}|${_potholeKey(p.location)}|'
              '${p.status.trim().toLowerCase()}|${p.isResolved}|${p.isAccessible}|'
              '${p.canonicalDefectId ?? ''}|${p.primaryDefect}|${p.primaryDpwhCode}|'
              '${p.potholeCount}|$detSig|${p.roadName ?? ''}|'
              '${p.roadBearingDeg?.toStringAsFixed(1) ?? ''}|${p.roadMatched}|'
              '${p.timestamp.millisecondsSinceEpoch}';
        })
        .join('||');
  }

  Future<void> _ensurePotholeSnapCache({
    int? requestSeq,
    List<List<LatLng>>? routes,
  }) async {
    final double snapRadius = _snapRadiusMeters < _corridorConfig.corridorMeters
        ? _snapRadiusMeters
        : _corridorConfig.corridorMeters;
    final List<RouteHazardInput> hazards = _buildHazardInputs();
    final activeRoutes = routes ?? _alternativeRoutes;
    final List<RouteBoundingBox> routeBoxes = activeRoutes.isNotEmpty
        ? activeRoutes
              .where((r) => r.length >= 2)
              .map(
                (r) => RouteBoundingBox.fromPoints(
                  r,
                  bufferMeters: snapRadius + 15.0,
                ),
              )
              .toList(growable: false)
        : const [];

    final missing = <LatLng>[];
    final seenMissing = <String>{};
    for (final h in hazards) {
      if (!h.isEligibleForPublicRouteCount) continue;
      if (routeBoxes.isNotEmpty &&
          !routeBoxes.any((b) => b.contains(h.location))) {
        continue;
      }
      final key = _potholeKey(h.location);
      if (_snappedPotholeCache.containsKey(key) || seenMissing.contains(key)) {
        continue;
      }
      seenMissing.add(key);
      missing.add(h.location);
    }
    if (missing.isEmpty) return;

    if (_orsApiKey.isEmpty) {
      for (final p in missing) {
        final key = _potholeKey(p);
        _snappedPotholeCache[key] = p;
        _snappedWasVerified[key] = false;
      }
      _potholeDerivedVersion++;
      _cachedHazardInputs = null;
      return;
    }

    bool anySnapUpdated = false;
    // Batch missing locations in chunks of 30 to strictly satisfy ORS max-location parameter limits (max 50)
    const int batchSize = 30;
    for (int i = 0; i < missing.length; i += batchSize) {
      if (!mounted ||
          (requestSeq != null && requestSeq != _routingRequestSeq)) {
        return;
      }
      final batch = missing.sublist(
        i,
        (i + batchSize > missing.length) ? missing.length : i + batchSize,
      );

      try {
        final url = Uri.parse(
          'https://api.openrouteservice.org/v2/snap/driving-car/json',
        );
        final body = {
          'locations': batch.map((p) => [p.longitude, p.latitude]).toList(),
          'radius': snapRadius,
        };

        final response = await _httpClient
            .post(
              url,
              headers: {
                'Authorization': _orsApiKey,
                'Content-Type': 'application/json',
                'User-Agent': 'PotholeScannerApp/1.0',
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 3));

        if (!mounted ||
            (requestSeq != null && requestSeq != _routingRequestSeq)) {
          return;
        }
        if (response.statusCode != 200) {
          // Transient HTTP failures must not permanently poison the snap cache.
          continue;
        }

        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        final snapped = (payload['locations'] as List?) ?? [];

        for (int j = 0; j < batch.length; j++) {
          final original = batch[j];
          final key = _potholeKey(original);
          final item = j < snapped.length ? snapped[j] : null;

          if (item is Map<String, dynamic>) {
            final loc = item['location'] as List?;
            final dist =
                (item['snapped_distance'] as num?)?.toDouble() ??
                double.infinity;
            if (loc != null && loc.length >= 2 && dist <= snapRadius) {
              _snappedPotholeCache[key] = LatLng(
                (loc[1] as num).toDouble(),
                (loc[0] as num).toDouble(),
              );
              _snappedWasVerified[key] = true;
            } else {
              _snappedPotholeCache[key] = original;
              _snappedWasVerified[key] = false;
            }
          } else {
            _snappedPotholeCache[key] = original;
            _snappedWasVerified[key] = false;
          }
          anySnapUpdated = true;
        }
      } catch (_) {
        // Leave uncached so subsequent refreshes can retry snapping once back online.
      }
    }
    if (anySnapUpdated) {
      _potholeDerivedVersion++;
      _cachedHazardInputs = null;
    }
  }

  List<List<RouteStepRoadSpan>> _stepSpansForRoutes(
    List<List<RouteStep>> stepsList,
    int routeCount,
  ) {
    return List<List<RouteStepRoadSpan>>.generate(
      routeCount,
      (i) => i < stepsList.length
          ? stepsList[i]
                .map(
                  (s) => RouteStepRoadSpan(
                    roadName: s.roadName,
                    location: s.location,
                  ),
                )
                .toList(growable: false)
          : const [],
      growable: false,
    );
  }

  Future<void> _fetchCorridorSupplementIfNeeded({
    required List<List<LatLng>> routes,
    required int routeSeq,
    required int hazardSeq,
    bool forceRefresh = false,
  }) async {
    final fetcher = widget.corridorReportFetcher;
    if (fetcher == null || routes.isEmpty) return;
    final allPts = <LatLng>[];
    for (final r in routes) {
      allPts.addAll(r);
    }
    if (allPts.isEmpty) return;
    final bbox = RouteBoundingBox.fromPoints(
      allPts,
      bufferMeters: _corridorConfig.corridorMeters + 20.0,
    );
    final String key =
        '${bbox.minLat.toStringAsFixed(5)}:${bbox.maxLat.toStringAsFixed(5)}:'
        '${bbox.minLon.toStringAsFixed(5)}:${bbox.maxLon.toStringAsFixed(5)}';
    if (!forceRefresh && key == _lastCorridorFetchKey) {
      return;
    }
    try {
      final fetched = await fetcher(
        minLat: bbox.minLat,
        maxLat: bbox.maxLat,
        minLon: bbox.minLon,
        maxLon: bbox.maxLon,
      );
      if (!mounted ||
          routeSeq != _routingRequestSeq ||
          hazardSeq != _hazardRefreshSeq) {
        return;
      }
      _corridorSupplementPotholes = fetched;
      _lastCorridorFetchKey = key;
      _invalidatePotholeDerivedCaches();
    } catch (_) {}
  }

  PrecomputedRouteIndex _indexForRouteOrBuild({
    required RouteComparisonResult comparison,
    required int routeIndex,
    required List<LatLng> route,
    required List<RouteHazardInput> hazards,
    required List<double> distances,
    required List<double> durations,
    required List<List<RouteStepRoadSpan>> spansByRoute,
  }) {
    final existing = comparison.routeIndices
        .cast<PrecomputedRouteIndex?>()
        .firstWhere((idx) => idx?.routeIndex == routeIndex, orElse: () => null);
    if (existing != null) return existing;
    return PrecomputedRouteIndex.build(
      route: route,
      hazards: hazards,
      routeIndex: routeIndex,
      routeDistanceMeters: routeIndex < distances.length
          ? distances[routeIndex]
          : null,
      durationSeconds: routeIndex < durations.length
          ? durations[routeIndex]
          : 0.0,
      config: _corridorConfig,
      steps: routeIndex < spansByRoute.length
          ? spansByRoute[routeIndex]
          : const [],
    );
  }

  Future<void> _refreshRouteAwarePotholeState({
    int? requestSeq,
    bool refetchCorridor = false,
  }) async {
    final int routeSeq = requestSeq ?? _routingRequestSeq;
    final int hazardSeq = ++_hazardRefreshSeq;

    if (_alternativeRoutes.isEmpty) {
      if (_currentPosition != null) {
        _checkPotholeProximity(_currentPosition!);
      }
      return;
    }

    await _fetchCorridorSupplementIfNeeded(
      routes: _alternativeRoutes,
      routeSeq: routeSeq,
      hazardSeq: hazardSeq,
      forceRefresh: refetchCorridor,
    );
    if (!mounted ||
        routeSeq != _routingRequestSeq ||
        hazardSeq != _hazardRefreshSeq) {
      return;
    }

    await _ensurePotholeSnapCache(
      requestSeq: routeSeq,
      routes: _alternativeRoutes,
    );
    if (!mounted ||
        routeSeq != _routingRequestSeq ||
        hazardSeq != _hazardRefreshSeq) {
      return;
    }

    final hazards = _buildHazardInputs();
    final spansByRoute = _stepSpansForRoutes(
      _alternativeRouteSteps,
      _alternativeRoutes.length,
    );
    final viaList = List<String>.generate(
      _alternativeRoutes.length,
      (i) => _routeViaSummary(i),
      growable: false,
    );

    final int totalRefreshVertices = _alternativeRoutes.fold<int>(
      0,
      (sum, r) => sum + r.length,
    );
    final RouteComparisonResult comparison =
        (!kIsWeb && (totalRefreshVertices >= 120 || hazards.length >= 60))
        ? await compute(
            evaluateRouteAlternativesWorker,
            RouteAlternativesEvalRequest(
              routes: _alternativeRoutes,
              distancesMeters: _routeDistances,
              durationsSeconds: _routeDurations,
              hazards: hazards,
              viaSummaries: viaList,
              stepsByRoute: spansByRoute,
              corridorConfig: _corridorConfig,
            ),
          )
        : RoutePotholeAdvisor.evaluateAlternatives(
            routes: _alternativeRoutes,
            distancesMeters: _routeDistances,
            durationsSeconds: _routeDurations,
            hazards: hazards,
            viaSummaries: viaList,
            stepsByRoute: spansByRoute,
            corridorConfig: _corridorConfig,
          );
    if (!mounted ||
        routeSeq != _routingRequestSeq ||
        hazardSeq != _hazardRefreshSeq) {
      return;
    }

    final List<int> updatedCounts = List<int>.generate(
      _alternativeRoutes.length,
      (i) => _indexForRouteOrBuild(
        comparison: comparison,
        routeIndex: i,
        route: _alternativeRoutes[i],
        hazards: hazards,
        distances: _routeDistances,
        durations: _routeDurations,
        spansByRoute: spansByRoute,
      ).summary.distinctPotholeCount,
      growable: false,
    );

    final int activeIndex = _selectedRouteIndex < _alternativeRoutes.length
        ? _selectedRouteIndex
        : 0;
    final activeBuilt = _indexForRouteOrBuild(
      comparison: comparison,
      routeIndex: activeIndex,
      route: _alternativeRoutes[activeIndex],
      hazards: hazards,
      distances: _routeDistances,
      durations: _routeDurations,
      spansByRoute: spansByRoute,
    );

    final RouteSwitchSuggestion? suggestion =
        RoutePotholeAdvisor.buildSwitchSuggestion(
          currentRouteIndex: activeIndex,
          hazardCounts: updatedCounts,
          distancesMeters: _routeDistances,
          durationsSeconds: _routeDurations,
        );

    if (!mounted ||
        routeSeq != _routingRequestSeq ||
        hazardSeq != _hazardRefreshSeq) {
      return;
    }
    setState(() {
      _selectedRouteIndex = activeIndex;
      if (_alternativeRouteSteps.isNotEmpty &&
          activeIndex < _alternativeRouteSteps.length) {
        _routeSteps = _alternativeRouteSteps[activeIndex];
      }
      _routeComparison = comparison;
      _activeRouteIndex = activeBuilt;
      if (_navigationTracker == null) {
        _navigationTracker = NavigationHazardTracker(activeBuilt);
      } else {
        _navigationTracker!.replaceRouteIndex(
          activeBuilt,
          keepAlerts: true,
          preserveProgress: true,
        );
      }
      _routePotholeCounts = updatedCounts;
      _potholesOnRoute = activeBuilt.summary.potholeEncounters
          .map((e) => e.hazard.location)
          .toList(growable: false);
      _routeSwitchSuggestion = suggestion;
    });

    if (_currentPosition != null) {
      _checkPotholeProximity(_currentPosition!);
    }
  }

  void _recomputeRouteSuggestion() {
    _routeSwitchSuggestion = RoutePotholeAdvisor.buildSwitchSuggestion(
      currentRouteIndex: _selectedRouteIndex,
      hazardCounts: _routePotholeCounts,
      distancesMeters: _routeDistances,
      durationsSeconds: _routeDurations,
    );
  }

  void _stopRouteSimulation() {
    _simulationTimer?.cancel();
    _simulationTimer = null;
    if (_isSimulatingRoute && mounted) {
      setState(() {
        _isSimulatingRoute = false;
        _useMockLocation = false;
      });
    } else {
      _isSimulatingRoute = false;
      _useMockLocation = false;
    }
  }

  void _toggleRouteSimulation() {
    if (_isSimulatingRoute) {
      _stopRouteSimulation();
      return;
    }
    final List<LatLng> path =
        _alternativeRoutes.isNotEmpty &&
            _selectedRouteIndex < _alternativeRoutes.length
        ? _alternativeRoutes[_selectedRouteIndex]
        : _routePoints;
    if (path.length < 2) return;

    _simulationTimer?.cancel();
    setState(() {
      _isSimulatingRoute = true;
      _useMockLocation = true;
      _simulatedChainMeters = 0.0;
      _currentPosition = path.first;
      _animatedPuckPositionNotifier.value = path.first;
    });
    final double? simHeading = GpsTrackerSmoother.routeForwardBearingDeg(
      path,
      path.first,
      lookaheadMeters: 30.0,
      maxDistanceMeters: 500.0,
    );
    _gpsSmoother.reset(position: path.first, headingDeg: simHeading);
    if (simHeading != null) {
      _lastHeadingNotifier.value = simHeading;
      if (_isNavigating && _drivingCameraAngle.isHeadingUp) {
        final double rot = (360.0 - simHeading) % 360.0;
        _currentMapRotation = rot;
        _mapRotationNotifier.value = rot;
        try {
          _mapController.rotate(rot);
        } catch (_) {}
      }
    }
    _checkPotholeProximity(path.first);
    _animatedMapMoveToVisible(
      path.first,
      _isNavigating ? 17.5 : 16.5,
      isExpandedSheet: false,
    );

    _simulationTimer = Timer.periodic(const Duration(milliseconds: 350), (t) {
      if (!mounted || !_isSimulatingRoute) {
        t.cancel();
        return;
      }
      final List<LatLng> activePath =
          _alternativeRoutes.isNotEmpty &&
              _selectedRouteIndex < _alternativeRoutes.length
          ? _alternativeRoutes[_selectedRouteIndex]
          : _routePoints;
      if (activePath.length < 2) {
        _stopRouteSimulation();
        return;
      }

      _simulatedChainMeters += 18.0;
      final LatLng? nextPos = _interpolatePointAlongRoute(
        activePath,
        _simulatedChainMeters,
      );
      if (nextPos == null) {
        _stopRouteSimulation();
        return;
      }
      _animatePuckTo(
        nextPos,
        speedMps: 18.0 / 0.35,
        isMock: true,
      );
      _checkPotholeProximity(nextPos);
    });
  }

  LatLng? _interpolatePointAlongRoute(List<LatLng> path, double targetMeters) {
    if (path.length < 2) return null;
    double walked = 0.0;
    for (int i = 0; i < path.length - 1; i++) {
      final double segLen = Geolocator.distanceBetween(
        path[i].latitude,
        path[i].longitude,
        path[i + 1].latitude,
        path[i + 1].longitude,
      );
      if (walked + segLen >= targetMeters) {
        final double t = segLen > 0
            ? ((targetMeters - walked) / segLen).clamp(0.0, 1.0)
            : 0.0;
        return LatLng(
          path[i].latitude + t * (path[i + 1].latitude - path[i].latitude),
          path[i].longitude + t * (path[i + 1].longitude - path[i].longitude),
        );
      }
      walked += segLen;
    }
    return null;
  }

  double _distancePointToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    final double latRefRad =
        ((a.latitude + b.latitude) / 2.0) * (3.141592653589793 / 180.0);
    final double metersPerDegLat = 110540.0;
    final double metersPerDegLon = 111320.0 * cos(latRefRad);

    final double ax = 0;
    final double ay = 0;
    final double bx = (b.longitude - a.longitude) * metersPerDegLon;
    final double by = (b.latitude - a.latitude) * metersPerDegLat;
    final double px = (p.longitude - a.longitude) * metersPerDegLon;
    final double py = (p.latitude - a.latitude) * metersPerDegLat;

    final double abx = bx - ax;
    final double aby = by - ay;
    final double apx = px - ax;
    final double apy = py - ay;
    final double abLen2 = abx * abx + aby * aby;

    if (abLen2 <= 1e-6) {
      final dx = px - ax;
      final dy = py - ay;
      return sqrt(dx * dx + dy * dy);
    }

    double t = (apx * abx + apy * aby) / abLen2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;

    final double closestX = ax + t * abx;
    final double closestY = ay + t * aby;
    final double dx = px - closestX;
    final double dy = py - closestY;
    return sqrt(dx * dx + dy * dy);
  }

  List<double> _routeDistances = [];

  void _rubberBandActiveRoute({LatLng? newStart, LatLng? newEnd}) {
    final LatLng start =
        newStart ?? _customOrigin ?? _currentPosition ?? _bulacanCenter;
    final LatLng? end = newEnd ?? _destination;
    if (end == null) return;

    if (_routePoints.length >= 2) {
      final double startJump = newStart != null
          ? Geolocator.distanceBetween(
              _routePoints.first.latitude,
              _routePoints.first.longitude,
              newStart.latitude,
              newStart.longitude,
            )
          : 0.0;
      final double endJump = newEnd != null
          ? Geolocator.distanceBetween(
              _routePoints.last.latitude,
              _routePoints.last.longitude,
              newEnd.latitude,
              newEnd.longitude,
            )
          : 0.0;
      if (!_isDraggingEndpoint && (startJump > 300.0 || endJump > 300.0)) {
        // Preserve the existing road-following route until a replacement route succeeds.
        return;
      }
      final updated = List<LatLng>.from(_routePoints);
      if (newStart != null) {
        updated[0] = newStart;
      }
      if (newEnd != null) {
        updated[updated.length - 1] = newEnd;
      }
      _routePoints = updated;
      return;
    }
    _routePoints = [start, end];
  }

  Future<void> _tryDiscoverAvoidanceRoutes({
    required LatLng start,
    required LatLng destination,
    required List<List<LatLng>> routes,
    required List<double> durations,
    required List<double> distances,
    required List<List<RouteStep>> stepsByRoute,
    required int requestSeq,
  }) async {
    await _ensurePotholeSnapCache(requestSeq: requestSeq, routes: routes);
    if (!mounted || requestSeq != _routingRequestSeq) return;
    final allHazards = _buildHazardInputs();
    final potholePoints = allHazards
        .where((h) => h.isEligibleForPublicRouteCount && h.containsPotholeClass)
        .map((h) => h.location)
        .toList(growable: false);
    if (potholePoints.isEmpty || routes.isEmpty) return;

    final spansByRoute = _stepSpansForRoutes(stepsByRoute, routes.length);
    int countRouteHazards(
      List<LatLng> routePts,
      int idx,
      List<RouteStepRoadSpan> steps, {
      double? routeDistMeters,
      double durationSeconds = 0.0,
    }) {
      return PrecomputedRouteIndex.build(
        route: routePts,
        hazards: allHazards,
        routeIndex: idx,
        routeDistanceMeters: routeDistMeters,
        durationSeconds: durationSeconds,
        config: _corridorConfig,
        steps: steps,
      ).summary.distinctPotholeCount;
    }

    final primaryCount = countRouteHazards(
      routes.first,
      0,
      spansByRoute.isNotEmpty ? spansByRoute.first : const [],
      routeDistMeters: distances.isNotEmpty ? distances.first : null,
      durationSeconds: durations.isNotEmpty ? durations.first : 0.0,
    );
    if (primaryCount == 0) return;

    final existingCounts = List<int>.generate(
      routes.length,
      (i) => countRouteHazards(
        routes[i],
        i,
        i < spansByRoute.length ? spansByRoute[i] : const [],
        routeDistMeters: i < distances.length ? distances[i] : null,
        durationSeconds: i < durations.length ? durations[i] : 0.0,
      ),
      growable: false,
    );
    final int currentMin = existingCounts.reduce((a, b) => a < b ? a : b);
    if (currentMin == 0 && routes.length >= 2) return;

    final waypoints = RoutePotholeAdvisor.buildAvoidanceWaypoints(
      primaryRoute: routes.first,
      hazards: potholePoints,
      routeToleranceMeters: _corridorConfig.corridorMeters,
    );
    if (waypoints.isEmpty) return;

    final String baseHost = _travelMode == OsrmTravelMode.bike
        ? 'https://routing.openstreetmap.de/routed-bike/route/v1/driving/'
        : _travelMode == OsrmTravelMode.foot
        ? 'https://routing.openstreetmap.de/routed-foot/route/v1/driving/'
        : 'https://router.project-osrm.org/route/v1/driving/';

    final selectedWaypoints = waypoints.take(2).toList(growable: false);
    Future<http.Response?> fetchViaWaypoint(LatLng via) async {
      try {
        final viaUrl = Uri.parse(
          '$baseHost${start.longitude},${start.latitude};'
          '${via.longitude},${via.latitude};'
          '${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&steps=true&annotations=true',
        );
        var res = await _httpClient
            .get(viaUrl)
            .timeout(const Duration(milliseconds: 3500));
        if (res.statusCode != 200 && _travelMode != OsrmTravelMode.car) {
          final carUrl = Uri.parse(
            'https://router.project-osrm.org/route/v1/driving/'
            '${start.longitude},${start.latitude};'
            '${via.longitude},${via.latitude};'
            '${destination.longitude},${destination.latitude}'
            '?overview=full&geometries=geojson&steps=true&annotations=true',
          );
          res = await _httpClient
              .get(carUrl)
              .timeout(const Duration(milliseconds: 3500));
        }
        return res;
      } catch (_) {
        return null;
      }
    }

    final responses = await Future.wait(
      selectedWaypoints.map(fetchViaWaypoint),
    );
    for (final res in responses) {
      if (!mounted || requestSeq != _routingRequestSeq || routes.length >= 3) {
        break;
      }
      try {
        if (res == null || res.statusCode != 200) continue;

        final data = jsonDecode(res.body);
        final List osrmRoutes = data['routes'] ?? [];
        if (osrmRoutes.isEmpty) continue;
        final r = osrmRoutes.first as Map<String, dynamic>;
        final List coords =
            (r['geometry'] as Map<String, dynamic>)['coordinates'] as List;
        List<LatLng> points = coords.map((c) {
          final List pair = c as List;
          return LatLng(
            (pair[1] as num).toDouble(),
            (pair[0] as num).toDouble(),
          );
        }).toList();
        if (points.length < 2) continue;
        points = _sanitizeRoutePoints(points, destination);
        if (!RoutePotholeAdvisor.isDistinctAlternateRoute(points, routes)) {
          continue;
        }

        double duration = (r['duration'] as num).toDouble();
        final double distance = (r['distance'] as num).toDouble();
        if (_travelMode == OsrmTravelMode.bike && duration < (distance / 4.5)) {
          duration = distance / 4.16;
        } else if (_travelMode == OsrmTravelMode.foot &&
            duration < (distance / 1.5)) {
          duration = distance / 1.33;
        }

        final parsedSteps = _parseOsrmSteps(r);
        routes.add(points);
        durations.add(duration);
        distances.add(distance);
        stepsByRoute.add(parsedSteps);

        final candSpans = parsedSteps
            .map(
              (s) =>
                  RouteStepRoadSpan(roadName: s.roadName, location: s.location),
            )
            .toList(growable: false);
        final candHazards = countRouteHazards(
          points,
          routes.length - 1,
          candSpans,
          routeDistMeters: distance,
          durationSeconds: duration,
        );
        if (candHazards < primaryCount) break;
      } catch (_) {}
    }
  }

  Future<void> _findFewerPotholes() async {
    if (_alternativeRoutes.isEmpty || _destination == null) return;
    final int seq = _routingRequestSeq;
    setState(() {
      _isSearchingAlternatives = true;
      _hasEvaluatedFewerPotholes = true;
    });

    try {
      if (_alternativeRoutes.length < 3) {
        final routesCopy = _alternativeRoutes
            .map((r) => List<LatLng>.from(r))
            .toList();
        final dursCopy = List<double>.from(_routeDurations);
        final distsCopy = List<double>.from(_routeDistances);
        final stepsCopy = _alternativeRouteSteps
            .map((s) => List<RouteStep>.from(s))
            .toList();
        final LatLng start =
            _customOrigin ?? _currentPosition ?? routesCopy.first.first;
        await _tryDiscoverAvoidanceRoutes(
          start: start,
          destination: _destination!,
          routes: routesCopy,
          durations: dursCopy,
          distances: distsCopy,
          stepsByRoute: stepsCopy,
          requestSeq: seq,
        );
        if (!mounted || seq != _routingRequestSeq) return;
        if (routesCopy.length > _alternativeRoutes.length) {
          _alternativeRoutes = routesCopy;
          _routeDurations = dursCopy;
          _routeDistances = distsCopy;
          _alternativeRouteSteps = stepsCopy;
        }
      }
      await _refreshRouteAwarePotholeState(requestSeq: seq);
    } finally {
      if (mounted && seq == _routingRequestSeq) {
        setState(() => _isSearchingAlternatives = false);
      }
    }
  }

  Future<void> _processRoutes(
    List<List<LatLng>> routes,
    List<double> durations,
    List<double> distances,
    LatLng destination, {
    List<List<RouteStep>>? stepsByRoute,
    bool fitCamera = true,
    int? requestSeq,
    bool fromCache = false,
  }) async {
    if (requestSeq != null && requestSeq != _routingRequestSeq) return;
    if (routes.isEmpty || durations.isEmpty) {
      setState(() => _isRouting = false);
      return;
    }

    final int routeSeq = requestSeq ?? _routingRequestSeq;
    final int hazardSeq = ++_hazardRefreshSeq;

    await _fetchCorridorSupplementIfNeeded(
      routes: routes,
      routeSeq: routeSeq,
      hazardSeq: hazardSeq,
    );
    if (!mounted ||
        routeSeq != _routingRequestSeq ||
        hazardSeq != _hazardRefreshSeq) {
      return;
    }

    await _ensurePotholeSnapCache(requestSeq: routeSeq, routes: routes);
    if (!mounted ||
        routeSeq != _routingRequestSeq ||
        hazardSeq != _hazardRefreshSeq) {
      return;
    }

    final hazards = _buildHazardInputs();
    final List<List<RouteStep>> allSteps = stepsByRoute ?? [];
    final spansByRoute = _stepSpansForRoutes(allSteps, routes.length);
    final viaList = List<String>.generate(
      routes.length,
      (i) => _routeViaSummary(i),
      growable: false,
    );

    final int totalVertices = routes.fold<int>(
      0,
      (sum, r) => sum + r.length,
    );
    final RouteComparisonResult comparison =
        (!kIsWeb && (totalVertices >= 120 || hazards.length >= 60))
        ? await compute(
            evaluateRouteAlternativesWorker,
            RouteAlternativesEvalRequest(
              routes: routes,
              distancesMeters: distances,
              durationsSeconds: durations,
              hazards: hazards,
              viaSummaries: viaList,
              stepsByRoute: spansByRoute,
              corridorConfig: _corridorConfig,
            ),
          )
        : RoutePotholeAdvisor.evaluateAlternatives(
            routes: routes,
            distancesMeters: distances,
            durationsSeconds: durations,
            hazards: hazards,
            viaSummaries: viaList,
            stepsByRoute: spansByRoute,
            corridorConfig: _corridorConfig,
          );
    if (!mounted ||
        routeSeq != _routingRequestSeq ||
        hazardSeq != _hazardRefreshSeq) {
      return;
    }

    final List<int> potholeCounts = List<int>.generate(
      routes.length,
      (i) => _indexForRouteOrBuild(
        comparison: comparison,
        routeIndex: i,
        route: routes[i],
        hazards: hazards,
        distances: distances,
        durations: durations,
        spansByRoute: spansByRoute,
      ).summary.distinctPotholeCount,
      growable: false,
    );

    const int initialRouteIndex = 0;
    final List<LatLng> initialRoute = routes[initialRouteIndex];
    final List<RouteStep> initialSteps =
        allSteps.isNotEmpty && allSteps.length > initialRouteIndex
        ? allSteps[initialRouteIndex]
        : [];
    final activeBuilt = _indexForRouteOrBuild(
      comparison: comparison,
      routeIndex: initialRouteIndex,
      route: initialRoute,
      hazards: hazards,
      distances: distances,
      durations: durations,
      spansByRoute: spansByRoute,
    );

    if (!fromCache && initialRoute.isNotEmpty) {
      unawaited(
        RoadReportCache.saveRecentRoute(
          routeKey: RoadReportCache.routeCacheKey(
            origin: initialRoute.first,
            destination: destination,
            travelMode: _travelMode.name,
          ),
          routes: routes,
          durationsSeconds: durations,
          distancesMeters: distances,
        ),
      );
      unawaited(_tileProvider.prewarmRoute(initialRoute));
    }

    if (!mounted || (requestSeq != null && requestSeq != _routingRequestSeq)) {
      return;
    }

    setState(() {
      _alternativeRoutes = routes;
      _alternativeRouteSteps = allSteps;
      _routeSteps = initialSteps;
      if (fitCamera || !_isNavigating) {
        _isRoutePlanningMode = true;
        _isNavigating = false;
      }
      _routePotholeCounts = potholeCounts;
      _routeDurations = durations;
      _routeDistances = distances;
      _selectedRouteIndex = initialRouteIndex;
      _lastMatchedSegmentIndex = 0;
      _routePoints = initialRoute;
      _destination = destination;
      _isRouting = false;
      _routeErrorMessage = null;
      _routeUsingCachedGeometry = fromCache;
      _isSearchVisible = true;
      if (fitCamera) {
        _followMode = FollowMode.none;
      }
      _routeComparison = comparison;
      _activeRouteIndex = activeBuilt;
      _navigationTracker = NavigationHazardTracker(activeBuilt);
      _spokenEncounterIds.clear();
      _navHazardState = null;
      _potholesOnRoute = activeBuilt.summary.potholeEncounters
          .map((e) => e.hazard.location)
          .toList(growable: false);
      _nearestPotholeInfo = 'Clear ahead';
      _upcomingHazard = null;
      _recomputeRouteSuggestion();
    });

    AppSettings.instance.setRouteActive(true);
    if (fitCamera) {
      _fitCameraToRoute(initialRoute);
    }
    if (_currentPosition != null) {
      _checkPotholeProximity(_currentPosition!);
    }
  }

  void _clearRouteState() {
    _routingRequestSeq++;
    _stopRouteSimulation();
    if (!kIsWeb) {
      _tts.stop();
    }
    _navigationTracker?.reset();
    setState(() {
      _destination = null;
      _customOrigin = null;
      _routePoints = [];
      _routeSteps = [];
      _alternativeRoutes = [];
      _alternativeRouteSteps = [];
      _routeDistances = [];
      _routeDurations = [];
      _routePotholeCounts = [];
      _selectedRouteIndex = 0;
      _lastMatchedSegmentIndex = 0;
      _searchController.clear();
      _potholesOnRoute = [];
      _routeComparison = null;
      _activeRouteIndex = null;
      _navigationTracker = null;
      _navHazardState = null;
      _spokenEncounterIds.clear();
      _routeErrorMessage = null;
      _routeUsingCachedGeometry = false;
      _hasEvaluatedFewerPotholes = false;
      _isSearchingAlternatives = false;
      _nearestPotholeInfo = '';
      _nextPotholeEta = null;
      _upcomingHazard = null;
      _routeSwitchSuggestion = null;
      _inProximityWarning = false;
      _warningBannerTimer?.cancel();
      _warningBanner.value = (highlighted: false, dismissedEncounterId: null);
      _isRoutePlanningMode = false;
      _drivingHudNoticeTimer?.cancel();
      _isNavigating = false;
      _isNavOverview = false;
      _drivingCameraAngle = DrivingCameraAngle.chase3D;
      _isManualRerouting = false;
      _drivingHudNotice = null;
      _isRouteSheetExpanded = false;
      _isRouteDockMinimized = false;
    });
    AppSettings.instance.setRouteActive(false);
    if (widget.isMapActive && !_puckPulseController.isAnimating) {
      _puckPulseController.repeat();
    }
    if (_currentPosition != null) {
      _checkPotholeProximity(_currentPosition!);
    }
  }

  void _fitCameraToRoute(List<LatLng> points) {
    if (points.isEmpty) return;

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final bounds = LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));

    try {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: EdgeInsets.only(
            top: 150,
            bottom: _alternativeRoutes.length > 1 ? 255 : 195,
            left: 52,
            right: 52,
          ),
        ),
      );
    } catch (_) {}
  }

  String _routeViaSummary(int routeIndex) {
    if (routeIndex >= 0 && routeIndex < _alternativeRouteSteps.length) {
      final seen = <String>{};
      final roads = <String>[];
      for (final step in _alternativeRouteSteps[routeIndex]) {
        final raw = step.roadName.trim();
        if (raw.isEmpty) continue;
        final key = raw.toLowerCase();
        if (key == 'road' || key == 'unnamed road' || seen.contains(key)) {
          continue;
        }
        seen.add(key);
        roads.add(raw);
        if (roads.length >= 2) break;
      }
      if (roads.isNotEmpty) {
        return 'Via ${roads.join(' & ')}';
      }
    }
    if (routeIndex == 0) return 'Primary route';
    return 'Alternate route ${routeIndex + 1}';
  }

  void _selectActiveRoute(int index) {
    if (index < 0 || index >= _alternativeRoutes.length) return;
    final hazards = _buildHazardInputs();
    final spansByRoute = _stepSpansForRoutes(
      _alternativeRouteSteps,
      _alternativeRoutes.length,
    );
    final activeBuilt = PrecomputedRouteIndex.build(
      route: _alternativeRoutes[index],
      hazards: hazards,
      routeIndex: index,
      routeDistanceMeters: index < _routeDistances.length
          ? _routeDistances[index]
          : null,
      durationSeconds: index < _routeDurations.length
          ? _routeDurations[index]
          : 0.0,
      config: _corridorConfig,
      steps: index < spansByRoute.length ? spansByRoute[index] : const [],
    );

    setState(() {
      _selectedRouteIndex = index;
      _lastMatchedSegmentIndex = 0;
      _routePoints = _alternativeRoutes[index];
      if (_alternativeRouteSteps.isNotEmpty &&
          index < _alternativeRouteSteps.length) {
        _routeSteps = _alternativeRouteSteps[index];
      }
      _selectedStepIndex = null;
      _activeRouteIndex = activeBuilt;
      if (index < _routePotholeCounts.length) {
        final updatedCounts = List<int>.from(_routePotholeCounts);
        updatedCounts[index] = activeBuilt.summary.distinctPotholeCount;
        _routePotholeCounts = updatedCounts;
      }
      if (_navigationTracker == null) {
        _navigationTracker = NavigationHazardTracker(activeBuilt);
      } else {
        _navigationTracker!.replaceRouteIndex(activeBuilt, keepAlerts: false);
      }
      _spokenEncounterIds.clear();
      _potholesOnRoute = activeBuilt.summary.potholeEncounters
          .map((e) => e.hazard.location)
          .toList(growable: false);
      if (_isSimulatingRoute) {
        _simulatedChainMeters = 0.0;
      }
      _recomputeRouteSuggestion();
    });
    if (_currentPosition != null) {
      _checkPotholeProximity(_currentPosition!);
    }
  }

  /// Cycles between all available alternative and navigation routes
  void _cycleRoutes() {
    if (_alternativeRoutes.isEmpty) return;
    HapticFeedback.mediumImpact();
    final nextIndex = (_selectedRouteIndex + 1) % _alternativeRoutes.length;
    _selectActiveRoute(nextIndex);
    if (!kIsWeb &&
        _travelMode == OsrmTravelMode.bike &&
        AppSettings.instance.mobileVoiceAlertsEnabled) {
      _tts.speak(
        'Route ${nextIndex + 1} of ${_alternativeRoutes.length} selected.',
      );
    }
  }

  // Pre-indexed Bulacan LGUs & Key Barangays for zero-latency local geocoding
  static const List<Map<String, dynamic>> _bulacanBarangays = [
    // Santa Maria
    {
      'name': 'Barangay Poblacion',
      'municipality': 'Santa Maria',
      'lat': 14.8197,
      'lon': 120.9575,
    },
    {
      'name': 'Barangay Bagbaguin',
      'municipality': 'Santa Maria',
      'lat': 14.8083,
      'lon': 120.9542,
    },
    {
      'name': 'Barangay Caypombo',
      'municipality': 'Santa Maria',
      'lat': 14.8427,
      'lon': 120.9739,
    },
    {
      'name': 'Barangay Catmon',
      'municipality': 'Santa Maria',
      'lat': 14.8315,
      'lon': 120.9858,
    },
    {
      'name': 'Barangay Guyong',
      'municipality': 'Santa Maria',
      'lat': 14.8236,
      'lon': 120.9712,
    },
    {
      'name': 'Barangay Balasing',
      'municipality': 'Santa Maria',
      'lat': 14.8584,
      'lon': 121.0062,
    },
    {
      'name': 'Barangay Pulong Buhangin',
      'municipality': 'Santa Maria',
      'lat': 14.8633,
      'lon': 121.0022,
    },
    {
      'name': 'Barangay San Gabriel',
      'municipality': 'Santa Maria',
      'lat': 14.8251,
      'lon': 120.9631,
    },
    {
      'name': 'Barangay Santa Clara',
      'municipality': 'Santa Maria',
      'lat': 14.8164,
      'lon': 120.9501,
    },
    {
      'name': 'Barangay Buenavista',
      'municipality': 'Santa Maria',
      'lat': 14.8521,
      'lon': 120.9934,
    },
    {
      'name': 'Barangay Camangyanan',
      'municipality': 'Santa Maria',
      'lat': 14.8115,
      'lon': 120.9412,
    },
    {
      'name': 'Barangay Caysio',
      'municipality': 'Santa Maria',
      'lat': 14.8458,
      'lon': 120.9812,
    },
    {
      'name': 'Barangay Lalakhan',
      'municipality': 'Santa Maria',
      'lat': 14.8123,
      'lon': 120.9621,
    },
    {
      'name': 'Barangay Mag-asawang Sapa',
      'municipality': 'Santa Maria',
      'lat': 14.8711,
      'lon': 121.0189,
    },
    {
      'name': 'Barangay Mahabang Parang',
      'municipality': 'Santa Maria',
      'lat': 14.8654,
      'lon': 121.0211,
    },
    {
      'name': 'Barangay Manggahan',
      'municipality': 'Santa Maria',
      'lat': 14.8389,
      'lon': 120.9689,
    },
    {
      'name': 'Barangay Parada',
      'municipality': 'Santa Maria',
      'lat': 14.8012,
      'lon': 120.9642,
    },
    {
      'name': 'Barangay San Jose Patag',
      'municipality': 'Santa Maria',
      'lat': 14.8091,
      'lon': 120.9782,
    },
    {
      'name': 'Barangay San Vicente',
      'municipality': 'Santa Maria',
      'lat': 14.8291,
      'lon': 120.9521,
    },
    {
      'name': 'Barangay Silangan',
      'municipality': 'Santa Maria',
      'lat': 14.8412,
      'lon': 121.0142,
    },
    {
      'name': 'Barangay Tumana',
      'municipality': 'Santa Maria',
      'lat': 14.8178,
      'lon': 120.9712,
    },

    // Malolos City
    {
      'name': 'Barangay Guinhawa',
      'municipality': 'Malolos',
      'lat': 14.8569,
      'lon': 120.8167,
    },
    {
      'name': 'Barangay Liang',
      'municipality': 'Malolos',
      'lat': 14.8489,
      'lon': 120.8123,
    },
    {
      'name': 'Barangay San Agustin',
      'municipality': 'Malolos',
      'lat': 14.8411,
      'lon': 120.8178,
    },
    {
      'name': 'Barangay Sumapang Matanda',
      'municipality': 'Malolos',
      'lat': 14.8612,
      'lon': 120.8251,
    },
    {
      'name': 'Barangay Cofradia',
      'municipality': 'Malolos',
      'lat': 14.8689,
      'lon': 120.8312,
    },
    {
      'name': 'Barangay Bulihan',
      'municipality': 'Malolos',
      'lat': 14.8512,
      'lon': 120.8354,
    },
    {
      'name': 'Barangay Caingin',
      'municipality': 'Malolos',
      'lat': 14.8432,
      'lon': 120.8211,
    },
    {
      'name': 'Barangay Catmon',
      'municipality': 'Malolos',
      'lat': 14.8471,
      'lon': 120.8192,
    },
    {
      'name': 'Barangay Dakila',
      'municipality': 'Malolos',
      'lat': 14.8589,
      'lon': 120.8412,
    },
    {
      'name': 'Barangay Ligas',
      'municipality': 'Malolos',
      'lat': 14.8641,
      'lon': 120.8491,
    },
    {
      'name': 'Barangay Lugam',
      'municipality': 'Malolos',
      'lat': 14.8712,
      'lon': 120.8211,
    },
    {
      'name': 'Barangay Mabolo',
      'municipality': 'Malolos',
      'lat': 14.8391,
      'lon': 120.8291,
    },
    {
      'name': 'Barangay Mojon',
      'municipality': 'Malolos',
      'lat': 14.8621,
      'lon': 120.8152,
    },
    {
      'name': 'Barangay Panasahan',
      'municipality': 'Malolos',
      'lat': 14.8281,
      'lon': 120.8241,
    },
    {
      'name': 'Barangay Santisima Trinidad',
      'municipality': 'Malolos',
      'lat': 14.8541,
      'lon': 120.8212,
    },
    {
      'name': 'Barangay Santo Rosario',
      'municipality': 'Malolos',
      'lat': 14.8439,
      'lon': 120.8115,
    },
    {
      'name': 'Barangay Tikay',
      'municipality': 'Malolos',
      'lat': 14.8491,
      'lon': 120.8482,
    },

    // City of San Jose del Monte (CSJDM)
    {
      'name': 'Barangay Tungkong Mangga',
      'municipality': 'San Jose del Monte',
      'lat': 14.8021,
      'lon': 121.0742,
    },
    {
      'name': 'Barangay Muzon',
      'municipality': 'San Jose del Monte',
      'lat': 14.8062,
      'lon': 121.0315,
    },
    {
      'name': 'Barangay Gaya-Gaya',
      'municipality': 'San Jose del Monte',
      'lat': 14.8112,
      'lon': 121.0541,
    },
    {
      'name': 'Barangay Graceville',
      'municipality': 'San Jose del Monte',
      'lat': 14.8191,
      'lon': 121.0421,
    },
    {
      'name': 'Barangay Francisco Homes',
      'municipality': 'San Jose del Monte',
      'lat': 14.8212,
      'lon': 121.0612,
    },
    {
      'name': 'Barangay Kaypian',
      'municipality': 'San Jose del Monte',
      'lat': 14.8312,
      'lon': 121.0712,
    },
    {
      'name': 'Barangay Minuyan',
      'municipality': 'San Jose del Monte',
      'lat': 14.8251,
      'lon': 121.0821,
    },
    {
      'name': 'Barangay Sapang Palay',
      'municipality': 'San Jose del Monte',
      'lat': 14.8412,
      'lon': 121.0651,
    },
    {
      'name': 'Barangay Santo Cristo',
      'municipality': 'San Jose del Monte',
      'lat': 14.8091,
      'lon': 121.0851,
    },

    // Meycauayan City
    {
      'name': 'Barangay Calvario',
      'municipality': 'Meycauayan',
      'lat': 14.7391,
      'lon': 120.9582,
    },
    {
      'name': 'Barangay Camalig',
      'municipality': 'Meycauayan',
      'lat': 14.7451,
      'lon': 120.9821,
    },
    {
      'name': 'Barangay Iba',
      'municipality': 'Meycauayan',
      'lat': 14.7321,
      'lon': 120.9841,
    },
    {
      'name': 'Barangay Langka',
      'municipality': 'Meycauayan',
      'lat': 14.7491,
      'lon': 120.9912,
    },
    {
      'name': 'Barangay Lawa',
      'municipality': 'Meycauayan',
      'lat': 14.7312,
      'lon': 120.9612,
    },
    {
      'name': 'Barangay Malhacan',
      'municipality': 'Meycauayan',
      'lat': 14.7381,
      'lon': 120.9712,
    },
    {
      'name': 'Barangay Perez',
      'municipality': 'Meycauayan',
      'lat': 14.7412,
      'lon': 120.9951,
    },
    {
      'name': 'Barangay Saluysoy',
      'municipality': 'Meycauayan',
      'lat': 14.7351,
      'lon': 120.9521,
    },

    // Marilao
    {
      'name': 'Barangay Ibayo',
      'municipality': 'Marilao',
      'lat': 14.7551,
      'lon': 120.9482,
    },
    {
      'name': 'Barangay Lambakin',
      'municipality': 'Marilao',
      'lat': 14.7681,
      'lon': 120.9712,
    },
    {
      'name': 'Barangay Lias',
      'municipality': 'Marilao',
      'lat': 14.7612,
      'lon': 120.9612,
    },
    {
      'name': 'Barangay Loma de Gato',
      'municipality': 'Marilao',
      'lat': 14.7812,
      'lon': 120.9982,
    },
    {
      'name': 'Barangay Patubig',
      'municipality': 'Marilao',
      'lat': 14.7721,
      'lon': 120.9551,
    },
    {
      'name': 'Barangay Poblacion I',
      'municipality': 'Marilao',
      'lat': 14.7581,
      'lon': 120.9512,
    },
    {
      'name': 'Barangay Prenza I',
      'municipality': 'Marilao',
      'lat': 14.7791,
      'lon': 120.9812,
    },
    {
      'name': 'Barangay Saog',
      'municipality': 'Marilao',
      'lat': 14.7641,
      'lon': 120.9421,
    },
    {
      'name': 'Barangay Tabing Ilog',
      'municipality': 'Marilao',
      'lat': 14.7512,
      'lon': 120.9541,
    },

    // Bocaue
    {
      'name': 'Barangay Bagumbayan',
      'municipality': 'Bocaue',
      'lat': 14.7981,
      'lon': 120.9291,
    },
    {
      'name': 'Barangay Bambang',
      'municipality': 'Bocaue',
      'lat': 14.7921,
      'lon': 120.9312,
    },
    {
      'name': 'Barangay Batia',
      'municipality': 'Bocaue',
      'lat': 14.8151,
      'lon': 120.9182,
    },
    {
      'name': 'Barangay Bundukan',
      'municipality': 'Bocaue',
      'lat': 14.8021,
      'lon': 120.9451,
    },
    {
      'name': 'Barangay Lolomboy',
      'municipality': 'Bocaue',
      'lat': 14.7881,
      'lon': 120.9412,
    },
    {
      'name': 'Barangay Poblacion',
      'municipality': 'Bocaue',
      'lat': 14.7991,
      'lon': 120.9341,
    },
    {
      'name': 'Barangay Taal',
      'municipality': 'Bocaue',
      'lat': 14.8112,
      'lon': 120.9381,
    },
    {
      'name': 'Barangay Turo',
      'municipality': 'Bocaue',
      'lat': 14.8051,
      'lon': 120.9281,
    },

    // Guiguinto & Balagtas
    {
      'name': 'Barangay Tuktukan',
      'municipality': 'Guiguinto',
      'lat': 14.8321,
      'lon': 120.8812,
    },
    {
      'name': 'Barangay Tabang',
      'municipality': 'Guiguinto',
      'lat': 14.8412,
      'lon': 120.8712,
    },
    {
      'name': 'Barangay Santa Rita',
      'municipality': 'Guiguinto',
      'lat': 14.8351,
      'lon': 120.8912,
    },
    {
      'name': 'Barangay Wawa',
      'municipality': 'Balagtas',
      'lat': 14.8191,
      'lon': 120.9082,
    },
    {
      'name': 'Barangay Borol 1st',
      'municipality': 'Balagtas',
      'lat': 14.8112,
      'lon': 120.9141,
    },
    {
      'name': 'Barangay Santol',
      'municipality': 'Balagtas',
      'lat': 14.8251,
      'lon': 120.9121,
    },

    // Baliuag & Plaridel
    {
      'name': 'Barangay Poblacion',
      'municipality': 'Baliuag',
      'lat': 14.9541,
      'lon': 120.9012,
    },
    {
      'name': 'Barangay Subic',
      'municipality': 'Baliuag',
      'lat': 14.9612,
      'lon': 120.8951,
    },
    {
      'name': 'Barangay Bagong Nayon',
      'municipality': 'Baliuag',
      'lat': 14.9481,
      'lon': 120.9051,
    },
    {
      'name': 'Barangay Banga 1st',
      'municipality': 'Plaridel',
      'lat': 14.8871,
      'lon': 120.8582,
    },
    {
      'name': 'Barangay Poblacion',
      'municipality': 'Plaridel',
      'lat': 14.8891,
      'lon': 120.8612,
    },
    {
      'name': 'Barangay Dampol',
      'municipality': 'Plaridel',
      'lat': 14.9012,
      'lon': 120.8451,
    },
    {
      'name': 'Barangay Tabang',
      'municipality': 'Plaridel',
      'lat': 14.8781,
      'lon': 120.8691,
    },

    // Pandi & Norzagaray
    {
      'name': 'Barangay Poblacion',
      'municipality': 'Pandi',
      'lat': 14.8681,
      'lon': 120.9572,
    },
    {
      'name': 'Barangay Bunsuran 1st',
      'municipality': 'Pandi',
      'lat': 14.8812,
      'lon': 120.9481,
    },
    {
      'name': 'Barangay Masuso',
      'municipality': 'Pandi',
      'lat': 14.8721,
      'lon': 120.9712,
    },
    {
      'name': 'Barangay Poblacion',
      'municipality': 'Norzagaray',
      'lat': 14.9121,
      'lon': 121.0421,
    },
    {
      'name': 'Barangay Bigte',
      'municipality': 'Norzagaray',
      'lat': 14.8951,
      'lon': 121.0612,
    },
    {
      'name': 'Barangay Minuyan',
      'municipality': 'Norzagaray',
      'lat': 14.9041,
      'lon': 121.0741,
    },
  ];

  /// Instant local search matcher for Philippine & Bulacan Barangays
  List<Map<String, dynamic>> _fetchLocalBarangayCandidates(String query) {
    final clean = query
        .toLowerCase()
        .replaceAll(
          RegExp(r'\b(barangay|brgy\.?|bgy\.?)\b', caseSensitive: false),
          '',
        )
        .trim();
    if (clean.length < 2) return [];

    final refPos = _currentPosition ?? _bulacanCenter;
    final List<Map<String, dynamic>> matches = [];

    for (final b in _bulacanBarangays) {
      final name = b['name'] as String;
      final mun = b['municipality'] as String;
      final lat = (b['lat'] as num).toDouble();
      final lon = (b['lon'] as num).toDouble();
      final nameClean = name.toLowerCase().replaceAll('barangay', '').trim();
      final munClean = mun.toLowerCase();

      final loc = LatLng(lat, lon);
      final dist = _calculateDistanceKm(refPos, loc);

      double score = 0.0;
      if (nameClean == clean) {
        score = 220.0;
      } else if (nameClean.startsWith(clean)) {
        score = 170.0;
      } else if (nameClean.contains(clean)) {
        score = 140.0;
      } else if ('$nameClean $munClean'.contains(clean) ||
          '$munClean $nameClean'.contains(clean)) {
        score = 130.0;
      }

      if (score > 0) {
        if (dist != double.infinity) {
          score += (1.0 / (dist + 1.0)) * 50.0;
        }
        matches.add({
          'lat': lat.toString(),
          'lon': lon.toString(),
          '_name': name,
          '_short_addr': '$mun, Bulacan',
          'display_name': '$name, $mun, Bulacan',
          '_distance_km': dist,
          '_score': score,
          '_is_barangay': true,
          '_source': 'Bulacan LGU Registry',
        });
      }
    }

    matches.sort(
      (a, b) => (b['_score'] as double).compareTo(a['_score'] as double),
    );
    return matches.take(5).toList();
  }

  String _normalizeQuery(String rawQuery) {
    String normalized = rawQuery.trim();
    if (normalized.length > 100) {
      normalized = normalized.substring(0, 100).trim();
    }

    // Expand Philippine barangay abbreviations
    normalized = normalized.replaceAll(
      RegExp(r'\b(brgy\.?|bgy\.?)\b', caseSensitive: false),
      'Barangay ',
    );

    // Standardize road and religious place prefix aliases
    normalized = normalized.replaceAll(
      RegExp(r'\bsta\.?\b', caseSensitive: false),
      'Santa',
    );
    normalized = normalized.replaceAll(
      RegExp(r'\bsto\.?\b', caseSensitive: false),
      'Santo',
    );
    normalized = normalized.replaceAll(
      RegExp(r'\bsn\.?\b', caseSensitive: false),
      'San',
    );
    normalized = normalized.replaceAll(
      RegExp(r'\b(pob\.?)\b', caseSensitive: false),
      'Poblacion',
    );

    // Popular local search aliases
    final lower = normalized
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (lower == 'sjdm' || lower == 'csjdm' || lower == 'sjdm bulacan') {
      normalized = 'San Jose del Monte Bulacan';
    } else if (lower.contains('sm sta maria') ||
        lower.contains('sm santa maria') ||
        lower.contains('sm city sta maria') ||
        lower.contains('sm city santa maria')) {
      normalized = 'SM City Santa Maria';
    } else if (lower == 'sta maria bulacan' ||
        lower == 'santa maria bulacan' ||
        lower == 'sta. maria bulacan') {
      normalized = 'Santa Maria Bulacan';
    } else if (lower == 'bul' || lower == 'bulacan') {
      normalized = 'Bulacan Philippines';
    }

    return normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  double _calculateDistanceKm(LatLng p1, LatLng p2) {
    const double earthRadiusKm = 6371.0;
    final dLat = (p2.latitude - p1.latitude) * (3.141592653589793 / 180.0);
    final dLon = (p2.longitude - p1.longitude) * (3.141592653589793 / 180.0);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(p1.latitude * (3.141592653589793 / 180.0)) *
            cos(p2.latitude * (3.141592653589793 / 180.0)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusKm * c;
  }

  static const String _geoapifyApiKey = String.fromEnvironment(
    'GEOAPIFY_API_KEY',
  );

  // Bulacan Province Center & Coordinates
  static const LatLng _bulacanCenter = LatLng(
    14.8192,
    120.9634,
  ); // Santa Maria / Malolos Bulacan

  Future<List<Map<String, dynamic>>> _fetchGeoapifyCandidates(
    String normalizedQuery,
  ) async {
    if (_geoapifyApiKey.isEmpty) return [];
    try {
      final Map<String, String> queryParams = {
        'text': normalizedQuery,
        'apiKey': _geoapifyApiKey,
        'filter': 'countrycode:ph',
        'limit': '10',
      };
      if (_currentPosition != null) {
        queryParams['bias'] =
            'proximity:${_currentPosition!.longitude},${_currentPosition!.latitude}';
      } else {
        queryParams['bias'] =
            'proximity:120.9634,14.8192'; // Default bias to Bulacan Center
      }
      final url = Uri.https(
        'api.geoapify.com',
        '/v1/geocode/autocomplete',
        queryParams,
      );
      final res = await http.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return [];

      final payload = jsonDecode(res.body) as Map<String, dynamic>;
      final features = (payload['features'] as List?) ?? [];
      final List<Map<String, dynamic>> results = [];

      for (final item in features) {
        final props = (item['properties'] as Map<String, dynamic>?) ?? {};
        final geometry = (item['geometry'] as Map<String, dynamic>?) ?? {};
        final coords = (geometry['coordinates'] as List?) ?? [0, 0];
        final countryCode = (props['country_code'] ?? '')
            .toString()
            .toLowerCase();

        if (countryCode.isNotEmpty && countryCode != 'ph') continue;

        final double lat =
            (props['lat'] as num?)?.toDouble() ??
            ((coords.length > 1 ? coords[1] : 0) as num).toDouble();
        final double lon =
            (props['lon'] as num?)?.toDouble() ??
            ((coords.isNotEmpty ? coords[0] : 0) as num).toDouble();
        final LatLng candidateLoc = LatLng(lat, lon);

        final String formatted =
            (props['formatted'] ?? props['address_line1'] ?? '').toString();
        final String name =
            (props['name'] ??
                    props['address_line1'] ??
                    formatted.split(',').first)
                .toString();
        final String shortAddr = (props['address_line2'] ?? '').toString();

        double distanceKm = double.infinity;
        final refPos = _currentPosition ?? _bulacanCenter;
        distanceKm = _calculateDistanceKm(refPos, candidateLoc);

        double score = 0.0;
        final String nameLower = name.toLowerCase();
        final String formattedLower = formatted.toLowerCase();
        final String queryLower = normalizedQuery.toLowerCase();

        if (nameLower == queryLower) {
          score += 100.0;
        } else if (nameLower.startsWith(queryLower)) {
          score += 50.0;
        } else if (nameLower.contains(queryLower)) {
          score += 25.0;
        }

        // Bulacan Location Bonus
        if (formattedLower.contains('bulacan') ||
            formattedLower.contains('santa maria') ||
            formattedLower.contains('malolos') ||
            formattedLower.contains('meycauayan') ||
            formattedLower.contains('marilao')) {
          score += 45.0;
        }

        if (distanceKm != double.infinity) {
          score += (1.0 / (distanceKm + 1.0)) * 60.0;
        }

        results.add({
          'lat': lat.toString(),
          'lon': lon.toString(),
          '_name': name,
          '_short_addr': shortAddr.isNotEmpty
              ? shortAddr
              : (distanceKm != double.infinity
                    ? '${distanceKm.toStringAsFixed(1)} km away'
                    : ''),
          'display_name': formatted,
          '_distance_km': distanceKm,
          '_score': score,
          '_source': 'Geoapify',
        });
      }
      return results;
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchPhotonOsmCandidates(
    String normalizedQuery,
  ) async {
    try {
      final refPos = _currentPosition ?? _bulacanCenter;
      final url = Uri.https('photon.komoot.io', '/api/', {
        'q': normalizedQuery,
        'lat': refPos.latitude.toString(),
        'lon': refPos.longitude.toString(),
        'limit': '10',
      });

      final res = await http
          .get(url, headers: {'User-Agent': 'PotholeScannerApp/1.0'})
          .timeout(const Duration(seconds: 4));

      if (res.statusCode != 200) return [];
      final payload = jsonDecode(res.body) as Map<String, dynamic>;
      final features = (payload['features'] as List?) ?? [];
      final List<Map<String, dynamic>> results = [];

      for (final item in features) {
        final props = (item['properties'] as Map<String, dynamic>?) ?? {};
        final geometry = (item['geometry'] as Map<String, dynamic>?) ?? {};
        final coords = (geometry['coordinates'] as List?) ?? [0, 0];
        final country = (props['country'] ?? props['countrycode'] ?? '')
            .toString()
            .toLowerCase();

        if (country.isNotEmpty && country != 'philippines' && country != 'ph') {
          continue;
        }

        final double lon = ((coords.isNotEmpty ? coords[0] : 0) as num)
            .toDouble();
        final double lat = ((coords.length > 1 ? coords[1] : 0) as num)
            .toDouble();
        if (lat == 0 && lon == 0) continue;

        final LatLng candidateLoc = LatLng(lat, lon);
        final String name =
            (props['name'] ??
                    props['street'] ??
                    props['city'] ??
                    props['district'] ??
                    'Location')
                .toString();

        final List<String> addrParts = [];
        if (props['street'] != null && props['street'] != name) {
          addrParts.add(props['street'].toString());
        }
        if (props['district'] != null) {
          addrParts.add(props['district'].toString());
        }
        if (props['city'] != null) addrParts.add(props['city'].toString());
        if (props['state'] != null) addrParts.add(props['state'].toString());

        final String shortAddr = addrParts.join(', ');
        final double distanceKm = _calculateDistanceKm(refPos, candidateLoc);

        double score = 0.0;
        final String nameLower = name.toLowerCase();
        final String queryLower = normalizedQuery.toLowerCase();

        if (nameLower == queryLower) {
          score += 120.0;
        } else if (nameLower.startsWith(queryLower)) {
          score += 60.0;
        } else if (nameLower.contains(queryLower)) {
          score += 30.0;
        }

        if (shortAddr.toLowerCase().contains('bulacan')) {
          score += 40.0;
        }
        if (distanceKm != double.infinity) {
          score += (1.0 / (distanceKm + 1.0)) * 60.0;
        }

        results.add({
          'lat': lat.toString(),
          'lon': lon.toString(),
          '_name': name,
          '_short_addr': shortAddr.isNotEmpty
              ? shortAddr
              : (distanceKm != double.infinity
                    ? '${distanceKm.toStringAsFixed(1)} km away'
                    : ''),
          'display_name': shortAddr.isNotEmpty ? '$name, $shortAddr' : name,
          '_distance_km': distanceKm,
          '_score': score,
          '_source': 'Photon OSM (Project-OSRM)',
        });
      }
      return results;
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchNominatimCandidates(
    String normalizedQuery,
  ) async {
    try {
      final refPos = _currentPosition ?? _bulacanCenter;
      final url = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': normalizedQuery,
        'format': 'json',
        'addressdetails': '1',
        'countrycodes': 'ph',
        'viewbox':
            '120.55,15.25,121.35,14.65', // Bias results toward Bulacan & Central Luzon
        'bounded': '0',
        'limit': '10',
      });

      final res = await http
          .get(url, headers: {'User-Agent': 'RoadSense-GIS/1.0'})
          .timeout(const Duration(seconds: 4));

      if (res.statusCode != 200) return [];
      final List data = jsonDecode(res.body) as List;
      final List<Map<String, dynamic>> results = [];

      for (final item in data) {
        final double lat = double.tryParse(item['lat'].toString()) ?? 0;
        final double lon = double.tryParse(item['lon'].toString()) ?? 0;
        if (lat == 0 && lon == 0) continue;

        final LatLng candidateLoc = LatLng(lat, lon);
        final String displayName = (item['display_name'] ?? '').toString();
        final addr = (item['address'] as Map<String, dynamic>?) ?? {};

        // Extract Philippine Barangay
        String rawBrgy =
            (addr['suburb'] ??
                    addr['village'] ??
                    addr['quarter'] ??
                    addr['neighbourhood'] ??
                    addr['city_district'] ??
                    '')
                .toString()
                .trim();
        String brgy = '';
        if (rawBrgy.isNotEmpty) {
          final lower = rawBrgy.toLowerCase();
          if (lower.startsWith('brgy.') || lower.startsWith('brgy ')) {
            brgy = 'Barangay ${rawBrgy.substring(5).trim()}';
          } else if (lower.startsWith('barangay')) {
            brgy = rawBrgy;
          } else {
            brgy = 'Barangay $rawBrgy';
          }
        }

        String city =
            (addr['city'] ??
                    addr['town'] ??
                    addr['municipality'] ??
                    addr['county'] ??
                    '')
                .toString()
                .trim();
        String province = (addr['state'] ?? addr['province'] ?? '')
            .toString()
            .trim();

        final type = (item['type'] ?? item['addresstype'] ?? '')
            .toString()
            .toLowerCase();
        final bool isBarangay =
            type == 'suburb' ||
            type == 'village' ||
            type == 'quarter' ||
            (rawBrgy.isNotEmpty &&
                (item['name'] ?? '').toString().toLowerCase().contains(
                  rawBrgy.toLowerCase(),
                ));

        String name = (item['name'] ?? displayName.split(',').first)
            .toString()
            .trim();
        if (isBarangay && !name.toLowerCase().startsWith('barangay')) {
          name = 'Barangay $name';
        }

        // Clean structured subtitle: [Barangay], [City], [Province]
        List<String> subParts = [];
        if (!isBarangay && brgy.isNotEmpty) subParts.add(brgy);
        if (city.isNotEmpty) subParts.add(city);
        if (province.isNotEmpty && province != city) subParts.add(province);

        final String shortAddr = subParts.isNotEmpty
            ? subParts.join(', ')
            : displayName;
        final double distanceKm = _calculateDistanceKm(refPos, candidateLoc);

        double score = 0.0;
        final String nameLower = name.toLowerCase();
        final String queryLower = normalizedQuery.toLowerCase();

        if (nameLower == queryLower) {
          score += 130.0;
        } else if (nameLower.startsWith(queryLower)) {
          score += 70.0;
        } else if (nameLower.contains(queryLower)) {
          score += 35.0;
        }

        if (isBarangay) {
          score += 45.0; // Boost official Barangay entities
        }
        if (nameLower.contains('barangay') || queryLower.contains('barangay')) {
          score += 30.0;
        }
        if (displayName.toLowerCase().contains('bulacan')) {
          score += 40.0;
        }
        if (distanceKm != double.infinity) {
          score += (1.0 / (distanceKm + 1.0)) * 60.0;
        }

        results.add({
          'lat': lat.toString(),
          'lon': lon.toString(),
          '_name': name,
          '_short_addr': shortAddr.isNotEmpty ? shortAddr : displayName,
          'display_name': displayName,
          '_distance_km': distanceKm,
          '_score': score,
          '_is_barangay': isBarangay,
          '_source': 'OSM Nominatim',
        });
      }
      return results;
    } catch (_) {
      return [];
    }
  }

  Future<void> _fetchSuggestions(String query) async {
    try {
      final normalizedQuery = _normalizeQuery(query);

      final List<Map<String, dynamic>> allCandidates = [];

      // Local instant Bulacan Barangay matches (<1ms)
      final localMatches = _fetchLocalBarangayCandidates(normalizedQuery);
      allCandidates.addAll(localMatches);

      final results = await Future.wait([
        _fetchPhotonOsmCandidates(normalizedQuery),
        _fetchNominatimCandidates(normalizedQuery),
        _fetchGeoapifyCandidates(normalizedQuery),
      ]);
      for (final list in results) {
        allCandidates.addAll(list);
      }

      // Deduplicate results by place name or coordinates
      final List<Map<String, dynamic>> merged = [];
      for (final candidate in allCandidates) {
        final candName = (candidate['_name'] ?? '').toString().toLowerCase();
        final candLat = double.tryParse(candidate['lat'].toString()) ?? 0;
        final candLon = double.tryParse(candidate['lon'].toString()) ?? 0;

        final isDuplicate = merged.any((existing) {
          final exName = (existing['_name'] ?? '').toString().toLowerCase();
          final exLat = double.tryParse(existing['lat'].toString()) ?? 0;
          final exLon = double.tryParse(existing['lon'].toString()) ?? 0;

          final nameMatch =
              candName.isNotEmpty &&
              exName.isNotEmpty &&
              (candName == exName ||
                  candName.contains(exName) ||
                  exName.contains(candName));
          final distDiff = (candLat - exLat).abs() + (candLon - exLon).abs();
          return (nameMatch && distDiff < 0.08) || distDiff < 0.0005;
        });

        if (!isDuplicate) {
          merged.add(candidate);
        }
      }

      // Sort by combined score descending
      merged.sort(
        (a, b) => (b['_score'] as double).compareTo(a['_score'] as double),
      );

      final top5 = merged.take(5).toList();

      if (mounted) {
        setState(() {
          _suggestions = top5;
          _isLoadingSuggestions = false;
        });
      }
    } catch (e) {
      print("Multi-Source Autocomplete Error: $e");
      if (mounted) {
        setState(() => _isLoadingSuggestions = false);
      }
    }
  }

  void _swapOriginDestination() {
    final tempText = _originController.text;
    _originController.text = _searchController.text;
    _searchController.text = tempText;

    final tempLoc = _customOrigin;
    _customOrigin = _destination;
    _destination = tempLoc;

    if (_originController.text == 'Your location') {
      _customOrigin = null;
    }

    if (_searchController.text == 'Your location') {
      _destination = _currentPosition ?? _bulacanCenter;
    }

    if (_destination != null) {
      final start =
          (_originController.text == 'Your location' || _customOrigin == null)
          ? (_currentPosition ?? _bulacanCenter)
          : _customOrigin!;
      setState(() {
        _rubberBandActiveRoute(newStart: start, newEnd: _destination);
      });
      _calculateRoute(
        _destination!,
        customOrigin: start,
        fitCamera: false,
        silent: true,
      );
    } else {
      setState(() {});
      if (_originController.text.isNotEmpty &&
          _searchController.text.isNotEmpty) {
        _searchAndRoute();
      }
    }
  }

  void _selectSuggestion(dynamic suggestion) {
    final lat = double.parse(suggestion['lat'].toString());
    final lon = double.parse(suggestion['lon'].toString());
    final name =
        (suggestion['_name'] ??
                suggestion['display_name'] ??
                'Selected Location')
            .toString();
    final shortAddr = (suggestion['_short_addr'] ?? '').toString();
    final selectedLoc = LatLng(lat, lon);

    _addToSearchHistory(
      name: name,
      address: shortAddr.isNotEmpty ? shortAddr : name,
      lat: lat,
      lon: lon,
    );

    if (_isRoutePlanningMode) {
      if (_isEditingOrigin) {
        setState(() {
          _originController.text = name;
          _customOrigin = selectedLoc;
          _suggestions = [];
        });
        if (_hasValidDestination()) {
          setState(() => _isSearchPageActive = false);
          _originFocusNode.unfocus();
          _destinationFocusNode.unfocus();
          _calculateRoute(_destination!, customOrigin: selectedLoc);
        } else {
          setState(() {
            _isSearchPageActive = true;
            _isEditingOrigin = false;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _destinationFocusNode.requestFocus();
          });
        }
      } else {
        setState(() {
          _searchController.text = name;
          _destination = selectedLoc;
          _suggestions = [];
        });
        if (_hasValidOrigin()) {
          setState(() => _isSearchPageActive = false);
          _originFocusNode.unfocus();
          _destinationFocusNode.unfocus();
          final start =
              (_originController.text.trim() == 'Your location' ||
                  _customOrigin == null)
              ? (_currentPosition ?? _bulacanCenter)
              : _customOrigin;
          _calculateRoute(selectedLoc, customOrigin: start);
        } else {
          setState(() {
            _isSearchPageActive = true;
            _isEditingOrigin = true;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _originFocusNode.requestFocus();
          });
        }
      }
    } else {
      // Standard Search: Set destination and show Point A to Point B route preview
      setState(() {
        _searchController.text = name;
        _originController.text = 'Your location';
        _destination = selectedLoc;
        _customOrigin = null;
        _suggestions = [];
        _selectedPothole = null;
        _isRoutePlanningMode = true;
        _isNavigating = false;
        _searchedPlace = null;
        _isSearchPageActive = false;
      });
      _searchFocusNode.unfocus();
      _calculateRoute(selectedLoc);

      _animatedMapMove(selectedLoc, 16.5);
    }
  }

  bool _hasValidOrigin() {
    final text = _originController.text.trim();
    if (text.isEmpty) return false;
    if (_customOrigin != null) return true;
    if (text == 'Your location' && _currentPosition != null) return true;
    return false;
  }

  bool _hasValidDestination() {
    final text = _searchController.text.trim();
    if (text.isEmpty) return false;
    return _destination != null;
  }

  Future<String> _reverseGeocodeLabel(LatLng point) async {
    try {
      final url = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat': point.latitude.toString(),
        'lon': point.longitude.toString(),
        'format': 'json',
        'addressdetails': '1',
      });
      final res = await http
          .get(url, headers: {'User-Agent': 'RoadSense-GIS/1.0'})
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final addr = (data['address'] as Map<String, dynamic>?) ?? {};

        String road = addr['house_number'] != null
            ? '${addr['house_number']} ${addr['road'] ?? ''}'.trim()
            : (addr['road'] ??
                      addr['pedestrian'] ??
                      addr['amenity'] ??
                      addr['building'] ??
                      '')
                  .toString()
                  .trim();

        String rawBrgy =
            (addr['suburb'] ??
                    addr['village'] ??
                    addr['quarter'] ??
                    addr['neighbourhood'] ??
                    addr['city_district'] ??
                    '')
                .toString()
                .trim();
        String brgy = '';
        if (rawBrgy.isNotEmpty) {
          final lower = rawBrgy.toLowerCase();
          if (lower.startsWith('brgy.') || lower.startsWith('brgy ')) {
            brgy = 'Barangay ${rawBrgy.substring(5).trim()}';
          } else if (lower.startsWith('barangay')) {
            brgy = rawBrgy;
          } else {
            brgy = 'Barangay $rawBrgy';
          }
        }

        String city =
            (addr['city'] ??
                    addr['town'] ??
                    addr['municipality'] ??
                    addr['county'] ??
                    '')
                .toString()
                .trim();

        String province = (addr['province'] ?? addr['state'] ?? 'Bulacan')
            .toString()
            .trim();

        List<String> parts = [];
        if (road.isNotEmpty) parts.add(road);
        if (brgy.isNotEmpty && brgy != road) parts.add(brgy);
        if (city.isNotEmpty) parts.add(city);
        if (province.isNotEmpty && province != city) parts.add(province);

        if (parts.isNotEmpty) return parts.join(', ');
      }
    } catch (_) {}
    return 'Selected on map';
  }

  void _confirmChooseLocationOnMap() {
    final LatLng centerLoc = _mapController.camera.center;

    if (_isRoutePlanningMode) {
      if (_isChoosingOriginOnMap) {
        setState(() {
          _customOrigin = centerLoc;
          _originController.text = 'Selected on map';
          _isChoosingLocationOnMap = false;
        });

        _reverseGeocodeLabel(centerLoc).then((label) {
          if (mounted && _originController.text == 'Selected on map') {
            setState(() => _originController.text = label);
          }
        });

        if (_hasValidDestination()) {
          setState(() => _isSearchPageActive = false);
          _calculateRoute(_destination!, customOrigin: centerLoc);
        } else {
          // Destination is missing -> return to Point A to Point B page to select Point B
          setState(() {
            _isSearchPageActive = true;
            _isEditingOrigin = false;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _destinationFocusNode.requestFocus();
          });
        }
      } else {
        setState(() {
          _destination = centerLoc;
          _searchController.text = 'Selected on map';
          _isChoosingLocationOnMap = false;
        });

        _reverseGeocodeLabel(centerLoc).then((label) {
          if (mounted && _searchController.text == 'Selected on map') {
            setState(() => _searchController.text = label);
          }
        });

        if (_hasValidOrigin()) {
          setState(() => _isSearchPageActive = false);
          final start =
              (_originController.text.trim() == 'Your location' ||
                  _customOrigin == null)
              ? (_currentPosition ?? _bulacanCenter)
              : _customOrigin;
          _calculateRoute(centerLoc, customOrigin: start);
        } else {
          // Origin is missing -> return to Point A to Point B page to select Point A
          setState(() {
            _isSearchPageActive = true;
            _isEditingOrigin = true;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _originFocusNode.requestFocus();
          });
        }
      }
    } else {
      // Standard Search: set destination and calculate route
      setState(() {
        _isChoosingLocationOnMap = false;
        _isSearchPageActive = false;
        _destination = centerLoc;
        _searchController.text = 'Selected on map';
        _originController.text = 'Your location';
        _customOrigin = null;
        _isRoutePlanningMode = true;
        _isNavigating = false;
        _searchedPlace = null;
      });

      _reverseGeocodeLabel(centerLoc).then((label) {
        if (mounted && _searchController.text == 'Selected on map') {
          setState(() => _searchController.text = label);
        }
      });

      _calculateRoute(centerLoc);
    }
  }

  List<LatLng> _sanitizeRoutePoints(List<LatLng> points, LatLng destination) {
    // Keep the full road-following polyline intact (including final approach
    // segments longer than 35m) so hazards near the destination remain matched.
    return points;
  }

  Future<LatLng?> _geocodeQuery(String query) async {
    final text = _normalizeQuery(
      query,
    ).replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ').trim();
    if (text.isEmpty || text == 'Your location') return null;

    // 0. Instant Check: Local Bulacan Barangay Registry (<1ms)
    final localMatches = _fetchLocalBarangayCandidates(text);
    if (localMatches.isNotEmpty) {
      final best = localMatches.first;
      final lat = double.tryParse(best['lat'].toString());
      final lon = double.tryParse(best['lon'].toString());
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // 1. Primary: OSM Nominatim Geocoding API with Bulacan viewbox bias
    try {
      final nomUrl = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': text,
        'format': 'json',
        'limit': '1',
        'countrycodes': 'ph',
        'viewbox': '120.55,15.25,121.35,14.65',
        'bounded': '0',
      });
      final nomRes = await http
          .get(nomUrl, headers: {'User-Agent': 'RoadSense-GIS/1.0'})
          .timeout(const Duration(seconds: 4));
      if (nomRes.statusCode == 200) {
        final List data = jsonDecode(nomRes.body) as List;
        if (data.isNotEmpty) {
          final lat = double.tryParse(data.first['lat'].toString());
          final lon = double.tryParse(data.first['lon'].toString());
          if (lat != null && lon != null) return LatLng(lat, lon);
        }
      }
    } catch (e) {
      print('OSM Nominatim Geocode Error: $e');
    }

    // 1b. Fallback: Query with Province & Country Context if not specified
    if (!text.toLowerCase().contains('bulacan') &&
        !text.toLowerCase().contains('philippines')) {
      try {
        final fallbackUrl =
            Uri.https('nominatim.openstreetmap.org', '/search', {
              'q': '$text, Bulacan, Philippines',
              'format': 'json',
              'limit': '1',
              'countrycodes': 'ph',
            });
        final fallbackRes = await http
            .get(fallbackUrl, headers: {'User-Agent': 'RoadSense-GIS/1.0'})
            .timeout(const Duration(seconds: 4));
        if (fallbackRes.statusCode == 200) {
          final List data = jsonDecode(fallbackRes.body) as List;
          if (data.isNotEmpty) {
            final lat = double.tryParse(data.first['lat'].toString());
            final lon = double.tryParse(data.first['lon'].toString());
            if (lat != null && lon != null) return LatLng(lat, lon);
          }
        }
      } catch (_) {}
    }

    // 2. Secondary: Photon OSM Geocoding API
    try {
      final refPos = _currentPosition ?? _bulacanCenter;
      final photUrl = Uri.https('photon.komoot.io', '/api/', {
        'q': text,
        'lat': refPos.latitude.toString(),
        'lon': refPos.longitude.toString(),
        'limit': '1',
      });
      final photRes = await http
          .get(photUrl, headers: {'User-Agent': 'RoadSense-GIS/1.0'})
          .timeout(const Duration(seconds: 4));
      if (photRes.statusCode == 200) {
        final payload = jsonDecode(photRes.body) as Map<String, dynamic>;
        final features = (payload['features'] as List?) ?? [];
        if (features.isNotEmpty) {
          final geometry =
              (features.first['geometry'] as Map<String, dynamic>?) ?? {};
          final coords = (geometry['coordinates'] as List?) ?? [0, 0];
          return LatLng(
            ((coords.length > 1 ? coords[1] : 0) as num).toDouble(),
            ((coords.isNotEmpty ? coords[0] : 0) as num).toDouble(),
          );
        }
      }
    } catch (e) {
      print('Photon OSM Geocode Error: $e');
    }

    // 3. Fallback: ORS Geocoding API
    if (_orsApiKey.isNotEmpty) {
      try {
        final Map<String, String> queryParams = {
          'api_key': _orsApiKey,
          'text': text,
          'size': '1',
          'boundary.country': 'PH',
        };
        if (_currentPosition != null) {
          queryParams['focus.point.lat'] = _currentPosition!.latitude
              .toString();
          queryParams['focus.point.lon'] = _currentPosition!.longitude
              .toString();
        }
        final geoUrl = Uri.https(
          'api.openrouteservice.org',
          '/geocode/search',
          queryParams,
        );
        final geoRes = await http
            .get(geoUrl, headers: {'User-Agent': 'PotholeScannerApp/1.0'})
            .timeout(const Duration(seconds: 4));
        if (geoRes.statusCode == 200) {
          final payload = jsonDecode(geoRes.body) as Map<String, dynamic>;
          final features = (payload['features'] as List?) ?? [];
          if (features.isNotEmpty) {
            final best = features.first as Map<String, dynamic>;
            final geometry = (best['geometry'] as Map<String, dynamic>?) ?? {};
            final coords = (geometry['coordinates'] as List?) ?? [0, 0];
            return LatLng(
              ((coords.length > 1 ? coords[1] : 0) as num).toDouble(),
              ((coords.isNotEmpty ? coords[0] : 0) as num).toDouble(),
            );
          }
        }
      } catch (e) {
        print('ORS Geocoding error for "$text": $e');
      }
    }

    return null;
  }

  double _calculateBearing(LatLng from, LatLng to) {
    final double lat1 = from.latitude * (math.pi / 180.0);
    final double lon1 = from.longitude * (math.pi / 180.0);
    final double lat2 = to.latitude * (math.pi / 180.0);
    final double lon2 = to.longitude * (math.pi / 180.0);

    final double dLon = lon2 - lon1;
    final double y = math.sin(dLon) * math.cos(lat2);
    final double x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final double radians = math.atan2(y, x);
    return (radians * (180.0 / math.pi) + 360.0) % 360.0;
  }

  List<RouteStep> _parseOsrmSteps(Map<String, dynamic> route) {
    final List<RouteStep> stepsList = [];
    final List legs = (route['legs'] as List?) ?? [];
    for (final leg in legs) {
      final List steps = (leg['steps'] as List?) ?? [];
      for (int i = 0; i < steps.length; i++) {
        final step = steps[i] as Map<String, dynamic>;
        final maneuver = (step['maneuver'] as Map<String, dynamic>?) ?? {};
        final String type = (maneuver['type'] as String? ?? 'turn')
            .toLowerCase();
        final String? rawModifier = maneuver['modifier'] as String?;
        final List locCoords = (maneuver['location'] as List?) ?? [0, 0];
        final LatLng loc = LatLng(
          (locCoords.length > 1 ? locCoords[1] as num : 0).toDouble(),
          (locCoords.isNotEmpty ? locCoords[0] as num : 0).toDouble(),
        );

        final String name = (step['name'] as String? ?? '').trim();
        final double dist = (step['distance'] as num? ?? 0.0).toDouble();
        final double dur = (step['duration'] as num? ?? 0.0).toDouble();

        // Prioritize OSRM's verified modifier directly from the routing engine
        String? verifiedModifier =
            (rawModifier != null && rawModifier.trim().isNotEmpty)
            ? rawModifier.trim().toLowerCase()
            : null;
        final num? bBefore = maneuver['bearing_before'] as num?;
        final num? bAfter = maneuver['bearing_after'] as num?;

        if (verifiedModifier == null &&
            bBefore != null &&
            bAfter != null &&
            type != 'arrive' &&
            type != 'depart') {
          final double delta =
              ((bAfter.toDouble() - bBefore.toDouble()) + 540) % 360 - 180;
          if (delta < -135) {
            verifiedModifier = 'sharp left';
          } else if (delta < -30) {
            verifiedModifier = 'left';
          } else if (delta < -10) {
            verifiedModifier = 'slight left';
          } else if (delta > 135) {
            verifiedModifier = 'sharp right';
          } else if (delta > 30) {
            verifiedModifier = 'right';
          } else if (delta > 10) {
            verifiedModifier = 'slight right';
          } else {
            verifiedModifier = 'straight';
          }
        } else if (verifiedModifier == null &&
            i > 0 &&
            i < steps.length - 1 &&
            type != 'arrive' &&
            type != 'depart') {
          // Secondary Fallback: Calculate angle between previous step, this step, and next step locations
          final prevStep = steps[i - 1] as Map<String, dynamic>;
          final nextStep = steps[i + 1] as Map<String, dynamic>;
          final prevLocCoords =
              (prevStep['maneuver']?['location'] as List?) ?? [];
          final nextLocCoords =
              (nextStep['maneuver']?['location'] as List?) ?? [];
          if (prevLocCoords.length >= 2 && nextLocCoords.length >= 2) {
            final prevLoc = LatLng(
              (prevLocCoords[1] as num).toDouble(),
              (prevLocCoords[0] as num).toDouble(),
            );
            final nextLoc = LatLng(
              (nextLocCoords[1] as num).toDouble(),
              (nextLocCoords[0] as num).toDouble(),
            );
            final double bIn = _calculateBearing(prevLoc, loc);
            final double bOut = _calculateBearing(loc, nextLoc);
            final double delta = ((bOut - bIn) + 540) % 360 - 180;
            if (delta < -135) {
              verifiedModifier = 'sharp left';
            } else if (delta < -30) {
              verifiedModifier = 'left';
            } else if (delta < -10) {
              verifiedModifier = 'slight left';
            } else if (delta > 135) {
              verifiedModifier = 'sharp right';
            } else if (delta > 30) {
              verifiedModifier = 'right';
            } else if (delta > 10) {
              verifiedModifier = 'slight right';
            }
          }
        }

        String instruction = '';
        if (type == 'depart') {
          instruction = 'Head ${verifiedModifier ?? 'ahead'}';
        } else if (type == 'arrive') {
          instruction = verifiedModifier != null
              ? 'You have arrived at your destination, on the $verifiedModifier'
              : 'You have arrived at your destination';
        } else if (type == 'turn' || type == 'end of road') {
          final modStr = verifiedModifier ?? 'ahead';
          if (name.isNotEmpty) {
            instruction = 'Turn $modStr onto $name';
          } else {
            instruction = 'Turn $modStr';
          }
        } else if (type == 'new name' || type == 'continue') {
          if (name.isNotEmpty) {
            instruction = 'Continue onto $name';
          } else {
            instruction = 'Continue straight';
          }
        } else if (type == 'roundabout' || type == 'rotary') {
          instruction = name.isNotEmpty
              ? 'Enter roundabout and exit onto $name'
              : 'Enter roundabout';
        } else if (type == 'fork') {
          instruction =
              'Keep ${verifiedModifier ?? 'right'}${name.isNotEmpty ? ' onto $name' : ''}';
        } else if (type == 'merge') {
          instruction =
              'Merge ${verifiedModifier ?? 'onto road'}${name.isNotEmpty ? ' onto $name' : ''}';
        } else {
          instruction = name.isNotEmpty
              ? 'Continue on $name'
              : 'Continue on road';
        }

        stepsList.add(
          RouteStep(
            instruction: instruction,
            roadName: name,
            distanceMeters: dist,
            durationSeconds: dur,
            maneuverType: type,
            modifier: verifiedModifier,
            location: loc,
          ),
        );
      }
    }
    return stepsList;
  }

  Future<void> _calculateRoute(
    LatLng destination, {
    LatLng? customOrigin,
    bool fitCamera = true,
    bool silent = false,
  }) async {
    LatLng? resolvedStart = customOrigin ?? _customOrigin;
    if (resolvedStart == null) {
      if (_originController.text == 'Your location' ||
          _originController.text.trim().isEmpty) {
        resolvedStart = _currentPosition ?? _bulacanCenter;
      } else {
        resolvedStart = await _geocodeQuery(_originController.text);
        if (resolvedStart != null) {
          _customOrigin = resolvedStart;
        } else {
          resolvedStart = _currentPosition ?? _bulacanCenter;
        }
      }
    }
    final LatLng start = resolvedStart;

    final int seq = ++_routingRequestSeq;
    if (!silent) {
      setState(() {
        _isRouting = true;
        _routeErrorMessage = null;
        _hasEvaluatedFewerPotholes = false;
      });
    } else {
      if (!_isRouting && mounted) {
        setState(() {
          _isRouting = true;
          _routeErrorMessage = null;
        });
      }
    }

    List<List<LatLng>> routes = [];
    List<double> durations = [];
    List<double> distances = [];
    List<List<RouteStep>> stepsByRoute = [];
    bool loadedFromCache = false;

    // 1. Primary: Project-OSRM Routing Engine API with 3 Travel Modes
    try {
      Uri osrmUrl;
      if (_travelMode == OsrmTravelMode.bike) {
        osrmUrl = Uri.parse(
          'https://routing.openstreetmap.de/routed-bike/route/v1/driving/'
          '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&alternatives=3&steps=true&annotations=true',
        );
      } else if (_travelMode == OsrmTravelMode.foot) {
        osrmUrl = Uri.parse(
          'https://routing.openstreetmap.de/routed-foot/route/v1/driving/'
          '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&alternatives=3&steps=true&annotations=true',
        );
      } else {
        osrmUrl = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/'
          '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&alternatives=3&steps=true&annotations=true',
        );
      }

      var osrmRes = await _httpClient
          .get(osrmUrl)
          .timeout(const Duration(seconds: 6));
      if (osrmRes.statusCode != 200 && _travelMode != OsrmTravelMode.car) {
        final fallbackUrl = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/'
          '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&alternatives=3&steps=true&annotations=true',
        );
        osrmRes = await _httpClient
            .get(fallbackUrl)
            .timeout(const Duration(seconds: 6));
      }

      if (osrmRes.statusCode == 200) {
        final data = jsonDecode(osrmRes.body);
        final List osrmRoutes = data['routes'] ?? [];
        for (final r in osrmRoutes.take(3)) {
          final List coords =
              (r['geometry'] as Map<String, dynamic>)['coordinates'] as List;
          List<LatLng> points = coords.map((c) {
            final List pair = c as List;
            return LatLng(
              (pair[1] as num).toDouble(),
              (pair[0] as num).toDouble(),
            );
          }).toList();
          if (points.length < 2) continue;

          points = _sanitizeRoutePoints(points, destination);

          double duration = (r['duration'] as num).toDouble();
          final double distance = (r['distance'] as num).toDouble();

          // Duration scaling if standard server was used for bike/foot
          if (_travelMode == OsrmTravelMode.bike &&
              duration < (distance / 4.5)) {
            duration = distance / 4.16; // ~15 km/h
          } else if (_travelMode == OsrmTravelMode.foot &&
              duration < (distance / 1.5)) {
            duration = distance / 1.33; // ~4.8 km/h
          }

          final List<RouteStep> parsedSteps = _parseOsrmSteps(
            r as Map<String, dynamic>,
          );

          routes.add(points);
          durations.add(duration);
          distances.add(distance);
          stepsByRoute.add(parsedSteps);
        }
      }
    } catch (e) {
      print('Project-OSRM Routing Error: $e');
    }

    // 2. Secondary Fallback: OpenRouteService Directions API
    if (routes.isEmpty) {
      try {
        String orsProfile = 'driving-car';
        if (_travelMode == OsrmTravelMode.bike) orsProfile = 'cycling-regular';
        if (_travelMode == OsrmTravelMode.foot) orsProfile = 'foot-walking';

        final url = Uri.parse(
          'https://api.openrouteservice.org/v2/directions/$orsProfile/geojson',
        );

        final Map<String, dynamic> requestBody = {
          "coordinates": [
            [start.longitude, start.latitude],
            [destination.longitude, destination.latitude],
          ],
          "radiuses": [-1, -1],
          "alternative_routes": {
            "target_count": 3,
            "share_factor": 0.6,
            "weight_factor": 1.4,
          },
        };

        final response = await _httpClient
            .post(
              url,
              headers: {
                'Authorization': _orsApiKey,
                'Content-Type': 'application/json',
                'User-Agent': 'PotholeScannerApp/1.0',
              },
              body: jsonEncode(requestBody),
            )
            .timeout(const Duration(seconds: 7));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final List features = data['features'] ?? [];
          for (final feature in features.take(3)) {
            final Map<String, dynamic> featureMap =
                feature as Map<String, dynamic>;
            final List coords =
                (featureMap['geometry'] as Map<String, dynamic>)['coordinates']
                    as List;
            List<LatLng> points = coords.map((c) {
              final List pair = c as List;
              return LatLng(
                (pair[1] as num).toDouble(),
                (pair[0] as num).toDouble(),
              );
            }).toList();
            if (points.length < 2) continue;

            points = _sanitizeRoutePoints(points, destination);

            final props = featureMap['properties'] as Map<String, dynamic>;
            final summary = props['summary'] as Map<String, dynamic>;
            final double duration = (summary['duration'] as num).toDouble();
            final double distance = (summary['distance'] as num).toDouble();
            routes.add(points);
            durations.add(duration);
            distances.add(distance);
            stepsByRoute.add([]);
          }
        }
      } catch (e) {
        print('ORS fallback routing attempt failed: $e');
      }
    }

    if (routes.isNotEmpty && routes.length < 3 && !silent) {
      await _tryDiscoverAvoidanceRoutes(
        start: start,
        destination: destination,
        routes: routes,
        durations: durations,
        distances: distances,
        stepsByRoute: stepsByRoute,
        requestSeq: seq,
      );
    }

    if (!mounted || seq != _routingRequestSeq) return;

    if (routes.isEmpty || durations.isEmpty) {
      final cachedRoute = await RoadReportCache.loadRecentRoute(
        RoadReportCache.routeCacheKey(
          origin: start,
          destination: destination,
          travelMode: _travelMode.name,
        ),
      );
      if (!mounted || seq != _routingRequestSeq) return;
      if (cachedRoute != null && cachedRoute.routes.isNotEmpty) {
        loadedFromCache = true;
        routes = cachedRoute.routes;
        durations = cachedRoute.durations;
        distances = cachedRoute.distances;
        stepsByRoute = List<List<RouteStep>>.generate(
          routes.length,
          (_) => const [],
        );
      }
    }

    if (routes.isEmpty || durations.isEmpty) {
      const String errMsg =
          'Unable to calculate route right now. Active route preserved.';
      if (mounted && seq == _routingRequestSeq) {
        setState(() {
          _isRouting = false;
          _routeErrorMessage = errMsg;
          if (_alternativeRoutes.isNotEmpty) {
            final int activeIdx =
                _selectedRouteIndex < _alternativeRoutes.length
                ? _selectedRouteIndex
                : 0;
            _routePoints = _alternativeRoutes[activeIdx];
          }
        });
      }
      if (mounted && !silent && seq == _routingRequestSeq) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(errMsg),
            backgroundColor: Colors.red,
            action: SnackBarAction(
              label: 'RETRY',
              textColor: Colors.white,
              onPressed: () => _calculateRoute(destination),
            ),
          ),
        );
      }
      return;
    }

    await _processRoutes(
      routes,
      durations,
      distances,
      destination,
      stepsByRoute: stepsByRoute,
      fitCamera: fitCamera,
      requestSeq: seq,
      fromCache: loadedFromCache,
    );
  }

  Future<bool> _showLocationPermissionPrimer() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_locationPrimerPrefKey) ?? false) return true;

    if (!mounted) return false;
    final bool isDark = AppSettings.instance.isDarkMode;

    final bool? proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        backgroundColor: AppDesign.surface(isDark),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: AppDesign.border(isDark), width: 1.2),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppDesign.accent(isDark).withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.my_location_rounded,
                    color: AppDesign.accent(isDark),
                    size: 32,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Enable Location',
                style: TextStyle(
                  color: AppDesign.textPrimary(isDark),
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'RoadSense AI needs your location to center the map on your '
                'position and warn you in real time about potholes ahead on '
                'your route.',
                style: TextStyle(
                  color: AppDesign.textSecondary(isDark),
                  fontSize: 13.5,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      style: TextButton.styleFrom(
                        foregroundColor: AppDesign.textSecondary(isDark),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: AppDesign.border(isDark),
                            width: 1.2,
                          ),
                        ),
                      ),
                      child: const Text(
                        'Not Now',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppDesign.accent(isDark),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Allow Location',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    await prefs.setBool(_locationPrimerPrefKey, true);
    return proceed ?? false;
  }

  Future<void> _determinePosition({bool requestPermission = true}) async {
    if (requestPermission) {
      if (mounted) {
        setState(() {
          _dismissedLocationPrompt = false;
        });
      }
    }

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        setState(() {
          _isLocationDisabled = true;
          _isLoadingLocation = false;
        });
      }
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      if (requestPermission) {
        final bool proceed = await _showLocationPermissionPrimer();
        if (!proceed) {
          if (mounted) {
            setState(() {
              _isPermissionDenied = true;
              _isLoadingLocation = false;
            });
          }
          return;
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        if (mounted) {
          setState(() {
            _isPermissionDenied = true;
            _isLoadingLocation = false;
          });
        }
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() {
          _isPermissionDenied = true;
          _isLoadingLocation = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLocationDisabled = false;
        _isPermissionDenied = false;
        _dismissedLocationPrompt = false;
      });
    }

    try {
      Position? lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && mounted) {
        final lastPos = LatLng(lastKnown.latitude, lastKnown.longitude);
        setState(() {
          if (!_useMockLocation && _currentPosition == null) {
            _currentPosition = lastPos;
            _cachedGlobalPosition = lastPos;
          }
          _isLoadingLocation = false;
        });
        if (!_useMockLocation && _animatedPuckPositionNotifier.value == null) {
          _gpsSmoother.reset(position: lastPos);
          _animatedPuckPositionNotifier.value = lastPos;
        }
        _startFollowing();
      }

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 5),
        ),
      );
      final livePosition = LatLng(position.latitude, position.longitude);
      _lastRealGpsPosition = livePosition;

      if (mounted) {
        setState(() {
          _lastGpsAccuracyMeters = position.accuracy;
          _lastGpsSpeedMps = position.speed;
          _lastGpsTimestamp = position.timestamp;
          if (!_useMockLocation) {
            _currentPosition = livePosition;
            _cachedGlobalPosition = livePosition;
          }
          _isLoadingLocation = false;
        });
        if (!_useMockLocation) {
          _animatePuckTo(
            livePosition,
            timestamp: position.timestamp,
            speedMps: position.speed,
            headingDeg: position.heading >= 0 ? position.heading : null,
          );
        }
        if (_currentPosition != null) {
          _checkPotholeProximity(_currentPosition!);
        }
        _startFollowing();
      }
    } catch (e) {
      print('Location fetch error or timeout: $e');
      if (mounted) {
        setState(() {
          _isLoadingLocation = false;
          _currentPosition ??= _cachedGlobalPosition ?? _bulacanCenter;
        });
        _startFollowing();
      }
    }
  }

  /// Show a full-screen bottom sheet with the pothole photo and details.
  Future<void> _showPotholeDetails(PotholeMarker pothole) async {
    final currentUser = CloudService.instance.currentUser;
    String role = 'user';
    if (currentUser != null) {
      role = await CloudService.instance.getUserRole(currentUser.uid);
    }
    final bool isAdminUser = (role == 'admin' || role == 'super_admin');

    if (!mounted) return;

    final isDarkNow = AppSettings.instance.isDarkMode;
    final isApproved = pothole.status == 'approved';
    final isRejected = pothole.status == 'rejected';

    final Color statusBg = isApproved
        ? AppDesign.success
        : (isRejected ? AppDesign.danger : AppDesign.warning);
    final IconData statusIcon = isApproved
        ? Icons.verified_rounded
        : (isRejected ? Icons.cancel_rounded : Icons.pending_actions_rounded);
    final String statusLabel = isApproved
        ? 'Approved'
        : (isRejected ? 'Rejected' : 'Pending Review');
    final DpwhDefectClass defectCls = DpwhStandards.classify(
      pothole.primaryDefect,
    );
    double topConfidence = 0.0;
    if (pothole.detections != null) {
      for (final d in pothole.detections!) {
        final raw = (d['confidence'] as num?)?.toDouble() ?? 0.0;
        final pct = raw > 1.0 ? raw : raw * 100.0;
        if (pct > topConfidence) topConfidence = pct;
      }
    }
    final String confidenceLabel = topConfidence > 0
        ? '${topConfidence.toStringAsFixed(0)}% AI match'
        : (isApproved ? 'Admin verified' : 'Pending review');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.45,
        maxChildSize: 0.95,
        builder: (_, scrollController) => Container(
          decoration: BoxDecoration(
            color: AppDesign.surface(isDarkNow),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: AppDesign.border(isDarkNow), width: 1.0),
            boxShadow: AppDesign.shadowMd(isDarkNow),
          ),
          child: Column(
            children: [
              // Drag Handle
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppDesign.border(isDarkNow),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header Bar
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    MobileStatusPill(
                      label: statusLabel,
                      icon: statusIcon,
                      color: statusBg,
                      compact: true,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Road Defect Report',
                        style: TextStyle(
                          color: AppDesign.textPrimary(isDarkNow),
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    MobileTouchIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Close report details',
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),

              Divider(
                color: AppDesign.border(isDarkNow),
                height: 1,
                thickness: 1,
              ),

              // Main Body Content
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Photo Preview Box with Zoom capability
                      GestureDetector(
                        onTap: () {
                          if (pothole.imagePath.isNotEmpty) {
                            _showFullScreenPhoto(pothole.imagePath);
                          }
                        },
                        child: Container(
                          width: double.infinity,
                          height: 224,
                          decoration: BoxDecoration(
                            color: AppDesign.sunken(isDarkNow),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: AppDesign.border(isDarkNow),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child:
                                    pothole.imagePath.startsWith('http') ||
                                        pothole.imagePath.startsWith('blob:')
                                    ? Image.network(
                                        pothole.imagePath,
                                        fit: BoxFit.cover,
                                        loadingBuilder:
                                            (context, child, progress) {
                                              if (progress == null) {
                                                return child;
                                              }
                                              return Container(
                                                color: AppDesign.sunken(
                                                  isDarkNow,
                                                ),
                                                child: Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                        color: AppDesign.accent(
                                                          isDarkNow,
                                                        ),
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                              );
                                            },
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                _buildNoPhotoPlaceholder(),
                                      )
                                    : (pothole.imagePath.isNotEmpty
                                          ? Image.network(
                                              pothole.imagePath,
                                              fit: BoxFit.cover,
                                              errorBuilder:
                                                  (
                                                    context,
                                                    error,
                                                    stackTrace,
                                                  ) =>
                                                      _buildNoPhotoPlaceholder(),
                                            )
                                          : _buildNoPhotoPlaceholder()),
                              ),

                              // Bottom Scrim Overlay & Zoom Hint
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: const BoxDecoration(
                                    color: Color(0xCC0F172A),
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.pin_drop_rounded,
                                            color: Color(0xFF34D399),
                                            size: 14,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${pothole.location.latitude.toStringAsFixed(4)}, ${pothole.location.longitude.toStringAsFixed(4)}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (pothole.imagePath.isNotEmpty)
                                        const Row(
                                          children: [
                                            Icon(
                                              Icons.zoom_in_rounded,
                                              color: Colors.white,
                                              size: 14,
                                            ),
                                            SizedBox(width: 4),
                                            Text(
                                              'Tap to Zoom',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w600,
                                              ),
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
                      ),

                      const SizedBox(height: 18),

                      // Section Title
                      Text(
                        'REPORT METADATA & PRIORITY',
                        style: TextStyle(
                          color: AppDesign.textSecondary(isDarkNow),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),

                      const SizedBox(height: 10),

                      Row(
                        children: [
                          Expanded(
                            child: _buildTelemetryCard(
                              icon: statusIcon,
                              iconColor: statusBg,
                              title: 'REPORT STATUS',
                              value: statusLabel,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: const SizedBox.shrink()),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _buildTelemetryCard(
                              icon: Icons.engineering_rounded,
                              iconColor: AppDesign.accent(isDarkNow),
                              title: 'MAINTENANCE SLA',
                              value:
                                  '${defectCls.code} • ${pothole.responseTime}',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildTelemetryCard(
                              icon: Icons.psychology_rounded,
                              iconColor: AppDesign.accent(isDarkNow),
                              title: 'AI CONFIDENCE',
                              value: confidenceLabel,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _buildTelemetryCard(
                              icon: Icons.explore_rounded,
                              iconColor: AppDesign.accent(isDarkNow),
                              title: 'GPS COORDINATES',
                              value:
                                  '${pothole.location.latitude.toStringAsFixed(5)}, ${pothole.location.longitude.toStringAsFixed(5)}',
                              onTap: () {
                                Clipboard.setData(
                                  ClipboardData(
                                    text:
                                        '${pothole.location.latitude}, ${pothole.location.longitude}',
                                  ),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Coordinates copied to clipboard!',
                                    ),
                                    backgroundColor: AppDesign.brand,
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildTelemetryCard(
                              icon: Icons.schedule_rounded,
                              iconColor: AppDesign.warning,
                              title: 'DETECTED AT',
                              value:
                                  '${pothole.timestamp.year}-${pothole.timestamp.month.toString().padLeft(2, '0')}-${pothole.timestamp.day.toString().padLeft(2, '0')} ${pothole.timestamp.hour.toString().padLeft(2, '0')}:${pothole.timestamp.minute.toString().padLeft(2, '0')}',
                            ),
                          ),
                        ],
                      ),
                      if (isAdminUser) ...[
                        const SizedBox(height: 10),
                        _buildTelemetryCard(
                          icon: Icons.person_pin_rounded,
                          iconColor: AppDesign.success,
                          title: 'REPORTED BY',
                          value:
                              pothole.reporterEmail ?? 'RoadSense Contributor',
                        ),
                      ],

                      const SizedBox(height: 18),

                      // Official DPWH Specifications Section
                      Text(
                        'DPWH ROAD MAINTENANCE SPECIFICATIONS',
                        style: TextStyle(
                          color: AppDesign.textSecondary(isDarkNow),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 10),

                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: DpwhStandards.getClassColor(
                            pothole.primaryDefect,
                          ).withValues(alpha: isDarkNow ? 0.12 : 0.07),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: DpwhStandards.getClassColor(
                              pothole.primaryDefect,
                            ).withValues(alpha: 0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                MobileDefectPill(
                                  defectClass: defectCls,
                                  showCode: true,
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppDesign.brandWash(isDarkNow),
                                    borderRadius: BorderRadius.circular(
                                      AppDesign.radiusPill,
                                    ),
                                    border: Border.all(
                                      color: AppDesign.brandBorder(isDarkNow),
                                    ),
                                  ),
                                  child: Text(
                                    'SLA: ${pothole.responseTime}',
                                    style: TextStyle(
                                      color: AppDesign.accent(isDarkNow),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Standard Corrective Measure',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: AppDesign.textSecondary(isDarkNow),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              pothole.correctiveMeasure,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: AppDesign.textPrimary(isDarkNow),
                              ),
                            ),
                            if (pothole.detections != null &&
                                pothole.detections!.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Divider(
                                color: DpwhStandards.getClassColor(
                                  pothole.primaryDefect,
                                ).withValues(alpha: 0.25),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'AI Detected Defects (${pothole.detections!.length})',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppDesign.textSecondary(isDarkNow),
                                ),
                              ),
                              const SizedBox(height: 6),
                              ...pothole.detections!.map((d) {
                                final dCode =
                                    d['dpwhCode'] as String? ?? 'CODE 01';
                                final dName =
                                    d['defectType'] as String? ??
                                    d['className'] as String? ??
                                    'Hazard';
                                final dConf =
                                    (d['confidence'] as num?)?.toDouble() ??
                                    0.0;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2.5,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.check_circle_rounded,
                                        size: 13,
                                        color: DpwhStandards.getCodeColor(
                                          dCode,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          '[$dCode] $dName',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppDesign.textPrimary(
                                              isDarkNow,
                                            ),
                                          ),
                                        ),
                                      ),
                                      Text(
                                        dConf > 0
                                            ? '${(dConf > 1 ? dConf : dConf * 100).toStringAsFixed(0)}% confidence'
                                            : 'Detected',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: AppDesign.textSecondary(
                                            isDarkNow,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          ],
                        ),
                      ),
                      // Community Driver Verification & Consensus Feedback Loop
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: AppDesign.cardDecoration(
                          isDark: isDarkNow,
                          fill: AppDesign.sunken(isDarkNow),
                          radius: 14,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: AppDesign.brandWash(isDarkNow),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.people_alt_rounded,
                                    size: 14,
                                    color: AppDesign.accent(isDarkNow),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'COMMUNITY VERIFICATION',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.0,
                                    color: AppDesign.textSecondary(isDarkNow),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Help fellow drivers keep road maps accurate. Is this defect still present?',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                                color: AppDesign.textPrimary(isDarkNow),
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () =>
                                          _submitHazardFeedback(pothole, true),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF10B981,
                                          ).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: const Color(
                                              0xFF10B981,
                                            ).withValues(alpha: 0.6),
                                            width: 1.2,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.thumb_up_alt_rounded,
                                              size: 15,
                                              color: Color(0xFF10B981),
                                            ),
                                            SizedBox(width: 6),
                                            Text(
                                              'Still There',
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF10B981),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () =>
                                          _submitHazardFeedback(pothole, false),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFFEF4444,
                                          ).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: const Color(
                                              0xFFEF4444,
                                            ).withValues(alpha: 0.6),
                                            width: 1.2,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.thumb_down_alt_rounded,
                                              size: 15,
                                              color: Color(0xFFEF4444),
                                            ),
                                            SizedBox(width: 6),
                                            Text(
                                              'Fixed / Gone',
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFFEF4444),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: AppDesign.outlinedButtonStyle(
                            isDark: isDarkNow,
                          ),
                          onPressed: () => Navigator.of(ctx).pop(),
                          icon: const Icon(Icons.close_rounded, size: 18),
                          label: const Text('Close'),
                        ),
                      ),

                      // Admin Administrative Bar
                      if (isAdminUser) ...[
                        const SizedBox(height: 24),
                        Divider(color: AppDesign.border(isDarkNow)),
                        const SizedBox(height: 12),
                        const Text(
                          'ADMINISTRATIVE CONTROLS',
                          style: TextStyle(
                            color: AppDesign.warning,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            if (pothole.docId != null &&
                                pothole.status != 'approved') ...[
                              Expanded(
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppDesign.brand,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.check_circle_rounded,
                                    size: 18,
                                  ),
                                  label: const Text(
                                    'Approve',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  onPressed: () async {
                                    await CloudService.instance
                                        .updatePotholeStatus(
                                          pothole.docId!,
                                          'approved',
                                        );
                                    if (mounted) Navigator.pop(context);
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            if (pothole.docId != null &&
                                pothole.status != 'rejected') ...[
                              Expanded(
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppDesign.warning,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.cancel_rounded,
                                    size: 18,
                                  ),
                                  label: const Text(
                                    'Reject',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  onPressed: () async {
                                    await CloudService.instance
                                        .updatePotholeStatus(
                                          pothole.docId!,
                                          'rejected',
                                        );
                                    if (mounted) Navigator.pop(context);
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],

                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppDesign.danger,
                                  side: BorderSide(color: AppDesign.danger),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.delete_forever_rounded,
                                  size: 18,
                                ),
                                label: const Text(
                                  'Delete',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12.5,
                                  ),
                                ),
                                onPressed: () async {
                                  Navigator.of(ctx).pop();
                                  try {
                                    await _deleteDetectedPothole(pothole);
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Pothole marker deleted.',
                                        ),
                                      ),
                                    );
                                  } catch (_) {}
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
  Future<void> _showEditPotholeDialog(PotholeMarker pothole) async {
    if (DeveloperMarkers.owns(pothole.docId)) {
      await showDeveloperMarkerEditor(
        context,
        location: pothole.location,
        markerId: pothole.docId,
      );
      return;
    }

    if (pothole.docId == null) return;
    final isDark = AppSettings.instance.isDarkMode;
    int potholeCount = pothole.potholeCount;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: AppDesign.surface(isDark),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.edit_note_rounded,
                      color: Color(0xFF2563EB),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Edit Hazard Details',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppDesign.textPrimary(isDark),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 340,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 6),

                      const SizedBox(height: 16),
                      Text(
                        'Potholes in Cluster',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppDesign.textPrimary(isDark),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          IconButton.outlined(
                            icon: const Icon(Icons.remove, size: 16),
                            onPressed: potholeCount > 1
                                ? () => setDialogState(() => potholeCount--)
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              '$potholeCount',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppDesign.textPrimary(isDark),
                              ),
                            ),
                          ),
                          IconButton.outlined(
                            icon: const Icon(Icons.add, size: 16),
                            onPressed: () =>
                                setDialogState(() => potholeCount++),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      const SizedBox(height: 6),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    try {
                      await CloudService.instance.editPothole(
                        pothole.docId!,

                        potholeCount: potholeCount,
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Hazard updated successfully.'),
                            backgroundColor: Color(0xFF10B981),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Update failed: $e'),
                            backgroundColor: const Color(0xFFEF4444),
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('Save Changes'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildNoPhotoPlaceholder() {
    return Container(
      color: AppDesign.surface(AppSettings.instance.isDarkMode),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.no_photography_rounded,
              size: 42,
              color: Color(0xFF64748B),
            ),
            SizedBox(height: 8),
            Text(
              'No inspection photo captured',
              style: TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    VoidCallback? onTap,
  }) {
    return MouseRegion(
      cursor: onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppDesign.surface(AppSettings.instance.isDarkMode),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppDesign.border(AppSettings.instance.isDarkMode),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: iconColor, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: AppDesign.textSecondary(
                          AppSettings.instance.isDarkMode,
                        ),
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: TextStyle(
                  color: AppDesign.textPrimary(AppSettings.instance.isDarkMode),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFullScreenPhoto(String imagePath) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black.withValues(alpha: 0.92),
        insetPadding: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child:
                  _isTrustedRemoteImageUrl(imagePath) ||
                      (kIsWeb && imagePath.startsWith('blob:'))
                  ? Image.network(imagePath, fit: BoxFit.contain)
                  : Image.network(
                      imagePath,
                      fit: BoxFit.contain,
                      errorBuilder: (ctx, e, st) => const Icon(
                        Icons.broken_image,
                        color: Colors.white,
                        size: 64,
                      ),
                    ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _searchAndRoute() async {
    final destQuery = _searchController.text.trim();
    final originQuery = _originController.text.trim();
    if (destQuery.isEmpty) return;

    setState(() => _isRouting = true);

    try {
      if (!_isRoutePlanningMode) {
        // Standard Search: Geocode or use top suggestion, then show sleek Google Maps Place Card for user to verify
        LatLng? destLoc;
        String placeName = destQuery;
        String placeAddr = '';

        if (_suggestions.isNotEmpty) {
          final top = _suggestions.first;
          final lat = double.tryParse(top['lat'].toString()) ?? 0;
          final lon = double.tryParse(top['lon'].toString()) ?? 0;
          if (lat != 0 && lon != 0) {
            destLoc = LatLng(lat, lon);
            placeName = (top['_name'] ?? top['display_name'] ?? destQuery)
                .toString();
            placeAddr = (top['_short_addr'] ?? top['display_name'] ?? '')
                .toString();
          }
        }

        destLoc ??= await _geocodeQuery(destQuery);

        if (destLoc == null) {
          throw 'Location "$destQuery" not found. Please try another search term.';
        }

        double distKm = 0.0;
        if (_currentPosition != null) {
          distKm =
              Geolocator.distanceBetween(
                _currentPosition!.latitude,
                _currentPosition!.longitude,
                destLoc.latitude,
                destLoc.longitude,
              ) /
              1000.0;
        }

        _addToSearchHistory(
          name: placeName,
          address: placeAddr.isNotEmpty ? placeAddr : placeName,
          lat: destLoc.latitude,
          lon: destLoc.longitude,
        );

        setState(() {
          _destination = destLoc;
          _selectedPothole = null;
          _suggestions = [];
          _searchedPlace = {
            'name': placeName,
            'address': placeAddr.isNotEmpty
                ? placeAddr
                : 'Lat ${destLoc!.latitude.toStringAsFixed(4)}, Lng ${destLoc.longitude.toStringAsFixed(4)}',
            'location': destLoc,
            'distanceKm': distKm,
          };
          _isRouting = false;
        });

        _animatedMapMove(destLoc, 16.5);
        return;
      }

      // Route Planning Mode (Point A → Point B)
      LatLng? destLoc = _destination;
      if (destLoc == null || destQuery == 'Your location') {
        if (destQuery == 'Your location') {
          destLoc = _currentPosition ?? _bulacanCenter;
          _destination = destLoc;
        } else {
          destLoc = await _geocodeQuery(destQuery);
          if (destLoc == null) {
            throw 'Destination location not found.';
          }
          _destination = destLoc;
        }
      }

      // 2. Resolve Start Origin (Point A)
      LatLng? originLoc;
      if (originQuery.isEmpty || originQuery == 'Your location') {
        _customOrigin = null;
        originLoc = _currentPosition ?? _bulacanCenter;
      } else {
        if (_customOrigin != null) {
          originLoc = _customOrigin;
        } else {
          originLoc = await _geocodeQuery(originQuery);
          if (originLoc == null) {
            throw 'Start location (Point A) not found.';
          }
          _customOrigin = originLoc;
        }
      }

      await _calculateRoute(destLoc, customOrigin: originLoc);
    } catch (e) {
      print('Routing Error: $e');
      setState(() => _isRouting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.toString().contains("NoRoute")
                  ? "📍 No road path found to that place."
                  : "⚠️ $e",
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  double _calculateAccurateEtaSeconds(
    double rawSeconds, {
    double distanceMeters = 0,
    int potholeCount = 0,
  }) {
    if (rawSeconds <= 0) return 0;

    // Estimate distance in km if not passed
    final double distKm = distanceMeters > 0
        ? distanceMeters / 1000.0
        : (rawSeconds * 0.010);

    // Realistic Philippine Driving Speed Profiles:
    // - Short local city/barangay traffic (0 - 8 km): ~20 km/h (3.0 mins per km)
    // - Medium arterial highway (8 km - 35 km): ~26 km/h (2.3 mins per km)
    // - Long expressway / tollway (> 35 km): ~55 km/h (1.1 mins per km)
    double estimatedMinutes;
    if (distKm <= 8.0) {
      estimatedMinutes = distKm * 3.0; // ~20 km/h
    } else if (distKm <= 35.0) {
      estimatedMinutes = (8.0 * 3.0) + ((distKm - 8.0) * 2.3); // ~26 km/h
    } else {
      estimatedMinutes =
          (8.0 * 3.0) + (27.0 * 2.3) + ((distKm - 35.0) * 1.1); // ~55 km/h
    }

    double adjustedSeconds = estimatedMinutes * 60.0;

    // Add Pothole Hazard Deceleration Delay (+25 seconds per pothole)
    if (potholeCount > 0) {
      adjustedSeconds += (potholeCount * 25.0);
    }

    // Time-of-Day Rush Hour Delay (7:00-9:30 AM & 4:30-7:30 PM Peak Hours)
    final now = DateTime.now();
    final hour = now.hour + (now.minute / 60.0);
    final isPeakHour =
        (hour >= 7.0 && hour <= 9.5) || (hour >= 16.5 && hour <= 19.5);
    if (isPeakHour) {
      adjustedSeconds *= 1.20; // +20% peak hour delay
    }

    return adjustedSeconds;
  }

  String _formatEta(
    double seconds, {
    double distanceMeters = 0,
    int potholeCount = 0,
  }) {
    if (seconds <= 0) return '--';
    final double finalSeconds = _calculateAccurateEtaSeconds(
      seconds,
      distanceMeters: distanceMeters,
      potholeCount: potholeCount,
    );
    final totalMinutes = (finalSeconds / 60).round();
    if (totalMinutes < 1) return '<1 min';
    if (totalMinutes < 60) return '$totalMinutes min';
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    return '${h}h ${m}m';
  }

  Future<void> _deleteDetectedPothole(PotholeMarker pothole) async {
    if (DeveloperMarkers.owns(pothole.docId)) {
      await DeveloperMarkers.instance.remove(pothole.docId!);
      return;
    }

    if (isSampleStaMariaMarkerId(pothole.docId)) {
      setState(() {
        final key = _potholeKey(pothole.location);
        _dismissedSampleIds.add(pothole.docId!);
        _snappedPotholeCache.remove(key);
        _snappedWasVerified.remove(key);
        _invalidatePotholeDerivedCaches();
      });
      await _refreshRouteAwarePotholeState();
      return;
    }

    if (widget.onDeleteDetectedPothole == null) {
      throw StateError('Delete callback is not configured.');
    }

    // Cleanup cache before letting parent handle state
    setState(() {
      final key = _potholeKey(pothole.location);
      _snappedPotholeCache.remove(key);
      _snappedWasVerified.remove(key);
      if (pothole.docId != null && _corridorSupplementPotholes.isNotEmpty) {
        _corridorSupplementPotholes = _corridorSupplementPotholes
            .where((c) => c.docId != pothole.docId)
            .toList(growable: false);
      }
      _invalidatePotholeDerivedCaches();
    });

    await widget.onDeleteDetectedPothole!(pothole);
    await _refreshRouteAwarePotholeState(refetchCorridor: true);
  }

  double _getDynamicMarkerSize() {
    try {
      return RoadHazardMarker.sizeForZoom(_mapController.camera.zoom);
    } catch (_) {
      return RoadHazardMarker.sizeForZoom(15);
    }
  }

  Widget _buildUnifiedPotholeIcon({
    String status = 'approved',
    String severity = 'medium',
    String primaryDefect = 'Pothole',
    int count = 1,
    double size = 38,
    bool isSelected = false,
  }) => RoadHazardMarker(
    primaryDefect: primaryDefect,
    status: status,
    count: count,
    size: size,
    isSelected: isSelected,
  );

  /// Groups potholes within a 10-meter barrier tolerance radius into clusters.
  /// When multiple potholes (approved and/or pending) exist nearby, they form
  /// a unified spider cluster to eliminate any overlapping pins on the map.
  List<PotholeCluster> _clusterPotholes(
    List<PotholeMarker> potholes, {
    double radiusMeters = 10.0,
  }) {
    if (potholes.isEmpty) return [];

    final double degRadius = (radiusMeters / 111000.0) * 1.35;
    final List<PotholeCluster> clusters = [];
    final Set<PotholeMarker> visited = {};

    for (int i = 0; i < potholes.length; i++) {
      final p1 = potholes[i];
      if (visited.contains(p1)) continue;

      final List<PotholeMarker> group = [p1];
      visited.add(p1);

      for (int j = i + 1; j < potholes.length; j++) {
        final p2 = potholes[j];
        if (visited.contains(p2)) continue;

        if ((p1.location.latitude - p2.location.latitude).abs() > degRadius ||
            (p1.location.longitude - p2.location.longitude).abs() > degRadius) {
          continue;
        }

        final dist = Geolocator.distanceBetween(
          p1.location.latitude,
          p1.location.longitude,
          p2.location.latitude,
          p2.location.longitude,
        );

        if (dist <= radiusMeters) {
          group.add(p2);
          visited.add(p2);
        }
      }

      double sumLat = 0;
      double sumLng = 0;
      for (final p in group) {
        sumLat += p.location.latitude;
        sumLng += p.location.longitude;
      }
      final center = LatLng(sumLat / group.length, sumLng / group.length);
      final id = group
          .map(
            (p) => '${p.id ?? p.docId ?? p.timestamp.millisecondsSinceEpoch}',
          )
          .join('_');

      clusters.add(PotholeCluster(id: id, center: center, items: group));
    }

    return clusters;
  }

  List<PotholeCluster>? _cachedPotholeClusters;
  int _cachedPotholeSignature = 0;

  /// Filters markers by status and user-selected defect class filters.
  List<PotholeMarker> _getFilteredActiveMarkers() {
    return _effectivePotholes.where((p) {
      if (p.status == 'deleted' || p.status == 'rejected') return false;
      if (!_includePendingLayer && p.status == 'pending') return false;
      final canonicalName = DpwhStandards.classify(p.primaryDefect).name;
      return _selectedDefectNames.contains(canonicalName);
    }).toList();
  }

  /// Memoizes cluster generation so O(N^2) geodesic calculations only run
  /// when the marker collection or active filters change.
  List<PotholeCluster> _getMemoizedClusters() {
    final active = _getFilteredActiveMarkers();

    int signature = Object.hash(
      active.length,
      _includePendingLayer,
      Object.hashAllUnordered(_selectedDefectNames),
    );
    for (int i = 0; i < active.length; i++) {
      final p = active[i];
      signature =
          31 * signature +
          (p.docId?.hashCode ?? p.timestamp.millisecondsSinceEpoch);
    }

    if (_cachedPotholeClusters != null &&
        _cachedPotholeSignature == signature) {
      return _cachedPotholeClusters!;
    }

    _cachedPotholeSignature = signature;
    _cachedPotholeClusters = _clusterPotholes(active, radiusMeters: 10.0);
    return _cachedPotholeClusters!;
  }

  RouteBoundingBox _boundingBoxFromBounds(LatLngBounds b) => RouteBoundingBox(
    minLat: b.south,
    maxLat: b.north,
    minLon: b.west,
    maxLon: b.east,
  );

  RouteBoundingBox? _readMarkerViewportBounds() {
    try {
      return _boundingBoxFromBounds(_mapController.camera.visibleBounds);
    } catch (_) {
      return null;
    }
  }

  void _scheduleViewportMarkerRebuild() {
    if (!mounted) return;
    if (_viewportRebuildTimer?.isActive ?? false) return;
    // Coalesce camera events while FlutterMap keeps moving every frame. The
    // trailing update reads the latest zoom/bounds, including the final gesture.
    _viewportRebuildTimer = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        if (_pendingPostFrameViewportRebuild) return;
        _pendingPostFrameViewportRebuild = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _pendingPostFrameViewportRebuild = false;
          if (mounted) setState(() {});
        });
        return;
      }
      setState(() {});
    });
  }

  /// Culls markers that are far outside the camera's viewport (+2km buffer)
  /// to dramatically reduce Flutter layer tree memory and eliminate pan jank.
  Iterable<PotholeCluster> _getVisibleClusters() {
    final clusters = _getMemoizedClusters();
    final bounds = _readMarkerViewportBounds();
    if (bounds == null) return clusters;
    _lastMarkerViewportBounds = bounds;
    return clusters.where((c) => bounds.containsWithMargin(c.center));
  }

  int _dominantClusterClassId(List<PotholeMarker> items) {
    final counts = <int, int>{};
    for (final item in items) {
      final id = DpwhStandards.classify(item.primaryDefect).classId;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    const priority = [0, 1, 3, 4];
    var bestId = 0;
    var bestCount = -1;
    for (final id in priority) {
      final c = counts[id] ?? 0;
      if (c > bestCount) {
        bestCount = c;
        bestId = id;
      }
    }
    return bestId;
  }

  /// Builds the radial Spider Tree marker with connecting stems and anchor ring
  Widget _buildSpiderClusterMarker(PotholeCluster cluster, bool isDark) {
    final count = cluster.items.length;
    final double radius = count <= 2 ? 46.0 : (count <= 4 ? 54.0 : 64.0);
    final double boxSize = (radius + 28.0) * 2;
    final double centerXY = boxSize / 2;

    final List<Offset> childOffsets = [];
    for (int i = 0; i < count; i++) {
      final double angle = -math.pi / 2 + (i * 2 * math.pi / count);
      childOffsets.add(
        Offset(radius * math.cos(angle), radius * math.sin(angle)),
      );
    }

    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Radial Stems (Tree Branches)
          CustomPaint(
            size: Size(boxSize, boxSize),
            painter: SpiderLinesPainter(
              childOffsets: childOffsets,
              isDark: isDark,
            ),
          ),

          // 2. Center Anchor Ring (Collapse trigger with clear close icon)
          Positioned(
            left: centerXY - 13,
            top: centerXY - 13,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _expandedClusterId = null;
                });
              },
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? const Color(0xFF0F172A) : Colors.white,
                  border: Border.all(
                    color: const Color(0xFF00796B),
                    width: 2.8,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black38,
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: Color(0xFF00796B),
                  ),
                ),
              ),
            ),
          ),

          // 3. Child Pothole Nodes
          for (int i = 0; i < count; i++) ...[
            Positioned(
              left: centerXY + childOffsets[i].dx - 17,
              top: centerXY + childOffsets[i].dy - 17,
              child: GestureDetector(
                onTap: () {
                  final item = cluster.items[i];
                  if (DeveloperMarkers.owns(item.docId)) {
                    _startMarkerPlacement(item);
                    return;
                  }
                  setState(() {
                    _selectedPothole = item;
                  });
                },
                child: _buildSpiderChildNode(
                  pothole: cluster.items[i],
                  isSelected:
                      _selectedPothole == cluster.items[i] ||
                      (_selectedPothole?.docId != null &&
                          _selectedPothole?.docId == cluster.items[i].docId) ||
                      (_selectedPothole != null &&
                          _selectedPothole!.location.latitude ==
                              cluster.items[i].location.latitude &&
                          _selectedPothole!.location.longitude ==
                              cluster.items[i].location.longitude),
                  isDark: isDark,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSpiderChildNode({
    required PotholeMarker pothole,
    required bool isSelected,
    required bool isDark,
  }) => RoadHazardMarker(
    primaryDefect: pothole.primaryDefect,
    status: pothole.status,
    count: pothole.potholeCount,
    size: 34,
    isSelected: isSelected,
    compact: false,
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _syncSubPageTourIfNeeded();
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, themeMode, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: AppSettings.instance.showPotholesNotifier,
          builder: (context, showPotholes, _) {
            final bool isDark = themeMode == ThemeMode.system
                ? (MediaQuery.platformBrightnessOf(context) == Brightness.dark)
                : (themeMode == ThemeMode.dark);
            final bool showMarkers = showPotholes;
            final double viewportWidth = MediaQuery.sizeOf(context).width;
            final bool isCompactViewport = viewportWidth < 420;
            final bool isClearAhead =
                _nearestPotholeInfo.isEmpty ||
                _nearestPotholeInfo == 'Clear ahead';
            final int activeRouteIndex =
                _alternativeRoutes.isNotEmpty &&
                    _selectedRouteIndex < _alternativeRoutes.length
                ? _selectedRouteIndex
                : 0;
            final int activePotholeCount =
                (_destination != null || _routePoints.isNotEmpty)
                ? (_activeRouteIndex?.summary.distinctPotholeCount ??
                      (activeRouteIndex < _routePotholeCounts.length
                          ? _routePotholeCounts[activeRouteIndex]
                          : _potholesOnRoute.length))
                : 0;
            final List<LatLng> activeRoutePolyline =
                _alternativeRoutes.isNotEmpty
                ? (_routePoints.length >= 2
                      ? _routePoints
                      : _alternativeRoutes[activeRouteIndex])
                : _routePoints;

            double activeDistance = 0;
            if (_alternativeRoutes.isNotEmpty &&
                activeRouteIndex < _routeDistances.length &&
                _routeDistances[activeRouteIndex] > 0) {
              activeDistance = _routeDistances[activeRouteIndex];
            } else if (activeRoutePolyline.length >= 2) {
              activeDistance = _calculatePolylineDistanceMeters(
                activeRoutePolyline,
              );
            } else if (_currentPosition != null && _destination != null) {
              activeDistance = Geolocator.distanceBetween(
                _currentPosition!.latitude,
                _currentPosition!.longitude,
                _destination!.latitude,
                _destination!.longitude,
              );
            }

            double activeDuration = 0;
            if (_alternativeRoutes.isNotEmpty &&
                activeRouteIndex < _routeDurations.length &&
                _routeDurations[activeRouteIndex] > 0) {
              activeDuration = _routeDurations[activeRouteIndex];
            } else if (activeDistance > 0) {
              activeDuration = (activeDistance / 1000.0) * 144.0;
            }

            String nextPotholeEtaStr = '';
            if (!isClearAhead) {
              final double? nextDist = double.tryParse(
                _nearestPotholeInfo.replaceAll(RegExp(r'[^0-9.]'), ''),
              );
              if (nextDist != null && nextDist > 0) {
                final double nextSecs = nextDist / 8.33; // ~30 km/h avg speed
                nextPotholeEtaStr = nextSecs < 60
                    ? '${nextSecs.round()}s ETA'
                    : '${(nextSecs / 60).round()} min ETA';
              }
            }

            final String navHeadline = _destination == null
                ? 'Search your destination'
                : isClearAhead
                ? 'Road clear ahead'
                : 'Next hazard in $_nearestPotholeInfo${nextPotholeEtaStr.isNotEmpty ? ' (~$nextPotholeEtaStr)' : ''}';

            final String distStr = activeDistance > 0
                ? (activeDistance >= 1000
                      ? '${(activeDistance / 1000).toStringAsFixed(1)} km'
                      : '${activeDistance.round()} m')
                : '';

            final String totalEtaStr = _formatEta(
              activeDuration,
              distanceMeters: activeDistance,
              potholeCount: activePotholeCount,
            );

            // Check if bottom navigation dock should be hidden
            final bool shouldHideBottomNav =
                _routePoints.isNotEmpty ||
                _isNavigating ||
                _selectedPothole != null ||
                _isPlacingMarker ||
                _isEditingDevLocation ||
                _isChoosingLocationOnMap ||
                _isSearchPageActive;

            AppSettings.instance.setRouteActive(shouldHideBottomNav);

            // Compute safe bottom offsets accounting for floating bottom navigation bar and mobile SafeArea.
            // With Scaffold.extendBody = true, MediaQuery.paddingOf(context).bottom already includes
            // the visible bottomNavigationBar height, so adding 88px would double-count the bar.
            final double bottomInset = MediaQuery.paddingOf(context).bottom;
            final double baseBottomOffset = shouldHideBottomNav
                ? (bottomInset + 12.0)
                : (bottomInset + 8.0);
            final double actionButtonsBottom = _routePoints.isNotEmpty
                ? (baseBottomOffset +
                      (_isRouteDockMinimized
                          ? 60.0
                          : (_isRouteSheetExpanded
                                ? 270.0
                                : (_alternativeRoutes.length > 1 ||
                                          _routeSwitchSuggestion != null
                                      ? 258.0
                                      : 152.0))))
                : (_selectedPothole != null)
                ? (baseBottomOffset + 136.0)
                : (_searchedPlace != null ||
                      _isPlacingMarker ||
                      _isEditingDevLocation)
                ? (baseBottomOffset + 110.0)
                : baseBottomOffset;

            return Material(
              color: Colors.transparent,
              child: Stack(
                children: [
                  MouseRegion(
                    cursor: _isPlacingMarker || _isEditingDevLocation
                        ? SystemMouseCursors.precise
                        : (_isMapDragging
                              ? SystemMouseCursors.grabbing
                              : SystemMouseCursors.grab),
                    child: Listener(
                      key: _mapViewportKey,
                      onPointerDown: (_) {
                        if (kIsWeb && !_isMapDragging && mounted) {
                          setState(() => _isMapDragging = true);
                        }
                      },
                      onPointerUp: (_) {
                        if (kIsWeb && _isMapDragging && mounted) {
                          setState(() => _isMapDragging = false);
                        }
                      },
                      onPointerCancel: (_) {
                        if (kIsWeb && _isMapDragging && mounted) {
                          setState(() => _isMapDragging = false);
                        }
                      },
                      child: ClipRect(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(
                            end: (_isNavigating &&
                                    _drivingCameraAngle ==
                                        DrivingCameraAngle.chase3D &&
                                    _followMode != FollowMode.none)
                                ? 1.0
                                : 0.0,
                          ),
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOutCubic,
                          builder: (context, tiltT, mapChild) {
                            if (tiltT <= 0.001) return mapChild!;
                            final double s = 1.0 + 0.26 * tiltT;
                            final matrix = Matrix4.identity()
                              ..setEntry(3, 2, 0.00075 * tiltT)
                              ..rotateX(-0.34 * tiltT)
                              ..scaleByDouble(s, s, 1.0, 1.0);
                            return Transform(
                              alignment: const Alignment(0.0, 0.26),
                              transform: matrix,
                              child: mapChild,
                            );
                          },
                          child: RepaintBoundary(
                            child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _currentPosition ?? _bulacanCenter,
                          initialZoom: 15.0,
                          minZoom: 3.0,
                          maxZoom: 19.0,
                          interactionOptions: InteractionOptions(
                            flags: (_isNavigating && !_isNavOverview)
                                ? InteractiveFlag.none
                                : InteractiveFlag.all,
                            pinchMoveThreshold: 35.0,
                            scrollWheelVelocity: 0.005,
                          ),
                          onPositionChanged: _onMapPositionChanged,
                          onTap: (_, point) {
                            if (_isNavigating) return;
                            if (_isPlacingMarker) {
                              setState(() => _pendingMarkerLocation = point);
                            } else if (_isEditingDevLocation) {
                              setState(() => _pendingDevLocation = point);
                            } else if (_isChoosingLocationOnMap) {
                              _animatedMapMove(
                                point,
                                _mapController.camera.zoom,
                              );
                            } else {
                              // Check if user tapped directly on an alternative route line
                              if (_alternativeRoutes.length > 1) {
                                int? tappedIndex;
                                double minD = double.infinity;
                                final double zoom = _mapController.camera.zoom;
                                final double threshold =
                                    (60000.0 / (1 << zoom.floor())).clamp(
                                      30.0,
                                      200.0,
                                    );

                                for (
                                  int i = 0;
                                  i < _alternativeRoutes.length;
                                  i++
                                ) {
                                  final d = _distancePointToRouteMeters(
                                    point,
                                    _alternativeRoutes[i],
                                  );
                                  if (d <= threshold && d < minD) {
                                    minD = d;
                                    tappedIndex = i;
                                  }
                                }

                                if (tappedIndex != null) {
                                  _selectActiveRoute(tappedIndex);
                                  return;
                                }
                              }

                              if (_selectedPothole != null ||
                                  _searchedPlace != null) {
                                setState(() {
                                  _selectedPothole = null;
                                  _searchedPlace = null;
                                });
                              }

                              if (_isRoutePlanningMode ||
                                  (_destination != null && !_isNavigating)) {
                                final String coordStr =
                                    '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';
                                if (_isEditingOrigin) {
                                  setState(() {
                                    _customOrigin = point;
                                    _originController.text = coordStr;
                                    _suggestions = [];
                                  });
                                  _reverseGeocodeLabel(point).then((label) {
                                    if (mounted &&
                                        _customOrigin == point &&
                                        label.isNotEmpty) {
                                      setState(
                                        () => _originController.text = label,
                                      );
                                    }
                                  });
                                  final LatLng? dest =
                                      _destination ??
                                      (_routePoints.isNotEmpty
                                          ? _routePoints.last
                                          : null);
                                  if (dest != null) {
                                    setState(() {
                                      _rubberBandActiveRoute(
                                        newStart: point,
                                        newEnd: dest,
                                      );
                                    });
                                    unawaited(
                                      _calculateRoute(
                                        dest,
                                        customOrigin: point,
                                        fitCamera: false,
                                        silent: true,
                                      ),
                                    );
                                  }
                                } else {
                                  final LatLng start =
                                      (_originController.text.trim() ==
                                              'Your location' ||
                                          _originController.text
                                              .trim()
                                              .isEmpty ||
                                          _customOrigin == null)
                                      ? (_currentPosition ?? _bulacanCenter)
                                      : _customOrigin!;
                                  setState(() {
                                    _destination = point;
                                    _searchController.text = coordStr;
                                    if (_originController.text.trim().isEmpty) {
                                      _originController.text = 'Your location';
                                      _customOrigin = null;
                                    }
                                    _suggestions = [];
                                    _rubberBandActiveRoute(
                                      newStart: start,
                                      newEnd: point,
                                    );
                                  });
                                  _reverseGeocodeLabel(point).then((label) {
                                    if (mounted &&
                                        _destination == point &&
                                        label.isNotEmpty) {
                                      setState(
                                        () => _searchController.text = label,
                                      );
                                    }
                                  });
                                  unawaited(
                                    _calculateRoute(
                                      point,
                                      customOrigin: start,
                                      fitCamera: false,
                                      silent: true,
                                    ),
                                  );
                                }
                              }
                            }
                          },
                        ),
                        children: [
                          TileLayer(
                            tileProvider: _tileProvider,
                            urlTemplate:
                                'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}',
                            subdomains: const ['0', '1', '2', '3'],
                            userAgentPackageName: 'com.example.my_flutter_app',
                            evictErrorTileStrategy:
                                EvictErrorTileStrategy.notVisible,
                            reset: _tileLayerResetController.stream,
                            tileDisplay: const TileDisplay.fadeIn(
                              duration: Duration(milliseconds: 100),
                            ),
                            panBuffer: 1,
                            keepBuffer: 2,
                            minZoom: 3,
                            maxZoom: 20,
                            maxNativeZoom: 20,
                          ),
                          // Route Polylines (Google Maps Style: Bold Main + Cased Alternatives)
                          if (_alternativeRoutes.isNotEmpty)
                            PolylineLayer(
                              polylines: [
                                // 1. Draw unselected alternative routes with subtle casing (hidden in 3D driving view)
                                if (!_isNavigating || _isNavOverview)
                                  for (final entry
                                      in _alternativeRoutes.asMap().entries.where(
                                        (e) => e.key != _selectedRouteIndex,
                                      )) ...[
                                  Polyline(
                                    points: entry.value,
                                    color: isDark
                                        ? const Color(0xFF1E293B)
                                        : const Color(0xFFCBD5E1),
                                    strokeWidth: 7.8,
                                    strokeCap: StrokeCap.round,
                                    strokeJoin: StrokeJoin.round,
                                  ),
                                  Polyline(
                                    points: entry.value,
                                    color: isDark
                                        ? const Color(0xFF64748B)
                                        : const Color(0xFF94A3B8),
                                    strokeWidth: 4.8,
                                    strokeCap: StrokeCap.round,
                                    strokeJoin: StrokeJoin.round,
                                  ),
                                ],
                                // 2. Draw selected main route with high-contrast driving casing & core
                                Polyline(
                                  points: activeRoutePolyline,
                                  color: _isNavigating
                                      ? const Color(0xFF0B4DB8)
                                      : AppDesign.brandHover.withValues(
                                          alpha: 0.55,
                                        ),
                                  strokeWidth: _isNavigating ? 13.0 : 11.5,
                                  strokeCap: StrokeCap.round,
                                  strokeJoin: StrokeJoin.round,
                                ),
                                Polyline(
                                  points: activeRoutePolyline,
                                  color: _isNavigating
                                      ? const Color(0xFF00B8FF)
                                      : AppDesign.brand,
                                  strokeWidth: _isNavigating ? 8.0 : 6.5,
                                  strokeCap: StrokeCap.round,
                                  strokeJoin: StrokeJoin.round,
                                ),
                              ],
                            )
                          else if (_routePoints.isNotEmpty)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: _routePoints,
                                  color: AppDesign.accent(
                                    isDark,
                                  ).withValues(alpha: 0.5),
                                  strokeWidth: 10.0,
                                  strokeCap: StrokeCap.round,
                                  strokeJoin: StrokeJoin.round,
                                ),
                                Polyline(
                                  points: _routePoints,
                                  color: AppDesign.accent(isDark),
                                  strokeWidth: 6.0,
                                  strokeCap: StrokeCap.round,
                                  strokeJoin: StrokeJoin.round,
                                ),
                              ],
                            ),
                          // User proximity indicator circle (smoothly follows animated puck)
                          if (showMarkers)
                            ValueListenableBuilder<LatLng?>(
                              valueListenable: _animatedPuckPositionNotifier,
                              builder: (context, puckPos, _) {
                                final effectivePos =
                                    puckPos ?? _currentPosition;
                                if (effectivePos == null) {
                                  return const SizedBox.shrink();
                                }
                                return CircleLayer(
                                  circles: [
                                    CircleMarker(
                                      point: effectivePos,
                                      radius: _proximityCircleRadiusMeters,
                                      useRadiusInMeter: true,
                                      color: _inProximityWarning
                                          ? Colors.red.withValues(alpha: 0.5)
                                          : Colors.blue.withValues(alpha: 0.15),
                                      borderColor: _inProximityWarning
                                          ? Colors.red.withValues(alpha: 0.9)
                                          : const Color(0xAA1E88E5),
                                      borderStrokeWidth: _inProximityWarning
                                          ? 6
                                          : 3,
                                    ),
                                  ],
                                );
                              },
                            ),
                          // Blue user location marker (60 FPS smooth interpolation + breathing radar halo)
                          ValueListenableBuilder<LatLng?>(
                            valueListenable: _animatedPuckPositionNotifier,
                            builder: (context, puckPos, _) {
                              final effectivePos = puckPos ?? _currentPosition;
                              if (effectivePos == null) {
                                return const SizedBox.shrink();
                              }
                              return MarkerLayer(
                                markers: [
                                  Marker(
                                    point: effectivePos,
                                    width: 160,
                                    height: 160,
                                    rotate: false,
                                    child: RepaintBoundary(
                                      child: ValueListenableBuilder<double?>(
                                        valueListenable: _lastHeadingNotifier,
                                        builder:
                                            (context, headingValue, child) {
                                              return Transform.rotate(
                                                alignment: Alignment.center,
                                                angle:
                                                    (headingValue ?? 0) *
                                                    (3.14159 / 180),
                                                child: child,
                                              );
                                            },
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            if (!_isNavigating) ...[
                                              // 1. Google Maps Breathing Radar Pulse Halo
                                              AnimatedBuilder(
                                                animation: _puckPulseController,
                                                builder: (context, _) {
                                                  final t =
                                                      _puckPulseController.value;
                                                  final haloSize =
                                                      22.0 + t * 42.0;
                                                  final haloOpacity =
                                                      (1.0 - t) * 0.42;
                                                  return Container(
                                                    width: haloSize,
                                                    height: haloSize,
                                                    decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color:
                                                          const Color(
                                                            0xFF1A73E8,
                                                          ).withValues(
                                                            alpha: haloOpacity,
                                                          ),
                                                    ),
                                                  );
                                                },
                                              ),
                                              // 2. Directional Vision Cone
                                              CustomPaint(
                                                size: const Size(160, 160),
                                                painter: VisionConePainter(),
                                              ),
                                            ],
                                            // 3. Center Puck (Google Maps 3D Vehicle/Walker Avatar when navigating, Blue Dot otherwise)
                                            if (_isNavigating)
                                              GestureDetector(
                                                onTap: () =>
                                                    _showVehicleProfilePickerSheet(
                                                      isDark,
                                                    ),
                                                child:
                                                    _buildNavigationVehiclePuck(),
                                              )
                                            else
                                              Container(
                                                width: 22,
                                                height: 22,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: Colors.blue.shade600,
                                                  boxShadow: const [
                                                    BoxShadow(
                                                      color: Colors.black26,
                                                      blurRadius: 10,
                                                      spreadRadius: 2,
                                                    ),
                                                  ],
                                                  border: Border.all(
                                                    color: Colors.white,
                                                    width: 3,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          MarkerLayer(
                            markers: [
                              if (showMarkers) ...[
                                ..._getVisibleClusters().map((cluster) {
                                  if (cluster.isSingle) {
                                    final pothole = cluster.singleItem;
                                    final bool isSelected =
                                        _selectedPothole != null &&
                                        (_selectedPothole == pothole ||
                                            (_selectedPothole!.docId != null &&
                                                pothole.docId != null &&
                                                _selectedPothole!.docId ==
                                                    pothole.docId) ||
                                            (_selectedPothole!
                                                        .location
                                                        .latitude ==
                                                    pothole.location.latitude &&
                                                _selectedPothole!
                                                        .location
                                                        .longitude ==
                                                    pothole
                                                        .location
                                                        .longitude));
                                    final double baseMarkerSize =
                                        _getDynamicMarkerSize();
                                    final double dynamicSize = isSelected
                                        ? (baseMarkerSize * 1.35).clamp(
                                            24.0,
                                            56.0,
                                          )
                                        : baseMarkerSize;

                                    final double hitSize = math.max(
                                      48.0,
                                      dynamicSize,
                                    );

                                    return Marker(
                                      key: ValueKey(
                                        'detected_${pothole.id ?? pothole.docId ?? pothole.timestamp.millisecondsSinceEpoch}',
                                      ),
                                      point: pothole.location,
                                      width: hitSize,
                                      height: hitSize,
                                      child: Semantics(
                                        button: true,
                                        label:
                                            '${DpwhStandards.classify(pothole.primaryDefect).name}, ${pothole.status}',
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            if (DeveloperMarkers.owns(
                                              pothole.docId,
                                            )) {
                                              _startMarkerPlacement(pothole);
                                              return;
                                            }

                                            HapticFeedback.selectionClick();
                                            setState(() {
                                              _selectedPothole = pothole;
                                              _expandedClusterId = null;
                                            });
                                            _animatedMapMove(
                                              pothole.location,
                                              17.5,
                                            );
                                          },
                                          child: Center(
                                            child: _buildUnifiedPotholeIcon(
                                              status: pothole.status,
                                              severity: pothole.overallSeverity,
                                              primaryDefect:
                                                  pothole.primaryDefect,
                                              count: pothole.potholeCount,
                                              size: dynamicSize,
                                              isSelected: isSelected,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }

                                  // Multiple distinct potholes within 10m tolerance
                                  final bool isExpanded =
                                      _expandedClusterId == cluster.id;

                                  if (isExpanded) {
                                    final count = cluster.items.length;
                                    final double radius = count <= 2
                                        ? 46.0
                                        : (count <= 4 ? 54.0 : 64.0);
                                    final double boxSize = (radius + 28.0) * 2;

                                    return Marker(
                                      key: ValueKey('spider_${cluster.id}'),
                                      point: cluster.center,
                                      width: boxSize,
                                      height: boxSize,
                                      child: _buildSpiderClusterMarker(
                                        cluster,
                                        isDark,
                                      ),
                                    );
                                  } else {
                                    // Unexpanded 10m Cluster Marker
                                    final double clusterDiameter =
                                        (_getDynamicMarkerSize() + 4)
                                            .clamp(24.0, 36.0);
                                    final int dominantClassId =
                                        _dominantClusterClassId(cluster.items);
                                    return Marker(
                                      key: ValueKey('cluster_${cluster.id}'),
                                      point: cluster.center,
                                      width: 44,
                                      height: 44,
                                      child: GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _expandedClusterId = cluster.id;
                                          });
                                          _animatedMapMove(
                                            cluster.center,
                                            _mapController.camera.zoom.clamp(
                                              16.0,
                                              18.5,
                                            ),
                                          );
                                        },
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            Container(
                                              width: clusterDiameter,
                                              height: clusterDiameter,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: const Color(0xFF9333EA),
                                                border: Border.all(
                                                  color: Colors.white,
                                                  width: 2.2,
                                                ),
                                                boxShadow: const [
                                                  BoxShadow(
                                                    color: Colors.black38,
                                                    blurRadius: 6,
                                                    offset: Offset(0, 2),
                                                  ),
                                                ],
                                              ),
                                              child: Center(
                                                child: RoadDefectGlyph(
                                                  classId: dominantClassId,
                                                  color: Colors.white,
                                                  size: (clusterDiameter * 0.62)
                                                      .clamp(14.0, 23.0),
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              top: -2,
                                              right: -2,
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 5,
                                                      vertical: 1.5,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFF00796B,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                  border: Border.all(
                                                    color: Colors.white,
                                                    width: 1.2,
                                                  ),
                                                  boxShadow: const [
                                                    BoxShadow(
                                                      color: Colors.black26,
                                                      blurRadius: 3,
                                                      offset: Offset(0, 1),
                                                    ),
                                                  ],
                                                ),
                                                child: Text(
                                                  '${cluster.items.length}',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }
                                }),
                              ],

                              // Start Location Pin (Draggable A — hidden while actively driving)
                              if (!_isNavigating &&
                                  (_customOrigin != null ||
                                      _destination != null))
                                _buildDraggableEndpointPin(
                                  point:
                                      _customOrigin ??
                                      _currentPosition ??
                                      _bulacanCenter,
                                  kind: 1,
                                  color: const Color(0xFF0284C7),
                                ),

                              // Destination Location Pin (Draggable B — hidden while driving like Google Maps hideDestinationPins)
                              if (!_isNavigating && _destination != null)
                                _buildDraggableEndpointPin(
                                  point: _destination!,
                                  kind: 2,
                                  color: const Color(0xFFFB7185),
                                ),

                              // Active Selected Turn-by-Turn Maneuver Waypoint Dot (Translucent Halo + High-Visibility Core Dot)
                              if (!_isNavigating &&
                                  _selectedStepIndex != null &&
                                  _routeSteps.isNotEmpty &&
                                  _selectedStepIndex! < _routeSteps.length)
                                Marker(
                                  key: ValueKey(
                                    'active_step_marker_$_selectedStepIndex',
                                  ),
                                  point:
                                      _routeSteps[_selectedStepIndex!].location,
                                  width: 36,
                                  height: 36,
                                  child: Center(
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        // Translucent Glow Ring (Keeps roads & map clearly visible)
                                        Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            color: const Color(
                                              0xFF2563EB,
                                            ).withValues(alpha: 0.25),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        // Crisp Core Waypoint Dot with White Rim
                                        Container(
                                          width: 15,
                                          height: 15,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF2563EB),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2.5,
                                            ),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Colors.black38,
                                                blurRadius: 4,
                                                offset: Offset(0, 1.5),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),

                              // Google Maps Style Floating Route Duration & Pothole Callout Badges
                              if (_alternativeRoutes.length > 1) ...[
                                for (
                                  int rIdx = 0;
                                  rIdx < _alternativeRoutes.length;
                                  rIdx++
                                )
                                  if (_alternativeRoutes[rIdx].length > 2)
                                    Marker(
                                      key: ValueKey('route_eta_badge_$rIdx'),
                                      point:
                                          _alternativeRoutes[rIdx][_alternativeRoutes[rIdx]
                                                  .length ~/
                                              2],
                                      width: 158,
                                      height: 40,
                                      child: GestureDetector(
                                        onTap: () {
                                          HapticFeedback.selectionClick();
                                          _selectActiveRoute(rIdx);
                                        },
                                        child: Center(
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                              milliseconds: 200,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 9,
                                              vertical: 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: rIdx == _selectedRouteIndex
                                                  ? AppDesign.brand
                                                  : AppDesign.surface(isDark),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color:
                                                    rIdx == _selectedRouteIndex
                                                    ? Colors.white
                                                    : AppDesign.borderStrong(
                                                        isDark,
                                                      ),
                                                width:
                                                    rIdx == _selectedRouteIndex
                                                    ? 1.8
                                                    : 1.2,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color:
                                                      rIdx ==
                                                          _selectedRouteIndex
                                                      ? AppDesign.brand
                                                            .withValues(
                                                              alpha: 0.40,
                                                            )
                                                      : Colors.black.withValues(
                                                          alpha: isDark
                                                              ? 0.45
                                                              : 0.18,
                                                        ),
                                                  blurRadius: 8,
                                                  offset: const Offset(0, 2),
                                                ),
                                              ],
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Icon(
                                                  _travelMode ==
                                                          OsrmTravelMode.bike
                                                      ? Icons
                                                            .two_wheeler_rounded
                                                      : (_travelMode ==
                                                                OsrmTravelMode
                                                                    .foot
                                                            ? Icons
                                                                  .directions_walk_rounded
                                                            : Icons
                                                                  .directions_car_rounded),
                                                  size: 13,
                                                  color:
                                                      rIdx ==
                                                          _selectedRouteIndex
                                                      ? Colors.white
                                                      : AppDesign.textSecondary(
                                                          isDark,
                                                        ),
                                                ),
                                                const SizedBox(width: 4),
                                                Flexible(
                                                  child: Text(
                                                    rIdx <
                                                            _routeDurations
                                                                .length
                                                        ? (rIdx ==
                                                                  _selectedRouteIndex
                                                              ? totalEtaStr
                                                              : _formatEta(
                                                                  _routeDurations[rIdx],
                                                                  distanceMeters:
                                                                      rIdx <
                                                                          _routeDistances
                                                                              .length
                                                                      ? _routeDistances[rIdx]
                                                                      : 0,
                                                                  potholeCount:
                                                                      rIdx <
                                                                          _routePotholeCounts
                                                                              .length
                                                                      ? _routePotholeCounts[rIdx]
                                                                      : 0,
                                                                ))
                                                        : 'Route ${rIdx + 1}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: AppDesign.tabular(
                                                      TextStyle(
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color:
                                                            rIdx ==
                                                                _selectedRouteIndex
                                                            ? Colors.white
                                                            : AppDesign.textPrimary(
                                                                isDark,
                                                              ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                if (rIdx <
                                                    _routePotholeCounts
                                                        .length) ...[
                                                  const SizedBox(width: 5),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 5,
                                                          vertical: 1.5,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color:
                                                          rIdx ==
                                                              _selectedRouteIndex
                                                          ? Colors.white
                                                                .withValues(
                                                                  alpha: 0.22,
                                                                )
                                                          : (_routePotholeCounts[rIdx] ==
                                                                    0
                                                                ? AppDesign
                                                                      .success
                                                                      .withValues(
                                                                        alpha:
                                                                            0.16,
                                                                      )
                                                                : AppDesign
                                                                      .warning
                                                                      .withValues(
                                                                        alpha:
                                                                            0.18,
                                                                      )),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          _routePotholeCounts[rIdx] ==
                                                                  0
                                                              ? Icons
                                                                    .verified_user_rounded
                                                              : Icons
                                                                    .warning_amber_rounded,
                                                          size: 10,
                                                          color:
                                                              rIdx ==
                                                                  _selectedRouteIndex
                                                              ? Colors.white
                                                              : (_routePotholeCounts[rIdx] ==
                                                                        0
                                                                    ? (isDark
                                                                          ? const Color(
                                                                              0xFF34D399,
                                                                            )
                                                                          : const Color(
                                                                              0xFF047857,
                                                                            ))
                                                                    : (isDark
                                                                          ? const Color(
                                                                              0xFFFBBF24,
                                                                            )
                                                                          : const Color(
                                                                              0xFFB45309,
                                                                            ))),
                                                        ),
                                                        const SizedBox(
                                                          width: 2,
                                                        ),
                                                        Text(
                                                          '${_routePotholeCounts[rIdx]}',
                                                          style: AppDesign.tabular(
                                                            TextStyle(
                                                              fontSize: 10,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                              color:
                                                                  rIdx ==
                                                                      _selectedRouteIndex
                                                                  ? Colors.white
                                                                  : (_routePotholeCounts[rIdx] ==
                                                                            0
                                                                        ? (isDark
                                                                              ? const Color(
                                                                                  0xFF34D399,
                                                                                )
                                                                              : const Color(
                                                                                  0xFF047857,
                                                                                ))
                                                                        : (isDark
                                                                              ? const Color(
                                                                                  0xFFFBBF24,
                                                                                )
                                                                              : const Color(0xFFB45309))),
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                              ],

                              if (_isPlacingMarker &&
                                  _pendingMarkerLocation != null)
                                Marker(
                                  key: const ValueKey(
                                    'pending_marker_placement',
                                  ),
                                  point: _pendingMarkerLocation!,
                                  width: 42,
                                  height: 42,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: const Color(0xFF0B6E4F),
                                        width: 2,
                                      ),
                                    ),
                                    child: _buildUnifiedPotholeIcon(),
                                  ),
                                ),

                              if (_isEditingDevLocation &&
                                  _pendingDevLocation != null)
                                Marker(
                                  key: const ValueKey(
                                    'pending_dev_location_marker',
                                  ),
                                  point: _pendingDevLocation!,
                                  width: 40,
                                  height: 40,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF3C78D8),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.person_pin_circle_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 1. Top-Right Corner Map / Profile / Settings Toggle Pill (Web Only)
                  if (kIsWeb && widget.isMapActive)
                    Positioned(
                      top: 12,
                      right: 16,
                      child: SafeArea(
                        child: _buildTopRightMapProfileToggle(
                          isMapActive: true,
                        ),
                      ),
                    ),

                  // 2. Full-Screen Dedicated Search Page Overlay (Standard Search or Point A to Point B)
                  if (_isSearchPageActive && !_isChoosingLocationOnMap)
                    _buildDedicatedSearchPage(isDark),

                  // 3. Top-Left Search Bar, Warnings & Navigation HUD Panel (Normal Map Mode)
                  if (_isSearchVisible &&
                      widget.isMapActive &&
                      !_isChoosingLocationOnMap &&
                      !_isSearchPageActive)
                    Positioned(
                      top: 12,
                      left: 16,
                      right: isCompactViewport ? 16 : null,
                      child: SafeArea(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: isCompactViewport
                                ? (viewportWidth - 32 - (kIsWeb ? 175 : 0))
                                : (viewportWidth > 640
                                      ? 420.0
                                      : (viewportWidth -
                                            32 -
                                            (kIsWeb ? 175 : 0))),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_isNavigating) ...[
                                // Google Maps Style Sleek Top Guidance Header (Turn-by-Turn or Free Drive)
                                _buildGoogleMapsNavigationHeader(
                                  isDark: isDark,
                                  activePotholeCount: activePotholeCount,
                                  navHeadline: _routePoints.isEmpty
                                      ? 'Free Drive'
                                      : navHeadline,
                                ),
                              ] else if (_routePoints.isNotEmpty) ...[
                                // Google Maps Style Active Route Header (Dual Point A & B Card)
                                _buildGoogleMapsActiveRouteHeader(isDark),
                              ] else ...[
                                // Google Maps Style Floating Search Bar Capsule
                                _buildFloatingMapSearchBar(isDark),
                              ],

                              // 1. Offline, active filter, empty result & GPS status chips
                              if (!_isNavigating && _routePoints.isEmpty)
                                _buildMapStatusChips(isDark, showMarkers),

                              // 2. Natural Upper-Side Pothole Countdown Notification & Proactive Detour Cue
                              if (!_isSearchingActive &&
                                  ((_isNavigating &&
                                          ((_upcomingHazard != null &&
                                                  _upcomingHazard!
                                                          .distanceMeters <=
                                                      _proximityCircleRadiusMeters) ||
                                              (_navHazardState
                                                          ?.distanceToNextMeters !=
                                                      null &&
                                                  _navHazardState!
                                                          .distanceToNextMeters! <=
                                                      _proximityCircleRadiusMeters)) &&
                                          showMarkers) ||
                                      (!_isNavigating &&
                                          ((_routePoints.isNotEmpty ||
                                                  _destination != null) ||
                                              (_upcomingHazard != null &&
                                                  showMarkers &&
                                                  !_isLocationDisabled &&
                                                  !_isPermissionDenied)))))
                                ValueListenableBuilder(
                                  valueListenable: _warningBanner,
                                  builder: (context, warning, child) =>
                                      _buildUpperPotholeCountdownNotification(
                                        activePotholeCount: activePotholeCount,
                                        isDark: isDark,
                                        showMarkers: showMarkers,
                                      ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  if (_isPlacingMarker && _pendingMarkerLocation != null)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: baseBottomOffset,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        decoration: BoxDecoration(
                          color: const Color(0xF20F2C25),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0x803EC9A7),
                            width: 1,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black38,
                              blurRadius: 12,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.add_location_alt_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'Place marker at crosshair',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${_pendingMarkerLocation!.latitude.toStringAsFixed(5)}, ${_pendingMarkerLocation!.longitude.toStringAsFixed(5)}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: _isSavingPlacedMarker
                                  ? null
                                  : _cancelMarkerPlacement,
                              child: const Text(
                                'Cancel',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                            const SizedBox(width: 4),
                            ElevatedButton(
                              onPressed: _isSavingPlacedMarker
                                  ? null
                                  : _confirmMarkerPlacement,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF3EC9A7),
                                foregroundColor: Colors.black,
                              ),
                              child: _isSavingPlacedMarker
                                  ? const SizedBox(
                                      height: 16,
                                      width: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.black,
                                      ),
                                    )
                                  : const Text('Add'),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // DEV TOOLS LOCATION EDITING OVERLAY
                  if (_isEditingDevLocation && _pendingDevLocation != null)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: baseBottomOffset,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        decoration: BoxDecoration(
                          color: const Color(0xF2162A45),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0x803C78D8),
                            width: 1,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black38,
                              blurRadius: 12,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Mock Location Crosshair Active',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Target: ${_pendingDevLocation!.latitude.toStringAsFixed(5)}, ${_pendingDevLocation!.longitude.toStringAsFixed(5)}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11.5,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                TextButton(
                                  onPressed: _cancelDevLocationEdit,
                                  child: const Text(
                                    'Cancel',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                ),
                                const Spacer(),
                                ElevatedButton(
                                  onPressed: _applyDevLocationEdit,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF3C78D8),
                                    foregroundColor: Colors.white,
                                  ),
                                  child: const Text('Apply location'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                  // RIGHT SIDE ACTION BUTTONS:
                  // Dedicated 4-button dark circular stack in Driving Mode (no zoom +/-),
                  // or standard Browse/Planning stack outside Driving Mode.
                  if (_isNavigating &&
                      !_isChoosingLocationOnMap &&
                      !_isSearchPageActive) ...[
                    Positioned(
                      right: 16,
                      bottom: (_isRouteSheetExpanded ? 290.0 : 112.0) +
                          bottomInset,
                      child: _buildDrivingRightControls(isDark),
                    ),
                    if (!_isNavOverview && !_isRouteSheetExpanded)
                      Positioned(
                        left: 16,
                        bottom: 112.0 + bottomInset,
                        child: _buildDrivingSpeedometer(),
                      ),
                    if (_drivingHudNotice != null)
                      Positioned(
                        left: 84,
                        right: 84,
                        bottom: (_isRouteSheetExpanded ? 290.0 : 120.0) +
                            bottomInset,
                        child: IgnorePointer(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xE60B0F17),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.white24,
                                  width: 1.0,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black54,
                                    blurRadius: 10,
                                    offset: Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Text(
                                _drivingHudNotice!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ] else if (!_isChoosingLocationOnMap &&
                      !_isSearchPageActive)
                    Positioned(
                      right: 14,
                      bottom: actionButtonsBottom,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // Route Switcher / Cycle Controller
                          if (_alternativeRoutes.length > 1) ...[
                            Container(
                              height: 48,
                              decoration: BoxDecoration(
                                color: AppDesign.accent(isDark),
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppDesign.accent(
                                      isDark,
                                    ).withValues(alpha: 0.35),
                                    blurRadius: 8,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: _cycleRoutes,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _travelMode == OsrmTravelMode.bike
                                              ? Icons.two_wheeler_rounded
                                              : Icons.alt_route_rounded,
                                          color: Colors.white,
                                          size: 19,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          _travelMode == OsrmTravelMode.bike
                                              ? 'Moto Route ${_selectedRouteIndex + 1}/${_alternativeRoutes.length}'
                                              : 'Route ${_selectedRouteIndex + 1}/${_alternativeRoutes.length}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (_potholesOnRoute.isNotEmpty) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(
                                                alpha: 0.25,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.warning_amber_rounded,
                                                  size: 12,
                                                  color: Colors.white,
                                                ),
                                                const SizedBox(width: 3),
                                                Text(
                                                  '${_potholesOnRoute.length}',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],

                          // ── DEVELOPER MOCK CONTROLS (Right Side) ──
                          if (AppSettings.instance.devMockModeNotifier.value ||
                              AppSettings
                                  .instance
                                  .manualPotholePlacementNotifier
                                  .value ||
                              AppSettings
                                  .instance
                                  .devEditLocationNotifier
                                  .value ||
                              AppSettings
                                  .instance
                                  .mobileDevMockLocationEnabled) ...[
                            // 1. Custom Marker Placement Button
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: _isPlacingMarker
                                    ? const Color(0xFFF59E0B)
                                    : AppDesign.surface(isDark),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _isPlacingMarker
                                      ? const Color(0xFFF59E0B)
                                      : AppDesign.border(isDark),
                                  width: _isPlacingMarker ? 1.8 : 1.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: isDark ? 0.35 : 0.15,
                                    ),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  _isPlacingMarker
                                      ? Icons.close_rounded
                                      : Icons.add_location_alt_rounded,
                                  color: _isPlacingMarker
                                      ? Colors.white
                                      : const Color(0xFFF59E0B),
                                  size: 20,
                                ),
                                onPressed: _isPlacingMarker
                                    ? _cancelMarkerPlacement
                                    : _startMarkerPlacement,
                                tooltip: 'Custom markers (local)',
                              ),
                            ),
                            const SizedBox(height: 6),

                            // 2. Custom Location / Mock GPS Button
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: _isEditingDevLocation
                                    ? const Color(0xFF3C78D8)
                                    : (_useMockLocation
                                          ? const Color(
                                              0xFF3C78D8,
                                            ).withValues(alpha: 0.18)
                                          : AppDesign.surface(isDark)),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color:
                                      _isEditingDevLocation || _useMockLocation
                                      ? const Color(0xFF3C78D8)
                                      : AppDesign.border(isDark),
                                  width: _isEditingDevLocation ? 1.8 : 1.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: isDark ? 0.35 : 0.15,
                                    ),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  _isEditingDevLocation
                                      ? Icons.close_rounded
                                      : Icons.edit_location_alt_rounded,
                                  color: _isEditingDevLocation
                                      ? Colors.white
                                      : const Color(0xFF3C78D8),
                                  size: 20,
                                ),
                                onPressed: _isEditingDevLocation
                                    ? _cancelDevLocationEdit
                                    : _startDevLocationEdit,
                                tooltip: _isEditingDevLocation
                                    ? 'Cancel Custom Location'
                                    : 'Set Custom GPS Location',
                              ),
                            ),
                            const SizedBox(height: 6),

                            // 3. Reset Real GPS Button (Visible when Mock GPS is active)
                            if (_useMockLocation) ...[
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: AppDesign.surface(isDark),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFF10B981),
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: isDark ? 0.35 : 0.15,
                                      ),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(
                                    Icons.gps_fixed_rounded,
                                    color: Color(0xFF10B981),
                                    size: 20,
                                  ),
                                  onPressed: _resetToRealLocation,
                                  tooltip: 'Reset to Real GPS Location',
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                          ],

                          // 0. Standalone Floating Directions Action Button (Only when route is not active)
                          if (_routePoints.isEmpty) ...[
                            MobileTouchIconButton(
                              key: _directionsGuideKey,
                              icon: Icons.directions_rounded,
                              tooltip: 'Plan Point A to Point B Route',
                              backgroundColor: AppDesign.accent(isDark),
                              foregroundColor: Colors.white,
                              borderColor: Colors.transparent,
                              onPressed: () {
                                setState(() {
                                  _isSearchPageActive = true;
                                  _isRoutePlanningMode = true;
                                  _isEditingOrigin = false;
                                  _suggestions = [];
                                });
                                _destinationFocusNode.requestFocus();
                              },
                            ),
                            const SizedBox(height: 8),
                          ],

                          // 1. Navigation / Compass Mode Toggle
                          MobileTouchIconButton(
                            targetKey: _compassGuideKey,
                            icon: _followMode == FollowMode.compass
                                ? Icons.explore_rounded
                                : Icons.navigation_rounded,
                            tooltip: _currentMapRotation.abs() > 1.0
                                ? 'Reset North'
                                : 'Toggle Compass / Follow Mode',
                            foregroundColor: _followMode == FollowMode.compass
                                ? AppDesign.accent(isDark)
                                : (_currentMapRotation.abs() > 1.0
                                      ? const Color(0xFFEA4335)
                                      : AppDesign.textSecondary(isDark)),
                            onPressed: () {
                              if (_currentMapRotation.abs() > 1.0 &&
                                  _followMode != FollowMode.compass) {
                                try {
                                  _mapController.rotate(0);
                                } catch (_) {}
                                setState(() => _currentMapRotation = 0.0);
                              } else {
                                _toggleFollowMode();
                              }
                            },
                          ),

                          if (_isNavigating) ...[
                            const SizedBox(height: 8),
                            MobileTouchIconButton(
                              icon: AppSettings.instance.mobileVoiceAlertsEnabled
                                  ? Icons.volume_up_rounded
                                  : Icons.volume_off_rounded,
                              tooltip:
                                  AppSettings.instance.mobileVoiceAlertsEnabled
                                  ? 'Mute voice alerts'
                                  : 'Unmute voice alerts',
                              foregroundColor:
                                  AppSettings.instance.mobileVoiceAlertsEnabled
                                  ? AppDesign.textPrimary(isDark)
                                  : const Color(0xFFFCA5A5),
                              onPressed: () {
                                final wasEnabled = AppSettings
                                    .instance
                                    .mobileVoiceAlertsEnabled;
                                setState(() {
                                  AppSettings
                                          .instance
                                          .mobileVoiceAlertsEnabled =
                                      !wasEnabled;
                                });
                                if (wasEnabled && !kIsWeb) {
                                  try {
                                    _tts.stop();
                                  } catch (_) {}
                                }
                              },
                            ),
                            const SizedBox(height: 8),
                            MobileTouchIconButton(
                              icon: _travelMode == OsrmTravelMode.car
                                  ? Icons.directions_car_rounded
                                  : _travelMode == OsrmTravelMode.bike
                                  ? Icons.two_wheeler_rounded
                                  : Icons.directions_walk_rounded,
                              tooltip: 'Vehicle Profile (Car / Motorcycle / Walk)',
                              foregroundColor: AppDesign.accent(isDark),
                              onPressed: () =>
                                  _showVehicleProfilePickerSheet(isDark),
                            ),
                            const SizedBox(height: 8),
                            MobileTouchIconButton(
                              icon: _isNavOverview
                                  ? Icons.navigation_rounded
                                  : Icons.alt_route_rounded,
                              tooltip: _isNavOverview
                                  ? 'Resume 3D Driving View'
                                  : 'Route Overview',
                              foregroundColor: _isNavOverview
                                  ? AppDesign.accent(isDark)
                                  : AppDesign.textPrimary(isDark),
                              onPressed: () {
                                setState(() {
                                  _isNavOverview = !_isNavOverview;
                                  if (!_isNavOverview) {
                                    _followMode = FollowMode.compass;
                                  }
                                });
                                if (_isNavOverview && _routePoints.isNotEmpty) {
                                  try {
                                    _mapController.rotate(0);
                                  } catch (_) {}
                                  _fitCameraToRoute(_routePoints);
                                } else if (_currentPosition != null) {
                                  if (_lastHeadingNotifier.value != null) {
                                    try {
                                      _mapController.rotate(
                                        (360.0 - _lastHeadingNotifier.value!) %
                                            360.0,
                                      );
                                    } catch (_) {}
                                  }
                                  _animatedMapMoveToVisible(
                                    _currentPosition!,
                                    17.5,
                                    isExpandedSheet: false,
                                  );
                                }
                              },
                            ),
                          ],

                          const SizedBox(height: 8),

                          // 2. Zoom Controls Connected Vertical Pill (>= 48dp each)
                          Container(
                            width: 48,
                            decoration: BoxDecoration(
                              color: AppDesign.surface(isDark),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: AppDesign.border(isDark),
                                width: 1.2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: isDark ? 0.35 : 0.14,
                                  ),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                IconButton(
                                  key: _zoomGuideKey,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 48,
                                    minHeight: 48,
                                  ),
                                  icon: Icon(
                                    Icons.add_rounded,
                                    color: AppDesign.textPrimary(isDark),
                                    size: 22,
                                  ),
                                  onPressed: () {
                                    final currentZoom =
                                        _mapController.camera.zoom;
                                    _animatedMapMove(
                                      _mapController.camera.center,
                                      currentZoom + 1,
                                    );
                                  },
                                  tooltip: 'Zoom In',
                                ),
                                Divider(
                                  height: 1,
                                  color: AppDesign.border(isDark),
                                  indent: 8,
                                  endIndent: 8,
                                ),
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 48,
                                    minHeight: 48,
                                  ),
                                  icon: Icon(
                                    Icons.remove_rounded,
                                    color: AppDesign.textPrimary(isDark),
                                    size: 22,
                                  ),
                                  onPressed: () {
                                    final currentZoom =
                                        _mapController.camera.zoom;
                                    _animatedMapMove(
                                      _mapController.camera.center,
                                      currentZoom - 1,
                                    );
                                  },
                                  tooltip: 'Zoom Out',
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 8),

                          // 3. Target My Location (+ Free Drive quick button beside it)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!_isNavigating && _routePoints.isEmpty) ...[
                                MobileTouchIconButton(
                                  targetKey: _freeDriveGuideKey,
                                  icon: _travelMode == OsrmTravelMode.car
                                      ? Icons.directions_car_rounded
                                      : _travelMode == OsrmTravelMode.bike
                                      ? Icons.two_wheeler_rounded
                                      : Icons.directions_walk_rounded,
                                  tooltip: 'Start Free Drive Mode',
                                  foregroundColor: const Color(0xFF0F766E),
                                  onPressed: _startFreeDriveNavigation,
                                ),
                                const SizedBox(width: 8),
                              ],
                              MobileTouchIconButton(
                                targetKey:
                                    widget.tourLocationButtonKey ??
                                    _locationGuideKey,
                                icon: Icons.my_location_rounded,
                                tooltip: 'Center My Location',
                                foregroundColor: AppDesign.accent(isDark),
                                isLoading:
                                    _isLoadingLocation &&
                                    _currentPosition == null,
                                onPressed: () {
                                  _navAutoRecenterTimer?.cancel();
                                  if (_currentPosition != null) {
                                    if (_isNavigating) {
                                      setState(() {
                                        _isNavOverview = false;
                                        _followMode = FollowMode.compass;
                                      });
                                      if (_lastHeadingNotifier.value != null) {
                                        final rot =
                                            (360.0 -
                                                _lastHeadingNotifier.value!) %
                                            360.0;
                                        _currentMapRotation = rot;
                                        try {
                                          _mapController.rotate(rot);
                                        } catch (_) {}
                                      }
                                      _animatedMapMoveToVisible(
                                        _currentPosition!,
                                        17.5,
                                        isExpandedSheet: false,
                                      );
                                    } else {
                                      if (_followMode == FollowMode.none) {
                                        setState(
                                          () =>
                                              _followMode = FollowMode.location,
                                        );
                                      }
                                      _animatedMapMove(_currentPosition!, 16.5);
                                      _mapController.rotate(0.0);
                                    }
                                    _startFollowing();
                                  } else {
                                    _determinePosition();
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                  // Zoom-based distance scale bar & subtle attribution (hidden in driving mode)
                  if (!_isNavigating &&
                      _selectedPothole == null &&
                      _searchedPlace == null &&
                      _routePoints.isEmpty &&
                      !_isChoosingLocationOnMap &&
                      !_isSearchPageActive &&
                      !_isPlacingMarker &&
                      !_isEditingDevLocation)
                    Positioned(
                      left: 16,
                      bottom: bottomInset + 8,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          MapScaleBar(
                            controller: _mapController,
                            isDark: isDark,
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppDesign.surface(
                                isDark,
                              ).withValues(alpha: 0.88),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppDesign.border(isDark),
                              ),
                            ),
                            child: Text(
                              '© OpenStreetMap',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: AppDesign.textSecondary(isDark),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // 4. Floating Inspector Details Overlay Card (When a Pothole Marker is Selected)
                  if (_selectedPothole != null &&
                      !_isChoosingLocationOnMap &&
                      !_isSearchPageActive)
                    Positioned(
                      left: 16,
                      right: isCompactViewport ? 16 : null,
                      bottom: baseBottomOffset,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isCompactViewport
                              ? (viewportWidth - 32)
                              : 440.0,
                        ),
                        child: _buildSelectedPotholeCard(
                          _selectedPothole!,
                          isDark,
                        ),
                      ),
                    ),

                  // 5. Google Maps Style Searched Place Details Card
                  if (_searchedPlace != null &&
                      _selectedPothole == null &&
                      _routePoints.isEmpty &&
                      !_isChoosingLocationOnMap &&
                      !_isSearchPageActive)
                    Positioned(
                      left: 16,
                      right: isCompactViewport ? 16 : null,
                      bottom: baseBottomOffset,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isCompactViewport
                              ? (viewportWidth - 32)
                              : 420.0,
                        ),
                        child: _buildSearchedPlaceCard(isDark),
                      ),
                    ),

                  // 6. Google Maps Style Bottom Navigation Dock (Dedicated full-width dark drawer when driving)
                  if (_isNavigating &&
                      _selectedPothole == null &&
                      _searchedPlace == null &&
                      !_isChoosingLocationOnMap &&
                      !_isSearchPageActive)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildDrivingModeBottomSheet(
                        isDark: isDark,
                        distStr: distStr,
                        totalEtaStr: totalEtaStr,
                        activePotholeCount: activePotholeCount,
                      ),
                    )
                  else if (_routePoints.isNotEmpty &&
                      _selectedPothole == null &&
                      _searchedPlace == null &&
                      !_isChoosingLocationOnMap &&
                      !_isSearchPageActive)
                    Positioned(
                      left: isCompactViewport ? 12 : 16,
                      right: isCompactViewport ? 12 : 16,
                      bottom: baseBottomOffset,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isCompactViewport
                              ? (viewportWidth - 24)
                              : 460.0,
                        ),
                        child: _buildGoogleMapsBottomDock(
                          isDark: isDark,
                          distStr: distStr,
                          totalEtaStr: totalEtaStr,
                          activePotholeCount: activePotholeCount,
                        ),
                      ),
                    ),

                  // 7. Interactive "Choose Location on Map" Picker Overlays
                  if (_isChoosingLocationOnMap) ...[
                    // Top Header Bar
                    Positioned(
                      top: 12,
                      left: 16,
                      right: 16,
                      child: SafeArea(
                        child: Container(
                          height: 52,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: AppDesign.surface(isDark),
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(
                              color: AppDesign.border(isDark),
                              width: 1.2,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 12,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_back_rounded),
                                color: AppDesign.textPrimary(isDark),
                                onPressed: () {
                                  if (_selectedPothole != null ||
                                      _searchedPlace != null ||
                                      _expandedClusterId != null) {
                                    setState(() {
                                      _selectedPothole = null;
                                      _searchedPlace = null;
                                      _expandedClusterId = null;
                                    });
                                  }
                                  setState(() {
                                    _isChoosingLocationOnMap = false;
                                  });
                                },
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _isRoutePlanningMode && _isChoosingOriginOnMap
                                    ? 'Choose starting point on map'
                                    : 'Choose destination on map',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppDesign.textPrimary(isDark),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // Center Crosshair Pin
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                'Set point here',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.location_on,
                              color: Color(0xFFEA4335),
                              size: 44,
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Bottom OK Action Bar
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: baseBottomOffset,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: AppDesign.surface(isDark),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppDesign.border(isDark),
                            width: 1.2,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black38,
                              blurRadius: 16,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.touch_app_rounded,
                              color: Color(0xFF00796B),
                              size: 24,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Move map to choose location',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppDesign.textPrimary(isDark),
                                ),
                              ),
                            ),
                            ElevatedButton(
                              onPressed: _confirmChooseLocationOnMap,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00796B),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 22,
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'OK',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // 8. Centered Location Permission Modal Box
                  // Suppressed while a guided spotlight tour is active so
                  // the user sees the UI without forced OS dialogs.
                  if (!widget.isTourActive &&
                      (_isLocationDisabled || _isPermissionDenied) &&
                      !_dismissedLocationPrompt)
                    _buildLocationPermissionCenterBox(isDark),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ── DEDICATED FULL-SCREEN SEARCH PAGE ──
  Widget _buildEndpointConnectorRail(bool isDark, {bool compact = false}) {
    final Color lineDot = AppDesign.textMuted(isDark).withValues(alpha: 0.7);
    final double dotGap = compact ? 3.5 : 4.5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: compact ? 10 : 12,
          height: compact ? 10 : 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppDesign.surface(isDark),
            border: Border.all(
              color: AppDesign.accent(isDark),
              width: compact ? 2.2 : 2.6,
            ),
          ),
        ),
        SizedBox(height: dotGap),
        for (int i = 0; i < 3; i++) ...[
          Container(
            width: 3,
            height: 3,
            decoration: BoxDecoration(color: lineDot, shape: BoxShape.circle),
          ),
          if (i < 2) SizedBox(height: dotGap),
        ],
        SizedBox(height: compact ? 2.5 : 3.5),
        Icon(
          Icons.location_on_rounded,
          color: const Color(0xFFEA4335),
          size: compact ? 16 : 18,
        ),
      ],
    );
  }

  Widget _buildQuickSearchPill({
    required bool isDark,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    final Color fg = highlighted
        ? AppDesign.accent(isDark)
        : AppDesign.textPrimary(isDark);
    return Material(
      color: highlighted
          ? AppDesign.brandWash(isDark)
          : AppDesign.sunken(isDark),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppDesign.radiusPill),
        side: BorderSide(
          color: highlighted
              ? AppDesign.brandBorder(isDark)
              : AppDesign.border(isDark),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppDesign.radiusPill),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 38),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: highlighted
                      ? AppDesign.accent(isDark)
                      : AppDesign.textSecondary(isDark),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDedicatedSearchPage(bool isDark) {
    final Color bgColor = AppDesign.bg(isDark);
    final Color cardBg = AppDesign.sunken(isDark);
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color hintColor = AppDesign.textSecondary(isDark);

    return Positioned.fill(
      child: Material(
        color: bgColor,
        child: SafeArea(
          child: Column(
            children: [
              // ── Top Navigation & Input Bar (Google Maps Header + RoadSense Surface) ──
              Container(
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 12),
                decoration: BoxDecoration(
                  color: AppDesign.surface(isDark),
                  border: Border(
                    bottom: BorderSide(
                      color: AppDesign.border(isDark),
                      width: 1,
                    ),
                  ),
                  boxShadow: AppDesign.shadowSm(isDark),
                ),
                child: _isRoutePlanningMode
                    ? _buildDedicatedRouteHeader(
                        isDark,
                        cardBg,
                        textColor,
                        hintColor,
                      )
                    : _buildDedicatedSearchHeader(
                        isDark,
                        cardBg,
                        textColor,
                        hintColor,
                      ),
              ),

              // ── Body Content (Quick Actions / Route Options / Suggestions / Recent) ──
              Expanded(
                child: _buildDedicatedSearchBody(isDark, textColor, hintColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDedicatedSearchHeader(
    bool isDark,
    Color cardBg,
    Color textColor,
    Color hintColor,
  ) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          color: textColor,
          tooltip: 'Close search',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: () {
            setState(() {
              _isSearchPageActive = false;
              _isLoadingSuggestions = false;
              _suggestions = [];
              _searchFocusNode.unfocus();
            });
          },
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Container(
            key: _searchInputGuideKey,
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.only(left: 14, right: 6),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: _searchFocusNode.hasFocus
                    ? AppDesign.accent(isDark)
                    : AppDesign.borderStrong(isDark),
                width: _searchFocusNode.hasFocus ? 1.5 : 1.0,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: AppDesign.accent(isDark),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    autofocus: true,
                    style: TextStyle(
                      fontSize: 15.0,
                      color: textColor,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search place, barangay, or report...',
                      hintStyle: TextStyle(
                        color: hintColor,
                        fontSize: 14.5,
                        fontWeight: FontWeight.normal,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                    onChanged: (value) {
                      setState(() {});
                      _onSearchChanged(value);
                    },
                    onSubmitted: (val) {
                      if (val.isNotEmpty) {
                        setState(() {
                          _isSearchPageActive = false;
                          _isLoadingSuggestions = false;
                        });
                        _searchAndRoute();
                      }
                    },
                  ),
                ),
                if (_isRouting)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppDesign.accent(isDark),
                      ),
                    ),
                  ),
                if (_searchController.text.isNotEmpty)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    tooltip: 'Clear search',
                    onPressed: () {
                      setState(() {
                        _searchController.clear();
                        _suggestions = [];
                        _isLoadingSuggestions = false;
                      });
                    },
                    icon: Icon(
                      Icons.cancel_rounded,
                      size: 19,
                      color: hintColor,
                    ),
                  )
                else
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    tooltip: 'Directions (Point A to B)',
                    onPressed: () {
                      setState(() {
                        _isRoutePlanningMode = true;
                        _isEditingOrigin = false;
                        _suggestions = [];
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _destinationFocusNode.requestFocus();
                      });
                    },
                    icon: Icon(
                      Icons.directions_rounded,
                      size: 21,
                      color: AppDesign.accent(isDark),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDedicatedRouteHeader(
    bool isDark,
    Color cardBg,
    Color textColor,
    Color hintColor,
  ) {
    final bool originFocused = _isEditingOrigin;
    final Color activeBorder = AppDesign.accent(isDark);
    final Color idleBorder = AppDesign.border(isDark);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Top Bar: Back + Title + Quick Route Preview Shortcut ──
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 22),
              color: textColor,
              tooltip: 'Back',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () {
                setState(() {
                  _isRoutePlanningMode =
                      _routePoints.isNotEmpty || _destination != null;
                  _isSearchPageActive = false;
                  _suggestions = [];
                  _originFocusNode.unfocus();
                  _destinationFocusNode.unfocus();
                });
              },
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                'Directions',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            if (_routePoints.isNotEmpty)
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _isSearchPageActive = false;
                    _suggestions = [];
                  });
                  _originFocusNode.unfocus();
                  _destinationFocusNode.unfocus();
                },
                icon: const Icon(Icons.map_rounded, size: 16),
                label: Text(
                  _alternativeRoutes.length > 1
                      ? 'Routes (${_alternativeRoutes.length})'
                      : 'View map',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: activeBorder,
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),

        // ── Google Maps 3-Column Connector + Point A / Point B Inputs + Swap ──
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 28, child: _buildEndpointConnectorRail(isDark)),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                key: _routeEndpointsGuideKey,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Point A (Starting Point)
                  Container(
                    height: 44,
                    padding: const EdgeInsets.only(left: 12, right: 4),
                    decoration: BoxDecoration(
                      color: originFocused ? AppDesign.surface(isDark) : cardBg,
                      borderRadius: BorderRadius.circular(AppDesign.radiusMd),
                      border: Border.all(
                        color: originFocused ? activeBorder : idleBorder,
                        width: originFocused ? 1.6 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _originController,
                            focusNode: _originFocusNode,
                            style: TextStyle(
                              fontSize: 14.0,
                              color: textColor,
                              fontWeight: FontWeight.w600,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Choose starting point',
                              hintStyle: TextStyle(
                                color: hintColor,
                                fontSize: 14.0,
                                fontWeight: FontWeight.normal,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              filled: false,
                              fillColor: Colors.transparent,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                            onTap: () =>
                                setState(() => _isEditingOrigin = true),
                            onChanged: (val) {
                              setState(() => _isEditingOrigin = true);
                              _onSearchChanged(val);
                            },
                            onSubmitted: (_) {
                              if (_searchController.text.isNotEmpty) {
                                setState(() => _isSearchPageActive = false);
                                _searchAndRoute();
                              } else {
                                setState(() => _isEditingOrigin = false);
                                _destinationFocusNode.requestFocus();
                              }
                            },
                          ),
                        ),
                        if (_originController.text.isNotEmpty)
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 38,
                              minHeight: 38,
                            ),
                            tooltip: 'Clear starting point',
                            onPressed: () {
                              setState(() {
                                _originController.clear();
                                _customOrigin = null;
                                _suggestions = [];
                                _isEditingOrigin = true;
                              });
                              _originFocusNode.requestFocus();
                            },
                            icon: Icon(
                              Icons.cancel_rounded,
                              size: 18,
                              color: hintColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Point B (Destination)
                  Container(
                    height: 44,
                    padding: const EdgeInsets.only(left: 12, right: 4),
                    decoration: BoxDecoration(
                      color: !originFocused
                          ? AppDesign.surface(isDark)
                          : cardBg,
                      borderRadius: BorderRadius.circular(AppDesign.radiusMd),
                      border: Border.all(
                        color: !originFocused ? activeBorder : idleBorder,
                        width: !originFocused ? 1.6 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            focusNode: _destinationFocusNode,
                            autofocus: _destination == null,
                            style: TextStyle(
                              fontSize: 14.0,
                              color: textColor,
                              fontWeight: FontWeight.w600,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Choose destination',
                              hintStyle: TextStyle(
                                color: hintColor,
                                fontSize: 14.0,
                                fontWeight: FontWeight.normal,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              filled: false,
                              fillColor: Colors.transparent,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                            onTap: () =>
                                setState(() => _isEditingOrigin = false),
                            onChanged: (val) {
                              setState(() => _isEditingOrigin = false);
                              _onSearchChanged(val);
                            },
                            onSubmitted: (val) {
                              if (val.isNotEmpty) {
                                setState(() => _isSearchPageActive = false);
                                _searchAndRoute();
                              }
                            },
                          ),
                        ),
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 38,
                              minHeight: 38,
                            ),
                            tooltip: 'Clear destination',
                            onPressed: () {
                              setState(() {
                                _searchController.clear();
                                _destination = null;
                                _suggestions = [];
                                _isEditingOrigin = false;
                              });
                              _destinationFocusNode.requestFocus();
                            },
                            icon: Icon(
                              Icons.cancel_rounded,
                              size: 18,
                              color: hintColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              key: _routeSwapGuideKey,
              icon: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cardBg,
                  shape: BoxShape.circle,
                  border: Border.all(color: idleBorder),
                ),
                child: Icon(
                  Icons.swap_vert_rounded,
                  color: activeBorder,
                  size: 20,
                ),
              ),
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              onPressed: _swapOriginDestination,
              tooltip: 'Swap start and destination',
            ),
          ],
        ),
        const SizedBox(height: 10),
        KeyedSubtree(
          key: _routeTravelModeGuideKey,
          child: _buildTravelModeSelector(isDark),
        ),
      ],
    );
  }

  Widget _buildDedicatedSearchBody(
    bool isDark,
    Color textColor,
    Color hintColor,
  ) {
    final activeQuery =
        (_isRoutePlanningMode && _isEditingOrigin
                ? _originController.text
                : _searchController.text)
            .trim();
    final lowerQuery = activeQuery.toLowerCase();
    final matchingReports = (lowerQuery.isNotEmpty && !_isRoutePlanningMode)
        ? _effectivePotholes
              .where((p) {
                final haystack = [
                  p.primaryDefect,
                  p.primaryDpwhCode,
                  p.barangay,
                  p.city,
                  p.province,
                  p.formattedAddress,
                  p.overallSeverity,
                  p.status,
                ].join(' ').toLowerCase();
                return haystack.contains(lowerQuery);
              })
              .take(4)
              .toList()
        : <PotholeMarker>[];

    final santaMariaPresets = _bulacanBarangays
        .where((b) => b['municipality'] == 'Santa Maria')
        .take(5)
        .toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        // Quick action pills (Google Maps style Saved / Quick Picks bar)
        if (_suggestions.isEmpty && matchingReports.isEmpty)
          Padding(
            key: _searchQuickPicksGuideKey,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildQuickSearchPill(
                    isDark: isDark,
                    icon: Icons.pin_drop_rounded,
                    label: _isRoutePlanningMode && _isEditingOrigin
                        ? 'Set A on map'
                        : 'Choose on map',
                    highlighted: true,
                    onTap: () {
                      setState(() {
                        _isSearchPageActive = false;
                        _isChoosingLocationOnMap = true;
                        _isChoosingOriginOnMap = _isRoutePlanningMode
                            ? _isEditingOrigin
                            : false;
                        _suggestions = [];
                        _searchFocusNode.unfocus();
                        _originFocusNode.unfocus();
                        _destinationFocusNode.unfocus();
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  if (!_isRoutePlanningMode)
                    _buildQuickSearchPill(
                      isDark: isDark,
                      icon: Icons.directions_rounded,
                      label: 'Directions A → B',
                      onTap: () {
                        setState(() {
                          _isRoutePlanningMode = true;
                          _isEditingOrigin = false;
                          _suggestions = [];
                        });
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _destinationFocusNode.requestFocus();
                        });
                      },
                    )
                  else if (_currentPosition != null &&
                      _originController.text != 'Your location')
                    _buildQuickSearchPill(
                      isDark: isDark,
                      icon: Icons.my_location_rounded,
                      label: 'Your location',
                      onTap: () {
                        setState(() {
                          _originController.text = 'Your location';
                          _customOrigin = null;
                          _suggestions = [];
                          _isLoadingSuggestions = false;
                        });
                        if (_hasValidDestination()) {
                          setState(() => _isSearchPageActive = false);
                          _originFocusNode.unfocus();
                          _destinationFocusNode.unfocus();
                          _calculateRoute(_destination!);
                        }
                      },
                    ),
                  for (final preset in santaMariaPresets) ...[
                    const SizedBox(width: 8),
                    _buildQuickSearchPill(
                      isDark: isDark,
                      icon: Icons.place_outlined,
                      label: preset['name'].toString().replaceFirst(
                        'Barangay ',
                        'Brgy. ',
                      ),
                      onTap: () {
                        _selectSuggestion({
                          'lat': preset['lat'],
                          'lon': preset['lon'],
                          '_name': preset['name'],
                          '_short_addr': '${preset['municipality']}, Bulacan',
                          'display_name': preset['name'],
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),

        // Inline Route Options preview inside A-to-B setup when routes already exist
        if (_isRoutePlanningMode &&
            _alternativeRoutes.isNotEmpty &&
            !_isLoadingSuggestions &&
            _suggestions.isEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: Row(
              children: [
                Icon(
                  Icons.alt_route_rounded,
                  size: 16,
                  color: AppDesign.accent(isDark),
                ),
                const SizedBox(width: 6),
                Text(
                  _alternativeRoutes.length > 1
                      ? 'Pick a route (${_alternativeRoutes.length} options)'
                      : 'Active route',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppDesign.textSecondary(isDark),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              children: [
                for (int i = 0; i < _alternativeRoutes.length; i++) ...[
                  _buildRouteOptionCard(
                    i,
                    isDark,
                    fullWidth: true,
                    onTapOverride: () {
                      _selectActiveRoute(i);
                      setState(() => _isSearchPageActive = false);
                      _originFocusNode.unfocus();
                      _destinationFocusNode.unfocus();
                    },
                  ),
                  if (i < _alternativeRoutes.length - 1)
                    const SizedBox(height: 8),
                ],
              ],
            ),
          ),
          Divider(height: 12, color: AppDesign.border(isDark)),
        ],

        // 0. Quick "Your location" selection tile for Point A
        if (_isRoutePlanningMode &&
            _isEditingOrigin &&
            _originController.text != 'Your location' &&
            _currentPosition != null) ...[
          InkWell(
            onTap: () {
              setState(() {
                _originController.text = 'Your location';
                _customOrigin = null;
                _suggestions = [];
                _isLoadingSuggestions = false;
              });
              if (_hasValidDestination()) {
                setState(() => _isSearchPageActive = false);
                _originFocusNode.unfocus();
                _destinationFocusNode.unfocus();
                _calculateRoute(_destination!);
              } else {
                setState(() {
                  _isEditingOrigin = false;
                });
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _destinationFocusNode.requestFocus();
                });
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppDesign.brandWash(isDark),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.my_location_rounded,
                      color: AppDesign.accent(isDark),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Your location',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Use current GPS location as starting point',
                          style: TextStyle(fontSize: 12, color: hintColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: AppDesign.border(isDark)),
        ],
        if (_isLoadingSuggestions && activeQuery.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppDesign.accent(isDark),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Searching road reports and places...',
                  style: TextStyle(fontSize: 13, color: hintColor),
                ),
              ],
            ),
          ),
        // 1a. Matching approved road reports (when searching globally)
        if (matchingReports.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text(
              'Matching Road Reports',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: hintColor,
              ),
            ),
          ),
          ...matchingReports.map((p) {
            final cls = DpwhStandards.classify(p.primaryDefect);
            final defectFg = MobileDefectHelper.foregroundColor(cls, isDark);
            final locLabel = [
              p.barangay,
              p.city,
            ].where((s) => s.trim().isNotEmpty).join(', ');
            final subtitleText = locLabel.isNotEmpty
                ? locLabel
                : (p.formattedAddress.isNotEmpty
                      ? p.formattedAddress
                      : '${p.location.latitude.toStringAsFixed(5)}°, ${p.location.longitude.toStringAsFixed(5)}°');
            return InkWell(
              onTap: () {
                setState(() {
                  _isSearchPageActive = false;
                  _isLoadingSuggestions = false;
                });
                _searchFocusNode.unfocus();
                locatePothole(p.location, p.docId);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: cls.color.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        MobileDefectHelper.iconForClass(cls),
                        color: defectFg,
                        size: 19,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  '${cls.name} (${cls.code})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: textColor,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitleText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: hintColor),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          Divider(height: 8, color: AppDesign.border(isDark)),
        ],
        // 1b. Autocomplete Place Suggestions (if typing)
        if (_suggestions.isNotEmpty) ...[
          if (matchingReports.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Places & Barangays',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: hintColor,
                ),
              ),
            ),
          ..._suggestions.map((s) {
            final name = (s['_name'] ?? s['display_name']).toString();
            final shortAddr = (s['_short_addr'] ?? '').toString();
            final bool isBarangay =
                s['_is_barangay'] == true ||
                name.toLowerCase().contains('barangay');
            final Color brgyFg = isDark
                ? const Color(0xFF34D399)
                : const Color(0xFF047857);

            return InkWell(
              onTap: () {
                setState(() {
                  _isSearchPageActive = false;
                  _isLoadingSuggestions = false;
                });
                _selectSuggestion(s);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: isBarangay
                            ? AppDesign.success.withValues(alpha: 0.14)
                            : AppDesign.brandWash(isDark),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isBarangay
                            ? Icons.holiday_village_rounded
                            : Icons.place_rounded,
                        color: isBarangay ? brgyFg : AppDesign.accent(isDark),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: textColor,
                                  ),
                                ),
                              ),
                              if (isBarangay) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppDesign.success.withValues(
                                      alpha: 0.14,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: AppDesign.success.withValues(
                                        alpha: 0.35,
                                      ),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    'BARANGAY',
                                    style: TextStyle(
                                      fontSize: 9.0,
                                      fontWeight: FontWeight.bold,
                                      color: brgyFg,
                                      letterSpacing: 0.4,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (shortAddr.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              shortAddr,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: hintColor),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ]
        // 2. Search History (if query empty and history exists)
        else if (activeQuery.isEmpty && _searchHistory.isNotEmpty) ...[
          _buildSearchHistoryContent(isDark),
        ]
        // 2b. Empty query result state
        else if (activeQuery.isNotEmpty &&
            !_isLoadingSuggestions &&
            matchingReports.isEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: MobileStateCard(
              icon: Icons.search_off_rounded,
              iconColor: hintColor,
              title: 'No matching places or road reports',
              message:
                  'Try another barangay, road name, or defect keyword, or choose a location directly on the map.',
            ),
          ),
        ],

        // 3. ALWAYS AT THE VERY BOTTOM: "Choose Location on Map" Action Tile
        _buildChooseLocationOnMapTile(isDark),
      ],
    );
  }

  Widget _buildChooseLocationOnMapTile(bool isDark) {
    final Color hintColor = AppDesign.textSecondary(isDark);
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color accent = AppDesign.accent(isDark);

    final String titleText = _isRoutePlanningMode
        ? (_isEditingOrigin
              ? 'Choose starting point on map'
              : 'Choose destination on map')
        : 'Choose location on map';

    final String subtitleText = _isRoutePlanningMode
        ? (_isEditingOrigin
              ? 'Move the map to set Point A location'
              : 'Move the map to set Point B location')
        : 'Move the map to set a pin manually';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(height: 16, thickness: 1, color: AppDesign.border(isDark)),
        InkWell(
          onTap: () {
            setState(() {
              _isSearchPageActive = false;
              _isChoosingLocationOnMap = true;
              _isChoosingOriginOnMap = _isRoutePlanningMode
                  ? _isEditingOrigin
                  : false;
              _suggestions = [];
              _searchFocusNode.unfocus();
              _originFocusNode.unfocus();
              _destinationFocusNode.unfocus();
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppDesign.brandWash(isDark),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.pin_drop_rounded, color: accent, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titleText,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitleText,
                        style: TextStyle(fontSize: 12, color: hintColor),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: hintColor, size: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFloatingMapSearchBar(bool isDark) {
    final activeFilterCount = _hasActiveDefectFilter
        ? (DpwhStandards.allClasses.length - _selectedDefectNames.length) +
              (_includePendingLayer ? 0 : 1)
        : 0;
    final accent = AppDesign.accent(isDark);

    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            label: 'Search places to view nearby road reports',
            child: Material(
              key: widget.tourSearchBarKey,
              color: AppDesign.surface(isDark),
              elevation: 4,
              shadowColor: Colors.black.withValues(alpha: isDark ? 0.45 : 0.14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
                side: BorderSide(color: AppDesign.border(isDark), width: 1.2),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(26),
                onTap: () {
                  setState(() {
                    _isSearchPageActive = true;
                    _isRoutePlanningMode = false;
                  });
                  _searchFocusNode.requestFocus();
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 50),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14, right: 6),
                    child: Row(
                      children: [
                        RoadSenseLogo(size: 26, isDarkOverride: isDark),
                        const SizedBox(width: 10),
                        Icon(Icons.search_rounded, color: accent, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _searchController.text.isNotEmpty
                                ? _searchController.text
                                : 'Search place, barangay...',
                            style: TextStyle(
                              fontSize: 14.5,
                              color: _searchController.text.isNotEmpty
                                  ? AppDesign.textPrimary(isDark)
                                  : AppDesign.textSecondary(isDark),
                              fontWeight: _searchController.text.isNotEmpty
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            constraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: 44,
                            ),
                            tooltip: 'Clear search',
                            icon: Icon(
                              Icons.clear_rounded,
                              size: 20,
                              color: AppDesign.textSecondary(isDark),
                            ),
                            onPressed: _clearRouteState,
                          )
                        else ...[
                          Container(
                            width: 1,
                            height: 22,
                            color: AppDesign.border(isDark),
                          ),
                          IconButton(
                            constraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: 44,
                            ),
                            tooltip: 'Directions (Point A to B)',
                            icon: Icon(
                              Icons.directions_rounded,
                              size: 21,
                              color: accent,
                            ),
                            onPressed: () {
                              setState(() {
                                _isSearchPageActive = true;
                                _isRoutePlanningMode = true;
                                _isEditingOrigin = false;
                                _suggestions = [];
                              });
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  _destinationFocusNode.requestFocus();
                                }
                              });
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Stack(
          clipBehavior: Clip.none,
          children: [
            MobileTouchIconButton(
              targetKey: widget.tourLayersFilterKey,
              icon: Icons.tune_rounded,
              tooltip: 'Filters and map layers',
              backgroundColor: _hasActiveDefectFilter
                  ? AppDesign.brand
                  : AppDesign.surface(isDark),
              foregroundColor: _hasActiveDefectFilter
                  ? Colors.white
                  : AppDesign.textPrimary(isDark),
              borderColor: _hasActiveDefectFilter
                  ? Colors.transparent
                  : AppDesign.border(isDark),
              onPressed: () => _showMapLayersAndFiltersSheet(isDark),
            ),
            if (activeFilterCount > 0)
              Positioned(
                top: -3,
                right: -3,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppDesign.warning,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text(
                      '$activeFilterCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildMapStatusChips(bool isDark, bool showMarkers) {
    final bool hasLocationIssue = _isLocationDisabled || _isPermissionDenied;
    final bool emptyFiltered =
        showMarkers &&
        _effectivePotholes.isNotEmpty &&
        _getFilteredActiveMarkers().isEmpty;

    if (!_isOffline &&
        !_hasPartialTileFallback &&
        _routeErrorMessage == null &&
        showMarkers &&
        !_hasActiveDefectFilter &&
        !(hasLocationIssue &&
            (_dismissedLocationPrompt || widget.isTourActive))) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isOffline) ...[
            const MobileOfflineBanner(
              message:
                  'Offline: showing saved map tiles, road hazards & routes.',
            ),
            const SizedBox(height: 6),
          ],
          if (_routeErrorMessage != null && _destination != null) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF451A1A)
                    : const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppDesign.danger.withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.wifi_off_rounded,
                    size: 16,
                    color: AppDesign.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _routeErrorMessage!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF991B1B),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      if (_destination != null) {
                        _calculateRoute(
                          _destination!,
                          customOrigin: _customOrigin,
                        );
                      }
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (!_isOffline && _hasPartialTileFallback)
                ActionChip(
                  avatar: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Some map tiles offline · Reload'),
                  onPressed: _refreshMapTiles,
                ),
              if (!showMarkers)
                ActionChip(
                  avatar: const Icon(Icons.layers_clear_rounded, size: 16),
                  label: const Text('Markers hidden • Show'),
                  onPressed: () =>
                      AppSettings.instance.showPotholesNotifier.value = true,
                ),
              if (emptyFiltered)
                ActionChip(
                  avatar: const Icon(Icons.filter_alt_off_rounded, size: 16),
                  label: const Text('No defects match filter • Reset'),
                  onPressed: _resetMapFilters,
                )
              else if (_hasActiveDefectFilter)
                ActionChip(
                  avatar: const Icon(Icons.filter_list_rounded, size: 16),
                  label: Text(
                    'Filtered (${_getFilteredActiveMarkers().length}) • Reset',
                  ),
                  onPressed: _resetMapFilters,
                ),
              if (hasLocationIssue &&
                  (_dismissedLocationPrompt || widget.isTourActive))
                ActionChip(
                  avatar: Icon(
                    _isLocationDisabled
                        ? Icons.location_off_rounded
                        : Icons.location_searching_rounded,
                    size: 16,
                    color: AppDesign.warning,
                  ),
                  label: Text(
                    _isLocationDisabled
                        ? 'GPS off • Enable location'
                        : 'GPS permission needed',
                  ),
                  onPressed: widget.isTourActive
                      ? null
                      : () => _determinePosition(requestPermission: true),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _showMapLayersAndFiltersSheet(bool isDark) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            final darkNow = AppSettings.instance.isDarkMode;
            final accent = AppDesign.accent(darkNow);
            final showAllMarkers =
                AppSettings.instance.showPotholesNotifier.value;

            return Container(
              decoration: BoxDecoration(
                color: AppDesign.surface(darkNow),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                border: Border.all(color: AppDesign.border(darkNow)),
              ),
              padding: EdgeInsets.fromLTRB(
                18,
                12,
                18,
                MediaQuery.paddingOf(sheetCtx).bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppDesign.border(darkNow),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(Icons.layers_rounded, color: accent, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Map Layers & Filters',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: AppDesign.textPrimary(darkNow),
                                  ),
                                ),
                              ),
                              if (_hasActiveDefectFilter) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppDesign.brandWash(darkNow),
                                    borderRadius: BorderRadius.circular(
                                      AppDesign.radiusPill,
                                    ),
                                    border: Border.all(
                                      color: AppDesign.brandBorder(darkNow),
                                    ),
                                  ),
                                  child: Text(
                                    '${(DpwhStandards.allClasses.length - _selectedDefectNames.length) + (_includePendingLayer ? 0 : 1)} active',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: accent,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        MobileTouchIconButton(
                          icon: Icons.close_rounded,
                          tooltip: 'Close filters and layers',
                          onPressed: () => Navigator.of(sheetCtx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Show road defect markers',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppDesign.textPrimary(darkNow),
                        ),
                      ),
                      subtitle: Text(
                        'Display verified road hazards and alerts on map',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppDesign.textSecondary(darkNow),
                        ),
                      ),
                      value: showAllMarkers,
                      activeTrackColor: accent,
                      onChanged: (val) {
                        AppSettings.instance.showPotholesNotifier.value = val;
                        setSheetState(() {});
                        setState(() {});
                      },
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Include pending reports',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppDesign.textPrimary(darkNow),
                        ),
                      ),
                      subtitle: Text(
                        'Show unapproved reports awaiting admin review',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppDesign.textSecondary(darkNow),
                        ),
                      ),
                      value: _includePendingLayer,
                      activeTrackColor: accent,
                      onChanged: (val) {
                        setState(() {
                          _includePendingLayer = val;
                          _cachedPotholeClusters = null;
                        });
                        setSheetState(() {});
                        unawaited(_refreshRouteAwarePotholeState());
                      },
                    ),

                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'DEFECT TYPES',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.7,
                              color: AppDesign.textSecondary(darkNow),
                            ),
                          ),
                        ),
                        if (_hasActiveDefectFilter)
                          TextButton(
                            onPressed: () {
                              _resetMapFilters();
                              setSheetState(() {});
                            },
                            style: TextButton.styleFrom(
                              minimumSize: const Size(64, 48),
                            ),
                            child: Text(
                              'Reset all',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: accent,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: DpwhStandards.allClasses.map((cls) {
                        final selected = _selectedDefectNames.contains(
                          cls.name,
                        );
                        final fg = MobileDefectHelper.foregroundColor(
                          cls,
                          darkNow,
                        );
                        final classCount = _effectivePotholes.where((p) {
                          if (!_includePendingLayer && p.status == 'pending') {
                            return false;
                          }
                          return p.status != 'rejected' &&
                              p.status != 'deleted' &&
                              DpwhStandards.classify(p.primaryDefect).name ==
                                  cls.name;
                        }).length;
                        return FilterChip(
                          selected: selected,
                          showCheckmark: true,
                          checkmarkColor: fg,
                          selectedColor: cls.color.withValues(
                            alpha: darkNow ? 0.24 : 0.14,
                          ),
                          backgroundColor: AppDesign.sunken(darkNow),
                          side: BorderSide(
                            color: selected ? fg : AppDesign.border(darkNow),
                          ),
                          avatar: Icon(
                            MobileDefectHelper.iconForClass(cls),
                            size: 16,
                            color: fg,
                          ),
                          label: Text(
                            '${cls.name} ($classCount)',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: selected
                                  ? fg
                                  : AppDesign.textPrimary(darkNow),
                            ),
                          ),
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                          onSelected: (val) {
                            setState(() {
                              if (val) {
                                _selectedDefectNames.add(cls.name);
                              } else if (_selectedDefectNames.length > 1) {
                                _selectedDefectNames.remove(cls.name);
                              }
                              _cachedPotholeClusters = null;
                            });
                            setSheetState(() {});
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('All Map & App Settings'),
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (_) => MobileSettingsSheet(
                              onSettingsChanged: () => setState(() {}),
                              onReplayTour: widget.onReplayTour,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildGoogleMapsActiveRouteHeader(bool isDark) {
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color iconColor = AppDesign.textSecondary(isDark);
    final Color fieldFill = AppDesign.sunken(isDark);
    final Color fieldBorder = AppDesign.border(isDark);

    final String originText = _originController.text.isNotEmpty
        ? _originController.text
        : 'Your location';
    final String destText = _searchController.text.isNotEmpty
        ? _searchController.text
        : 'Choose destination';

    void openEndpointEditor({required bool editOrigin}) {
      setState(() {
        _isSearchPageActive = true;
        _isRoutePlanningMode = true;
        _isEditingOrigin = editOrigin;
        _suggestions = [];
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (editOrigin) {
          _originFocusNode.requestFocus();
        } else {
          _destinationFocusNode.requestFocus();
        }
      });
    }

    return Container(
      decoration: BoxDecoration(
        color: AppDesign.surface(isDark),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppDesign.border(isDark), width: 1.1),
        boxShadow: AppDesign.shadowMd(isDark),
      ),
      padding: const EdgeInsets.fromLTRB(4, 8, 6, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            onPressed: _clearRouteState,
            tooltip: 'Back to map',
            icon: Icon(Icons.arrow_back_rounded, color: textColor, size: 21),
            constraints: const BoxConstraints(minWidth: 42, minHeight: 44),
            padding: EdgeInsets.zero,
          ),
          _buildEndpointConnectorRail(isDark, compact: true),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  color: fieldFill,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppDesign.radiusMd),
                    side: BorderSide(color: fieldBorder),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppDesign.radiusMd),
                    onTap: () => openEndpointEditor(editOrigin: true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              originText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                          ),
                          Icon(Icons.edit_outlined, size: 14, color: iconColor),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Material(
                  color: fieldFill,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppDesign.radiusMd),
                    side: BorderSide(color: fieldBorder),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppDesign.radiusMd),
                    onTap: () => openEndpointEditor(editOrigin: false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              destText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.search_rounded,
                            size: 15,
                            color: iconColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 2),
          IconButton(
            onPressed: _swapOriginDestination,
            tooltip: 'Swap start and destination',
            icon: Icon(
              Icons.swap_vert_rounded,
              color: AppDesign.accent(isDark),
              size: 22,
            ),
            constraints: const BoxConstraints(minWidth: 42, minHeight: 44),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchHistoryContent(bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 17,
                    color: AppDesign.textSecondary(isDark),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Recent',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppDesign.textSecondary(isDark),
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: _clearSearchHistory,
                style: TextButton.styleFrom(
                  foregroundColor: AppDesign.accent(isDark),
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: const Text(
                  'Clear',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 4),
          itemCount: _searchHistory.length,
          itemBuilder: (ctx, i) {
            final h = _searchHistory[i];
            final String name = (h['name'] ?? 'Saved Location').toString();
            final String addr = (h['address'] ?? '').toString();
            return InkWell(
              onTap: () {
                final lat = (h['lat'] as num?)?.toDouble() ?? 0.0;
                final lon = (h['lon'] as num?)?.toDouble() ?? 0.0;
                _selectSuggestion({
                  'lat': lat,
                  'lon': lon,
                  '_name': name,
                  '_short_addr': addr,
                  'display_name': name,
                });
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: AppDesign.sunken(isDark),
                          shape: BoxShape.circle,
                          border: Border.all(color: AppDesign.border(isDark)),
                        ),
                        child: Icon(
                          Icons.history_rounded,
                          color: AppDesign.textSecondary(isDark),
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppDesign.textPrimary(isDark),
                              ),
                            ),
                            if (addr.isNotEmpty) ...[
                              const SizedBox(height: 1),
                              Text(
                                addr,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppDesign.textSecondary(isDark),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                        icon: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: AppDesign.textMuted(isDark),
                        ),
                        onPressed: () => _removeFromSearchHistory(i),
                        tooltip: 'Remove from recent',
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildLocationPermissionCenterBox(bool isDark) {
    final bool isLocationOff = _isLocationDisabled;
    final Color statusColor = isLocationOff
        ? AppDesign.warning
        : AppDesign.accent(isDark);

    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.52),
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            constraints: const BoxConstraints(maxWidth: 340),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppDesign.surface(isDark),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppDesign.border(isDark), width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.2),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isLocationOff
                        ? Icons.location_off_rounded
                        : Icons.location_searching_rounded,
                    color: statusColor,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isLocationOff
                      ? 'Location Services Disabled'
                      : 'Location Permission Needed',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppDesign.textPrimary(isDark),
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isLocationOff
                      ? 'Turn on GPS to center your location on the map, receive hazard alerts, and navigate routes.'
                      : 'Grant location permission so RoadSense AI can track your position, guide your route, and alert you to road defects.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppDesign.textSecondary(isDark),
                    fontSize: 13.5,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (isLocationOff) {
                        await Geolocator.openLocationSettings();
                      } else {
                        await _determinePosition(requestPermission: true);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: statusColor,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      isLocationOff ? 'Enable GPS' : 'Grant Access',
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: () {
                      setState(() => _dismissedLocationPrompt = true);
                    },
                    child: Text(
                      'Explore Map Without GPS',
                      style: TextStyle(
                        color: AppDesign.textSecondary(isDark),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUpperPotholeCountdownNotification({
    required int activePotholeCount,
    required bool isDark,
    required bool showMarkers,
  }) {
    final bool isOnRoute = _destination != null || _routePoints.isNotEmpty;
    final NavigationHazardState? nav = _navHazardState;
    final encounterId =
        nav?.nextEncounter?.encounterId ??
        _upcomingHazard?.encounterId ??
        (_upcomingHazard == null
            ? null
            : '${_upcomingHazard!.location.latitude},${_upcomingHazard!.location.longitude}');
    if (encounterId != null &&
        encounterId == _warningBanner.value.dismissedEncounterId) {
      return const SizedBox.shrink();
    }
    final bool hasUpcomingHazard =
        showMarkers &&
        !_isLocationDisabled &&
        !_isPermissionDenied &&
        ((nav?.nextEncounter != null) || _upcomingHazard != null);
    final RouteSwitchSuggestion? suggestion = _routeSwitchSuggestion;
    final bool isUsingSavedData =
        widget.isUsingCachedData || _routeUsingCachedGeometry;
    final bool isUpdatingRoute =
        isOnRoute &&
        (_isRouting ||
            _isAutoRerouting ||
            nav?.status == NavigationHazardStatus.offRoute);
    final bool isWaitingLocation =
        isOnRoute &&
        !isUpdatingRoute &&
        (_isLocationDisabled ||
            _isPermissionDenied ||
            _currentPosition == null ||
            nav?.status == NavigationHazardStatus.waitingForLocation);

    Widget buildCompactStatusBanner({
      required Color bg,
      required Color border,
      required Color fg,
      required IconData icon,
      required String title,
      String? subtitle,
      bool showSpinner = false,
    }) {
      return Semantics(
        liveRegion: true,
        label: subtitle != null && subtitle.isNotEmpty
            ? '$title $subtitle'
            : title,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: border.withValues(alpha: 0.75)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showSpinner)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: border,
                    ),
                  )
                else
                  Icon(icon, color: border, size: 17),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fg.withValues(alpha: 0.88),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (isUpdatingRoute) {
      return buildCompactStatusBanner(
        bg: isDark ? const Color(0xF21E293B) : const Color(0xFAF8FAFC),
        border: const Color(0xFF0EA5E9),
        fg: isDark ? Colors.white : const Color(0xFF0F172A),
        icon: Icons.sync_rounded,
        title: 'Updating route...',
        subtitle: isUsingSavedData ? 'Using saved pothole data.' : null,
        showSpinner: true,
      );
    }

    if (isWaitingLocation) {
      final List<String> waitMeta = [
        if (activePotholeCount > 0)
          '$activePotholeCount reported pothole${activePotholeCount == 1 ? '' : 's'} on route',
        if (isUsingSavedData) 'Using saved pothole data.',
      ];
      return buildCompactStatusBanner(
        bg: isDark ? const Color(0xF21F2937) : const Color(0xFAFFFBEB),
        border: const Color(0xFFD97706),
        fg: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
        icon: Icons.gps_not_fixed_rounded,
        title: 'Waiting for location...',
        subtitle: waitMeta.isEmpty ? null : waitMeta.join(' · '),
      );
    }

    // Clear-path state when on a route with no remaining hazards ahead.
    if (!hasUpcomingHazard) {
      if (!isOnRoute) return const SizedBox.shrink();
      final List<String> clearSubParts = [
        if (activePotholeCount > 0)
          '$activePotholeCount reported on route (all passed)',
        if (nav?.isLowAccuracy == true) 'Location accuracy is low.',
        if (nav?.isStaleLocation == true) 'GPS signal delayed.',
        if (isUsingSavedData) 'Using saved pothole data.',
      ];
      final Color clearBg = isDark
          ? const Color(0xE6064E3B)
          : const Color(0xF5ECFDF5);
      final Color clearBorder = isDark
          ? const Color(0xFF059669)
          : const Color(0xFF10B981);
      final Color clearFg = isDark
          ? const Color(0xFFA7F3D0)
          : const Color(0xFF065F46);

      return buildCompactStatusBanner(
        bg: clearBg,
        border: clearBorder,
        fg: clearFg,
        icon: Icons.verified_user_rounded,
        title: 'No reported potholes ahead on this route.',
        subtitle: clearSubParts.isEmpty ? null : clearSubParts.join(' · '),
      );
    }

    final double distanceMeters =
        nav?.distanceToNextMeters ?? _upcomingHazard?.distanceMeters ?? 0;
    final int meters = distanceMeters.round().clamp(0, 999999);
    final String upcomingBarangay =
        nav?.nextEncounter?.hazard.barangay ?? _upcomingHazard?.barangay ?? '';
    final String formattedAhead = RoutePotholeAdvisor.formatDistanceAhead(
      distanceMeters,
    );
    final bool isImmediate = meters <= 22 || _warningBanner.value.highlighted;
    final bool isClose = !isImmediate && meters <= 150;

    final Color surfaceBg = isImmediate
        ? const Color(0xFFDC2626)
        : (isClose
              ? (isDark ? const Color(0xF2331E09) : const Color(0xF7FFFBEB))
              : (isDark ? const Color(0xF2151922) : const Color(0xFAFFFFFF)));
    final Color borderColor = isImmediate
        ? const Color(0xFFFCA5A5)
        : (isClose
              ? (isDark ? const Color(0xFFD97706) : const Color(0xFFF59E0B))
              : (isDark ? const Color(0xFF2D3544) : const Color(0xFFE2E8F0)));
    final Color titleFg = isImmediate
        ? Colors.white
        : (isDark ? Colors.white : const Color(0xFF0F172A));
    final Color subtitleFg = isImmediate
        ? Colors.white.withValues(alpha: 0.92)
        : (isClose
              ? (isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E))
              : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569)));
    final Color accentColor = isImmediate
        ? Colors.white
        : (isClose ? const Color(0xFFF59E0B) : const Color(0xFF0EA5E9));
    final Color meterPillBg = isImmediate
        ? Colors.white
        : (isClose
              ? const Color(0xFFF59E0B)
              : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)));
    final Color meterPillFg = isImmediate
        ? const Color(0xFFB91C1C)
        : (isClose
              ? const Color(0xFF111827)
              : (isDark ? Colors.white : const Color(0xFF0F172A)));

    final double approachProgress = (1.0 - (distanceMeters / 500.0)).clamp(
      0.05,
      1.0,
    );

    final List<String> metaParts = [];
    if (isOnRoute && nav != null && nav.totalRoutePotholeCount > 0) {
      metaParts.add(
        '${nav.remainingPotholeCount} ahead · ${nav.totalRoutePotholeCount} on route',
      );
    } else if (isOnRoute && activePotholeCount > 0) {
      metaParts.add('$activePotholeCount on route');
    } else if (!isOnRoute) {
      metaParts.add('Nearby ahead');
    }
    if (upcomingBarangay.isNotEmpty) {
      metaParts.add('Brgy. $upcomingBarangay');
    }
    if (isOnRoute && _nextPotholeEta != null && _nextPotholeEta!.isNotEmpty) {
      metaParts.add('~$_nextPotholeEta');
    }
    if (nav?.isLowAccuracy == true) {
      metaParts.add('Location accuracy is low.');
    }
    if (isUsingSavedData) {
      metaParts.add('Using saved pothole data.');
    }
    final String metaLine = metaParts.join(' · ');

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        _dismissWarningBanner();
      },
      child: Semantics(
        liveRegion: true,
        onDismiss: _dismissWarningBanner,
        label: 'Pothole ahead, $formattedAhead. $metaLine',
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: surfaceBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor, width: 1.15),
              boxShadow: [
                BoxShadow(
                  color: isImmediate
                      ? const Color(0xFFDC2626).withValues(alpha: 0.35)
                      : Colors.black.withValues(alpha: isDark ? 0.40 : 0.12),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 10, 8),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: isImmediate
                              ? Colors.white.withValues(alpha: 0.2)
                              : accentColor.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isImmediate
                              ? Icons.warning_amber_rounded
                              : Icons.remove_road_rounded,
                          color: isImmediate ? Colors.white : accentColor,
                          size: 17,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Pothole ahead',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: titleFg,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (metaLine.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                metaLine,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: subtitleFg,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: meterPillBg,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          formattedAhead,
                          style: TextStyle(
                            color: meterPillFg,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Semantics(
                        container: true,
                        button: true,
                        label: 'Dismiss pothole warning',
                        child: InkWell(
                          onTap: _dismissWarningBanner,
                          borderRadius: BorderRadius.circular(22),
                          child: Container(
                            width: 48,
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: titleFg.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.close_rounded,
                              color: titleFg,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (suggestion != null && isOnRoute)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _takeDetourAroundHazard(
                          suggestion.recommendedRouteIndex,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: isImmediate
                                ? Colors.white.withValues(alpha: 0.18)
                                : const Color(
                                    0xFF0D9488,
                                  ).withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isImmediate
                                  ? Colors.white.withValues(alpha: 0.45)
                                  : const Color(
                                      0xFF0D9488,
                                    ).withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.alt_route_rounded,
                                size: 15,
                                color: isImmediate
                                    ? Colors.white
                                    : (isDark
                                          ? const Color(0xFF5EEAD4)
                                          : const Color(0xFF0F766E)),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '${suggestion.routeLabel} avoids ${suggestion.hazardsAvoided} reported pothole${suggestion.hazardsAvoided == 1 ? '' : 's'} (${suggestion.recommendedHazards} vs ${suggestion.currentHazards})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isImmediate
                                        ? Colors.white
                                        : (isDark
                                              ? const Color(0xFF99F6E4)
                                              : const Color(0xFF0F766E)),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Switch',
                                style: TextStyle(
                                  color: isImmediate
                                      ? Colors.white
                                      : (isDark
                                            ? const Color(0xFF2DD4BF)
                                            : const Color(0xFF0D9488)),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                LinearProgressIndicator(
                  value: approachProgress,
                  minHeight: 2.5,
                  backgroundColor: isImmediate
                      ? Colors.white24
                      : borderColor.withValues(alpha: 0.25),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isImmediate ? const Color(0xFFFDE047) : accentColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _getStepIconData(RouteStep step) {
    final type = step.maneuverType.toLowerCase();
    final modifier = (step.modifier ?? '').toLowerCase();
    final instruction = step.instruction.toLowerCase();

    // 1. Destination & Departure
    if (type == 'arrive' || instruction.contains('arrived')) {
      return Icons.place_rounded;
    }
    if (type == 'depart' || instruction.contains('head')) {
      return Icons.navigation_rounded;
    }

    // 2. U-Turn
    if (modifier.contains('uturn') || instruction.contains('u-turn')) {
      return Icons.u_turn_left_rounded;
    }

    // 3. Roundabout / Fork / Merge
    if (type == 'roundabout' || type == 'rotary') {
      return Icons.roundabout_right_rounded;
    }
    if (type == 'fork') {
      return (modifier.contains('left') || instruction.contains('left'))
          ? Icons.fork_left_rounded
          : Icons.fork_right_rounded;
    }
    if (type == 'merge') {
      return Icons.merge_rounded;
    }

    // 4. Left Turns
    if (modifier.contains('sharp left') || instruction.contains('sharp left')) {
      return Icons.turn_sharp_left_rounded;
    }
    if (modifier.contains('slight left') ||
        instruction.contains('slight left')) {
      return Icons.turn_slight_left_rounded;
    }
    if (modifier == 'left' ||
        modifier.contains('left') ||
        instruction.contains('turn left') ||
        instruction.contains('keep left')) {
      return Icons.turn_left_rounded;
    }

    // 5. Right Turns
    if (modifier.contains('sharp right') ||
        instruction.contains('sharp right')) {
      return Icons.turn_sharp_right_rounded;
    }
    if (modifier.contains('slight right') ||
        instruction.contains('slight right')) {
      return Icons.turn_slight_right_rounded;
    }
    if (modifier == 'right' ||
        modifier.contains('right') ||
        instruction.contains('turn right') ||
        instruction.contains('keep right')) {
      return Icons.turn_right_rounded;
    }

    // 6. Continue / Straight / New Name: Clean straight arrow with NO curves
    return Icons.arrow_upward_rounded;
  }

  String _currentStepInstruction() {
    if (_routeSteps.isEmpty) return '';
    final int stepIdx =
        (_selectedStepIndex != null && _selectedStepIndex! < _routeSteps.length)
        ? _selectedStepIndex!
        : 0;
    final currentStep = _routeSteps[stepIdx];
    return currentStep.instruction.isNotEmpty
        ? currentStep.instruction
        : (currentStep.roadName.isNotEmpty
              ? 'Continue on ${currentStep.roadName}'
              : 'Proceed along route');
  }

  void _speakCurrentStepInstruction() {
    if (kIsWeb || _routeSteps.isEmpty) return;
    try {
      final int stepIdx =
          (_selectedStepIndex != null &&
              _selectedStepIndex! < _routeSteps.length)
          ? _selectedStepIndex!
          : 0;
      final double stepDist = _routeSteps[stepIdx].distanceMeters;
      final String stepDistStr = stepDist >= 1000
          ? '${(stepDist / 1000).toStringAsFixed(1)} km'
          : '${stepDist.round()} m';
      _tts.speak('In $stepDistStr, ${_currentStepInstruction()}');
    } catch (_) {}
  }

  Widget _buildGoogleMapsNavigationHeader({
    required bool isDark,
    required int activePotholeCount,
    String? navHeadline,
  }) {
    final int remainingCount =
        _navHazardState?.remainingPotholeCount ?? activePotholeCount;
    final String routeHazardNote = _routePoints.isEmpty
        ? 'Pothole radar active'
        : (_navHazardState != null && activePotholeCount > 0
              ? '$remainingCount ahead · $activePotholeCount on route'
              : '$activePotholeCount reported pothole${activePotholeCount == 1 ? '' : 's'} on route');

    final double? nextHazardMeters =
        _navHazardState?.distanceToNextMeters ??
        _upcomingHazard?.distanceMeters;
    final String hazardGuidance = nextHazardMeters == null
        ? routeHazardNote
        : 'Next pothole: ${RoutePotholeAdvisor.formatDistanceAhead(nextHazardMeters)}';

    if (_routeSteps.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF005B4F) : const Color(0xFF00695C),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDark ? const Color(0xFF00897B) : const Color(0xFF00796B),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.34),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 32),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    navHeadline?.isNotEmpty == true ? navHeadline! : 'Follow Route',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hazardGuidance,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: nextHazardMeters != null
                          ? const Color(0xFFFBBF24)
                          : Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final int stepIdx =
        (_selectedStepIndex != null && _selectedStepIndex! < _routeSteps.length)
        ? _selectedStepIndex!
        : 0;
    final currentStep = _routeSteps[stepIdx];
    final IconData maneuverIcon = _getStepIconData(currentStep);
    final double stepDist = currentStep.distanceMeters;
    final String stepDistStr = stepDist >= 1000
        ? '${(stepDist / 1000).toStringAsFixed(1)} km'
        : '${stepDist.round()} m';
    final String instruction = _currentStepInstruction();

    final Color headerBg = isDark
        ? const Color(0xFF005B4F)
        : const Color(0xFF00695C);
    final Color headerBorder = isDark
        ? const Color(0xFF00897B)
        : const Color(0xFF00796B);
    final Color thenBg = isDark
        ? const Color(0xFF00433A)
        : const Color(0xFF004D40);
    final nextStep = (stepIdx + 1 < _routeSteps.length)
        ? _routeSteps[stepIdx + 1]
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: headerBg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomRight: const Radius.circular(18),
              bottomLeft: Radius.circular(nextStep != null ? 4 : 18),
            ),
            border: Border.all(color: headerBorder, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.34),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(maneuverIcon, color: Colors.white, size: 34),
              const SizedBox(width: 14),
              Expanded(
                child: Semantics(
                  button: true,
                  hint: 'Tap to repeat navigation instruction',
                  child: InkWell(
                    onTap: _speakCurrentStepInstruction,
                    borderRadius: BorderRadius.circular(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (stepDist >= 15)
                          Text(
                            stepDistStr,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2,
                            ),
                          ),
                        Text(
                          instruction,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            height: 1.2,
                          ),
                        ),
                        if (activePotholeCount > 0) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: Color(0xFFFBBF24),
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  hazardGuidance,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFFBBF24),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (nextStep != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: thenBg,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Then',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _getStepIconData(nextStep),
                  color: Colors.white,
                  size: 18,
                ),
              ],
            ),
          ),
      ],
    );
  }

  OsrmTravelMode _travelModeFromSetting(String mode) {
    switch (mode) {
      case 'motorcycle':
      case 'bike':
        return OsrmTravelMode.bike;
      case 'walk':
      case 'foot':
        return OsrmTravelMode.foot;
      default:
        return OsrmTravelMode.car;
    }
  }

  void _onNavVehicleModeChanged() {
    if (!mounted) return;
    final nextMode = _travelModeFromSetting(
      AppSettings.instance.mobileNavVehicleModeNotifier.value,
    );
    if (_travelMode != nextMode) {
      setState(() => _travelMode = nextMode);
    }
  }

  NavVehicleType _navVehicleTypeFor(OsrmTravelMode mode) {
    switch (mode) {
      case OsrmTravelMode.car:
        return NavVehicleType.car;
      case OsrmTravelMode.bike:
        return NavVehicleType.motorcycle;
      case OsrmTravelMode.foot:
        return NavVehicleType.walking;
    }
  }

  Widget _buildNavigationVehiclePuck() {
    return NavVehicle3DWidget(
      type: _navVehicleTypeFor(_travelMode),
      size: 64.0,
      showHeadlightGlow: true,
    );
  }

  Widget _buildDrivingCircleButton({
    Key? targetKey,
    required Widget icon,
    required String tooltip,
    required VoidCallback onPressed,
    String? badgeText,
    Color badgeAccent = const Color(0xFF38BDF8),
  }) {
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            Material(
              key: targetKey,
              color: const Color(0xE60B0F17),
              shape: const CircleBorder(
                side: BorderSide(color: Color(0x33FFFFFF), width: 1.1),
              ),
              elevation: 6,
              shadowColor: Colors.black54,
              child: InkWell(
                onTap: onPressed,
                customBorder: const CircleBorder(),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(child: icon),
                ),
              ),
            ),
            if (badgeText != null && badgeText.isNotEmpty)
              Positioned(
                bottom: -5,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B0F17),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: badgeAccent.withValues(alpha: 0.75),
                        width: 1.0,
                      ),
                    ),
                    child: Text(
                      badgeText,
                      style: TextStyle(
                        color: badgeAccent,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                        height: 1.05,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showDrivingHudNotice(
    String message, {
    Duration duration = const Duration(milliseconds: 2200),
  }) {
    _drivingHudNoticeTimer?.cancel();
    if (!mounted) return;
    setState(() => _drivingHudNotice = message);
    _drivingHudNoticeTimer = Timer(duration, () {
      if (!mounted) return;
      setState(() => _drivingHudNotice = null);
    });
  }

  void _applyDrivingCameraAngle(
    DrivingCameraAngle angle, {
    bool showNotice = true,
  }) {
    _navAutoRecenterTimer?.cancel();
    final bool isOverview = angle == DrivingCameraAngle.overview;
    final FollowMode nextFollow;
    switch (angle) {
      case DrivingCameraAngle.chase3D:
      case DrivingCameraAngle.topDown2D:
        nextFollow = FollowMode.compass;
      case DrivingCameraAngle.northUp2D:
        nextFollow = FollowMode.location;
      case DrivingCameraAngle.overview:
        nextFollow = FollowMode.none;
    }

    setState(() {
      _drivingCameraAngle = angle;
      _isNavOverview = isOverview;
      _followMode = nextFollow;
    });

    if (isOverview && _routePoints.isNotEmpty) {
      _currentMapRotation = 0.0;
      _mapRotationNotifier.value = 0.0;
      try {
        _mapController.rotate(0.0);
      } catch (_) {}
      _fitCameraToRoute(_routePoints);
    } else {
      final double targetRot;
      if (angle.isHeadingUp && _lastHeadingNotifier.value != null) {
        targetRot = (360.0 - _lastHeadingNotifier.value!) % 360.0;
      } else {
        targetRot = 0.0;
      }
      _currentMapRotation = targetRot;
      _mapRotationNotifier.value = targetRot;
      try {
        _mapController.rotate(targetRot);
      } catch (_) {}

      final LatLng? focus =
          _animatedPuckPositionNotifier.value ?? _currentPosition;
      if (focus != null) {
        final double targetZoom = switch (angle) {
          DrivingCameraAngle.chase3D => 17.5,
          DrivingCameraAngle.topDown2D => 16.6,
          DrivingCameraAngle.northUp2D => 16.2,
          DrivingCameraAngle.overview => 15.0,
        };
        _animatedMapMoveToVisible(
          focus,
          targetZoom,
          isExpandedSheet: false,
          rotationDeg: targetRot,
        );
      }
      _startFollowing();
    }

    if (showNotice) {
      _showDrivingHudNotice(angle.label);
    }
  }

  void _alignDrivingCameraToActiveRoute(LatLng anchorPos) {
    final double? routeBearing = _routePoints.length >= 2
        ? GpsTrackerSmoother.routeForwardBearingDeg(
            _routePoints,
            anchorPos,
            lookaheadMeters: 30.0,
            maxDistanceMeters: 500.0,
          )
        : null;
    if (routeBearing != null) {
      _gpsSmoother.setHeading(routeBearing);
      _lastHeadingNotifier.value = routeBearing;
    }
    _applyDrivingCameraAngle(_drivingCameraAngle, showNotice: false);
  }

  Future<void> _handleDrivingReroute() async {
    if (_isManualRerouting || _isRouting) return;
    HapticFeedback.mediumImpact();

    final LatLng? dest = _destination;
    if (dest == null) {
      _showDrivingHudNotice('Set a destination first to reroute');
      return;
    }

    final LatLng livePos =
        _animatedPuckPositionNotifier.value ??
        _currentPosition ??
        (_routePoints.isNotEmpty ? _routePoints.first : _bulacanCenter);
    final double distFromStart = _routePoints.isNotEmpty
        ? Geolocator.distanceBetween(
            livePos.latitude,
            livePos.longitude,
            _routePoints.first.latitude,
            _routePoints.first.longitude,
          )
        : double.infinity;
    final double distToRoute = _routePoints.isNotEmpty
        ? _distancePointToRouteMeters(livePos, _routePoints)
        : double.infinity;

    // Fast path near the origin: cycle to the next already-fetched alternative.
    if (distFromStart <= 65.0 &&
        distToRoute <= 35.0 &&
        _alternativeRoutes.length > 1) {
      final int nextIndex =
          (_selectedRouteIndex + 1) % _alternativeRoutes.length;
      _selectActiveRoute(nextIndex);
      _alignDrivingCameraToActiveRoute(livePos);
      final int hazards = _selectedRouteIndex < _routePotholeCounts.length
          ? _routePotholeCounts[_selectedRouteIndex]
          : _potholesOnRoute.length;
      final String hazardText = hazards == 0
          ? '0 potholes'
          : '$hazards pothole${hazards == 1 ? '' : 's'}';
      _showDrivingHudNotice(
        'Rerouted · Route ${nextIndex + 1}/${_alternativeRoutes.length} ($hazardText)',
      );
      if (!kIsWeb && AppSettings.instance.mobileVoiceAlertsEnabled) {
        _tts.speak(
          'Rerouted to route ${nextIndex + 1} of ${_alternativeRoutes.length}.',
        );
      }
      return;
    }

    final LatLng? prevMid = _routePoints.length >= 2
        ? _routePoints[_routePoints.length ~/ 2]
        : null;

    setState(() {
      _isManualRerouting = true;
      _customOrigin = null;
    });
    _showDrivingHudNotice(
      'Rerouting...',
      duration: const Duration(seconds: 6),
    );

    try {
      await _calculateRoute(
        dest,
        customOrigin: livePos,
        fitCamera: false,
        silent: true,
      );
      if (!mounted || !_isNavigating) return;

      if (_alternativeRoutes.length < 2) {
        await _findFewerPotholes();
        if (!mounted || !_isNavigating) return;
      }

      // If still on-route and alternative 0 matches the previous route, pick alternate 1.
      if (_alternativeRoutes.length > 1 &&
          prevMid != null &&
          distToRoute <= 35.0 &&
          _alternativeRoutes.first.length >= 2) {
        final newMid =
            _alternativeRoutes.first[_alternativeRoutes.first.length ~/ 2];
        final midShiftMeters = Geolocator.distanceBetween(
          prevMid.latitude,
          prevMid.longitude,
          newMid.latitude,
          newMid.longitude,
        );
        if (midShiftMeters < 40.0) {
          _selectActiveRoute(1);
        }
      }

      _alignDrivingCameraToActiveRoute(livePos);
      final int hazards = _selectedRouteIndex < _routePotholeCounts.length
          ? _routePotholeCounts[_selectedRouteIndex]
          : _potholesOnRoute.length;
      final String hazardText = hazards == 0
          ? 'clear road'
          : '$hazards pothole${hazards == 1 ? '' : 's'}';
      _showDrivingHudNotice(
        'Rerouted · Route ${_selectedRouteIndex + 1}/${_alternativeRoutes.isEmpty ? 1 : _alternativeRoutes.length} ($hazardText)',
      );
      if (!kIsWeb && AppSettings.instance.mobileVoiceAlertsEnabled) {
        _tts.speak('Rerouted.');
      }
    } finally {
      if (mounted) {
        setState(() => _isManualRerouting = false);
      } else {
        _isManualRerouting = false;
      }
    }
  }

  Widget _buildDrivingRightControls(bool isDark) {
    final bool voiceEnabled = AppSettings.instance.mobileVoiceAlertsEnabled;
    final bool isReroutingBusy = _isManualRerouting || _isRouting;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDrivingCircleButton(
          targetKey: _drivingAngleGuideKey,
          icon: _drivingCameraAngle == DrivingCameraAngle.overview
              ? const Icon(
                  Icons.zoom_out_map_rounded,
                  color: Color(0xFF38BDF8),
                  size: 22,
                )
              : ValueListenableBuilder<double>(
                  valueListenable: _mapRotationNotifier,
                  builder: (_, rotDeg, _) => NavCompassNeedleIcon(
                    size: 24,
                    angleRadians: _drivingCameraAngle.isHeadingUp
                        ? rotDeg * math.pi / 180.0
                        : 0.0,
                  ),
                ),
          badgeText: _drivingCameraAngle.shortBadge,
          tooltip:
              'Camera angle: ${_drivingCameraAngle.label} (tap to switch)',
          onPressed: () {
            HapticFeedback.selectionClick();
            _applyDrivingCameraAngle(
              _drivingCameraAngle.next(hasRoute: _routePoints.isNotEmpty),
            );
          },
        ),
        const SizedBox(height: 14),
        _buildDrivingCircleButton(
          targetKey: _drivingSearchGuideKey,
          icon: const Icon(Icons.search_rounded, color: Colors.white, size: 22),
          tooltip: 'Search destination',
          onPressed: () {
            setState(() {
              _isSearchPageActive = true;
              _isRoutePlanningMode = false;
              _suggestions = [];
            });
            _destinationFocusNode.requestFocus();
          },
        ),
        const SizedBox(height: 14),
        _buildDrivingCircleButton(
          targetKey: _drivingVoiceGuideKey,
          icon: Icon(
            voiceEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            color: voiceEnabled ? Colors.white : const Color(0xFFFCA5A5),
            size: 22,
          ),
          tooltip: voiceEnabled ? 'Mute voice alerts' : 'Unmute voice alerts',
          onPressed: () {
            final wasEnabled = AppSettings.instance.mobileVoiceAlertsEnabled;
            setState(() {
              AppSettings.instance.mobileVoiceAlertsEnabled = !wasEnabled;
            });
            if (wasEnabled && !kIsWeb) {
              try {
                _tts.stop();
              } catch (_) {}
            }
          },
        ),
        const SizedBox(height: 14),
        _buildDrivingCircleButton(
          targetKey: _drivingRerouteGuideKey,
          icon: isReroutingBusy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Color(0xFF38BDF8),
                  ),
                )
              : const Icon(
                  Icons.alt_route_rounded,
                  color: Colors.white,
                  size: 22,
                ),
          badgeText: !isReroutingBusy && _alternativeRoutes.length > 1
              ? '${_selectedRouteIndex + 1}/${_alternativeRoutes.length}'
              : null,
          tooltip: 'Reroute',
          onPressed: () => unawaited(_handleDrivingReroute()),
        ),
      ],
    );
  }

  Widget _buildDrivingSpeedometer() {
    return ValueListenableBuilder<LatLng?>(
      valueListenable: _animatedPuckPositionNotifier,
      builder: (context, _, _) {
        final int kmh = (_gpsSmoother.speedMps * 3.6).round().clamp(0, 299);
        return Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xE60B0F17),
            border: Border.all(color: Colors.white38, width: 1.4),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$kmh',
                style: AppDesign.tabular(
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'km/h',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showVehicleProfilePickerSheet(bool isDark) {
    _setRouteSheetExpanded(true);
  }

  void _startFreeDriveNavigation() {
    AppSettings.instance.setRouteActive(true);
    _navAutoRecenterTimer?.cancel();
    _drivingHudNoticeTimer?.cancel();
    if (_puckPulseController.isAnimating) {
      _puckPulseController.stop();
    }
    _endpointDragScreenBase = null;
    _endpointDragPointerOffset = null;
    setState(() {
      _isNavigating = true;
      _isNavOverview = false;
      _drivingCameraAngle = DrivingCameraAngle.chase3D;
      _isManualRerouting = false;
      _drivingHudNotice = null;
      _isRoutePlanningMode = false;
      _isDraggingEndpoint = false;
      _draggingEndpointKind = 0;
      _isEditingDevLocation = false;
      _isChoosingLocationOnMap = false;
      _isPlacingMarker = false;
      _followMode = FollowMode.compass;
      _isRouteSheetExpanded = false;
      _isRouteDockMinimized = false;
      _selectedStepIndex = null;
    });
    if (_currentPosition != null) {
      if (_lastHeadingNotifier.value != null) {
        final rot = (360.0 - _lastHeadingNotifier.value!) % 360.0;
        _currentMapRotation = rot;
        _mapRotationNotifier.value = rot;
        try {
          _mapController.rotate(rot);
        } catch (_) {}
      }
      _animatedMapMoveToVisible(
        _currentPosition!,
        17.6,
        isExpandedSheet: false,
      );
      _checkPotholeProximity(_currentPosition!);
    } else {
      _determinePosition();
    }
    _startFollowing();
  }

  void _startTurnByTurnNavigation(int activePotholeCount) {
    AppSettings.instance.setRouteActive(true);
    _navAutoRecenterTimer?.cancel();
    _drivingHudNoticeTimer?.cancel();
    if (_puckPulseController.isAnimating) {
      _puckPulseController.stop();
    }
    final double? initialRouteHeading = _routePoints.length >= 2
        ? GpsTrackerSmoother.routeForwardBearingDeg(
            _routePoints,
            _currentPosition ?? _routePoints.first,
            lookaheadMeters: 30.0,
            maxDistanceMeters: 500.0,
          )
        : null;
    if (initialRouteHeading != null) {
      _gpsSmoother.setHeading(initialRouteHeading);
      _lastHeadingNotifier.value = initialRouteHeading;
    }
    _endpointDragScreenBase = null;
    _endpointDragPointerOffset = null;
    setState(() {
      _isNavigating = true;
      _isNavOverview = false;
      _drivingCameraAngle = DrivingCameraAngle.chase3D;
      _isManualRerouting = false;
      _drivingHudNotice = null;
      _isRoutePlanningMode = false;
      _isDraggingEndpoint = false;
      _draggingEndpointKind = 0;
      _isEditingDevLocation = false;
      _isChoosingLocationOnMap = false;
      _isPlacingMarker = false;
      _followMode = FollowMode.compass;
      _isRouteSheetExpanded = false;
      _isRouteDockMinimized = false;
      _selectedStepIndex = null;
    });

    if (_currentPosition != null) {
      final heading = initialRouteHeading ?? _lastHeadingNotifier.value;
      double? targetRot;
      if (heading != null) {
        targetRot = (360.0 - heading) % 360.0;
        _currentMapRotation = targetRot;
        _mapRotationNotifier.value = targetRot;
        try {
          _mapController.rotate(targetRot);
        } catch (_) {}
      }
      _animatedMapMoveToVisible(
        _currentPosition!,
        17.5,
        isExpandedSheet: false,
        rotationDeg: targetRot,
      );
      _checkPotholeProximity(_currentPosition!);
    }
    _startFollowing();

    // Route Hazard Speech & Banner Notification
    if (!kIsWeb && AppSettings.instance.mobileVoiceAlertsEnabled) {
      if (activePotholeCount > 0) {
        final stepPrompt = _routeSteps.isNotEmpty
            ? ' ${_routeSteps.first.instruction}'
            : '';
        if (_travelMode == OsrmTravelMode.bike) {
          _tts.speak(
            'Motorcycle navigation started. Caution: $activePotholeCount reported pothole${activePotholeCount == 1 ? '' : 's'} on your route. Ride carefully.$stepPrompt',
          );
        } else {
          _tts.speak(
            'Navigation started. Caution: $activePotholeCount reported pothole${activePotholeCount == 1 ? '' : 's'} on your route.$stepPrompt',
          );
        }
      } else {
        final stepPrompt = _routeSteps.isNotEmpty
            ? ' ${_routeSteps.first.instruction}'
            : '';
        _tts.speak(
          'Navigation started. No reported potholes along your route.$stepPrompt',
        );
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: activePotholeCount > 0
            ? const Color(0xFFDC2626)
            : const Color(0xFF0F5132),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        content: Row(
          children: [
            Icon(
              activePotholeCount > 0
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_rounded,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                activePotholeCount > 0
                    ? 'Route Alert: $activePotholeCount reported pothole${activePotholeCount == 1 ? '' : 's'} on this route. Drive carefully.'
                    : 'No reported potholes along this route.',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _buildRouteOptionCard(
    int idx,
    bool isDark, {
    bool fullWidth = false,
    VoidCallback? onTapOverride,
  }) {
    final RouteComparisonOption? compOption = _routeComparison?.options
        .cast<RouteComparisonOption?>()
        .firstWhere((o) => o?.routeIndex == idx, orElse: () => null);
    final bool isSelected = idx == _selectedRouteIndex;
    final int hazards = compOption != null
        ? compOption.summary.distinctPotholeCount
        : (idx < _routePotholeCounts.length ? _routePotholeCounts[idx] : 0);
    final int minHazards = _routePotholeCounts.isEmpty
        ? hazards
        : _routePotholeCounts.reduce((a, b) => a < b ? a : b);
    final int maxHazards = _routePotholeCounts.isEmpty
        ? hazards
        : _routePotholeCounts.reduce((a, b) => a > b ? a : b);
    final bool isSafest = hazards == minHazards && minHazards < maxHazards;

    final double distM = idx < _routeDistances.length
        ? _routeDistances[idx]
        : 0;
    final double durSec = idx < _routeDurations.length
        ? _routeDurations[idx]
        : 0;
    final String rDist = distM > 0
        ? RoutePotholeAdvisor.formatRouteDistance(distM)
        : '';
    final String rDur = durSec > 0
        ? _formatEta(durSec, distanceMeters: distM, potholeCount: hazards)
        : 'Route ${idx + 1}';

    final int selectedHazards = _selectedRouteIndex < _routePotholeCounts.length
        ? _routePotholeCounts[_selectedRouteIndex]
        : hazards;
    final double selectedSecs = _selectedRouteIndex < _routeDurations.length
        ? _calculateAccurateEtaSeconds(
            _routeDurations[_selectedRouteIndex],
            distanceMeters: _selectedRouteIndex < _routeDistances.length
                ? _routeDistances[_selectedRouteIndex]
                : 0,
            potholeCount: selectedHazards,
          )
        : 0;
    final double thisSecs = durSec > 0
        ? _calculateAccurateEtaSeconds(
            durSec,
            distanceMeters: distM,
            potholeCount: hazards,
          )
        : 0;
    final int deltaMin = ((thisSecs - selectedSecs) / 60).round();

    final Color safeFg = isDark
        ? const Color(0xFF34D399)
        : const Color(0xFF047857);
    final Color warnFg = isDark
        ? const Color(0xFFFBBF24)
        : const Color(0xFFB45309);
    final Color brandFg = AppDesign.accent(isDark);
    final Color activeBorder = isSafest && isSelected
        ? AppDesign.success
        : (isSelected ? brandFg : AppDesign.border(isDark));
    final Color cardFill = isSelected
        ? (isSafest
              ? AppDesign.success.withValues(alpha: isDark ? 0.16 : 0.08)
              : AppDesign.brandWash(isDark))
        : AppDesign.sunken(isDark);

    final String hazardLabel = hazards == 0
        ? 'No reported potholes'
        : '$hazards reported pothole${hazards == 1 ? '' : 's'}';
    final String viaText = compOption?.viaSummary?.isNotEmpty == true
        ? compOption!.viaSummary!
        : _routeViaSummary(idx);
    final String roleLabel =
        compOption?.roleLabel ??
        (isSafest
            ? 'Fewer reported potholes'
            : (idx == 0 ? 'Fastest' : 'Alternative'));

    final Widget badge;
    if (roleLabel == 'Fewer reported potholes' || isSafest) {
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: AppDesign.success.withValues(alpha: isDark ? 0.20 : 0.14),
          borderRadius: BorderRadius.circular(AppDesign.radiusPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_user_rounded, size: 11, color: safeFg),
            const SizedBox(width: 3),
            Text(
              'Fewer potholes',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: safeFg,
              ),
            ),
          ],
        ),
      );
    } else if (roleLabel == 'Fastest' || idx == 0) {
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: AppDesign.brandWash(isDark),
          borderRadius: BorderRadius.circular(AppDesign.radiusPill),
        ),
        child: Text(
          'Fastest',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            color: brandFg,
          ),
        ),
      );
    } else {
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: AppDesign.surface(isDark),
          borderRadius: BorderRadius.circular(AppDesign.radiusPill),
          border: Border.all(color: AppDesign.border(isDark)),
        ),
        child: Text(
          roleLabel,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: AppDesign.textSecondary(isDark),
          ),
        ),
      );
    }

    final Widget cardBody = Material(
      color: cardFill,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTapOverride ?? () => _selectActiveRoute(idx),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: activeBorder,
              width: isSelected ? 1.6 : 1.0,
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: isSelected ? 4 : 0,
                  color: isSafest ? AppDesign.success : brandFg,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      rDur,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppDesign.tabular(
                                        TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -0.3,
                                          color: isSafest
                                              ? safeFg
                                              : AppDesign.textPrimary(isDark),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (rDist.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        rDist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppDesign.tabular(
                                          TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                            color: AppDesign.textSecondary(
                                              isDark,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            badge,
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          compOption != null &&
                                  compOption.fewerPotholesThanFastest > 0 &&
                                  compOption.tradeoffExplanation.isNotEmpty
                              ? compOption.tradeoffExplanation
                              : viaText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppDesign.textPrimary(isDark),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Icon(
                                    hazards == 0
                                        ? Icons.verified_user_rounded
                                        : Icons.warning_amber_rounded,
                                    size: 13,
                                    color: hazards == 0 ? safeFg : warnFg,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      hazardLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppDesign.tabular(
                                        TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                          color: hazards == 0 ? safeFg : warnFg,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (isSelected)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_circle_rounded,
                                    size: 13,
                                    color: isSafest ? safeFg : brandFg,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    'Selected',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: isSafest ? safeFg : brandFg,
                                    ),
                                  ),
                                ],
                              )
                            else if (durSec > 0 && selectedSecs > 0)
                              Text(
                                deltaMin == 0
                                    ? 'Same ETA'
                                    : (deltaMin > 0
                                          ? '+$deltaMin min'
                                          : '${deltaMin.abs()} min faster'),
                                style: AppDesign.tabular(
                                  TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: deltaMin < 0
                                        ? safeFg
                                        : AppDesign.textSecondary(isDark),
                                  ),
                                ),
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
        ),
      ),
    );

    if (fullWidth) return cardBody;
    return SizedBox(width: 236, child: cardBody);
  }

  void _showCompareRoutesBottomSheet(bool isDark) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        bool searchingInSheet = _isSearchingAlternatives;
        return StatefulBuilder(
          builder: (sheetCtx, setModalState) {
            final RouteComparisonResult? comparison = _routeComparison;
            final List<RouteComparisonOption> options =
                comparison != null && comparison.options.isNotEmpty
                ? comparison.options
                : <RouteComparisonOption>[
                    if (_activeRouteIndex != null)
                      RouteComparisonOption(
                        routeIndex: _selectedRouteIndex,
                        roleLabel: 'Fastest',
                        viaSummary: _routeViaSummary(_selectedRouteIndex),
                        summary: _activeRouteIndex!.summary,
                        fewerPotholesThanFastest: 0,
                        extraSecondsVsFastest: 0,
                        extraMetersVsFastest: 0,
                        withinDetourAllowance: true,
                        tradeoffExplanation: '',
                      ),
                  ];
            final bool usingSaved =
                widget.isUsingCachedData || _routeUsingCachedGeometry;
            final String updatedLabel = RoadReportCache.formatDataUpdatedLabel(
              widget.reportsLastUpdatedAt,
              isUsingCached: usingSaved,
            );
            final bool anyApproximate = options.any(
              (o) => o.summary.isApproximate,
            );
            final Color safeFg = isDark
                ? const Color(0xFF34D399)
                : const Color(0xFF047857);
            final Color warnFg = isDark
                ? const Color(0xFFFBBF24)
                : const Color(0xFFB45309);
            final Color brandFg = AppDesign.accent(isDark);

            return SafeArea(
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.82,
                ),
                decoration: BoxDecoration(
                  color: AppDesign.surface(isDark),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  border: Border.all(color: AppDesign.border(isDark)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: AppDesign.borderStrong(isDark),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(
                            Icons.alt_route_rounded,
                            color: brandFg,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Compare routes',
                                  style: TextStyle(
                                    color: AppDesign.textPrimary(isDark),
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                Text(
                                  anyApproximate
                                      ? 'Approximate corridor · $updatedLabel'
                                      : updatedLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: AppDesign.textSecondary(isDark),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Semantics(
                            button: true,
                            label: 'Close compare routes sheet',
                            child: IconButton(
                              onPressed: () => Navigator.pop(sheetCtx),
                              icon: const Icon(Icons.close_rounded),
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (int i = 0; i < options.length; i++) ...[
                                Builder(
                                  builder: (_) {
                                    final opt = options[i];
                                    final bool isSelected =
                                        opt.routeIndex == _selectedRouteIndex;
                                    final int potholes =
                                        opt.summary.distinctPotholeCount;
                                    final bool isFewerRole =
                                        opt.roleLabel ==
                                        'Fewer reported potholes';
                                    final String distText =
                                        RoutePotholeAdvisor.formatRouteDistance(
                                          opt.summary.distanceMeters,
                                        );
                                    final String etaText = _formatEta(
                                      opt.summary.durationSeconds,
                                      distanceMeters:
                                          opt.summary.distanceMeters,
                                      potholeCount: potholes,
                                    );
                                    final String potholeText = potholes == 0
                                        ? 'No reported potholes'
                                        : '$potholes reported pothole${potholes == 1 ? '' : 's'}';
                                    return Container(
                                      margin: EdgeInsets.only(
                                        bottom: i < options.length - 1 ? 10 : 0,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? (isFewerRole
                                                  ? AppDesign.success
                                                        .withValues(
                                                          alpha: isDark
                                                              ? 0.16
                                                              : 0.08,
                                                        )
                                                  : AppDesign.brandWash(isDark))
                                            : AppDesign.sunken(isDark),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: isSelected
                                              ? (isFewerRole
                                                    ? AppDesign.success
                                                    : brandFg)
                                              : AppDesign.border(isDark),
                                          width: isSelected ? 1.6 : 1.0,
                                        ),
                                      ),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(16),
                                        onTap: () {
                                          Navigator.pop(sheetCtx);
                                          _selectActiveRoute(opt.routeIndex);
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.all(13),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.center,
                                                children: [
                                                  Expanded(
                                                    child: Wrap(
                                                      spacing: 6,
                                                      runSpacing: 4,
                                                      crossAxisAlignment:
                                                          WrapCrossAlignment
                                                              .center,
                                                      children: [
                                                        Container(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 8,
                                                                vertical: 3,
                                                              ),
                                                          decoration: BoxDecoration(
                                                            color: isFewerRole
                                                                ? AppDesign
                                                                      .success
                                                                      .withValues(
                                                                        alpha:
                                                                            0.16,
                                                                      )
                                                                : AppDesign.brandWash(
                                                                    isDark,
                                                                  ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  999,
                                                                ),
                                                          ),
                                                          child: Text(
                                                            opt.roleLabel,
                                                            style: TextStyle(
                                                              color: isFewerRole
                                                                  ? safeFg
                                                                  : brandFg,
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                            ),
                                                          ),
                                                        ),
                                                        if (opt
                                                            .summary
                                                            .isApproximate)
                                                          Text(
                                                            'Approx.',
                                                            style: TextStyle(
                                                              color:
                                                                  AppDesign.textMuted(
                                                                    isDark,
                                                                  ),
                                                              fontSize: 10.5,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                  if (isSelected) ...[
                                                    const SizedBox(width: 8),
                                                    Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          Icons
                                                              .check_circle_rounded,
                                                          size: 15,
                                                          color: isFewerRole
                                                              ? safeFg
                                                              : brandFg,
                                                        ),
                                                        const SizedBox(
                                                          width: 4,
                                                        ),
                                                        Text(
                                                          'Selected',
                                                          style: TextStyle(
                                                            color: isFewerRole
                                                                ? safeFg
                                                                : brandFg,
                                                            fontSize: 11.5,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 8),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          'Distance',
                                                          style: TextStyle(
                                                            color:
                                                                AppDesign.textMuted(
                                                                  isDark,
                                                                ),
                                                            fontSize: 10.5,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                        ),
                                                        Text(
                                                          distText,
                                                          style: AppDesign.tabular(
                                                            TextStyle(
                                                              color:
                                                                  AppDesign.textPrimary(
                                                                    isDark,
                                                                  ),
                                                              fontSize: 14,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          'Est. time',
                                                          style: TextStyle(
                                                            color:
                                                                AppDesign.textMuted(
                                                                  isDark,
                                                                ),
                                                            fontSize: 10.5,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                        ),
                                                        Text(
                                                          etaText,
                                                          style: AppDesign.tabular(
                                                            TextStyle(
                                                              color:
                                                                  AppDesign.textPrimary(
                                                                    isDark,
                                                                  ),
                                                              fontSize: 14,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  Expanded(
                                                    flex: 2,
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          'Reported potholes',
                                                          style: TextStyle(
                                                            color:
                                                                AppDesign.textMuted(
                                                                  isDark,
                                                                ),
                                                            fontSize: 10.5,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                        ),
                                                        Text(
                                                          potholeText,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              AppDesign.tabular(
                                                                TextStyle(
                                                                  color:
                                                                      potholes ==
                                                                          0
                                                                      ? safeFg
                                                                      : warnFg,
                                                                  fontSize:
                                                                      13.5,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w800,
                                                                ),
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              if (opt
                                                  .tradeoffExplanation
                                                  .isNotEmpty) ...[
                                                const SizedBox(height: 6),
                                                Text(
                                                  opt.tradeoffExplanation,
                                                  style: TextStyle(
                                                    color: safeFg,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ] else if (opt.viaSummary !=
                                                      null &&
                                                  opt
                                                      .viaSummary!
                                                      .isNotEmpty) ...[
                                                const SizedBox(height: 6),
                                                Text(
                                                  opt.viaSummary!,
                                                  style: TextStyle(
                                                    color:
                                                        AppDesign.textSecondary(
                                                          isDark,
                                                        ),
                                                    fontSize: 11.5,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ],
                                              if (opt
                                                      .summary
                                                      .totalOtherDefectsCount >
                                                  0) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  'Other road defects: ${opt.summary.otherDefectsSummary}',
                                                  style: TextStyle(
                                                    color:
                                                        AppDesign.textSecondary(
                                                          isDark,
                                                        ),
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                              if (comparison != null &&
                                  !comparison.hasFewerPotholesOption) ...[
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.all(11),
                                  decoration: BoxDecoration(
                                    color: AppDesign.sunken(isDark),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: AppDesign.border(isDark),
                                    ),
                                  ),
                                  child: Text(
                                    (comparison.statusMessage?.isNotEmpty ==
                                            true)
                                        ? comparison.statusMessage!
                                        : 'No route with fewer reported potholes was found.',
                                    style: TextStyle(
                                      color: AppDesign.textSecondary(isDark),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: searchingInSheet
                                  ? null
                                  : () async {
                                      setModalState(
                                        () => searchingInSheet = true,
                                      );
                                      await _findFewerPotholes();
                                      if (sheetCtx.mounted) {
                                        setModalState(
                                          () => searchingInSheet = false,
                                        );
                                      }
                                    },
                              icon: searchingInSheet
                                  ? const SizedBox(
                                      width: 15,
                                      height: 15,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.alt_route_rounded,
                                      size: 18,
                                    ),
                              label: Text(
                                searchingInSheet
                                    ? 'Checking alternatives...'
                                    : 'Find fewer potholes',
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 48),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDrivingModeBottomSheet({
    required bool isDark,
    required String distStr,
    required String totalEtaStr,
    required int activePotholeCount,
  }) {
    final double activeDistance =
        _routeDistances.isNotEmpty &&
            _selectedRouteIndex < _routeDistances.length
        ? _routeDistances[_selectedRouteIndex]
        : 0.0;
    final double activeDuration =
        _routeDurations.isNotEmpty &&
            _selectedRouteIndex < _routeDurations.length
        ? _routeDurations[_selectedRouteIndex]
        : 0.0;

    final String formattedDist = distStr.isNotEmpty
        ? distStr
        : RoutePotholeAdvisor.formatRouteDistance(activeDistance);

    final double accurateSeconds = _calculateAccurateEtaSeconds(
      activeDuration,
      distanceMeters: activeDistance,
      potholeCount: activePotholeCount,
    );
    final int min = (accurateSeconds / 60).round().clamp(1, 9999);
    final String formattedDur = _routePoints.isEmpty
        ? 'Free Drive'
        : (totalEtaStr.isNotEmpty
              ? totalEtaStr
              : (min < 60 ? '$min min' : '${min ~/ 60}h ${min % 60}m'));

    final DateTime arrivalTime = DateTime.now().add(Duration(minutes: min));
    final int hour = arrivalTime.hour % 12 == 0 ? 12 : arrivalTime.hour % 12;
    final String amPm = arrivalTime.hour >= 12 ? 'PM' : 'AM';
    final String clockStr =
        '$hour:${arrivalTime.minute.toString().padLeft(2, '0')} $amPm';

    final Color etaColor = _routePoints.isEmpty
        ? const Color(0xFF38BDF8)
        : (activePotholeCount == 0
              ? const Color(0xFF34D399)
              : const Color(0xFFFBBF24));

    final String subtitleText = _routePoints.isEmpty
        ? (activePotholeCount == 0
              ? 'Pothole radar active'
              : '$activePotholeCount nearby hazards')
        : '$formattedDist · $clockStr';

    final int remainingPotholes =
        _navHazardState?.remainingPotholeCount ?? activePotholeCount;

    return GestureDetector(
      key: _drivingBottomSheetGuideKey,
      onVerticalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0.0;
        if (v < -100 && !_isRouteSheetExpanded) {
          _setRouteSheetExpanded(true);
        } else if (v > 100 && _isRouteSheetExpanded) {
          _setRouteSheetExpanded(false);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: const Color(0xFF0A0D12),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: 0.14),
              width: 1.0,
            ),
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 18,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setRouteSheetExpanded(!_isRouteSheetExpanded),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white30,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Semantics(
                      button: true,
                      label: 'End',
                      child: Tooltip(
                        message: 'End navigation',
                        child: Material(
                          color: Colors.transparent,
                          shape: const CircleBorder(
                            side: BorderSide(color: Colors.white38, width: 1.4),
                          ),
                          child: InkWell(
                            onTap: _clearRouteState,
                            customBorder: const CircleBorder(),
                            child: const SizedBox(
                              width: 46,
                              height: 46,
                              child: Icon(
                                Icons.close_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            _setRouteSheetExpanded(!_isRouteSheetExpanded),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              formattedDur,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppDesign.tabular(
                                TextStyle(
                                  color: etaColor,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  height: 1.05,
                                ),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              subtitleText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppDesign.tabular(
                                const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Material(
                      color: Colors.white.withValues(alpha: 0.08),
                      shape: const CircleBorder(),
                      child: InkWell(
                        onTap: () =>
                            _setRouteSheetExpanded(!_isRouteSheetExpanded),
                        customBorder: const CircleBorder(),
                        child: SizedBox(
                          width: 46,
                          height: 46,
                          child: Icon(
                            _isRouteSheetExpanded
                                ? Icons.keyboard_arrow_down_rounded
                                : Icons.keyboard_arrow_up_rounded,
                            color: Colors.white70,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_isRouteSheetExpanded) ...[
                  const SizedBox(height: 12),
                  Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
                  const SizedBox(height: 12),
                  const Text(
                    'VEHICLE PROFILE (3D)',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final item in const [
                        (
                          mode: OsrmTravelMode.car,
                          setting: 'car',
                          label: 'Car',
                          vehicleType: NavVehicleType.car,
                        ),
                        (
                          mode: OsrmTravelMode.bike,
                          setting: 'motorcycle',
                          label: 'Motorcycle',
                          vehicleType: NavVehicleType.motorcycle,
                        ),
                        (
                          mode: OsrmTravelMode.foot,
                          setting: 'walk',
                          label: 'Walking',
                          vehicleType: NavVehicleType.walking,
                        ),
                      ])
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: item.mode == OsrmTravelMode.foot ? 0 : 8,
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                if (_travelMode != item.mode) {
                                  setState(() => _travelMode = item.mode);
                                  AppSettings.instance.setMobileNavVehicleMode(
                                    item.setting,
                                  );
                                  final dest =
                                      _destination ??
                                      (_routePoints.isNotEmpty
                                          ? _routePoints.last
                                          : null);
                                  if (dest != null) {
                                    _calculateRoute(dest);
                                  }
                                }
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                  horizontal: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: _travelMode == item.mode
                                      ? const Color(0xFF00B8FF).withValues(
                                          alpha: 0.16,
                                        )
                                      : const Color(0xFF141923),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: _travelMode == item.mode
                                        ? const Color(0xFF00B8FF)
                                        : Colors.white12,
                                    width: _travelMode == item.mode ? 1.6 : 1.0,
                                  ),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    NavVehicle3DWidget(
                                      type: item.vehicleType,
                                      size: 46,
                                      showHeadlightGlow: false,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      item.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: _travelMode == item.mode
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                        color: _travelMode == item.mode
                                            ? const Color(0xFF38BDF8)
                                            : Colors.white70,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (_routePoints.isNotEmpty)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _toggleRouteSimulation,
                            icon: Icon(
                              _isSimulatingRoute
                                  ? Icons.stop_rounded
                                  : Icons.play_arrow_rounded,
                              size: 18,
                            ),
                            label: Text(
                              _isSimulatingRoute
                                  ? 'Stop Test Drive'
                                  : 'Simulate drive',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 42),
                              backgroundColor: _isSimulatingRoute
                                  ? const Color(0xFF451A03)
                                  : const Color(0xFF141923),
                              foregroundColor: _isSimulatingRoute
                                  ? const Color(0xFFFBBF24)
                                  : Colors.white,
                              side: const BorderSide(color: Colors.white12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      if (_routePoints.isNotEmpty) const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 42,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF141923),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                activePotholeCount == 0
                                    ? Icons.verified_user_rounded
                                    : Icons.warning_amber_rounded,
                                size: 15,
                                color: activePotholeCount == 0
                                    ? const Color(0xFF34D399)
                                    : const Color(0xFFFBBF24),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  activePotholeCount == 0
                                      ? 'Clear ahead'
                                      : '$remainingPotholes ahead · $activePotholeCount total',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: activePotholeCount == 0
                                        ? const Color(0xFF34D399)
                                        : const Color(0xFFFBBF24),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_routeSteps.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 165),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _routeSteps.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                        itemBuilder: (_, i) {
                          final step = _routeSteps[i];
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 0,
                            ),
                            leading: Icon(
                              _getStepIconData(step),
                              color: i == 0
                                  ? const Color(0xFF38BDF8)
                                  : Colors.white70,
                              size: 20,
                            ),
                            title: Text(
                              step.instruction.isNotEmpty
                                  ? step.instruction
                                  : (step.roadName.isNotEmpty
                                        ? step.roadName
                                        : 'Proceed'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            trailing: Text(
                              RoutePotholeAdvisor.formatRouteDistance(
                                step.distanceMeters,
                              ),
                              style: AppDesign.tabular(
                                const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGoogleMapsBottomDock({
    required bool isDark,
    required String distStr,
    required String totalEtaStr,
    required int activePotholeCount,
  }) {
    final double activeDistance =
        _routeDistances.isNotEmpty &&
            _selectedRouteIndex < _routeDistances.length
        ? _routeDistances[_selectedRouteIndex]
        : 0.0;
    final double activeDuration =
        _routeDurations.isNotEmpty &&
            _selectedRouteIndex < _routeDurations.length
        ? _routeDurations[_selectedRouteIndex]
        : 0.0;

    final String formattedDist = distStr.isNotEmpty
        ? distStr
        : RoutePotholeAdvisor.formatRouteDistance(activeDistance);

    final double accurateSeconds = _calculateAccurateEtaSeconds(
      activeDuration,
      distanceMeters: activeDistance,
      potholeCount: activePotholeCount,
    );
    final int min = (accurateSeconds / 60).round().clamp(1, 9999);
    final String formattedDur = totalEtaStr.isNotEmpty
        ? totalEtaStr
        : (min < 60 ? '$min min' : '${min ~/ 60}h ${min % 60}m');

    final DateTime arrivalTime = DateTime.now().add(Duration(minutes: min));
    final int hour = arrivalTime.hour % 12 == 0 ? 12 : arrivalTime.hour % 12;
    final String amPm = arrivalTime.hour >= 12 ? 'PM' : 'AM';
    final String clockStr =
        '$hour:${arrivalTime.minute.toString().padLeft(2, '0')} $amPm';

    final Color safeFg = isDark
        ? const Color(0xFF34D399)
        : const Color(0xFF047857);
    final Color warnFg = isDark
        ? const Color(0xFFFBBF24)
        : const Color(0xFFB45309);
    final Color primaryBlue = AppSettings.instance.isBlackAndWhite
        ? AppDesign.accent(isDark)
        : AppDesign.brand;

    final RouteHazardSummary? activeSummary = _activeRouteIndex?.summary;
    final bool usingSavedData =
        widget.isUsingCachedData || _routeUsingCachedGeometry;
    final String updatedLabel = RoadReportCache.formatDataUpdatedLabel(
      widget.reportsLastUpdatedAt,
      isUsingCached: usingSavedData,
    );
    final int remainingPotholes =
        _navHazardState?.remainingPotholeCount ?? activePotholeCount;
    final String routeSummaryLine = activePotholeCount == 0
        ? '$formattedDist · $formattedDur · No reported potholes along this route'
        : (activeSummary != null
              ? activeSummary.formattedSummaryLine(formattedEta: formattedDur)
              : '$formattedDist · $formattedDur · $activePotholeCount reported pothole${activePotholeCount == 1 ? '' : 's'}');
    final bool showNoBetterRouteNote =
        _hasEvaluatedFewerPotholes &&
        !_isSearchingAlternatives &&
        !(_routeComparison?.hasFewerPotholesOption ?? false);

    if (_isRouteDockMinimized) {
      return GestureDetector(
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity != null &&
              details.primaryVelocity! < -80) {
            setState(() {
              _isRouteDockMinimized = false;
              _isRouteSheetExpanded = false;
            });
          }
        },
        onTap: () => setState(() {
          _isRouteDockMinimized = false;
          _isRouteSheetExpanded = false;
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
          decoration: BoxDecoration(
            color: AppDesign.surface(isDark),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppDesign.border(isDark), width: 1.2),
            boxShadow: AppDesign.shadowMd(isDark),
          ),
          child: Row(
            children: [
              Icon(
                _travelMode == OsrmTravelMode.car
                    ? Icons.directions_car_rounded
                    : _travelMode == OsrmTravelMode.bike
                    ? Icons.two_wheeler_rounded
                    : Icons.directions_walk_rounded,
                color: AppDesign.accent(isDark),
                size: 20,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  routeSummaryLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppDesign.tabular(
                    TextStyle(
                      color: activePotholeCount == 0
                          ? safeFg
                          : AppDesign.textPrimary(isDark),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (!_isNavigating)
                ElevatedButton(
                  onPressed: () =>
                      _startTurnByTurnNavigation(activePotholeCount),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryBlue,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Start driving',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: Icon(
                  Icons.keyboard_arrow_up_rounded,
                  size: 22,
                  color: AppDesign.textSecondary(isDark),
                ),
                onPressed: () => _setRouteSheetExpanded(false),
                tooltip: 'Expand route info',
              ),
            ],
          ),
        ),
      );
    }

    final double screenHeight = MediaQuery.sizeOf(context).height;
    final double expandedSheetHeight = (screenHeight * 0.68).clamp(
      320.0,
      620.0,
    );
    final double collapsedMaxHeight = (screenHeight * 0.54).clamp(350.0, 480.0);

    final Widget summaryAndActionsBlock = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_routeErrorMessage != null) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF451A1A) : const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: AppDesign.danger.withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.wifi_off_rounded,
                  size: 16,
                  color: AppDesign.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _routeErrorMessage!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : const Color(0xFF991B1B),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    if (_destination != null) {
                      _calculateRoute(
                        _destination!,
                        customOrigin: _customOrigin,
                      );
                    }
                  },
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ],

        // Proactive Alternate Route Suggestion Strip
        if (_routeSwitchSuggestion != null && !_isNavigating) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: AppDesign.success.withValues(alpha: isDark ? 0.16 : 0.09),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppDesign.success.withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.alt_route_rounded, size: 17, color: safeFg),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _routeSwitchSuggestion!.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: safeFg,
                        ),
                      ),
                      Text(
                        _routeSwitchSuggestion!.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: AppDesign.textSecondary(isDark),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _takeDetourAroundHazard(
                    _routeSwitchSuggestion!.recommendedRouteIndex,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF059669),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                  child: Text(
                    'Use ${_routeSwitchSuggestion!.routeLabel}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        // Selected Route Summary + Dismiss / End Row
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Selected route',
                        style: TextStyle(
                          color: AppDesign.textSecondary(isDark),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                      if (activeSummary?.isApproximate ?? true)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppDesign.sunken(isDark),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppDesign.border(isDark)),
                          ),
                          child: Text(
                            'Approx.',
                            style: TextStyle(
                              color: AppDesign.textMuted(isDark),
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      if (_isNavigating && activePotholeCount > 0)
                        Text(
                          '$remainingPotholes ahead · $activePotholeCount total',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppDesign.tabular(
                            TextStyle(
                              color: warnFg,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    routeSummaryLine,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppDesign.tabular(
                      TextStyle(
                        color: activePotholeCount == 0
                            ? safeFg
                            : AppDesign.textPrimary(isDark),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Arrive $clockStr · $updatedLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppDesign.textSecondary(isDark),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (activeSummary != null &&
                      activeSummary.totalOtherDefectsCount > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Other defects along route: ${activeSummary.otherDefectsSummary}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppDesign.textMuted(isDark),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!_isNavigating)
              IconButton(
                onPressed: _clearRouteState,
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Close Route',
                style: IconButton.styleFrom(
                  backgroundColor: AppDesign.sunken(isDark),
                  foregroundColor: AppDesign.textSecondary(isDark),
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.all(8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                    side: BorderSide(color: AppDesign.border(isDark)),
                  ),
                ),
              )
            else
              ElevatedButton.icon(
                onPressed: _clearRouteState,
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text(
                  'End',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppDesign.danger,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
          ],
        ),

        const SizedBox(height: 8),
        if (!_isNavigating) ...[
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: 'Start driving navigation',
                  child: ElevatedButton.icon(
                    key: _routeStartDrivingGuideKey,
                    onPressed: () =>
                        _startTurnByTurnNavigation(activePotholeCount),
                    icon: const Icon(Icons.navigation_rounded, size: 16),
                    label: const Text(
                      'Start driving',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryBlue,
                      foregroundColor:
                          AppSettings.instance.isBlackAndWhite && isDark
                          ? Colors.black
                          : Colors.white,
                      elevation: 0,
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: _toggleRouteSimulation,
                icon: Icon(
                  _isSimulatingRoute
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded,
                  size: 19,
                ),
                tooltip: _isSimulatingRoute
                    ? 'Stop Test Drive'
                    : 'Simulate Route Drive',
                style: IconButton.styleFrom(
                  backgroundColor: _isSimulatingRoute
                      ? AppDesign.warning.withValues(alpha: 0.2)
                      : AppDesign.sunken(isDark),
                  foregroundColor: _isSimulatingRoute
                      ? warnFg
                      : AppDesign.textPrimary(isDark),
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.all(8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                    side: BorderSide(color: AppDesign.border(isDark)),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: () => _setRouteSheetExpanded(!_isRouteSheetExpanded),
                icon: Icon(
                  _isRouteSheetExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.format_list_bulleted_rounded,
                  size: 18,
                ),
                tooltip: _isRouteSheetExpanded ? 'Collapse' : 'Steps & routes',
                style: IconButton.styleFrom(
                  backgroundColor: AppDesign.sunken(isDark),
                  foregroundColor: AppDesign.textPrimary(isDark),
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.all(8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                    side: BorderSide(color: AppDesign.border(isDark)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: _routeAvoidGuideKey,
                  onPressed: _isSearchingAlternatives
                      ? null
                      : _findFewerPotholes,
                  icon: _isSearchingAlternatives
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.alt_route_rounded, size: 16),
                  label: Text(
                    _isSearchingAlternatives
                        ? 'Finding...'
                        : 'Find fewer potholes',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    side: BorderSide(color: AppDesign.borderStrong(isDark)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: _routeCompareGuideKey,
                  onPressed: () => _showCompareRoutesBottomSheet(isDark),
                  icon: const Icon(Icons.compare_arrows_rounded, size: 16),
                  label: Text(
                    (_routeComparison?.options.length ??
                                _alternativeRoutes.length) >
                            1
                        ? 'Compare routes (${_routeComparison?.options.length ?? _alternativeRoutes.length})'
                        : 'Compare routes',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    side: BorderSide(color: AppDesign.borderStrong(isDark)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _toggleRouteSimulation,
                  icon: Icon(
                    _isSimulatingRoute
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _isSimulatingRoute ? 'Stop Test Drive' : 'Simulate drive',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    backgroundColor: _isSimulatingRoute
                        ? AppDesign.warning.withValues(alpha: 0.16)
                        : AppDesign.sunken(isDark),
                    foregroundColor: _isSimulatingRoute
                        ? warnFg
                        : AppDesign.textPrimary(isDark),
                    side: BorderSide(color: AppDesign.border(isDark)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      _setRouteSheetExpanded(!_isRouteSheetExpanded),
                  icon: Icon(
                    _isRouteSheetExpanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.format_list_bulleted_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _isRouteSheetExpanded ? 'Collapse' : 'Steps',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    backgroundColor: AppDesign.sunken(isDark),
                    foregroundColor: AppDesign.textPrimary(isDark),
                    side: BorderSide(color: AppDesign.border(isDark)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],

        if (showNoBetterRouteNote) ...[
          const SizedBox(height: 6),
          Text(
            _routeComparison?.statusMessage?.isNotEmpty == true
                ? _routeComparison!.statusMessage!
                : 'No route with fewer reported potholes was found.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppDesign.textSecondary(isDark),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! < -120) {
            _setRouteSheetExpanded(true);
          } else if (details.primaryVelocity! > 120) {
            if (_isRouteSheetExpanded) {
              _setRouteSheetExpanded(false);
            } else {
              setState(() => _isRouteDockMinimized = true);
            }
          }
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        constraints: BoxConstraints(
          maxHeight: _isRouteSheetExpanded
              ? expandedSheetHeight
              : collapsedMaxHeight,
        ),
        decoration: BoxDecoration(
          color: AppDesign.surface(isDark),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppDesign.border(isDark), width: 1.2),
          boxShadow: AppDesign.shadowMd(isDark),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag Handle Pill (Tap or drag vertically like Google Maps)
            GestureDetector(
              onTap: () => _setRouteSheetExpanded(!_isRouteSheetExpanded),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppDesign.borderStrong(isDark),
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),

            // Google Maps Travel Mode Pills (preview mode)
            if (!_isNavigating) ...[
              _buildTravelModeSelector(isDark, activeEta: formattedDur),
              const SizedBox(height: 8),
            ],

            if (!_isRouteSheetExpanded)
              Flexible(
                child: SingleChildScrollView(child: summaryAndActionsBlock),
              )
            else ...[
              summaryAndActionsBlock,
              // Expanded Sheet: Stacked Route Options + Turn-by-Turn Steps
              const SizedBox(height: 8),
              Divider(height: 1, color: AppDesign.border(isDark)),
              const SizedBox(height: 6),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    if (!_isNavigating && _alternativeRoutes.length > 1) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(2, 2, 2, 6),
                        child: Text(
                          'Route options (${_alternativeRoutes.length})',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppDesign.textSecondary(isDark),
                          ),
                        ),
                      ),
                      for (
                        int idx = 0;
                        idx < _alternativeRoutes.length;
                        idx++
                      ) ...[
                        _buildRouteOptionCard(idx, isDark, fullWidth: true),
                        if (idx < _alternativeRoutes.length - 1)
                          const SizedBox(height: 8),
                      ],
                      if (_routeSteps.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            'Turn-by-turn steps',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppDesign.textSecondary(isDark),
                            ),
                          ),
                        ),
                      ],
                    ],
                    for (int i = 0; i < _routeSteps.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 0.8,
                          color: AppDesign.border(isDark),
                        ),
                      Builder(
                        builder: (_) {
                          final step = _routeSteps[i];
                          final isFirst = i == 0;
                          final isLast = i == _routeSteps.length - 1;
                          final isSelected = _selectedStepIndex == i;
                          return InkWell(
                            onTap: () {
                              setState(() => _selectedStepIndex = i);
                              _animatedMapMoveToVisible(
                                step.location,
                                17.5,
                                isExpandedSheet: _isRouteSheetExpanded,
                              );
                            },
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppDesign.brandWash(isDark)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  _buildManeuverIcon(
                                    step,
                                    isFirst,
                                    isLast,
                                    isDark,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: _buildStepText(step, isDark)),
                                  const SizedBox(width: 8),
                                  if (!isLast)
                                    _formatStepDistanceWidget(
                                      step.distanceMeters,
                                      isDark,
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchedPlaceCard(bool isDark) {
    if (_searchedPlace == null) return const SizedBox.shrink();

    final String name =
        _searchedPlace!['name'] as String? ?? 'Searched Location';
    final String address = _searchedPlace!['address'] as String? ?? '';
    final LatLng loc = _searchedPlace!['location'] as LatLng;
    final double distKm =
        (_searchedPlace!['distanceKm'] as num?)?.toDouble() ?? 0.0;
    final int estMinutes = (distKm * 2.2).round().clamp(1, 999);

    final String distText = distKm > 0
        ? '${distKm.toStringAsFixed(1)} km away • ~$estMinutes min'
        : 'Nearby';

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 100) {
          setState(() => _searchedPlace = null);
        }
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        decoration: BoxDecoration(
          color: AppDesign.surface(isDark),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppDesign.border(isDark), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.14),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Drag Handle Pill (Swipable vertically)
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF52525B)
                      : const Color(0xFFD4D4D8),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Row 1: Place Name + Close Button
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFEFF6FF),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.place_rounded,
                    color: AppDesign.accent(isDark),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          color: AppDesign.textPrimary(isDark),
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        address.isNotEmpty ? '$distText • $address' : distText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppDesign.textSecondary(isDark),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: AppDesign.textSecondary(isDark),
                    size: 20,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  tooltip: 'Close',
                  onPressed: () {
                    setState(() => _searchedPlace = null);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Row 2: Google Maps Action Buttons
            Row(
              children: [
                // Primary "Directions" button
                Expanded(
                  flex: 3,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        _isRoutePlanningMode = true;
                        _originController.text = 'Your location';
                        _searchController.text = name;
                        _destination = loc;
                        _customOrigin = null;
                        _searchedPlace = null;
                      });
                      _calculateRoute(loc);
                    },
                    icon: const Icon(Icons.directions_rounded, size: 18),
                    label: const Text(
                      'Directions',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00796B),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // "Point A → B" button
                Expanded(
                  flex: 2,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _isRoutePlanningMode = true;
                        _originController.text = 'Your location';
                        _searchController.text = name;
                        _destination = loc;
                        _customOrigin = null;
                        _searchedPlace = null;
                      });
                      _calculateRoute(loc);
                    },
                    icon: const Icon(Icons.alt_route_rounded, size: 16),
                    label: const Text(
                      'Route',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppDesign.textPrimary(isDark),
                      side: BorderSide(color: AppDesign.border(isDark)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Share button
                IconButton(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(
                        text:
                            '$name\n$address\nCoordinates: ${loc.latitude}, ${loc.longitude}',
                      ),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('📍 Location copied to clipboard!'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.share_rounded, size: 18),
                  color: AppDesign.textSecondary(isDark),
                  tooltip: 'Share location',
                  style: IconButton.styleFrom(
                    backgroundColor: isDark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFF1F5F9),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: AppDesign.border(isDark)),
                    ),
                    padding: const EdgeInsets.all(10),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _formatStepDistanceWidget(double meters, bool isDark) {
    String formatted;
    if (meters >= 1000) {
      final double km = meters / 1000.0;
      if (km == km.roundToDouble()) {
        formatted = '${km.round()} km';
      } else {
        formatted = '${km.toStringAsFixed(1)} km';
      }
    } else {
      formatted = '${meters.round()} m';
    }
    return Text(
      formatted,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
      ),
    );
  }

  Widget _buildStepText(RouteStep step, bool isDark) {
    final name = step.roadName;
    final instruction = step.instruction;

    if (name.isNotEmpty && instruction.contains(name)) {
      final parts = instruction.split(name);
      return RichText(
        text: TextSpan(
          style: TextStyle(
            fontSize: 14.0,
            color: isDark ? Colors.white70 : const Color(0xFF334155),
            height: 1.3,
          ),
          children: [
            TextSpan(text: parts[0]),
            TextSpan(
              text: name,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            if (parts.length > 1) TextSpan(text: parts[1]),
          ],
        ),
      );
    }

    return Text(
      instruction,
      style: TextStyle(
        fontSize: 14.0,
        fontWeight: FontWeight.w500,
        color: isDark ? Colors.white70 : const Color(0xFF334155),
        height: 1.3,
      ),
    );
  }

  Widget _buildManeuverIcon(
    RouteStep step,
    bool isFirst,
    bool isLast,
    bool isDark,
  ) {
    if (isFirst) {
      return Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        child: const Text(
          'A',
          style: TextStyle(
            color: Color(0xFF10B981), // Emerald green
            fontSize: 22,
            fontWeight: FontWeight.w900,
            fontFamily: 'serif',
          ),
        ),
      );
    }
    if (isLast) {
      return Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        child: const Text(
          'B',
          style: TextStyle(
            color: Color(0xFFDC2626), // Deep red
            fontSize: 22,
            fontWeight: FontWeight.w900,
            fontFamily: 'serif',
          ),
        ),
      );
    }

    final IconData iconData = _getStepIconData(step);

    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      child: Icon(
        iconData,
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
        size: 22,
      ),
    );
  }

  Widget _buildTravelModeSelector(bool isDark, {String? activeEta}) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppDesign.sunken(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppDesign.border(isDark)),
      ),
      child: Row(
        children: [
          _buildModeTab(
            mode: OsrmTravelMode.car,
            label: 'Car',
            icon: Icons.directions_car_rounded,
            isDark: isDark,
            activeEta: activeEta,
          ),
          _buildModeTab(
            mode: OsrmTravelMode.bike,
            label: 'Motorcycle',
            icon: Icons.two_wheeler_rounded,
            isDark: isDark,
            activeEta: activeEta,
          ),
          _buildModeTab(
            mode: OsrmTravelMode.foot,
            label: 'Walk',
            icon: Icons.directions_walk_rounded,
            isDark: isDark,
            activeEta: activeEta,
          ),
        ],
      ),
    );
  }

  Widget _buildModeTab({
    required OsrmTravelMode mode,
    required String label,
    required IconData icon,
    required bool isDark,
    String? activeEta,
  }) {
    final bool isSelected = _travelMode == mode;
    final Color selectedFg = AppDesign.accent(isDark);
    final Color unselectedFg = AppDesign.textSecondary(isDark);
    final bool showEta =
        isSelected &&
        activeEta != null &&
        activeEta.isNotEmpty &&
        activeEta != '--';

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: () {
            if (_travelMode != mode) {
              setState(() => _travelMode = mode);
              AppSettings.instance.setMobileNavVehicleMode(mode.name);
              final dest =
                  _destination ??
                  (_routePoints.isNotEmpty ? _routePoints.last : null);
              if (dest != null) {
                _calculateRoute(dest);
              }
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            constraints: const BoxConstraints(minHeight: 38),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppDesign.surface(isDark)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: isSelected
                    ? AppDesign.brandBorder(isDark)
                    : Colors.transparent,
              ),
              boxShadow: isSelected ? AppDesign.shadowSm(isDark) : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: isSelected ? selectedFg : unselectedFg,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    showEta ? '$label · $activeEta' : label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppDesign.tabular(
                      TextStyle(
                        fontSize: 11.5,
                        fontWeight: isSelected
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: isSelected ? selectedFg : unselectedFg,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedPotholeCard(PotholeMarker pothole, bool isDark) {
    final cls = DpwhStandards.classify(pothole.primaryDefect);

    final accent = AppDesign.accent(isDark);

    return GestureDetector(
      onVerticalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v < -240) {
          _showPotholeDetails(pothole);
        } else if (v > 240) {
          setState(() => _selectedPothole = null);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.fastOutSlowIn,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        decoration: BoxDecoration(
          color: AppDesign.surface(isDark),
          borderRadius: BorderRadius.circular(AppDesign.radiusLg + 2),
          border: Border.all(color: AppDesign.border(isDark), width: 1.1),
          boxShadow: AppDesign.shadowMd(isDark),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: AppDesign.border(isDark),
                  borderRadius: BorderRadius.circular(AppDesign.radiusPill),
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPotholeImageThumbnail(pothole.imagePath, isDark),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          MobileDefectPill(defectClass: cls, showCode: true),
                          MobileStatusPill.forReportStatus(
                            pothole.status,
                            isDark: isDark,
                            compact: true,
                          ),

                          if (pothole.potholeCount > 1)
                            MobileStatusPill(
                              label: '${pothole.potholeCount} detections',
                              icon: Icons.layers_rounded,
                              color: AppDesign.textSecondary(isDark),
                              compact: true,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.pin_drop_rounded, color: accent, size: 15),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${pothole.location.latitude.toStringAsFixed(5)}, ${pothole.location.longitude.toStringAsFixed(5)} • SLA: ${pothole.responseTime}',
                              style: TextStyle(
                                color: AppDesign.textPrimary(isDark),
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (pothole.barangay.isNotEmpty ||
                          pothole.city.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.location_city_rounded,
                              color: AppDesign.textSecondary(isDark),
                              size: 15,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'LGU: ${pothole.barangay.isNotEmpty ? pothole.barangay : 'Bulacan'}${pothole.city.isNotEmpty ? ', ${pothole.city}' : ''}',
                                style: TextStyle(
                                  color: AppDesign.textSecondary(isDark),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                MobileTouchIconButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Close selected defect card',
                  onPressed: () => setState(() => _selectedPothole = null),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: AppDesign.primaryButtonStyle(isDark: isDark),
                icon: const Icon(Icons.info_outline_rounded, size: 18),
                label: const Text(
                  'Inspect Report',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () => _showPotholeDetails(pothole),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPotholeImageThumbnail(String imagePath, bool isDark) {
    if (imagePath.startsWith('http')) {
      return GestureDetector(
        onTap: () => _openImagePreview(imagePath),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            imagePath,
            width: 76,
            height: 76,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _placeholderThumb(isDark),
          ),
        ),
      );
    }
    return _placeholderThumb(isDark);
  }

  Widget _placeholderThumb(bool isDark) {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF111827) : const Color(0xFFE2E8F0),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
        ),
      ),
      child: Icon(
        Icons.no_photography_rounded,
        color: isDark ? Colors.white54 : Colors.black38,
        size: 26,
      ),
    );
  }

  void _openImagePreview(String imageUrl) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(imageUrl, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopRightMapProfileToggle({required bool isMapActive}) {
    if (!kIsWeb) return const SizedBox.shrink();

    final bool isDark = AppSettings.instance.isDarkMode;
    final Color cardBg = AppDesign.surface(isDark);
    final Color cardBorder = AppDesign.border(isDark);
    final Color accentColor = AppDesign.accent(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);

    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cardBorder, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // GIS Map Tab Segment
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: isMapActive ? null : () {},
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isMapActive ? accentColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.map_rounded,
                      color: isMapActive ? Colors.white : subtextColor,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Map',
                      style: TextStyle(
                        color: isMapActive ? Colors.white : subtextColor,
                        fontSize: 12.5,
                        fontWeight: isMapActive
                            ? FontWeight.bold
                            : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // User Profile Tab Segment
          if (widget.onOpenProfile != null || !isMapActive)
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onOpenProfile,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: !isMapActive ? accentColor : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.person_rounded,
                        color: !isMapActive ? Colors.white : subtextColor,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Profile',
                        style: TextStyle(
                          color: !isMapActive ? Colors.white : subtextColor,
                          fontSize: 12.5,
                          fontWeight: !isMapActive
                              ? FontWeight.bold
                              : FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Settings Button (Included in top right pill)
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (ctx) => MobileSettingsSheet(
                    onSettingsChanged: () => setState(() {}),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.settings_rounded,
                  color: subtextColor,
                  size: 18,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Offset? _mapScreenPosition(Offset globalPosition) {
    final box = _mapViewportKey.currentContext?.findRenderObject();
    return box is RenderBox ? box.globalToLocal(globalPosition) : null;
  }

  void _onEndpointPanStart(int kind, DragStartDetails details) {
    if (_isNavigating) return;
    final LatLng? point = kind == 1
        ? (_customOrigin ??
              (_destination != null
                  ? (_currentPosition ?? _bulacanCenter)
                  : null))
        : _destination;
    if (point == null) return;
    final pointer = _mapScreenPosition(details.globalPosition);
    if (pointer == null) return;
    _endpointPressStart = DateTime.now();
    _endpointDragDistance = 0.0;
    _endpointDragRevision++;
    _routingRequestSeq++; // Invalidate requests started before the drag.
    _mapMoveController?.stop();
    setState(() {
      _draggingEndpointKind = kind;
      _isDraggingEndpoint = true;
      _endpointDragScreenBase = _mapController.camera.latLngToScreenOffset(
        point,
      );
      _endpointDragPointerOffset = pointer - _endpointDragScreenBase!;
    });
    _liveRerouteTimer?.cancel();
  }

  void _onEndpointPanUpdate(DragUpdateDetails details) {
    if (_isNavigating) return;
    final Offset? base = _endpointDragScreenBase;
    final pointer = _mapScreenPosition(details.globalPosition);
    if (!_isDraggingEndpoint ||
        base == null ||
        pointer == null ||
        _endpointDragPointerOffset == null) {
      return;
    }
    final targetScreen = pointer - _endpointDragPointerOffset!;
    _endpointDragDistance = (targetScreen - base).distance;
    final LatLng moved = _mapController.camera.screenOffsetToLatLng(
      targetScreen,
    );
    _endpointDragRevision++;
    final String coords =
        '${moved.latitude.toStringAsFixed(5)}, ${moved.longitude.toStringAsFixed(5)}';
    setState(() {
      if (_draggingEndpointKind == 1) {
        _customOrigin = moved;
        if (_originController.text != coords) {
          _originController.text = coords;
        }
        _rubberBandActiveRoute(newStart: moved);
      } else {
        _destination = moved;
        if (_searchController.text != coords) {
          _searchController.text = coords;
        }
        _rubberBandActiveRoute(newEnd: moved);
      }
    });
  }

  void _onEndpointPanEnd(DragEndDetails details) {
    if (_isNavigating || !_isDraggingEndpoint) return;
    _liveRerouteTimer?.cancel();
    _endpointDragScreenBase = null;
    _endpointDragPointerOffset = null;
    final int kind = _draggingEndpointKind;
    final bool wasTap =
        DateTime.now().difference(_endpointPressStart).inMilliseconds < 350 &&
        _endpointDragDistance < 8.0;
    setState(() => _isDraggingEndpoint = false);

    if (wasTap) {
      final LatLng? target = kind == 1
          ? (_customOrigin ?? _currentPosition ?? _bulacanCenter)
          : _destination;
      if (target != null) {
        _animatedMapMove(target, _mapController.camera.zoom);
      }
      return;
    }
    _rerouteFromEndpoints(force: true);
    _reverseGeocodeDraggedEndpoint(kind);
  }

  void _onEndpointPanCancel() {
    _liveRerouteTimer?.cancel();
    _endpointDragScreenBase = null;
    _endpointDragPointerOffset = null;
    if (!_isDraggingEndpoint) return;
    setState(() => _isDraggingEndpoint = false);
  }

  Future<void> _rerouteFromEndpoints({bool force = false}) async {
    final LatLng? dest = _destination;
    if (dest == null) return;
    if (!force && (_silentRouting || _isRouting)) return;
    _silentRouting = true;
    try {
      await _calculateRoute(
        dest,
        customOrigin: _customOrigin,
        fitCamera: false,
        silent: true,
      );
    } finally {
      _silentRouting = false;
    }
  }

  Future<void> _reverseGeocodeDraggedEndpoint(int kind) async {
    final revision = _endpointDragRevision;
    final LatLng? point = kind == 1
        ? (_customOrigin ?? _currentPosition ?? _bulacanCenter)
        : _destination;
    if (point == null || !mounted) return;
    final String label = await _reverseGeocodeLabel(point);
    final currentPoint = kind == 1
        ? (_customOrigin ?? _currentPosition ?? _bulacanCenter)
        : _destination;
    if (!mounted ||
        _isDraggingEndpoint ||
        label.isEmpty ||
        revision != _endpointDragRevision ||
        currentPoint != point) {
      return;
    }
    setState(() {
      if (kind == 1) {
        _originController.text = label;
      } else {
        _searchController.text = label;
      }
    });
  }

  Marker _buildDraggableEndpointPin({
    required LatLng point,
    required int kind,
    required Color color,
  }) {
    final bool active = _isDraggingEndpoint && _draggingEndpointKind == kind;
    final String label = kind == 1 ? 'A' : 'B';
    final String tipText = kind == 1 ? 'Start (A)' : 'Destination (B)';

    final List<Color> gradient = kind == 1
        ? [color.withValues(alpha: 0.85), color, const Color(0xFF0369A1)]
        : [const Color(0xFFFDA4AF), color, const Color(0xFFE11D48)];

    final Color badgeTextColor = kind == 1
        ? const Color(0xFF0C4A6E)
        : const Color(0xFF881337);

    return Marker(
      key: ValueKey('endpoint_pin_$kind'),
      point: point,
      width: 48,
      height: 64,
      alignment: Alignment.topCenter,
      child: Listener(
        onPointerCancel: (_) => _onEndpointPanCancel(),
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory<GestureRecognizer>>{
            _EagerPanGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  _EagerPanGestureRecognizer
                >(() => _EagerPanGestureRecognizer(), (instance) {
                  instance.dragStartBehavior = DragStartBehavior.down;
                  instance.onStart = (details) =>
                      _onEndpointPanStart(kind, details);
                  instance.onUpdate = _onEndpointPanUpdate;
                  instance.onEnd = _onEndpointPanEnd;
                  instance.onCancel = _onEndpointPanCancel;
                }),
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(0, active ? -8 : 0, 0)
              ..scaleByDouble(
                active ? 1.14 : 1.0,
                active ? 1.14 : 1.0,
                1.0,
                1.0,
              ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                if (active)
                  Positioned(
                    top: -24,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3.5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xEE0B1220),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: gradient[0], width: 1.2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        tipText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
                CustomPaint(
                  size: const Size(40, 52),
                  painter: _ModernPinPainter(
                    gradientColors: gradient,
                    borderColor: Colors.white,
                    isLifted: active,
                  ),
                ),
                Positioned(
                  top: 7,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: badgeTextColor,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                          height: 1.0,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints a gradient vision cone matching Google Maps style.
class VisionConePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        colors: [
          Colors.blue.withValues(alpha: 0.6),
          Colors.blue.withValues(alpha: 0.0),
        ],
        stops: const [0.1, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    final path = Path();
    path.moveTo(center.dx, center.dy);

    // Draw an arc representing the field of view (approx 100 degrees)
    // Canvas 0 radians is Right (East). North is -pi/2 (-1.5708).
    // We want the cone centered on North.
    const sweepAngle = 1.8; // radians (approx 103 degrees)
    const startAngle = -1.5708 - (sweepAngle / 2); // Center it on North

    path.arcTo(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
    );
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
