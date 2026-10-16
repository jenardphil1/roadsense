import 'dart:math' as math;
import 'dart:math' show cos, sin, sqrt, atan2;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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

enum FollowMode { none, location, compass }

/// 3 Travel Modes supported by Project-OSRM & OpenStreetMap
enum OsrmTravelMode { car, bike, foot }

bool _isTrustedRemoteImageUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.toLowerCase() ==
          'potholestorage2026.blob.core.windows.net' &&
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
  });
}

/// Represents a grouped cluster of potholes located within a 10-meter barrier radius
class PotholeCluster {
  final String id;
  final LatLng center;
  final List<PotholeMarker> items;

  PotholeCluster({
    required this.id,
    required this.center,
    required this.items,
  });

  bool get isSingle => items.length <= 1;
  PotholeMarker get singleItem => items.first;
}

/// Custom painter for the radial spider tree connecting stems
class SpiderLinesPainter extends CustomPainter {
  final List<Offset> childOffsets;
  final bool isDark;

  SpiderLinesPainter({
    required this.childOffsets,
    required this.isDark,
  });

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

class MapScreen extends StatefulWidget {
  final List<PotholeMarker> detectedPotholes;
  final Future<void> Function(PotholeMarker pothole)? onDeleteDetectedPothole;
  final Future<void> Function(LatLng location)? onAddDetectedPothole;
  final VoidCallback? onOpenProfile;
  final bool isMapActive;

  const MapScreen({
    super.key,
    required this.detectedPotholes,
    this.onDeleteDetectedPothole,
    this.onAddDetectedPothole,
    this.onOpenProfile,
    this.isMapActive = true,
  });

  @override
  State<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends State<MapScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  static LatLng? _cachedGlobalPosition;

  @override
  bool get wantKeepAlive => true;

  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  double _currentMapRotation = 0.0;
  String? _expandedClusterId;
  bool _isLoadingLocation = true;
  bool _isLocationDisabled = false;
  bool _isPermissionDenied = false;
  bool _dismissedLocationPrompt = false;
  PotholeMarker? _selectedPothole;

  late final AnimationController _puckPulseController;
  AnimationController? _puckMoveController;
  final ValueNotifier<LatLng?> _animatedPuckPositionNotifier =
      ValueNotifier<LatLng?>(null);

  /// Smoothly interpolates the user location marker between GPS fixes (Google Maps 60 FPS puck motion)
  void _animatePuckTo(LatLng targetPos) {
    final current = _animatedPuckPositionNotifier.value ?? _currentPosition;
    if (current == null) {
      _animatedPuckPositionNotifier.value = targetPos;
      return;
    }

    final startLat = current.latitude;
    final startLng = current.longitude;
    final endLat = targetPos.latitude;
    final endLng = targetPos.longitude;

    final dist = Geolocator.distanceBetween(startLat, startLng, endLat, endLng);
    if (dist > 300 || dist < 0.1) {
      _puckMoveController?.stop();
      _animatedPuckPositionNotifier.value = targetPos;
      if (_followMode != FollowMode.none) {
        final cameraCenter = _getVisibleMapOffsetCameraCenter(
          targetPos,
          _mapController.camera.zoom,
        );
        _mapController.move(cameraCenter, _mapController.camera.zoom);
      }
      return;
    }

    _puckMoveController?.stop();
    _puckMoveController?.dispose();

    _puckMoveController = AnimationController(
      duration: const Duration(milliseconds: 850),
      vsync: this,
    );

    final curved = CurvedAnimation(
      parent: _puckMoveController!,
      curve: Curves.easeOutCubic,
    );

    _puckMoveController!.addListener(() {
      if (!mounted) return;
      final t = curved.value;
      final interpLat = startLat + (endLat - startLat) * t;
      final interpLng = startLng + (endLng - startLng) * t;
      final interpPos = LatLng(interpLat, interpLng);
      _animatedPuckPositionNotifier.value = interpPos;

      if (_followMode != FollowMode.none) {
        final cameraCenter = _getVisibleMapOffsetCameraCenter(
          interpPos,
          _mapController.camera.zoom,
        );
        _mapController.move(cameraCenter, _mapController.camera.zoom);
      }
    });

    _puckMoveController!.forward();
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

      final controller = AnimationController(
        duration: const Duration(milliseconds: 550),
        vsync: this,
      );

      final Animation<double> animation = CurvedAnimation(
        parent: controller,
        curve: Curves.fastOutSlowIn,
      );

      controller.addListener(() {
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
        target = widget.detectedPotholes.firstWhere((p) => p.docId == docId);
      } catch (_) {}
    }
    if (target == null) {
      try {
        target = widget.detectedPotholes.firstWhere(
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
      final defectClass = DpwhStandards.classifyByCode(dpwhCode);
      target = PotholeMarker(
        docId: docId ?? '',
        location: location,
        imagePath: data['imageUrl'] as String? ?? '',
        timestamp: markerDate,
        status: data['status'] as String? ?? 'pending',
        overallSeverity: data['overallSeverity'] as String? ?? defectClass.severity,
        reporterEmail: data['reporterEmail'] as String? ?? '',
        potholeCount: (data['potholeCount'] as num?)?.toInt() ?? 1,
        primaryDpwhCode: dpwhCode,
        primaryDefect: data['primaryDefect'] as String? ?? defectClass.name,
        responseTime: data['responseTime'] as String? ?? defectClass.responseTime,
        correctiveMeasure: data['correctiveMeasure'] as String? ?? defectClass.correctiveMeasure,
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
  /// right in the middle of the unobstructed visible map area (between top header and bottom dock/sheet)
  LatLng _getVisibleMapOffsetCameraCenter(
    LatLng targetLocation,
    double zoom, {
    bool? isExpandedSheet,
  }) {
    try {
      final Size screenSize = MediaQuery.sizeOf(context);
      final double screenHeight = screenSize.height;
      final double topInset = MediaQuery.paddingOf(context).top;

      final bool expanded = isExpandedSheet ?? _isRouteSheetExpanded;

      // Top obstruction (top navigation header or active route card + status bar)
      final double topObstruction = (_isNavigating || _routePoints.isNotEmpty)
          ? (topInset + 84.0)
          : (topInset + 56.0);

      // Bottom obstruction (expanded 50% sheet or compact bottom dock)
      final double bottomObstruction = expanded
          ? (screenHeight * 0.50)
          : ((_isNavigating || _routePoints.isNotEmpty) ? 170.0 : 96.0);

      final double bottomSheetTop = screenHeight - bottomObstruction;
      final double visibleCenterY = (topObstruction + bottomSheetTop) / 2.0;
      final double screenCenterY = screenHeight / 2.0;

      // Pixel shift needed to move the target into the center of the visible area
      final double pixelShiftUp = screenCenterY - visibleCenterY;

      if (pixelShiftUp.abs() < 1.0) return targetLocation;

      final double metersPerPixel =
          (156543.03392 * math.cos(targetLocation.latitude * math.pi / 180.0)) /
          math.pow(2.0, zoom);
      final double metersDeltaY = pixelShiftUp * metersPerPixel;
      final double deltaLat = metersDeltaY / 111139.0;

      return LatLng(
        targetLocation.latitude - deltaLat,
        targetLocation.longitude,
      );
    } catch (_) {
      return targetLocation;
    }
  }

  void _animatedMapMoveToVisible(
    LatLng targetLocation,
    double destZoom, {
    bool? isExpandedSheet,
  }) {
    final center = _getVisibleMapOffsetCameraCenter(
      targetLocation,
      destZoom,
      isExpandedSheet: isExpandedSheet,
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

    final LatLng? focusPoint = (_selectedStepIndex != null &&
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
  bool _isAdminUser = false;
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
  bool _isNavigating = false;
  bool _isAutoRerouting = false;
  DateTime? _lastAutoRerouteAt;
  bool _useMockLocation = false;
  LatLng? _lastRealGpsPosition;
  bool _isEditingDevLocation = false;
  LatLng? _pendingDevLocation;
  bool _isMapDragging = false;

  final bool _showMarkers = true;
  final Map<String, LatLng> _snappedPotholeCache = {};

  List<dynamic> _suggestions = [];
  Timer? _debounceTimer;
  Map<String, dynamic>? _searchedPlace;

  bool get _isSearchingActive {
    return _isSearchPageActive ||
        _isChoosingLocationOnMap ||
        _searchFocusNode.hasFocus ||
        _originFocusNode.hasFocus ||
        _destinationFocusNode.hasFocus ||
        _suggestions.isNotEmpty ||
        _isRouting ||
        _isRoutePlanningMode ||
        _searchController.text.trim().isNotEmpty;
  }

  // Navigation / Follow Mode state
  FollowMode _followMode = FollowMode.location;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  LatLng? _destination;
  final ValueNotifier<double?> _lastHeadingNotifier = ValueNotifier(null);
  List<LatLng> _potholesOnRoute = [];

  // Pothole Proximity Alert
  late final FlutterTts _tts = FlutterTts();
  static const String _locationPrimerPrefKey = 'gps_primer_shown';
  String _nearestPotholeInfo = '';
  String? _nextPotholeEta;
  bool _inProximityWarning = false;
  final Set<String> _alertedAt50m = {};
  final Set<String> _alertedAtPreWarning = {};
  bool _isInitialStartup = true;
  bool _showWarningBanner = false;
  late final AnimationController _warningBannerCountdownController;
  String _selectedHazardCategory = 'All';
  bool _isSearchVisible = true;
  bool _isSearchPageActive = false;
  bool _isChoosingLocationOnMap = false;
  bool _isChoosingOriginOnMap = false;
  bool _isPlacingMarker = false;
  bool _isSavingPlacedMarker = false;
  LatLng? _pendingMarkerLocation;

  static const double _routeCountToleranceMeters = 12.0;
  static const double _routeWarningToleranceMeters = 14.0;
  static const double _snapRadiusMeters = 35.0;
  static const double _proximityCircleRadiusMeters = 22.0;
  static const double _routeSwitchToleranceMeters = 26.0;
  static const double _routeSwitchDeltaMeters = 8.0;
  static const double _offRouteRerouteThresholdMeters = 55.0;
  static const Duration _autoRerouteCooldown = Duration(seconds: 12);

  List<LatLng> get _allPotholeLocations => widget.detectedPotholes
      .where((p) => p.status != 'deleted' && p.status != 'rejected')
      .map((p) => p.location)
      .toList();

  static const double _lookAheadOffset = 0.0018;

  static const String _orsApiKey = String.fromEnvironment('ORS_API_KEY');

  @override
  void initState() {
    super.initState();
    _puckPulseController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    )..repeat();
    _warningBannerCountdownController = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    );
    if (_cachedGlobalPosition != null) {
      _currentPosition = _cachedGlobalPosition;
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
    _checkAdminStatus();
    AppSettings.instance.devMockModeNotifier.addListener(
      _onDevMockModeSettingChanged,
    );
    AppSettings.instance.manualPotholePlacementNotifier.addListener(
      _onManualPotholePlacementSettingChanged,
    );
    AppSettings.instance.devEditLocationNotifier.addListener(
      _onDevEditLocationSettingChanged,
    );
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

  Future<void> _checkAdminStatus() async {
    final currentUser = CloudService.instance.currentUser;
    if (currentUser != null) {
      final role = await CloudService.instance.getUserRole(currentUser.uid);
      if (mounted) {
        setState(() {
          _isAdminUser = (role == 'admin' || role == 'super_admin');
        });
      }
    }
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
        _startFollowing();
      } else {
        _positionSubscription?.cancel();
        _compassSubscription?.cancel();
      }
    }
    final oldSig = _potholeListSignature(oldWidget.detectedPotholes);
    final newSig = _potholeListSignature(widget.detectedPotholes);
    if (oldSig != newSig) {
      _snappedPotholeCache.clear();
      unawaited(_refreshRouteAwarePotholeState());
    }
  }

  @override
  void dispose() {
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
    _searchController.dispose();
    _originController.dispose();
    _debounceTimer?.cancel();
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();
    _puckPulseController.dispose();
    _warningBannerCountdownController.dispose();
    _puckMoveController?.stop();
    _puckMoveController?.dispose();
    _animatedPuckPositionNotifier.dispose();
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

    final List<LatLng> remaining = [userPos];

    final double distToProj = Geolocator.distanceBetween(
      userPos.latitude,
      userPos.longitude,
      projPoint.latitude,
      projPoint.longitude,
    );
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

    int bestIndex = safeActiveIndex;
    double bestDist = activeDist;
    for (int i = 0; i < _alternativeRoutes.length; i++) {
      final d = _distancePointToRouteMeters(userPos, _alternativeRoutes[i]);
      if (d < bestDist) {
        bestDist = d;
        bestIndex = i;
      }
    }

    final bool shouldSwitchRoute =
        bestIndex != safeActiveIndex &&
        bestDist <= _routeSwitchToleranceMeters &&
        (activeDist - bestDist) >= _routeSwitchDeltaMeters;

    if (shouldSwitchRoute) {
      if (!mounted) return;
      setState(() {
        _selectedRouteIndex = bestIndex;
        _lastMatchedSegmentIndex = 0;
        _routePoints = _remainingRouteFromUser(
          _alternativeRoutes[bestIndex],
          userPos,
        );
      });
      await _refreshRouteAwarePotholeState();
      return;
    }

    final bool shouldReroute = bestDist > _offRouteRerouteThresholdMeters;
    final now = DateTime.now();
    final bool cooldownActive =
        _lastAutoRerouteAt != null &&
        now.difference(_lastAutoRerouteAt!) < _autoRerouteCooldown;

    if (!shouldReroute || cooldownActive) return;

    _isAutoRerouting = true;
    _lastAutoRerouteAt = now;
    try {
      await _calculateRoute(_destination!);
    } finally {
      _isAutoRerouting = false;
    }
  }

  double _distanceAlongRouteToPothole(LatLng pothole, List<LatLng> route) {
    if (route.length < 2) {
      return Geolocator.distanceBetween(
        route.isNotEmpty ? route.first.latitude : pothole.latitude,
        route.isNotEmpty ? route.first.longitude : pothole.longitude,
        pothole.latitude,
        pothole.longitude,
      );
    }

    int potholeIdx = 1;
    double minPointDist = double.infinity;
    for (int i = 1; i < route.length; i++) {
      final d = Geolocator.distanceBetween(
        pothole.latitude,
        pothole.longitude,
        route[i].latitude,
        route[i].longitude,
      );
      if (d < minPointDist) {
        minPointDist = d;
        potholeIdx = i;
      }
    }

    double distance = 0;
    for (int i = 0; i < potholeIdx; i++) {
      distance += Geolocator.distanceBetween(
        route[i].latitude,
        route[i].longitude,
        route[i + 1].latitude,
        route[i + 1].longitude,
      );
    }
    return distance;
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

  void _startFollowing() {
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();

    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 3,
          ),
        ).listen((Position position) {
          if (!widget.isMapActive || !mounted) return;
          final gpsPos = LatLng(position.latitude, position.longitude);
          _lastRealGpsPosition = gpsPos;

          if (_useMockLocation) {
            return;
          }

          final newPos = gpsPos;
          _currentPosition = newPos;
          _checkPotholeProximity(newPos);
          unawaited(_autoAdjustRouteToCurrentPath(newPos));
          _animatePuckTo(newPos);
        });

    if (!kIsWeb) {
      _compassSubscription = FlutterCompass.events?.listen((
        CompassEvent event,
      ) {
        if (!widget.isMapActive || !mounted) return;
        if (event.heading == null) return;

        double heading = event.heading!;

        if (_lastHeadingNotifier.value != null) {
          final double prev = _lastHeadingNotifier.value!;
          final double diff = (heading - prev + 180) % 360 - 180;
          // Continuous exponential moving average without stutter-inducing deadband
          heading = (prev + diff * 0.25 + 360) % 360;
        }

        if (mounted) {
          _lastHeadingNotifier.value = heading;
        }

        if (_followMode == FollowMode.compass) {
          _mapController.rotate((360 - heading) % 360);
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

    if (_destination != null && _alternativeRoutes.isNotEmpty) {
      final int activeIndex = _selectedRouteIndex < _alternativeRoutes.length
          ? _selectedRouteIndex
          : 0;
      final activeRoute = _alternativeRoutes[activeIndex];
      routeForChecks = isUsingCustomOrigin
          ? activeRoute
          : _remainingRouteFromUser(activeRoute, userPos);
      final snapped = _roadAlignedPotholeLocations();
      warningCandidates = snapped
          .where(
            (p) => _isPotholeOnRoute(
              p,
              routeForChecks,
              _routeWarningToleranceMeters,
            ),
          )
          .toList();
    } else {
      warningCandidates = _allPotholeLocations;
    }

    double absoluteMin = double.infinity;
    String? closestPotholeKey;

    for (final pothole in warningCandidates) {
      final dist = Geolocator.distanceBetween(
        userPos.latitude,
        userPos.longitude,
        pothole.latitude,
        pothole.longitude,
      );
      if (dist < absoluteMin) {
        absoluteMin = dist;
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

    String nearestInfo = 'Clear ahead';
    String? nextPotholeEta;
    double nearestDistMeters = double.infinity;

    if (_destination != null && routeForChecks.length >= 2) {
      // Find distance to the next hazard along the route
      for (final pothole in pendingPotholes) {
        final drivingDist = _distanceAlongRouteToPothole(
          pothole,
          routeForChecks,
        );
        if (drivingDist < nearestDistMeters) {
          nearestDistMeters = drivingDist;
        }
      }
      if (nearestDistMeters != double.infinity) {
        nearestInfo = '${nearestDistMeters.round()}m';

        // Calculate ETA along route to next pothole
        final int activeIndex =
            _selectedRouteIndex < _routeDurations.length ? _selectedRouteIndex : 0;
        final double totalDur = (_routeDurations.isNotEmpty &&
                activeIndex < _routeDurations.length)
            ? _routeDurations[activeIndex]
            : 0.0;
        final double totalDist = (_routeDistances.isNotEmpty &&
                activeIndex < _routeDistances.length)
            ? _routeDistances[activeIndex]
            : _calculatePolylineDistanceMeters(routeForChecks);

        double etaSeconds = 0;
        if (totalDist > 0 && totalDur > 0) {
          etaSeconds = (nearestDistMeters / totalDist) * totalDur;
        } else {
          // Fallback driving speed ~35 km/h = 9.72 m/s
          etaSeconds = nearestDistMeters / 9.72;
        }

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
    } else {
      // Free roaming / No route searched
      for (final pothole in pendingPotholes) {
        final dist = Geolocator.distanceBetween(
          userPos.latitude,
          userPos.longitude,
          pothole.latitude,
          pothole.longitude,
        );
        if (dist < nearestDistMeters) nearestDistMeters = dist;
      }
      if (nearestDistMeters != double.infinity && nearestDistMeters <= 500) {
        nearestInfo = '${nearestDistMeters.round()}m';
      }
      // Strictly NO ETA when not searching for any location
      nextPotholeEta = null;
    }

    setState(() {
      _currentPosition = userPos;
      _inProximityWarning = inProximity;
      _nearestPotholeInfo = nearestInfo;
      _nextPotholeEta = nextPotholeEta;
      if (_destination != null) {
        _routePoints = routeForChecks;
        _potholesOnRoute = pendingPotholes;
        if (_selectedRouteIndex < _routePotholeCounts.length) {
          _routePotholeCounts[_selectedRouteIndex] = pendingPotholes.length;
        }
      }
    });

    // Multi-Stage Vocal Cues (Stage 1): Pre-warning at 150m - 320m along route
    if (_destination != null &&
        nearestDistMeters <= 320 &&
        nearestDistMeters >= 120 &&
        closestPotholeKey != null &&
        !_alertedAtPreWarning.contains(closestPotholeKey)) {
      _alertedAtPreWarning.add(closestPotholeKey);
      if (_showMarkers && !_isInitialStartup && !kIsWeb) {
        final String prePrompt = _travelMode == OsrmTravelMode.bike
            ? 'Motorcycle advisory: Pothole cluster reported ${nearestDistMeters.round()} meters ahead.'
            : 'Caution: Pothole cluster reported ${nearestDistMeters.round()} meters ahead.';
        _tts.speak(prePrompt);
      }
    }

    if (inProximity && closestPotholeKey != null) {
      if (!_alertedAt50m.contains(closestPotholeKey)) {
        _alertedAt50m.add(closestPotholeKey);

        if (_showMarkers) {
          HapticFeedback.lightImpact();
          setState(() => _showWarningBanner = true);
          _triggerWarningBannerCountdown();
          if (!_isInitialStartup && !kIsWeb) {
            final String etaSpeech = (_destination != null && nextPotholeEta != null)
                ? ', estimated arrival in $nextPotholeEta'
                : '';
            final String routeHazardPrompt =
                (_routePoints.isNotEmpty && pendingPotholes.isNotEmpty)
                    ? (_travelMode == OsrmTravelMode.bike
                        ? 'Motorcycle warning! Pothole detected ahead in ${absoluteMin.round()} meters$etaSpeech. Slow down now.'
                        : 'Warning! Slow down now, pothole ahead in ${absoluteMin.round()} meters$etaSpeech.')
                    : (_travelMode == OsrmTravelMode.bike
                        ? 'Motorcycle alert! Pothole nearby in ${absoluteMin.round()} meters. Slow down now.'
                        : 'Warning! Slow down now, pothole nearby.');
            _tts.speak(routeHazardPrompt);
            PotholeNotifier.instance.showPotholeAlert(
              '${absoluteMin.round()} m',
            );
          }
        }
      }
    } else if (absoluteMin > 60) {
      _alertedAt50m.clear();
      _alertedAtPreWarning.clear();
      if (_showWarningBanner) {
        _dismissWarningBanner();
      }
    }

    _isInitialStartup = false;
  }

  void _triggerWarningBannerCountdown() {
    _warningBannerCountdownController.stop();
    _warningBannerCountdownController.reset();
    _warningBannerCountdownController.forward().then((_) {
      if (mounted && _showWarningBanner) {
        setState(() => _showWarningBanner = false);
      }
    });
  }

  void _dismissWarningBanner() {
    _warningBannerCountdownController.stop();
    if (mounted && _showWarningBanner) {
      setState(() => _showWarningBanner = false);
    }
  }

  int? _findBetterDetourRouteIndex() {
    if (_alternativeRoutes.length <= 1) return null;
    final int currentCount = _selectedRouteIndex < _routePotholeCounts.length
        ? _routePotholeCounts[_selectedRouteIndex]
        : 999;
    int? bestIndex;
    int lowestPotholes = currentCount;
    for (int i = 0; i < _alternativeRoutes.length; i++) {
      if (i == _selectedRouteIndex) continue;
      final int count = i < _routePotholeCounts.length ? _routePotholeCounts[i] : 0;
      if (count < lowestPotholes) {
        lowestPotholes = count;
        bestIndex = i;
      }
    }
    if (bestIndex == null && currentCount > 0 && _alternativeRoutes.length > 1) {
      bestIndex = (_selectedRouteIndex + 1) % _alternativeRoutes.length;
    }
    return bestIndex;
  }

  void _takeDetourAroundHazard(int betterIndex) {
    HapticFeedback.heavyImpact();
    _selectActiveRoute(betterIndex);
    _dismissWarningBanner();
    if (!kIsWeb) {
      _tts.speak('Rerouting to bypass pothole hazard ahead. Alternate path selected.');
    }
  }

  Future<void> _submitHazardFeedback(PotholeMarker pothole, bool stillThere) async {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
    if (pothole.docId != null) {
      try {
        await CloudService.instance.submitHazardFeedback(pothole.docId!, stillThere);
      } catch (_) {}
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                stillThere ? Icons.thumb_up_alt_rounded : Icons.thumb_down_alt_rounded,
                color: stillThere ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  stillThere
                      ? 'Thanks! Hazard freshness verified for all drivers.'
                      : 'Thanks! Report logged — hazard marked for decay.',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF0F172A),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _onMapPositionChanged(MapCamera camera, bool hasGesture) {
    if ((_currentMapRotation - camera.rotation).abs() > 0.1) {
      _currentMapRotation = camera.rotation;
      if (mounted) setState(() {});
    }

    if (hasGesture && _followMode != FollowMode.none) {
      _followMode = FollowMode.none;
      if (mounted) setState(() {});
    }

    if (_isPlacingMarker && hasGesture) {
      _pendingMarkerLocation = camera.center;
      if (mounted) setState(() {});
    }

    if (_isEditingDevLocation && hasGesture) {
      _pendingDevLocation = camera.center;
      if (mounted) setState(() {});
    }
  }

  Future<void> _startMarkerPlacement() async {
    final startPoint = _currentPosition ?? _mapController.camera.center;
    setState(() {
      _isPlacingMarker = true;
      _isSavingPlacedMarker = false;
      _pendingMarkerLocation = startPoint;
      _isEditingDevLocation = false;
      _pendingDevLocation = null;
      _followMode = FollowMode.none;
    });
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

    if (AppSettings.instance.devEditLocationNotifier.value) {
      AppSettings.instance.devEditLocationNotifier.value = false;
    }

    _checkPotholeProximity(location);
    await _autoAdjustRouteToCurrentPath(location);
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
      _checkPotholeProximity(_currentPosition!);
      unawaited(_autoAdjustRouteToCurrentPath(_currentPosition!));
      _mapController.move(_currentPosition!, _mapController.camera.zoom);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Returned to real GPS location.')),
    );
  }

  Future<void> _confirmMarkerPlacement() async {
    final location = _pendingMarkerLocation;
    if (location == null) return;
    if (widget.onAddDetectedPothole == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add marker callback is not configured.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSavingPlacedMarker = true);
    try {
      await widget.onAddDetectedPothole!(location);
      await _refreshRouteAwarePotholeState();

      if (!mounted) return;
      setState(() {
        _isPlacingMarker = false;
        _isSavingPlacedMarker = false;
        _pendingMarkerLocation = null;
      });
      if (AppSettings.instance.manualPotholePlacementNotifier.value) {
        AppSettings.instance.manualPotholePlacementNotifier.value = false;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Marker added from selected map location.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSavingPlacedMarker = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not add marker to that location.'),
          backgroundColor: Colors.red,
        ),
      );
      print('Map placement add marker error: $e');
    }
  }

  void _onSearchChanged(String query) {
    if (_debounceTimer?.isActive ?? false) _debounceTimer?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (trimmed.isNotEmpty) {
        _fetchSuggestions(trimmed);
      } else {
        setState(() => _suggestions = []);
      }
    });
  }

  String _potholeKey(LatLng p) =>
      '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}';

  String _potholeListSignature(List<PotholeMarker> potholes) {
    return potholes
        .map(
          (p) =>
              '${p.id ?? -1}|${_potholeKey(p.location)}|${p.timestamp.millisecondsSinceEpoch}',
        )
        .join('||');
  }

  Future<void> _ensurePotholeSnapCache() async {
    final missing = _allPotholeLocations
        .where((p) => !_snappedPotholeCache.containsKey(_potholeKey(p)))
        .toList();
    if (missing.isEmpty) return;

    // Batch missing locations in chunks of 30 to strictly satisfy ORS max-location parameter limits (max 50)
    const int batchSize = 30;
    for (int i = 0; i < missing.length; i += batchSize) {
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
          'radius': _snapRadiusMeters,
        };

        final response = await http.post(
          url,
          headers: {
            'Authorization': _orsApiKey,
            'Content-Type': 'application/json',
            'User-Agent': 'PotholeScannerApp/1.0',
          },
          body: jsonEncode(body),
        ).timeout(const Duration(seconds: 3));

        if (response.statusCode != 200) {
          for (final p in batch) {
            _snappedPotholeCache[_potholeKey(p)] = p;
          }
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
            if (loc != null && loc.length >= 2 && dist <= _snapRadiusMeters) {
              _snappedPotholeCache[key] = LatLng(
                (loc[1] as num).toDouble(),
                (loc[0] as num).toDouble(),
              );
            } else {
              _snappedPotholeCache[key] = original;
            }
          } else {
            _snappedPotholeCache[key] = original;
          }
        }
      } catch (_) {
        for (final p in batch) {
          _snappedPotholeCache[_potholeKey(p)] = p;
        }
      }
    }
  }

  List<LatLng> _roadAlignedPotholeLocations() {
    return _allPotholeLocations
        .map((p) => _snappedPotholeCache[_potholeKey(p)] ?? p)
        .toList();
  }

  Future<void> _refreshRouteAwarePotholeState() async {
    if (_alternativeRoutes.isEmpty) {
      if (_currentPosition != null) {
        _checkPotholeProximity(_currentPosition!);
      }
      return;
    }

    await _ensurePotholeSnapCache();
    final snappedPotholes = _roadAlignedPotholeLocations();

    final List<int> updatedCounts = _alternativeRoutes.map((routePoints) {
      int count = 0;
      for (final pothole in snappedPotholes) {
        if (_isPotholeOnRoute(
          pothole,
          routePoints,
          _routeCountToleranceMeters,
        )) {
          count++;
        }
      }
      return count;
    }).toList();

    final int activeIndex = _selectedRouteIndex < _alternativeRoutes.length
        ? _selectedRouteIndex
        : 0;
    final activeRoute = _alternativeRoutes[activeIndex];
    final List<LatLng> onRoute = snappedPotholes
        .where(
          (p) =>
              _isPotholeOnRoute(p, activeRoute, _routeWarningToleranceMeters),
        )
        .toList();

    if (!mounted) return;
    setState(() {
      _selectedRouteIndex = activeIndex;
      if (_alternativeRouteSteps.isNotEmpty &&
          activeIndex < _alternativeRouteSteps.length) {
        _routeSteps = _alternativeRouteSteps[activeIndex];
      }
      _routePotholeCounts = updatedCounts;
      _potholesOnRoute = onRoute;
    });

    if (_currentPosition != null) {
      _checkPotholeProximity(_currentPosition!);
    }
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

  bool _isPotholeOnRoute(
    LatLng pothole,
    List<LatLng> route,
    double toleranceMeters,
  ) {
    if (route.length < 2) return false;
    for (int i = 0; i < route.length - 1; i++) {
      final d = _distancePointToSegmentMeters(pothole, route[i], route[i + 1]);
      if (d <= toleranceMeters) return true;
    }
    return false;
  }

  List<double> _routeDistances = [];

  Future<void> _processRoutes(
    List<List<LatLng>> routes,
    List<double> durations,
    List<double> distances,
    LatLng destination, {
    List<List<RouteStep>>? stepsByRoute,
  }) async {
    if (routes.isEmpty || durations.isEmpty) {
      setState(() => _isRouting = false);
      return;
    }

    await _ensurePotholeSnapCache();
    final snappedPotholes = _roadAlignedPotholeLocations();
    final List<int> potholeCounts = [];
    for (final route in routes) {
      int count = 0;
      for (final pothole in snappedPotholes) {
        if (_isPotholeOnRoute(pothole, route, _routeCountToleranceMeters)) {
          count++;
        }
      }
      potholeCounts.add(count);
    }

    const int initialRouteIndex = 0;
    final List<LatLng> initialRoute = routes[initialRouteIndex];
    final List<List<RouteStep>> allSteps = stepsByRoute ?? [];
    final List<RouteStep> initialSteps =
        allSteps.isNotEmpty && allSteps.length > initialRouteIndex
        ? allSteps[initialRouteIndex]
        : [];

    setState(() {
      _alternativeRoutes = routes;
      _alternativeRouteSteps = allSteps;
      _routeSteps = initialSteps;
      _isRoutePlanningMode = true;
      _isNavigating = false;
      _routePotholeCounts = potholeCounts;
      _routeDurations = durations;
      _routeDistances = distances;
      _selectedRouteIndex = initialRouteIndex;
      _lastMatchedSegmentIndex = 0;
      _routePoints = initialRoute;
      _destination = destination;
      _isRouting = false;
      _isSearchVisible = true;
      _followMode = FollowMode.none;
      _nearestPotholeInfo = 'Clear ahead';
    });

    AppSettings.instance.setRouteActive(true);
    _fitCameraToRoute(initialRoute);
    await _refreshRouteAwarePotholeState();
  }

  void _clearRouteState() {
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
      _nearestPotholeInfo = '';
      _nextPotholeEta = null;
      _isRoutePlanningMode = false;
      _isNavigating = false;
      _isRouteSheetExpanded = false;
      _isRouteDockMinimized = false;
    });
    AppSettings.instance.setRouteActive(false);
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
          padding: const EdgeInsets.only(
            top: 140,
            bottom: 180,
            left: 60,
            right: 60,
          ),
        ),
      );
    } catch (_) {}
  }

  void _selectActiveRoute(int index) {
    if (index < 0 || index >= _alternativeRoutes.length) return;
    setState(() {
      _selectedRouteIndex = index;
      _lastMatchedSegmentIndex = 0;
      _routePoints = _alternativeRoutes[index];
      if (_alternativeRouteSteps.isNotEmpty &&
          index < _alternativeRouteSteps.length) {
        _routeSteps = _alternativeRouteSteps[index];
      }
      _selectedStepIndex = null;
    });
    _updatePotholesOnActiveRoute();
  }

  /// Cycles between all available alternative and navigation routes
  void _cycleRoutes() {
    if (_alternativeRoutes.isEmpty) return;
    HapticFeedback.mediumImpact();
    final nextIndex = (_selectedRouteIndex + 1) % _alternativeRoutes.length;
    _selectActiveRoute(nextIndex);
    if (!kIsWeb && _travelMode == OsrmTravelMode.bike) {
      _tts.speak('Route ${nextIndex + 1} of ${_alternativeRoutes.length} selected.');
    }
  }

  Future<void> _updatePotholesOnActiveRoute() async {
    if (_alternativeRoutes.isEmpty) return;
    await _ensurePotholeSnapCache();

    final activeRoute = _alternativeRoutes[_selectedRouteIndex];
    final List<LatLng> onRoute = _roadAlignedPotholeLocations()
        .where(
          (p) =>
              _isPotholeOnRoute(p, activeRoute, _routeWarningToleranceMeters),
        )
        .toList();

    if (!mounted) return;
    setState(() => _potholesOnRoute = onRoute);
  }

  // Pre-indexed Bulacan LGUs & Key Barangays for zero-latency local geocoding
  static const List<Map<String, dynamic>> _bulacanBarangays = [
    // Santa Maria
    {'name': 'Barangay Poblacion', 'municipality': 'Santa Maria', 'lat': 14.8197, 'lon': 120.9575},
    {'name': 'Barangay Bagbaguin', 'municipality': 'Santa Maria', 'lat': 14.8083, 'lon': 120.9542},
    {'name': 'Barangay Caypombo', 'municipality': 'Santa Maria', 'lat': 14.8427, 'lon': 120.9739},
    {'name': 'Barangay Catmon', 'municipality': 'Santa Maria', 'lat': 14.8315, 'lon': 120.9858},
    {'name': 'Barangay Guyong', 'municipality': 'Santa Maria', 'lat': 14.8236, 'lon': 120.9712},
    {'name': 'Barangay Balasing', 'municipality': 'Santa Maria', 'lat': 14.8584, 'lon': 121.0062},
    {'name': 'Barangay Pulong Buhangin', 'municipality': 'Santa Maria', 'lat': 14.8633, 'lon': 121.0022},
    {'name': 'Barangay San Gabriel', 'municipality': 'Santa Maria', 'lat': 14.8251, 'lon': 120.9631},
    {'name': 'Barangay Santa Clara', 'municipality': 'Santa Maria', 'lat': 14.8164, 'lon': 120.9501},
    {'name': 'Barangay Buenavista', 'municipality': 'Santa Maria', 'lat': 14.8521, 'lon': 120.9934},
    {'name': 'Barangay Camangyanan', 'municipality': 'Santa Maria', 'lat': 14.8115, 'lon': 120.9412},
    {'name': 'Barangay Caysio', 'municipality': 'Santa Maria', 'lat': 14.8458, 'lon': 120.9812},
    {'name': 'Barangay Lalakhan', 'municipality': 'Santa Maria', 'lat': 14.8123, 'lon': 120.9621},
    {'name': 'Barangay Mag-asawang Sapa', 'municipality': 'Santa Maria', 'lat': 14.8711, 'lon': 121.0189},
    {'name': 'Barangay Mahabang Parang', 'municipality': 'Santa Maria', 'lat': 14.8654, 'lon': 121.0211},
    {'name': 'Barangay Manggahan', 'municipality': 'Santa Maria', 'lat': 14.8389, 'lon': 120.9689},
    {'name': 'Barangay Parada', 'municipality': 'Santa Maria', 'lat': 14.8012, 'lon': 120.9642},
    {'name': 'Barangay San Jose Patag', 'municipality': 'Santa Maria', 'lat': 14.8091, 'lon': 120.9782},
    {'name': 'Barangay San Vicente', 'municipality': 'Santa Maria', 'lat': 14.8291, 'lon': 120.9521},
    {'name': 'Barangay Silangan', 'municipality': 'Santa Maria', 'lat': 14.8412, 'lon': 121.0142},
    {'name': 'Barangay Tumana', 'municipality': 'Santa Maria', 'lat': 14.8178, 'lon': 120.9712},

    // Malolos City
    {'name': 'Barangay Guinhawa', 'municipality': 'Malolos', 'lat': 14.8569, 'lon': 120.8167},
    {'name': 'Barangay Liang', 'municipality': 'Malolos', 'lat': 14.8489, 'lon': 120.8123},
    {'name': 'Barangay San Agustin', 'municipality': 'Malolos', 'lat': 14.8411, 'lon': 120.8178},
    {'name': 'Barangay Sumapang Matanda', 'municipality': 'Malolos', 'lat': 14.8612, 'lon': 120.8251},
    {'name': 'Barangay Cofradia', 'municipality': 'Malolos', 'lat': 14.8689, 'lon': 120.8312},
    {'name': 'Barangay Bulihan', 'municipality': 'Malolos', 'lat': 14.8512, 'lon': 120.8354},
    {'name': 'Barangay Caingin', 'municipality': 'Malolos', 'lat': 14.8432, 'lon': 120.8211},
    {'name': 'Barangay Catmon', 'municipality': 'Malolos', 'lat': 14.8471, 'lon': 120.8192},
    {'name': 'Barangay Dakila', 'municipality': 'Malolos', 'lat': 14.8589, 'lon': 120.8412},
    {'name': 'Barangay Ligas', 'municipality': 'Malolos', 'lat': 14.8641, 'lon': 120.8491},
    {'name': 'Barangay Lugam', 'municipality': 'Malolos', 'lat': 14.8712, 'lon': 120.8211},
    {'name': 'Barangay Mabolo', 'municipality': 'Malolos', 'lat': 14.8391, 'lon': 120.8291},
    {'name': 'Barangay Mojon', 'municipality': 'Malolos', 'lat': 14.8621, 'lon': 120.8152},
    {'name': 'Barangay Panasahan', 'municipality': 'Malolos', 'lat': 14.8281, 'lon': 120.8241},
    {'name': 'Barangay Santisima Trinidad', 'municipality': 'Malolos', 'lat': 14.8541, 'lon': 120.8212},
    {'name': 'Barangay Santo Rosario', 'municipality': 'Malolos', 'lat': 14.8439, 'lon': 120.8115},
    {'name': 'Barangay Tikay', 'municipality': 'Malolos', 'lat': 14.8491, 'lon': 120.8482},

    // City of San Jose del Monte (CSJDM)
    {'name': 'Barangay Tungkong Mangga', 'municipality': 'San Jose del Monte', 'lat': 14.8021, 'lon': 121.0742},
    {'name': 'Barangay Muzon', 'municipality': 'San Jose del Monte', 'lat': 14.8062, 'lon': 121.0315},
    {'name': 'Barangay Gaya-Gaya', 'municipality': 'San Jose del Monte', 'lat': 14.8112, 'lon': 121.0541},
    {'name': 'Barangay Graceville', 'municipality': 'San Jose del Monte', 'lat': 14.8191, 'lon': 121.0421},
    {'name': 'Barangay Francisco Homes', 'municipality': 'San Jose del Monte', 'lat': 14.8212, 'lon': 121.0612},
    {'name': 'Barangay Kaypian', 'municipality': 'San Jose del Monte', 'lat': 14.8312, 'lon': 121.0712},
    {'name': 'Barangay Minuyan', 'municipality': 'San Jose del Monte', 'lat': 14.8251, 'lon': 121.0821},
    {'name': 'Barangay Sapang Palay', 'municipality': 'San Jose del Monte', 'lat': 14.8412, 'lon': 121.0651},
    {'name': 'Barangay Santo Cristo', 'municipality': 'San Jose del Monte', 'lat': 14.8091, 'lon': 121.0851},

    // Meycauayan City
    {'name': 'Barangay Calvario', 'municipality': 'Meycauayan', 'lat': 14.7391, 'lon': 120.9582},
    {'name': 'Barangay Camalig', 'municipality': 'Meycauayan', 'lat': 14.7451, 'lon': 120.9821},
    {'name': 'Barangay Iba', 'municipality': 'Meycauayan', 'lat': 14.7321, 'lon': 120.9841},
    {'name': 'Barangay Langka', 'municipality': 'Meycauayan', 'lat': 14.7491, 'lon': 120.9912},
    {'name': 'Barangay Lawa', 'municipality': 'Meycauayan', 'lat': 14.7312, 'lon': 120.9612},
    {'name': 'Barangay Malhacan', 'municipality': 'Meycauayan', 'lat': 14.7381, 'lon': 120.9712},
    {'name': 'Barangay Perez', 'municipality': 'Meycauayan', 'lat': 14.7412, 'lon': 120.9951},
    {'name': 'Barangay Saluysoy', 'municipality': 'Meycauayan', 'lat': 14.7351, 'lon': 120.9521},

    // Marilao
    {'name': 'Barangay Ibayo', 'municipality': 'Marilao', 'lat': 14.7551, 'lon': 120.9482},
    {'name': 'Barangay Lambakin', 'municipality': 'Marilao', 'lat': 14.7681, 'lon': 120.9712},
    {'name': 'Barangay Lias', 'municipality': 'Marilao', 'lat': 14.7612, 'lon': 120.9612},
    {'name': 'Barangay Loma de Gato', 'municipality': 'Marilao', 'lat': 14.7812, 'lon': 120.9982},
    {'name': 'Barangay Patubig', 'municipality': 'Marilao', 'lat': 14.7721, 'lon': 120.9551},
    {'name': 'Barangay Poblacion I', 'municipality': 'Marilao', 'lat': 14.7581, 'lon': 120.9512},
    {'name': 'Barangay Prenza I', 'municipality': 'Marilao', 'lat': 14.7791, 'lon': 120.9812},
    {'name': 'Barangay Saog', 'municipality': 'Marilao', 'lat': 14.7641, 'lon': 120.9421},
    {'name': 'Barangay Tabing Ilog', 'municipality': 'Marilao', 'lat': 14.7512, 'lon': 120.9541},

    // Bocaue
    {'name': 'Barangay Bagumbayan', 'municipality': 'Bocaue', 'lat': 14.7981, 'lon': 120.9291},
    {'name': 'Barangay Bambang', 'municipality': 'Bocaue', 'lat': 14.7921, 'lon': 120.9312},
    {'name': 'Barangay Batia', 'municipality': 'Bocaue', 'lat': 14.8151, 'lon': 120.9182},
    {'name': 'Barangay Bundukan', 'municipality': 'Bocaue', 'lat': 14.8021, 'lon': 120.9451},
    {'name': 'Barangay Lolomboy', 'municipality': 'Bocaue', 'lat': 14.7881, 'lon': 120.9412},
    {'name': 'Barangay Poblacion', 'municipality': 'Bocaue', 'lat': 14.7991, 'lon': 120.9341},
    {'name': 'Barangay Taal', 'municipality': 'Bocaue', 'lat': 14.8112, 'lon': 120.9381},
    {'name': 'Barangay Turo', 'municipality': 'Bocaue', 'lat': 14.8051, 'lon': 120.9281},

    // Guiguinto & Balagtas
    {'name': 'Barangay Tuktukan', 'municipality': 'Guiguinto', 'lat': 14.8321, 'lon': 120.8812},
    {'name': 'Barangay Tabang', 'municipality': 'Guiguinto', 'lat': 14.8412, 'lon': 120.8712},
    {'name': 'Barangay Santa Rita', 'municipality': 'Guiguinto', 'lat': 14.8351, 'lon': 120.8912},
    {'name': 'Barangay Wawa', 'municipality': 'Balagtas', 'lat': 14.8191, 'lon': 120.9082},
    {'name': 'Barangay Borol 1st', 'municipality': 'Balagtas', 'lat': 14.8112, 'lon': 120.9141},
    {'name': 'Barangay Santol', 'municipality': 'Balagtas', 'lat': 14.8251, 'lon': 120.9121},

    // Baliuag & Plaridel
    {'name': 'Barangay Poblacion', 'municipality': 'Baliuag', 'lat': 14.9541, 'lon': 120.9012},
    {'name': 'Barangay Subic', 'municipality': 'Baliuag', 'lat': 14.9612, 'lon': 120.8951},
    {'name': 'Barangay Bagong Nayon', 'municipality': 'Baliuag', 'lat': 14.9481, 'lon': 120.9051},
    {'name': 'Barangay Banga 1st', 'municipality': 'Plaridel', 'lat': 14.8871, 'lon': 120.8582},
    {'name': 'Barangay Poblacion', 'municipality': 'Plaridel', 'lat': 14.8891, 'lon': 120.8612},
    {'name': 'Barangay Dampol', 'municipality': 'Plaridel', 'lat': 14.9012, 'lon': 120.8451},
    {'name': 'Barangay Tabang', 'municipality': 'Plaridel', 'lat': 14.8781, 'lon': 120.8691},

    // Pandi & Norzagaray
    {'name': 'Barangay Poblacion', 'municipality': 'Pandi', 'lat': 14.8681, 'lon': 120.9572},
    {'name': 'Barangay Bunsuran 1st', 'municipality': 'Pandi', 'lat': 14.8812, 'lon': 120.9481},
    {'name': 'Barangay Masuso', 'municipality': 'Pandi', 'lat': 14.8721, 'lon': 120.9712},
    {'name': 'Barangay Poblacion', 'municipality': 'Norzagaray', 'lat': 14.9121, 'lon': 121.0421},
    {'name': 'Barangay Bigte', 'municipality': 'Norzagaray', 'lat': 14.8951, 'lon': 121.0612},
    {'name': 'Barangay Minuyan', 'municipality': 'Norzagaray', 'lat': 14.9041, 'lon': 121.0741},
  ];

  /// Instant local search matcher for Philippine & Bulacan Barangays
  List<Map<String, dynamic>> _fetchLocalBarangayCandidates(String query) {
    final clean = query
        .toLowerCase()
        .replaceAll(RegExp(r'\b(barangay|brgy\.?|bgy\.?)\b', caseSensitive: false), '')
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
    final lower = normalized.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
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
        'viewbox': '120.55,15.25,121.35,14.65', // Bias results toward Bulacan & Central Luzon
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
        String rawBrgy = (addr['suburb'] ??
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

        String city = (addr['city'] ??
                addr['town'] ??
                addr['municipality'] ??
                addr['county'] ??
                '')
            .toString()
            .trim();
        String province =
            (addr['state'] ?? addr['province'] ?? '').toString().trim();

        final type = (item['type'] ?? item['addresstype'] ?? '')
            .toString()
            .toLowerCase();
        final bool isBarangay = type == 'suburb' ||
            type == 'village' ||
            type == 'quarter' ||
            (rawBrgy.isNotEmpty &&
                (item['name'] ?? '')
                    .toString()
                    .toLowerCase()
                    .contains(rawBrgy.toLowerCase()));

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

        final String shortAddr =
            subParts.isNotEmpty ? subParts.join(', ') : displayName;
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
        setState(() => _suggestions = top5);
      }
    } catch (e) {
      print("Multi-Source Autocomplete Error: $e");
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
      _destination = _currentPosition;
    }

    setState(() {});
    if (_destination != null) {
      final start = (_originController.text == 'Your location' || _customOrigin == null)
          ? _currentPosition
          : _customOrigin;
      if (start != null) {
        _calculateRoute(_destination!, customOrigin: start);
      } else {
        _searchAndRoute();
      }
    } else if (_originController.text.isNotEmpty &&
        _searchController.text.isNotEmpty) {
      _searchAndRoute();
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
              (_originController.text.trim() == 'Your location' || _customOrigin == null)
                  ? _currentPosition
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

        String rawBrgy = (addr['suburb'] ??
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

        String city = (addr['city'] ??
                addr['town'] ??
                addr['municipality'] ??
                addr['county'] ??
                '')
            .toString()
            .trim();

        String province =
            (addr['province'] ?? addr['state'] ?? 'Bulacan').toString().trim();

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
              (_originController.text.trim() == 'Your location' || _customOrigin == null)
                  ? _currentPosition
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
    if (points.length < 3) return points;

    final LatLng lastPt = points.last;
    final LatLng secondLastPt = points[points.length - 2];

    final double lastSegDist = Geolocator.distanceBetween(
      secondLastPt.latitude,
      secondLastPt.longitude,
      lastPt.latitude,
      lastPt.longitude,
    );

    // If the last segment is a long off-road straight jump (> 35m) to an unsnapped destination coordinate,
    // trim the off-road jump so the route line ends cleanly on the road network
    if (lastSegDist > 35.0) {
      final double destDistToLast = Geolocator.distanceBetween(
        destination.latitude,
        destination.longitude,
        lastPt.latitude,
        lastPt.longitude,
      );
      if (destDistToLast < 10.0) {
        return points.sublist(0, points.length - 1);
      }
    }

    return points;
  }

  Future<LatLng?> _geocodeQuery(String query) async {
    final text = _normalizeQuery(query).replaceAll(
      RegExp(r'[\u0000-\u001F\u007F]'),
      ' ',
    ).trim();
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
        final fallbackUrl = Uri.https('nominatim.openstreetmap.org', '/search', {
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
          queryParams['focus.point.lat'] = _currentPosition!.latitude.toString();
          queryParams['focus.point.lon'] = _currentPosition!.longitude.toString();
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
    final double x = math.cos(lat1) * math.sin(lat2) -
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
        String? verifiedModifier = (rawModifier != null && rawModifier.trim().isNotEmpty)
            ? rawModifier.trim().toLowerCase()
            : null;
        final num? bBefore = maneuver['bearing_before'] as num?;
        final num? bAfter = maneuver['bearing_after'] as num?;

        if (verifiedModifier == null && bBefore != null && bAfter != null && type != 'arrive' && type != 'depart') {
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
        } else if (verifiedModifier == null && i > 0 && i < steps.length - 1 && type != 'arrive' && type != 'depart') {
          // Secondary Fallback: Calculate angle between previous step, this step, and next step locations
          final prevStep = steps[i - 1] as Map<String, dynamic>;
          final nextStep = steps[i + 1] as Map<String, dynamic>;
          final prevLocCoords = (prevStep['maneuver']?['location'] as List?) ?? [];
          final nextLocCoords = (nextStep['maneuver']?['location'] as List?) ?? [];
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
  }) async {
    LatLng? start = customOrigin ?? _customOrigin;
    if (start == null) {
      if (_originController.text == 'Your location' ||
          _originController.text.trim().isEmpty) {
        start = _currentPosition;
      } else {
        start = await _geocodeQuery(_originController.text);
        if (start != null) {
          _customOrigin = start;
        } else {
          start = _currentPosition;
        }
      }
    }

    if (start == null) return;
    setState(() {
      _isRouting = true;
      _alternativeRoutes = [];
      _routePotholeCounts = [];
      _routeSteps = [];
      _alternativeRouteSteps = [];
    });

    List<List<LatLng>> routes = [];
    List<double> durations = [];
    List<double> distances = [];
    List<List<RouteStep>> stepsByRoute = [];

    // 1. Primary: Project-OSRM Routing Engine API with 3 Travel Modes
    try {
      Uri osrmUrl;
      if (_travelMode == OsrmTravelMode.bike) {
        osrmUrl = Uri.parse(
          'https://routing.openstreetmap.de/routed-bike/route/v1/driving/'
          '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&alternatives=true&steps=true&annotations=true',
        );
      } else if (_travelMode == OsrmTravelMode.foot) {
        osrmUrl = Uri.parse(
          'https://routing.openstreetmap.de/routed-foot/route/v1/driving/'
          '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&alternatives=true&steps=true&annotations=true',
        );
      } else {
        osrmUrl = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/'
          '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&alternatives=true&steps=true&annotations=true',
        );
      }

      var osrmRes = await http.get(osrmUrl).timeout(const Duration(seconds: 6));
      if (osrmRes.statusCode != 200 && _travelMode != OsrmTravelMode.car) {
        final fallbackUrl = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/'
          '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&alternatives=true&steps=true&annotations=true',
        );
        osrmRes = await http
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

        final response = await http
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

    if (routes.isEmpty || durations.isEmpty) {
      setState(() => _isRouting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("📍 Unable to calculate route to destination."),
            backgroundColor: Colors.red,
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
          if (!_useMockLocation) {
            _currentPosition = livePosition;
            _cachedGlobalPosition = livePosition;
          }
          _isLoadingLocation = false;
        });
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

    final isApproved = pothole.status == 'approved';
    final isRejected = pothole.status == 'rejected';

    final Color statusBg = isApproved
        ? AppDesign.accent(AppSettings.instance.isDarkMode)
        : (isRejected ? AppDesign.danger : AppDesign.warning);
    final IconData statusIcon = isApproved
        ? Icons.verified_rounded
        : (isRejected ? Icons.cancel_rounded : Icons.pending_actions_rounded);
    final String statusLabel = isApproved
        ? 'VERIFIED HAZARD'
        : (isRejected ? 'REJECTED REPORT' : 'PENDING VERIFICATION');

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
            color: AppDesign.surface(AppSettings.instance.isDarkMode),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(
              color: AppDesign.border(AppSettings.instance.isDarkMode),
              width: 1.2,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 30,
                spreadRadius: 5,
                offset: Offset(0, -10),
              ),
            ],
          ),
          child: Column(
            children: [
              // Drag Handle
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: const Color(0xFF475569),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),

              // Enterprise Header Bar
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: statusBg.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: statusBg.withValues(alpha: 0.6),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon, color: statusBg, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            statusLabel,
                            style: TextStyle(
                              color: statusBg,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'INSPECTION REPORT',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppDesign.textPrimary(
                            AppSettings.instance.isDarkMode,
                          ),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => Navigator.of(ctx).pop(),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppDesign.surface(
                              AppSettings.instance.isDarkMode,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.close_rounded,
                            color: AppDesign.textSecondary(
                              AppSettings.instance.isDarkMode,
                            ),
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Divider(
                color: AppDesign.border(AppSettings.instance.isDarkMode),
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
                          height: 230,
                          decoration: BoxDecoration(
                            color: AppDesign.surface(
                              AppSettings.instance.isDarkMode,
                            ),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: AppDesign.border(
                                AppSettings.instance.isDarkMode,
                              ),
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 12,
                                offset: Offset(0, 4),
                              ),
                            ],
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
                                                color: AppDesign.surface(
                                                  AppSettings
                                                      .instance
                                                      .isDarkMode,
                                                ),
                                                child: Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                        color: AppDesign.accent(
                                                          AppSettings
                                                              .instance
                                                              .isDarkMode,
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

                              // Bottom Gradient Overlay & Zoom Hint
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
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (pothole.imagePath.isNotEmpty)
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.zoom_in_rounded,
                                              color: AppDesign.textSecondary(
                                                AppSettings.instance.isDarkMode,
                                              ),
                                              size: 14,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              'Tap to Expand',
                                              style: TextStyle(
                                                color: AppDesign.textSecondary(
                                                  AppSettings
                                                      .instance
                                                      .isDarkMode,
                                                ),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
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

                      const SizedBox(height: 20),

                      // Section Title
                      Text(
                        'HAZARD TELEMETRY & ATTRIBUTION',
                        style: TextStyle(
                          color: AppDesign.textSecondary(
                            AppSettings.instance.isDarkMode,
                          ),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Telemetry Cards Grid
                      if (isAdminUser) ...[
                        Row(
                          children: [
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.explore_rounded,
                                iconColor: AppDesign.accent(
                                  AppSettings.instance.isDarkMode,
                                ),
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
                                    SnackBar(
                                      content: const Text(
                                        'Coordinates copied to clipboard!',
                                      ),
                                      backgroundColor: AppDesign.accent(
                                        AppSettings.instance.isDarkMode,
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.person_pin_rounded,
                                iconColor: const Color(0xFF34D399),
                                title: 'REPORTED BY',
                                value:
                                    pothole.reporterEmail ?? 'RoadSense Surveyor',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.schedule_rounded,
                                iconColor: const Color(0xFFFBBF24),
                                title: 'DETECTION TIMESTAMP',
                                value:
                                    '${pothole.timestamp.year}-${pothole.timestamp.month.toString().padLeft(2, '0')}-${pothole.timestamp.day.toString().padLeft(2, '0')} ${pothole.timestamp.hour.toString().padLeft(2, '0')}:${pothole.timestamp.minute.toString().padLeft(2, '0')}',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.warning_amber_rounded,
                                iconColor: AppDesign.danger,
                                title: 'HAZARD IMPACT',
                                value: 'Class 1 Obstruction Zone',
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.explore_rounded,
                                iconColor: AppDesign.accent(
                                  AppSettings.instance.isDarkMode,
                                ),
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
                                    SnackBar(
                                      content: const Text(
                                        'Coordinates copied to clipboard!',
                                      ),
                                      backgroundColor: AppDesign.accent(
                                        AppSettings.instance.isDarkMode,
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.schedule_rounded,
                                iconColor: const Color(0xFFFBBF24),
                                title: 'DETECTION TIMESTAMP',
                                value:
                                    '${pothole.timestamp.year}-${pothole.timestamp.month.toString().padLeft(2, '0')}-${pothole.timestamp.day.toString().padLeft(2, '0')} ${pothole.timestamp.hour.toString().padLeft(2, '0')}:${pothole.timestamp.minute.toString().padLeft(2, '0')}',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.warning_amber_rounded,
                                iconColor: AppDesign.danger,
                                title: 'HAZARD IMPACT',
                                value: 'Class 1 Obstruction Zone',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.speed_rounded,
                                iconColor: const Color(0xFF38BDF8),
                                title: 'SEVERITY LEVEL',
                                value: pothole.overallSeverity.toUpperCase(),
                              ),
                            ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 18),

                      // Official DPWH Specifications Section
                      Text(
                        'DPWH ROAD MAINTENANCE SPECIFICATIONS',
                        style: TextStyle(
                          color: AppDesign.textSecondary(
                            AppSettings.instance.isDarkMode,
                          ),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 10),

                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode)
                              .withValues(alpha: AppSettings.instance.isDarkMode ? 0.12 : 0.07),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode)
                                .withValues(alpha: 0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    pothole.primaryDpwhCode,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    pothole.primaryDefect,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: AppDesign.textPrimary(AppSettings.instance.isDarkMode),
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2563EB).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: const Color(0xFF2563EB)),
                                  ),
                                  child: Text(
                                    'SLA: ${pothole.responseTime}',
                                    style: const TextStyle(
                                      color: Color(0xFF2563EB),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Standard Corrective Measure:',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppDesign.textSecondary(AppSettings.instance.isDarkMode),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              pothole.correctiveMeasure,
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.35,
                                color: AppDesign.textPrimary(AppSettings.instance.isDarkMode),
                              ),
                            ),
                            if (pothole.detections != null && pothole.detections!.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Divider(
                                color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode)
                                    .withValues(alpha: 0.25),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'AI Detected Hazards in Frame (${pothole.detections!.length}):',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppDesign.textSecondary(AppSettings.instance.isDarkMode),
                                ),
                              ),
                              const SizedBox(height: 6),
                              ...pothole.detections!.map((d) {
                                final dCode = d['dpwhCode'] as String? ?? 'CODE 01';
                                final dName = d['defectType'] as String? ?? d['className'] as String? ?? 'Hazard';
                                final dConf = (d['confidence'] as num?)?.toDouble() ?? 0.0;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2.5),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.check_circle_rounded,
                                        size: 13,
                                        color: DpwhStandards.getCodeColor(dCode),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '[$dCode] $dName',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: AppDesign.textPrimary(AppSettings.instance.isDarkMode),
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        dConf > 0
                                            ? '${(dConf > 1 ? dConf : dConf * 100).toStringAsFixed(0)}% confidence'
                                            : 'Detected',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: AppDesign.textSecondary(AppSettings.instance.isDarkMode),
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
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppSettings.instance.isDarkMode
                              ? const Color(0xFF1E293B).withValues(alpha: 0.75)
                              : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: AppSettings.instance.isDarkMode
                                ? const Color(0xFF334155).withValues(alpha: 0.8)
                                : const Color(0xFFE2E8F0),
                            width: 1.2,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.people_alt_rounded,
                                    size: 13,
                                    color: Color(0xFF0284C7),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'COMMUNITY VERIFICATION',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.0,
                                    color: AppDesign.textSecondary(AppSettings.instance.isDarkMode),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Help fellow drivers keep road maps accurate. Is this hazard still here?',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: AppDesign.textPrimary(AppSettings.instance.isDarkMode),
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
                                      onTap: () => _submitHazardFeedback(pothole, true),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF10B981).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: const Color(0xFF10B981).withValues(alpha: 0.6),
                                            width: 1.2,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.thumb_up_alt_rounded, size: 15, color: Color(0xFF10B981)),
                                            SizedBox(width: 6),
                                            Text(
                                              'Still There',
                                              style: TextStyle(
                                                fontSize: 12,
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
                                      onTap: () => _submitHazardFeedback(pothole, false),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: const Color(0xFFEF4444).withValues(alpha: 0.6),
                                            width: 1.2,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.thumb_down_alt_rounded, size: 15, color: Color(0xFFEF4444)),
                                            SizedBox(width: 6),
                                            Text(
                                              'Fixed / Gone',
                                              style: TextStyle(
                                                fontSize: 12,
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

                      // Admin Administrative Bar
                      if (isAdminUser) ...[
                        const SizedBox(height: 24),
                        Divider(
                          color: AppDesign.border(
                            AppSettings.instance.isDarkMode,
                          ),
                        ),
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
                                    backgroundColor: AppDesign.accent(
                                      AppSettings.instance.isDarkMode,
                                    ),
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
                            if (pothole.docId != null) ...[
                              Expanded(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF2563EB),
                                    side: const BorderSide(
                                      color: Color(0xFF2563EB),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.edit_note_rounded,
                                    size: 18,
                                  ),
                                  label: const Text(
                                    'Edit',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  onPressed: () {
                                    Navigator.of(ctx).pop();
                                    _showEditPotholeDialog(pothole);
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

  Future<void> _showEditPotholeDialog(PotholeMarker pothole) async {
    if (pothole.docId == null) return;
    final isDark = AppSettings.instance.isDarkMode;
    String selectedSeverity = pothole.overallSeverity.toLowerCase();
    int potholeCount = pothole.potholeCount;
    final noteController = TextEditingController();

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
                      Text(
                        'Overall Severity',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppDesign.textPrimary(isDark),
                        ),
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        value: selectedSeverity,
                        dropdownColor: AppDesign.surface(isDark),
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'low',
                            child: Text('Low Severity'),
                          ),
                          DropdownMenuItem(
                            value: 'medium',
                            child: Text('Medium Severity'),
                          ),
                          DropdownMenuItem(
                            value: 'high',
                            child: Text('High Severity'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() => selectedSeverity = val);
                          }
                        },
                      ),
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
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
                      Text(
                        'Maintenance / Review Notes',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppDesign.textPrimary(isDark),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: noteController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          hintText: 'Add or update hazard notes...',
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
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
                        overallSeverity: selectedSeverity,
                        potholeCount: potholeCount,
                        note: noteController.text.trim(),
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
          destLoc = _currentPosition;
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
        originLoc = _currentPosition;
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

      if (destLoc == null) {
        throw 'Destination location unavailable.';
      }
      if (originLoc == null) {
        throw 'Current location unavailable.';
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
    if (widget.onDeleteDetectedPothole == null) {
      throw StateError('Delete callback is not configured.');
    }

    // Cleanup cache before letting parent handle state
    setState(() {
      _snappedPotholeCache.remove(_potholeKey(pothole.location));
    });

    await widget.onDeleteDetectedPothole!(pothole);
    await _refreshRouteAwarePotholeState();
  }

  double _getDynamicMarkerSize() {
    double zoom = 15.0;
    try {
      zoom = _mapController.camera.zoom;
    } catch (_) {}

    if (zoom < 10) return 14.0;
    if (zoom < 12) return 20.0;
    if (zoom < 14) return 28.0;
    if (zoom < 16) return 36.0;
    return 44.0;
  }

  Widget _buildUnifiedPotholeIcon({
    String status = 'approved',
    String severity = 'medium',
    int count = 1,
    double size = 38.0,
    bool isSelected = false,
  }) {
    Color iconColor;
    IconData iconData;
    if (status == 'pending') {
      iconColor = const Color(0xFFF59E0B);
      iconData = Icons.pending_actions_rounded;
    } else if (status == 'rejected') {
      iconColor = Colors.grey;
      iconData = Icons.block_rounded;
    } else {
      if (severity == 'high') {
        iconColor = const Color(0xFFEF4444);
        iconData = Icons.dangerous_rounded;
      } else if (severity == 'low') {
        iconColor = const Color(0xFFEAB308);
        iconData = Icons.warning_amber_rounded;
      } else {
        iconColor = const Color(0xFFF97316);
        iconData = Icons.warning_rounded;
      }
    }

    final isDark = AppSettings.instance.isDarkMode;
    final double iconInnerSize = (size * 0.52).clamp(8.0, 26.0);
    final double borderWidth = isSelected ? 3.0 : (size < 20 ? 1.0 : 2.2);
    final double padding = size < 28 ? 2.0 : 4.0;

    final pinWidget = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppDesign.surface(isDark),
        shape: BoxShape.circle,
        border: Border.all(
          color: isSelected
              ? (status == 'approved'
                    ? const Color(0xFF10B981)
                    : const Color(0xFFF59E0B))
              : iconColor,
          width: borderWidth,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.2),
            blurRadius: isSelected ? 8 : 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: EdgeInsets.all(padding),
      child: Center(
        child: Icon(iconData, size: iconInnerSize, color: iconColor),
      ),
    );

    if (status == 'pending' && size >= 24) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          pinWidget,
          Positioned(
            top: -4,
            right: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white, width: 1.2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 8,
                    color: Colors.white,
                  ),
                  SizedBox(width: 2),
                  Text(
                    'YOU',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 7.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (count > 1 && size >= 24) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          pinWidget,
          Positioned(
            top: -2,
            right: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: iconColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 1.2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return pinWidget;
  }

  /// Groups potholes within a 10-meter barrier tolerance radius into clusters.
  /// When multiple potholes (approved and/or pending) exist nearby, they form
  /// a unified spider cluster to eliminate any overlapping pins on the map.
  List<PotholeCluster> _clusterPotholes(
    List<PotholeMarker> potholes, {
    double radiusMeters = 10.0,
  }) {
    if (potholes.isEmpty) return [];

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
          .map((p) => '${p.id ?? p.docId ?? p.timestamp.millisecondsSinceEpoch}')
          .join('_');

      clusters.add(PotholeCluster(id: id, center: center, items: group));
    }

    return clusters;
  }

  List<PotholeCluster>? _cachedPotholeClusters;
  int _cachedPotholeSignature = 0;

  /// Memoizes cluster generation so O(N^2) geodesic calculations only run
  /// when the pothole collection is modified, rather than on every animation frame.
  List<PotholeCluster> _getMemoizedClusters() {
    final active = widget.detectedPotholes.where((p) {
      if (p.status == 'deleted' || p.status == 'rejected') return false;
      if (_selectedHazardCategory == 'All') return true;
      final defect = p.primaryDefect.toLowerCase();
      final code = p.primaryDpwhCode.toLowerCase();
      if (_selectedHazardCategory == 'Potholes') {
        return defect.contains('pothole') || code.contains('01');
      } else if (_selectedHazardCategory == 'Flooding') {
        return defect.contains('flood') || defect.contains('water') || code.contains('05');
      } else if (_selectedHazardCategory == 'Road Works') {
        return defect.contains('work') || defect.contains('construct') || defect.contains('crack') || defect.contains('ravel') || code.contains('02') || code.contains('03');
      }
      return true;
    }).toList();

    int signature = active.length ^ _selectedHazardCategory.hashCode;
    for (int i = 0; i < active.length; i++) {
      final p = active[i];
      signature = 31 * signature +
          (p.docId?.hashCode ?? p.timestamp.millisecondsSinceEpoch);
    }

    if (_cachedPotholeClusters != null && _cachedPotholeSignature == signature) {
      return _cachedPotholeClusters!;
    }

    _cachedPotholeSignature = signature;
    _cachedPotholeClusters = _clusterPotholes(active, radiusMeters: 10.0);
    return _cachedPotholeClusters!;
  }

  /// Culls markers that are far outside the camera's viewport (+2km buffer)
  /// to dramatically reduce Flutter layer tree memory and eliminate pan jank.
  Iterable<PotholeCluster> _getVisibleClusters() {
    final clusters = _getMemoizedClusters();
    try {
      final camera = _mapController.camera;
      final bounds = camera.visibleBounds;
      const double margin = 0.02; // ~2.2km buffer to prevent edge pop-in
      final south = bounds.south - margin;
      final north = bounds.north + margin;
      final west = bounds.west - margin;
      final east = bounds.east + margin;

      return clusters.where((c) {
        final lat = c.center.latitude;
        final lng = c.center.longitude;
        return lat >= south && lat <= north && lng >= west && lng <= east;
      });
    } catch (_) {
      return clusters;
    }
  }

  /// Builds the radial Spider Tree marker with connecting stems and anchor ring
  Widget _buildSpiderClusterMarker(
    PotholeCluster cluster,
    bool isDark,
  ) {
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

          // 2. Center Anchor Ring (Hollow circle with teal border matching reference image)
          Positioned(
            left: centerXY - 12,
            top: centerXY - 12,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _expandedClusterId = null;
                });
              },
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? const Color(0xFF0F172A) : Colors.white,
                  border: Border.all(
                    color: const Color(0xFF00796B),
                    width: 3.2,
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
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF00796B),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 3. Child Pothole Nodes
          for (int i = 0; i < count; i++) ...[
            Positioned(
              left: centerXY + childOffsets[i].dx - 15,
              top: centerXY + childOffsets[i].dy - 15,
              child: GestureDetector(
                onTap: () {
                  final item = cluster.items[i];
                  setState(() {
                    _selectedPothole = item;
                  });
                },
                child: _buildSpiderChildNode(
                  pothole: cluster.items[i],
                  isSelected: _selectedPothole == cluster.items[i] ||
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
  }) {
    Color nodeColor = const Color(0xFF9333EA);
    IconData nodeIcon = Icons.warning_rounded;

    if (pothole.status == 'pending') {
      nodeColor = const Color(0xFFF59E0B);
      nodeIcon = Icons.schedule_rounded;
    } else if (pothole.status == 'rejected') {
      nodeColor = Colors.grey;
      nodeIcon = Icons.block_rounded;
    } else {
      if (pothole.overallSeverity == 'high') {
        nodeColor = const Color(0xFFEF4444);
        nodeIcon = Icons.dangerous_rounded;
      } else if (pothole.overallSeverity == 'low') {
        nodeColor = const Color(0xFFEAB308);
        nodeIcon = Icons.warning_amber_rounded;
      } else {
        nodeColor = const Color(0xFFF97316);
        nodeIcon = Icons.warning_rounded;
      }
    }

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: nodeColor,
        border: Border.all(
          color: isSelected ? const Color(0xFF10B981) : Colors.white,
          width: isSelected ? 3.0 : 2.0,
        ),
        boxShadow: [
          BoxShadow(
            color: isSelected
                ? const Color(0xFF10B981).withValues(alpha: 0.6)
                : Colors.black38,
            blurRadius: isSelected ? 8 : 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Icon(
          nodeIcon,
          size: 16,
          color: Colors.white,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
            final int activePotholeCount = (_destination != null || _routePoints.isNotEmpty)
                ? (activeRouteIndex < _routePotholeCounts.length && _routePotholeCounts[activeRouteIndex] > 0
                    ? _routePotholeCounts[activeRouteIndex]
                    : _potholesOnRoute.length)
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
            final bool shouldHideBottomNav = _routePoints.isNotEmpty ||
                _isNavigating ||
                _selectedPothole != null ||
                _isPlacingMarker ||
                _isEditingDevLocation ||
                _isChoosingLocationOnMap ||
                _isSearchPageActive;

            AppSettings.instance.setRouteActive(shouldHideBottomNav);

            // Compute safe bottom offsets accounting for floating bottom navigation bar and mobile SafeArea
            final double bottomInset = MediaQuery.paddingOf(context).bottom;
            final double baseBottomOffset = shouldHideBottomNav
                ? (bottomInset + 12.0)
                : (88.0 + bottomInset + 8.0);
            final double actionButtonsBottom = _routePoints.isNotEmpty
                ? (baseBottomOffset +
                      (_isRouteDockMinimized
                          ? 54.0
                          : (_isRouteSheetExpanded ? 240.0 : 136.0)))
                : (_selectedPothole != null)
                ? (baseBottomOffset + 136.0)
                : (_searchedPlace != null ||
                      _isPlacingMarker ||
                      _isEditingDevLocation)
                ? (baseBottomOffset + 110.0)
                : (baseBottomOffset + 4.0);

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
                            onPointerDown: (_) {
                              if (!_isMapDragging && mounted) {
                                setState(() => _isMapDragging = true);
                              }
                            },
                            onPointerUp: (_) {
                              if (_isMapDragging && mounted) {
                                setState(() => _isMapDragging = false);
                              }
                            },
                            onPointerCancel: (_) {
                              if (_isMapDragging && mounted) {
                                setState(() => _isMapDragging = false);
                              }
                            },
                            child: FlutterMap(
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter:
                                    _currentPosition ?? _bulacanCenter,
                                initialZoom: 15.0,
                                minZoom: 3.0,
                                maxZoom: 19.0,
                                interactionOptions: const InteractionOptions(
                                  flags: InteractiveFlag.all,
                                  pinchMoveThreshold: 35.0,
                                  scrollWheelVelocity: 0.005,
                                ),
                                onPositionChanged: _onMapPositionChanged,
                                onTap: (_, point) {
                                  if (_isPlacingMarker) {
                                    setState(
                                      () => _pendingMarkerLocation = point,
                                    );
                                  } else if (_isEditingDevLocation) {
                                    setState(() => _pendingDevLocation = point);
                                  } else {
                                    // Check if user tapped directly on an alternative route line
                                    if (_alternativeRoutes.length > 1) {
                                      int? tappedIndex;
                                      double minD = double.infinity;
                                      final double zoom =
                                          _mapController.camera.zoom;
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
                                  }
                                },
                              ),
                              children: [
                                TileLayer(
                                  urlTemplate:
                                      'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}',
                                  subdomains: const ['0', '1', '2', '3'],
                                  userAgentPackageName:
                                      'com.example.pothole_scanner',
                                  tileDisplay: const TileDisplay.fadeIn(
                                    duration: Duration(milliseconds: 100),
                                  ),
                                  panBuffer: 2,
                                  keepBuffer: 6,
                                  minZoom: 3,
                                  maxZoom: 20,
                                  maxNativeZoom: 20,
                                ),
                                // Route Polylines (Google Maps Style: Bold Main + Faint Alternatives)
                                if (_alternativeRoutes.isNotEmpty)
                                  PolylineLayer(
                                    polylines: [
                                      // 1. Draw unselected alternative routes as faint slate/grey lines
                                      ..._alternativeRoutes
                                          .asMap()
                                          .entries
                                          .where(
                                            (e) => e.key != _selectedRouteIndex,
                                          )
                                          .map((e) {
                                            return Polyline(
                                              points: e.value,
                                              color: isDark
                                                  ? const Color(
                                                      0xFF475569,
                                                    ).withValues(alpha: 0.8)
                                                  : const Color(
                                                      0xFF94A3B8,
                                                    ).withValues(alpha: 0.85),
                                              strokeWidth: 5.5,
                                              strokeCap: StrokeCap.round,
                                              strokeJoin: StrokeJoin.round,
                                            );
                                          }),
                                      // 2. Draw selected main route with Google Blue glow & core
                                      Polyline(
                                        points: activeRoutePolyline,
                                        color: const Color(
                                          0xFF1557A6,
                                        ).withValues(alpha: 0.5),
                                        strokeWidth: 11.5,
                                        strokeCap: StrokeCap.round,
                                        strokeJoin: StrokeJoin.round,
                                      ),
                                      Polyline(
                                        points: activeRoutePolyline,
                                        color: const Color(0xFF1A73E8),
                                        strokeWidth: 6.5,
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
                                        key: ValueKey(
                                          'user_circle_${effectivePos.latitude}_${effectivePos.longitude}_$_inProximityWarning',
                                        ),
                                        circles: [
                                          CircleMarker(
                                            point: effectivePos,
                                            radius:
                                                _proximityCircleRadiusMeters,
                                            useRadiusInMeter: true,
                                            color: _inProximityWarning
                                                ? Colors.red.withValues(
                                                    alpha: 0.5,
                                                  )
                                                : Colors.blue.withValues(
                                                    alpha: 0.15,
                                                  ),
                                            borderColor: _inProximityWarning
                                                ? Colors.red.withValues(
                                                    alpha: 0.9,
                                                  )
                                                : const Color(0xAA1E88E5),
                                            borderStrokeWidth:
                                                _inProximityWarning ? 6 : 3,
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                // Blue user location marker (60 FPS smooth interpolation + breathing radar halo)
                                ValueListenableBuilder<LatLng?>(
                                  valueListenable: _animatedPuckPositionNotifier,
                                  builder: (context, puckPos, _) {
                                    final effectivePos =
                                        puckPos ?? _currentPosition;
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
                                          child: ValueListenableBuilder<double?>(
                                            valueListenable:
                                                _lastHeadingNotifier,
                                            builder: (
                                              context,
                                              headingValue,
                                              child,
                                            ) {
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
                                                // 1. Google Maps Breathing Radar Pulse Halo
                                                AnimatedBuilder(
                                                  animation:
                                                      _puckPulseController,
                                                  builder: (context, _) {
                                                    final t =
                                                        _puckPulseController
                                                            .value;
                                                    final haloSize =
                                                        22.0 + t * 42.0;
                                                    final haloOpacity =
                                                        (1.0 - t) * 0.42;
                                                    return Container(
                                                      width: haloSize,
                                                      height: haloSize,
                                                      decoration: BoxDecoration(
                                                        shape: BoxShape.circle,
                                                        color: const Color(
                                                          0xFF1A73E8,
                                                        ).withValues(
                                                          alpha: haloOpacity,
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                                // 2. Directional Vision Cone (Always Visible)
                                                CustomPaint(
                                                  size: const Size(160, 160),
                                                  painter: VisionConePainter(),
                                                ),
                                                // 3. Center Dot (Google Maps Style Blue Dot)
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
                                                  (_selectedPothole!.docId !=
                                                          null &&
                                                      pothole.docId != null &&
                                                      _selectedPothole!.docId ==
                                                          pothole.docId) ||
                                                  (_selectedPothole!
                                                              .location
                                                              .latitude ==
                                                          pothole
                                                              .location
                                                              .latitude &&
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

                                          return Marker(
                                            key: ValueKey(
                                              'detected_${pothole.id ?? pothole.docId ?? pothole.timestamp.millisecondsSinceEpoch}',
                                            ),
                                            point: pothole.location,
                                            width: dynamicSize,
                                            height: dynamicSize,
                                            child: GestureDetector(
                                              onTap: () {
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
                                              child: _buildUnifiedPotholeIcon(
                                                status: pothole.status,
                                                severity:
                                                    pothole.overallSeverity,
                                                count: pothole.potholeCount,
                                                size: dynamicSize,
                                                isSelected: isSelected,
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
                                          final double boxSize =
                                              (radius + 28.0) * 2;

                                          return Marker(
                                            key: ValueKey(
                                              'spider_${cluster.id}',
                                            ),
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
                                          return Marker(
                                            key: ValueKey(
                                              'cluster_${cluster.id}',
                                            ),
                                            point: cluster.center,
                                            width: 44,
                                            height: 44,
                                            child: GestureDetector(
                                              onTap: () {
                                                setState(() {
                                                  _expandedClusterId =
                                                      cluster.id;
                                                });
                                                _animatedMapMove(
                                                  cluster.center,
                                                  _mapController.camera.zoom
                                                      .clamp(16.0, 18.5),
                                                );
                                              },
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                children: [
                                                  Container(
                                                    width: 38,
                                                    height: 38,
                                                    decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color: const Color(
                                                        0xFF9333EA,
                                                      ),
                                                      border: Border.all(
                                                        color: Colors.white,
                                                        width: 2.2,
                                                      ),
                                                      boxShadow: const [
                                                        BoxShadow(
                                                          color:
                                                              Colors.black38,
                                                          blurRadius: 6,
                                                          offset: Offset(
                                                            0,
                                                            2,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    child: const Center(
                                                      child: Icon(
                                                        Icons.hub_rounded,
                                                        color: Colors.white,
                                                        size: 18,
                                                      ),
                                                    ),
                                                  ),
                                                  Positioned(
                                                    top: -2,
                                                    right: -2,
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets
                                                              .symmetric(
                                                        horizontal: 5,
                                                        vertical: 1.5,
                                                      ),
                                                      decoration:
                                                          BoxDecoration(
                                                        color: const Color(
                                                          0xFF00796B,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(10),
                                                        border: Border.all(
                                                          color: Colors.white,
                                                          width: 1.2,
                                                        ),
                                                        boxShadow: const [
                                                          BoxShadow(
                                                            color: Colors
                                                                .black26,
                                                            blurRadius: 3,
                                                            offset: Offset(
                                                              0,
                                                              1,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                      child: Text(
                                                        '${cluster.items.length}',
                                                        style:
                                                            const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 9.5,
                                                          fontWeight:
                                                              FontWeight.bold,
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

                                    // Custom Start Location Pin (Blue)
                                    if (_customOrigin != null)
                                      Marker(
                                        key: const ValueKey(
                                          'custom_origin_start_marker',
                                        ),
                                        point: _customOrigin!,
                                        width: 44,
                                        height: 44,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF1A73E8),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 3,
                                            ),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Colors.black38,
                                                blurRadius: 10,
                                                offset: Offset(0, 3),
                                              ),
                                            ],
                                          ),
                                          child: const Icon(
                                            Icons.my_location_rounded,
                                            color: Colors.white,
                                            size: 22,
                                          ),
                                        ),
                                      ),

                                    // Destination Location Pin (Red)
                                    if (_destination != null)
                                      Marker(
                                        key: const ValueKey(
                                          'destination_end_marker',
                                        ),
                                        point: _destination!,
                                        width: 44,
                                        height: 44,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFEA4335),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 3,
                                            ),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Colors.black38,
                                                blurRadius: 10,
                                                offset: Offset(0, 3),
                                              ),
                                            ],
                                          ),
                                          child: const Icon(
                                            Icons.location_on_rounded,
                                            color: Colors.white,
                                            size: 24,
                                          ),
                                        ),
                                      ),

                                    // Active Selected Turn-by-Turn Maneuver Waypoint Dot (Translucent Halo + High-Visibility Core Dot)
                                    if (_selectedStepIndex != null &&
                                        _routeSteps.isNotEmpty &&
                                        _selectedStepIndex! <
                                            _routeSteps.length)
                                      Marker(
                                        key: ValueKey(
                                          'active_step_marker_$_selectedStepIndex',
                                        ),
                                        point: _routeSteps[_selectedStepIndex!]
                                            .location,
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
                                                  color: const Color(0xFF2563EB)
                                                      .withValues(alpha: 0.25),
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

                                    // Google Maps Style Floating Route Duration & Selection Badges
                                    if (_alternativeRoutes.length > 1) ...[
                                      for (
                                        int rIdx = 0;
                                        rIdx < _alternativeRoutes.length;
                                        rIdx++
                                      )
                                        if (_alternativeRoutes[rIdx].length > 2)
                                          Marker(
                                            key: ValueKey(
                                              'route_eta_badge_$rIdx',
                                            ),
                                            point:
                                                _alternativeRoutes[rIdx][_alternativeRoutes[rIdx]
                                                        .length ~/
                                                    2],
                                            width: 105,
                                            height: 38,
                                            child: GestureDetector(
                                              onTap: () =>
                                                  _selectActiveRoute(rIdx),
                                              child: AnimatedContainer(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 4,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color:
                                                      rIdx ==
                                                          _selectedRouteIndex
                                                      ? const Color(0xFF1A73E8)
                                                      : (isDark
                                                            ? const Color(
                                                                0xFF1E293B,
                                                              )
                                                            : Colors.white),
                                                  borderRadius:
                                                      BorderRadius.circular(18),
                                                  border: Border.all(
                                                    color:
                                                        rIdx ==
                                                            _selectedRouteIndex
                                                        ? Colors.white
                                                        : (isDark
                                                              ? const Color(
                                                                  0xFF475569,
                                                                )
                                                              : const Color(
                                                                  0xFFCBD5E1,
                                                                )),
                                                    width:
                                                        rIdx ==
                                                            _selectedRouteIndex
                                                        ? 2.0
                                                        : 1.2,
                                                  ),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color:
                                                          rIdx ==
                                                              _selectedRouteIndex
                                                          ? const Color(
                                                              0xFF1A73E8,
                                                            ).withValues(
                                                              alpha: 0.45,
                                                            )
                                                          : Colors.black26,
                                                      blurRadius: 6,
                                                      offset: const Offset(
                                                        0,
                                                        2,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    Icon(
                                                      _travelMode ==
                                                              OsrmTravelMode
                                                                  .bike
                                                          ? Icons
                                                                .directions_bike_rounded
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
                                                          : (isDark
                                                                ? Colors.white70
                                                                : const Color(
                                                                    0xFF5F6368,
                                                                  )),
                                                    ),
                                                    const SizedBox(width: 4),
                                                    Text(
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
                                                                            _routeDistances.length
                                                                        ? _routeDistances[rIdx]
                                                                        : 0,
                                                                    potholeCount:
                                                                        rIdx <
                                                                            _routePotholeCounts.length
                                                                        ? _routePotholeCounts[rIdx]
                                                                        : 0,
                                                                  ))
                                                          : 'Route ${rIdx + 1}',
                                                      style: TextStyle(
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color:
                                                            rIdx ==
                                                                _selectedRouteIndex
                                                            ? Colors.white
                                                            : (isDark
                                                                  ? Colors.white
                                                                  : const Color(
                                                                      0xFF202124,
                                                                    )),
                                                      ),
                                                    ),
                                                  ],
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
                                      ? (viewportWidth -
                                            32 -
                                            (kIsWeb ? 175 : 0))
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
                                    if (_isNavigating &&
                                        _routePoints.isNotEmpty) ...[
                                      // Google Maps Style Sleek Top Guidance Header (Active Navigation Only)
                                      _buildGoogleMapsNavigationHeader(
                                        isDark: isDark,
                                        activePotholeCount: activePotholeCount,
                                        navHeadline: navHeadline,
                                      ),
                                    ] else if (_routePoints.isNotEmpty) ...[
                                      // Google Maps Style Active Route Header (Dual Point A & B Card)
                                      _buildGoogleMapsActiveRouteHeader(isDark),
                                    ] else ...[
                                      // Google Maps Style Floating Search Bar Capsule
                                      _buildFloatingMapSearchBar(isDark),
                                      if (!_isSearchingActive && showMarkers) ...[
                                        const SizedBox(height: 8),
                                        _buildCategoryFilterChips(isDark),
                                      ],
                                    ],

                                    // 1. Route Hazard Counter Bar: Displays count of potholes on the route & next hazard ETA
                                    if ((_isNavigating ||
                                            _routePoints.isNotEmpty ||
                                            _destination != null) &&
                                        !_isSearchingActive)
                                      _buildRoutePotholeCountBar(
                                        activePotholeCount: activePotholeCount,
                                        nearestInfo: _nearestPotholeInfo,
                                        nextPotholeEta: _nextPotholeEta,
                                        isDark: isDark,
                                      ),

                                    // 2. Pothole Proximity Alert Banner (shown across all modes whenever approaching a pothole)
                                    if (_showWarningBanner &&
                                        showMarkers &&
                                        !_isLocationDisabled &&
                                        !_isPermissionDenied &&
                                        !_isSearchingActive)
                                      _buildPotholeWarningBanner(
                                        activePotholeCount: activePotholeCount,
                                        nearestInfo: _nearestPotholeInfo,
                                        nextPotholeEta: _nextPotholeEta,
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
                              padding: const EdgeInsets.fromLTRB(
                                14,
                                12,
                                14,
                                12,
                              ),
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                      backgroundColor: const Color(
                                        0xFF3EC9A7,
                                      ),
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
                        if (_isEditingDevLocation &&
                            _pendingDevLocation != null)
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: baseBottomOffset,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(
                                14,
                                12,
                                14,
                                12,
                              ),
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
                                          style: TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      ElevatedButton(
                                        onPressed: _applyDevLocationEdit,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF3C78D8,
                                          ),
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

                        // RIGHT SIDE ACTION BUTTONS (Google Maps Controls Stack - Positioned near bottom)
                        if (!_isChoosingLocationOnMap && !_isSearchPageActive)
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
                                        color: AppDesign.accent(isDark)
                                            .withValues(alpha: 0.35),
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
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.25),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Text(
                                                  '${_potholesOnRoute.length} ⚠️',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                  ),
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
                              if (_isAdminUser ||
                                  AppSettings
                                      .instance
                                      .devMockModeNotifier
                                      .value ||
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
                                    tooltip: _isPlacingMarker
                                        ? 'Cancel Custom Marker'
                                        : 'Place Custom Marker',
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
                                      color: _isEditingDevLocation ||
                                              _useMockLocation
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
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: AppDesign.accent(isDark),
                                    shape: BoxShape.circle,
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
                                      Icons.directions_rounded,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _isSearchPageActive = true;
                                        _isRoutePlanningMode = true;
                                        _isEditingOrigin = false;
                                        _suggestions = [];
                                      });
                                      _destinationFocusNode.requestFocus();
                                    },
                                    tooltip:
                                        'Point A to Point B Route Planning',
                                  ),
                                ),
                                const SizedBox(height: 6),
                              ],

                              // 1. Google Maps Navigation / Compass Mode Toggle
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: AppDesign.surface(isDark),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppDesign.border(isDark),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: isDark ? 0.3 : 0.12,
                                      ),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  icon: Transform.rotate(
                                    angle: -_currentMapRotation *
                                        (math.pi / 180),
                                    child: Icon(
                                      _followMode == FollowMode.compass
                                          ? Icons.explore_rounded
                                          : Icons.navigation_rounded,
                                      color: _followMode == FollowMode.compass
                                          ? AppDesign.accent(isDark)
                                          : (_currentMapRotation.abs() > 1.0
                                              ? const Color(0xFFEA4335)
                                              : AppDesign.textSecondary(isDark)),
                                      size: 20,
                                    ),
                                  ),
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
                                  tooltip: _currentMapRotation.abs() > 1.0
                                      ? 'Reset North'
                                      : 'Toggle Compass / Navigation Mode',
                                ),
                              ),

                              const SizedBox(height: 6),

                              // 2. Google Maps Zoom Controls Connected Vertical Pill
                              Container(
                                width: 40,
                                decoration: BoxDecoration(
                                  color: AppDesign.surface(isDark),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: AppDesign.border(isDark),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: isDark ? 0.3 : 0.12,
                                      ),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  children: [
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 40,
                                        minHeight: 38,
                                      ),
                                      icon: Icon(
                                        Icons.add_rounded,
                                        color: AppDesign.textPrimary(isDark),
                                        size: 19,
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
                                      indent: 6,
                                      endIndent: 6,
                                    ),
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 40,
                                        minHeight: 38,
                                      ),
                                      icon: Icon(
                                        Icons.remove_rounded,
                                        color: AppDesign.textPrimary(isDark),
                                        size: 19,
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

                              const SizedBox(height: 6),

                              // 3. Google Maps Target My Location Button
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: AppDesign.surface(isDark),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppDesign.border(isDark),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: isDark ? 0.3 : 0.12,
                                      ),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  icon: _isLoadingLocation && _currentPosition == null
                                      ? SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppDesign.accent(isDark),
                                          ),
                                        )
                                      : Icon(
                                          Icons.my_location_rounded,
                                          color: AppDesign.accent(isDark),
                                          size: 20,
                                        ),
                                  onPressed: () {
                                    if (_currentPosition != null) {
                                      if (_followMode == FollowMode.none) {
                                        setState(
                                          () =>
                                              _followMode = FollowMode.location,
                                        );
                                      }
                                      _animatedMapMove(_currentPosition!, 16.5);
                                      _mapController.rotate(0.0);
                                      _startFollowing();
                                    } else {
                                      _determinePosition();
                                    }
                                  },
                                  tooltip: 'Center My Location',
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Zoom-based distance scale bar (Google Maps style)
                        if (_selectedPothole == null &&
                            _searchedPlace == null &&
                            _routePoints.isEmpty &&
                            !_isChoosingLocationOnMap &&
                            !_isSearchPageActive &&
                            !_isPlacingMarker &&
                            !_isEditingDevLocation)
                          Positioned(
                            left: 16,
                            bottom: shouldHideBottomNav
                                ? (bottomInset + 12)
                                : 12,
                            child: MapScaleBar(
                              controller: _mapController,
                              isDark: isDark,
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

                        // 6. Google Maps Style Bottom Navigation Dock
                        if (_routePoints.isNotEmpty &&
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
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
                                      _isRoutePlanningMode &&
                                              _isChoosingOriginOnMap
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
                        if ((_isLocationDisabled || _isPermissionDenied) &&
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

  // ── DEDICATED FULL-SCREEN GOOGLE MAPS SEARCH PAGE ──
  Widget _buildDedicatedSearchPage(bool isDark) {
    final Color bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final Color cardBg =
        isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF1F5F9);
    final Color textColor = isDark ? Colors.white : const Color(0xFF1E293B);
    final Color hintColor =
        isDark ? const Color(0xFFA1A1AA) : const Color(0xFF94A3B8);

    return Positioned.fill(
      child: Material(
        color: bgColor,
        child: SafeArea(
          child: Column(
            children: [
              // ── Top Navigation & Input Bar ──
              Container(
                padding: const EdgeInsets.fromLTRB(8, 8, 14, 10),
                decoration: BoxDecoration(
                  color: bgColor,
                  border: Border(
                    bottom: BorderSide(
                      color: AppDesign.border(isDark),
                      width: 1,
                    ),
                  ),
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

              // ── Body Content (Suggestions / Search History / Choose on Map) ──
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
          onPressed: () {
            setState(() {
              _isSearchPageActive = false;
              _suggestions = [];
              _searchFocusNode.unfocus();
            });
          },
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
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
                      hintText: "Search here...",
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
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (value) {
                      setState(() {});
                      _onSearchChanged(value);
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
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _searchController.clear();
                        _suggestions = [];
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(
                        Icons.cancel_rounded,
                        size: 18,
                        color: hintColor,
                      ),
                    ),
                  ),
                if (_isRouting)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
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
    final Color iconColor = isDark ? Colors.white70 : const Color(0xFF5F6368);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Top Bar: Back, Title, Swap Action ──
        Row(
          children: [
            IconButton(
              icon: Icon(
                Icons.arrow_back_rounded,
                color: iconColor,
                size: 22,
              ),
              onPressed: () {
                setState(() {
                  _isRoutePlanningMode = false;
                  _isSearchPageActive = false;
                  _suggestions = [];
                  _originFocusNode.unfocus();
                  _destinationFocusNode.unfocus();
                });
              },
            ),
            const SizedBox(width: 4),
            Text(
              'Choose route',
              style: TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.swap_vert_rounded, color: iconColor, size: 22),
              onPressed: _swapOriginDestination,
              tooltip: 'Swap start and destination',
            ),
          ],
        ),
        const SizedBox(height: 6),

        // ── Point A (Starting Point) - Seamless Full Width Bar ──
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: Color(0xFF10B981),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _originController,
                  focusNode: _originFocusNode,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: textColor,
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    hintText: "Your location (Starting point)",
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
                    focusedErrorBorder: InputBorder.none,
                    filled: false,
                    fillColor: Colors.transparent,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onTap: () => setState(() => _isEditingOrigin = true),
                  onChanged: (val) {
                    setState(() => _isEditingOrigin = true);
                    _onSearchChanged(val);
                  },
                  onSubmitted: (_) {
                    if (_searchController.text.isNotEmpty) {
                      setState(() => _isSearchPageActive = false);
                      _searchAndRoute();
                    }
                  },
                ),
              ),
              if (_originController.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _originController.clear();
                      _customOrigin = null;
                      _suggestions = [];
                      _isEditingOrigin = true;
                    });
                    _originFocusNode.requestFocus();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Icon(
                      Icons.cancel_rounded,
                      size: 18,
                      color: hintColor,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // ── Point B (Destination) - Seamless Full Width Bar ──
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  focusNode: _destinationFocusNode,
                  autofocus: true,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: textColor,
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    hintText: "Choose destination",
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
                    focusedErrorBorder: InputBorder.none,
                    filled: false,
                    fillColor: Colors.transparent,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onTap: () => setState(() => _isEditingOrigin = false),
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
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _searchController.clear();
                      _destination = null;
                      _suggestions = [];
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Icon(
                      Icons.cancel_rounded,
                      size: 18,
                      color: hintColor,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDedicatedSearchBody(
    bool isDark,
    Color textColor,
    Color hintColor,
  ) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
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
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.my_location_rounded,
                      color: Color(0xFF10B981),
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
        // 1. Autocomplete Suggestions (if typing)
        if (_suggestions.isNotEmpty) ...[
          ..._suggestions.map((s) {
            final name = (s['_name'] ?? s['display_name']).toString();
            final shortAddr = (s['_short_addr'] ?? '').toString();
            final bool isBarangay = s['_is_barangay'] == true ||
                name.toLowerCase().contains('barangay');
            const Color brgyTeal = Color(0xFF0D9488);

            return InkWell(
              onTap: () {
                setState(() => _isSearchPageActive = false);
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
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: isBarangay
                            ? brgyTeal.withValues(alpha: 0.15)
                            : (isDark
                                ? const Color(0xFF1E293B)
                                : const Color(0xFFEFF6FF)),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isBarangay ? Icons.holiday_village_rounded : Icons.place_rounded,
                        color: isBarangay ? brgyTeal : AppDesign.accent(isDark),
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
                                    color: brgyTeal.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: brgyTeal.withValues(alpha: 0.35),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: const Text(
                                    'BARANGAY',
                                    style: TextStyle(
                                      fontSize: 9.0,
                                      fontWeight: FontWeight.bold,
                                      color: brgyTeal,
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
        else if (_searchHistory.isNotEmpty) ...[
          _buildSearchHistoryContent(isDark),
        ],

        // 3. ALWAYS AT THE VERY BOTTOM: "Choose Location on Map" Action Tile
        _buildChooseLocationOnMapTile(isDark),
      ],
    );
  }

  Widget _buildChooseLocationOnMapTile(bool isDark) {
    final Color hintColor =
        isDark ? const Color(0xFFA1A1AA) : const Color(0xFF94A3B8);
    final Color textColor = isDark ? Colors.white : const Color(0xFF1E293B);

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
              _isChoosingOriginOnMap =
                  _isRoutePlanningMode ? _isEditingOrigin : false;
              _suggestions = [];
              _searchFocusNode.unfocus();
              _originFocusNode.unfocus();
              _destinationFocusNode.unfocus();
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00796B).withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.pin_drop_rounded,
                    color: Color(0xFF00796B),
                    size: 20,
                  ),
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
                Icon(
                  Icons.chevron_right_rounded,
                  color: hintColor,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryFilterChips(bool isDark) {
    final categories = const [
      {'key': 'All', 'label': 'All Hazards', 'icon': Icons.layers_rounded},
      {'key': 'Potholes', 'label': 'Potholes', 'icon': Icons.warning_amber_rounded},
      {'key': 'Flooding', 'label': 'Flooding', 'icon': Icons.water_drop_rounded},
      {'key': 'Road Works', 'label': 'Road Works', 'icon': Icons.construction_rounded},
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: categories.map((cat) {
          final isSelected = _selectedHazardCategory == cat['key'];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() {
                    _selectedHazardCategory = cat['key'] as String;
                    _cachedPotholeClusters = null;
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF0284C7)
                        : (isDark
                            ? const Color(0xFF1E293B).withValues(alpha: 0.85)
                            : Colors.white.withValues(alpha: 0.92)),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFF38BDF8)
                          : (isDark
                              ? const Color(0xFF334155).withValues(alpha: 0.7)
                              : const Color(0xFFE2E8F0)),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isSelected
                            ? const Color(0xFF0284C7).withValues(alpha: 0.35)
                            : Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
                        blurRadius: isSelected ? 8 : 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        cat['icon'] as IconData,
                        size: 13,
                        color: isSelected
                            ? Colors.white
                            : (isDark
                                ? const Color(0xFF38BDF8)
                                : const Color(0xFF0369A1)),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        cat['label'] as String,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                          color: isSelected
                              ? Colors.white
                              : (isDark
                                  ? const Color(0xFFE2E8F0)
                                  : const Color(0xFF1E293B)),
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFloatingMapSearchBar(bool isDark) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _isSearchPageActive = true;
          _isRoutePlanningMode = false;
        });
        _searchFocusNode.requestFocus();
      },
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF121212) : Colors.white,
          borderRadius: BorderRadius.circular(24.0),
          border: Border.all(
            color: isDark ? const Color(0xFF27272A) : const Color(0xFFE5E7EB),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
              blurRadius: 14.0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              color: isDark ? Colors.white70 : const Color(0xFF5F6368),
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _searchController.text.isNotEmpty
                    ? _searchController.text
                    : "Search here...",
                style: TextStyle(
                  fontSize: 14.5,
                  color: _searchController.text.isNotEmpty
                      ? (isDark ? Colors.white : const Color(0xFF202124))
                      : (isDark ? Colors.white54 : const Color(0xFF70757A)),
                  fontWeight: _searchController.text.isNotEmpty
                      ? FontWeight.w500
                      : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_searchController.text.isNotEmpty)
              GestureDetector(
                onTap: _clearRouteState,
                child: Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Icon(
                    Icons.clear_rounded,
                    size: 18,
                    color: isDark ? Colors.white60 : const Color(0xFF5F6368),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGoogleMapsActiveRouteHeader(bool isDark) {
    final Color bgColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final Color textColor = isDark ? Colors.white : const Color(0xFF202124);
    final Color iconColor = isDark ? Colors.white70 : const Color(0xFF5F6368);

    final String originText = _originController.text.isNotEmpty
        ? _originController.text
        : 'Your location';
    final String destText = _searchController.text.isNotEmpty
        ? _searchController.text
        : 'Destination';

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF2E2E32) : const Color(0xFFE0E2E6),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
            blurRadius: 14.0,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            setState(() {
              _isSearchPageActive = true;
              _isRoutePlanningMode = true;
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                // Left Dot Indicator + Vertical Connecting Line + Red Pin
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: const BoxDecoration(
                        color: Color(0xFF1A73E8),
                        shape: BoxShape.circle,
                      ),
                    ),
                    Container(
                      width: 1.5,
                      height: 20,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: isDark
                          ? const Color(0xFF3F3F46)
                          : const Color(0xFFD4D4D8),
                    ),
                    const Icon(
                      Icons.location_on,
                      color: Color(0xFFEA4335),
                      size: 16,
                    ),
                  ],
                ),
                const SizedBox(width: 12),

                // Center Column: Origin Text & Destination Text
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Origin text
                      Text(
                        originText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Divider(
                        height: 1,
                        thickness: 0.8,
                        color: AppDesign.border(isDark),
                      ),
                      const SizedBox(height: 5),
                      // Destination text
                      Text(
                        destText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),

                // Right Actions: Options / Swap
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _isSearchPageActive = true;
                          _isRoutePlanningMode = true;
                          _isEditingOrigin = true;
                        });
                        _originFocusNode.requestFocus();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.more_vert_rounded,
                          color: iconColor,
                          size: 18,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: _swapOriginDestination,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.swap_vert_rounded,
                          color: iconColor,
                          size: 18,
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
    );
  }

  Widget _buildSearchHistoryContent(bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 18,
                    color: isDark ? Colors.white54 : const Color(0xFF70757A),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Recent searches',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white70 : const Color(0xFF5F6368),
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: _clearSearchHistory,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    'Clear all',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppDesign.accent(isDark),
                    ),
                  ),
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
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF1E293B)
                            : const Color(0xFFF1F3F4),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.history_rounded,
                        color: isDark
                            ? Colors.white60
                            : const Color(0xFF5F6368),
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
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AppDesign.textPrimary(isDark),
                            ),
                          ),
                          if (addr.isNotEmpty)
                            Text(
                              addr,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppDesign.textSecondary(isDark),
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: isDark
                            ? Colors.white38
                            : const Color(0xFF9AA0A6),
                      ),
                      onPressed: () => _removeFromSearchHistory(i),
                      tooltip: 'Remove',
                    ),
                  ],
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
                      : 'Grant location permission so Pothole Scanner can track your position, guide your route, and alert you to hazards in real-time.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppDesign.textSecondary(isDark),
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 44,
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
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _dismissedLocationPrompt = true);
                  },
                  child: Text(
                    'Explore Map Without GPS',
                    style: TextStyle(
                      color: AppDesign.textSecondary(isDark),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
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

  Widget _buildRoutePotholeCountBar({
    required int activePotholeCount,
    String? nearestInfo,
    String? nextPotholeEta,
    required bool isDark,
  }) {
    final bool hasPotholes = activePotholeCount > 0;
    final Color bgColor = hasPotholes
        ? (isDark ? const Color(0xFF451A03) : const Color(0xFFFEF3C7))
        : (isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5));
    final Color borderColor = hasPotholes
        ? (isDark ? const Color(0xFFD97706) : const Color(0xFFF59E0B))
        : (isDark ? const Color(0xFF059669) : const Color(0xFF10B981));
    final Color textColor = hasPotholes
        ? (isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E))
        : (isDark ? const Color(0xFFA7F3D0) : const Color(0xFF065F46));
    final Color iconColor = hasPotholes
        ? const Color(0xFFF59E0B)
        : const Color(0xFF10B981);

    String detailText = '';
    if (hasPotholes &&
        nearestInfo != null &&
        nearestInfo.isNotEmpty &&
        nearestInfo != 'Clear ahead') {
      detailText = ' • Next in $nearestInfo';
      if (nextPotholeEta != null && nextPotholeEta.isNotEmpty) {
        detailText += ' (ETA: $nextPotholeEta)';
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: borderColor.withValues(alpha: isDark ? 0.35 : 0.18),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasPotholes
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_rounded,
              color: iconColor,
              size: 17,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                hasPotholes
                    ? '$activePotholeCount Pothole Hazard${activePotholeCount == 1 ? '' : 's'} on Route$detailText'
                    : 'Route Clear • 0 Reported Potholes',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPotholeWarningBanner({
    int activePotholeCount = 0,
    String? nearestInfo,
    String? nextPotholeEta,
  }) {
    final bool isOnRoute = _destination != null || _routePoints.isNotEmpty;

    final String distText = (nearestInfo != null &&
            nearestInfo.isNotEmpty &&
            nearestInfo != 'Clear ahead')
        ? ' • $nearestInfo ahead'
        : '';

    final String etaText =
        (isOnRoute && nextPotholeEta != null && nextPotholeEta.isNotEmpty)
            ? ' • ETA: $nextPotholeEta'
            : '';

    final String routeInfo = (isOnRoute && activePotholeCount > 0)
        ? ' ($activePotholeCount on route)'
        : '';

    final String title =
        isOnRoute ? 'POTHOLE HAZARD AHEAD' : 'POTHOLE HAZARD NEARBY';

    final int? betterRouteIndex = _findBetterDetourRouteIndex();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF991B1B), Color(0xFFDC2626)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFFCA5A5), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.red.withValues(alpha: 0.45),
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
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
              child: Row(
                children: [
                  // Circular 8-second countdown ring
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: AnimatedBuilder(
                          animation: _warningBannerCountdownController,
                          builder: (context, _) => CircularProgressIndicator(
                            value: (1.0 - _warningBannerCountdownController.value).clamp(0.0, 1.0),
                            strokeWidth: 2.2,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.white,
                        size: 15,
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$title$distText$etaText$routeInfo • SLOW DOWN',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _dismissWarningBanner,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.25),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Waze-Style 1-Tap Detour Action Pill
            if (betterRouteIndex != null && _alternativeRoutes.length > 1) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 9),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _takeDetourAroundHazard(betterRouteIndex),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.alt_route_rounded, size: 15, color: Colors.white),
                          SizedBox(width: 6),
                          Text(
                            '⚡ AVOID HAZARD: TAKE ALT ROUTE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            // Slim linear countdown timer indicator
            AnimatedBuilder(
              animation: _warningBannerCountdownController,
              builder: (context, _) => LinearProgressIndicator(
                value: (1.0 - _warningBannerCountdownController.value).clamp(0.0, 1.0),
                minHeight: 2.5,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFDE047)),
              ),
            ),
          ],
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
    if (modifier.contains('slight left') || instruction.contains('slight left')) {
      return Icons.turn_slight_left_rounded;
    }
    if (modifier == 'left' ||
        modifier.contains('left') ||
        instruction.contains('turn left') ||
        instruction.contains('keep left')) {
      return Icons.turn_left_rounded;
    }

    // 5. Right Turns
    if (modifier.contains('sharp right') || instruction.contains('sharp right')) {
      return Icons.turn_sharp_right_rounded;
    }
    if (modifier.contains('slight right') || instruction.contains('slight right')) {
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
    if (_routeSteps.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF132A1D) : const Color(0xFF0F5132),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDark ? const Color(0xFF235336) : const Color(0xFF198754),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.navigation_rounded, color: Colors.white, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                navHeadline?.isNotEmpty == true ? navHeadline! : 'Follow Route',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.close_rounded,
                color: Colors.white,
                size: 20,
              ),
              onPressed: _clearRouteState,
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
        ? const Color(0xFF132A1D)
        : const Color(0xFF0F5132);
    final Color headerBorder = isDark
        ? const Color(0xFF235336)
        : const Color(0xFF198754);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: headerBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: headerBorder, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(maneuverIcon, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'In $stepDistStr',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  instruction,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                if (activePotholeCount > 0) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFFFBBF24),
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$activePotholeCount hazard${activePotholeCount == 1 ? '' : 's'} on route',
                        style: const TextStyle(
                          color: Color(0xFFFBBF24),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Repeat Instruction',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _speakCurrentStepInstruction,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.volume_up_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
          Tooltip(
            message: 'Exit Navigation',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _clearRouteState,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _startTurnByTurnNavigation(int activePotholeCount) {
    setState(() {
      _isNavigating = true;
      _isRoutePlanningMode = false;
      _followMode = FollowMode.location;
      _isRouteSheetExpanded = false;
      _isRouteDockMinimized = false;
      _selectedStepIndex = null;
    });

    if (_currentPosition != null) {
      _animatedMapMoveToVisible(
        _currentPosition!,
        17.0,
        isExpandedSheet: false,
      );
    }
    _startFollowing();

    // Route Hazard Speech & Banner Notification
    if (!kIsWeb) {
      if (activePotholeCount > 0) {
        final stepPrompt = _routeSteps.isNotEmpty ? ' ${_routeSteps.first.instruction}' : '';
        if (_travelMode == OsrmTravelMode.bike) {
          _tts.speak(
            'Motorcycle navigation started. Caution: $activePotholeCount pothole hazard${activePotholeCount == 1 ? '' : 's'} detected on your route. Ride carefully.$stepPrompt',
          );
        } else {
          _tts.speak(
            'Navigation started. Caution: $activePotholeCount pothole hazard${activePotholeCount == 1 ? '' : 's'} detected on your route.$stepPrompt',
          );
        }
      } else {
        final stepPrompt = _routeSteps.isNotEmpty ? ' ${_routeSteps.first.instruction}' : '';
        _tts.speak('Navigation started. Route is clear of reported pothole hazards.$stepPrompt');
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
                    ? 'Route Alert: $activePotholeCount pothole hazard${activePotholeCount == 1 ? '' : 's'} on this route. Drive carefully.'
                    : 'Route Clear: No pothole hazards detected along route.',
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
        : (activeDistance >= 1000
              ? '${(activeDistance / 1000).toStringAsFixed(1)} km'
              : '${activeDistance.round()} m');

    final double accurateSeconds = _calculateAccurateEtaSeconds(
      activeDuration,
      distanceMeters: activeDistance,
      potholeCount: activePotholeCount,
    );
    final int min = (accurateSeconds / 60).round().clamp(1, 9999);
    final String formattedDur = totalEtaStr.isNotEmpty
        ? totalEtaStr
        : (min < 60 ? '$min min' : '${min ~/ 60}h ${min % 60}m');

    final DateTime arrivalTime = DateTime.now().add(
      Duration(minutes: min),
    );
    final int hour = arrivalTime.hour % 12 == 0 ? 12 : arrivalTime.hour % 12;
    final String amPm = arrivalTime.hour >= 12 ? 'PM' : 'AM';
    final String clockStr =
        '$hour:${arrivalTime.minute.toString().padLeft(2, '0')} $amPm';

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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF121212) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? const Color(0xFF27272A) : const Color(0xFFE5E7EB),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.14),
                blurRadius: 14,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(
                _travelMode == OsrmTravelMode.car
                    ? Icons.directions_car_rounded
                    : _travelMode == OsrmTravelMode.bike
                    ? Icons.directions_bike_rounded
                    : Icons.directions_walk_rounded,
                color: const Color(0xFF1E8E3E),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                formattedDur,
                style: const TextStyle(
                  color: Color(0xFF1E8E3E),
                  fontSize: 15.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '($formattedDist)',
                style: TextStyle(
                  color: isDark ? Colors.white70 : const Color(0xFF5F6368),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (!_isNavigating)
                ElevatedButton(
                  onPressed: () => _startTurnByTurnNavigation(activePotholeCount),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00796B),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    'Start',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              const SizedBox(width: 4),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 22),
                onPressed: () => _setRouteSheetExpanded(false),
                tooltip: 'Expand route info',
              ),
            ],
          ),
        ),
      );
    }

    final double screenHeight = MediaQuery.sizeOf(context).height;
    final double expandedSheetHeight = (screenHeight * 0.50).clamp(280.0, 520.0);

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
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        constraints: BoxConstraints(
          maxHeight: _isRouteSheetExpanded ? expandedSheetHeight : 185,
        ),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF121212) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isDark ? const Color(0xFF27272A) : const Color(0xFFE5E7EB),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.50 : 0.16),
              blurRadius: 18,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag Handle Indicator Pill (Swipable vertically like Google Maps)
            GestureDetector(
              onTap: () => setState(
                () => _isRouteSheetExpanded = !_isRouteSheetExpanded,
              ),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                alignment: Alignment.center,
                child: Container(
                  width: 38,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF52525B)
                        : const Color(0xFFD4D4D8),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),

            // Show travel mode selector only in preview mode
            if (!_isNavigating)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildTravelModeSelector(isDark),
              ),

            // Summary Row: ETA, Distance, Arrive time, Hazard badge & Action Buttons
            Row(
              children: [
                // ETA & Distance Summary
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            formattedDur,
                            style: const TextStyle(
                              color: Color(0xFF1E8E3E),
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            formattedDist,
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black87,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.access_time_rounded,
                            color: isDark
                                ? const Color(0xFFA1A1AA)
                                : const Color(0xFF71717A),
                            size: 12,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Arrive $clockStr',
                            style: TextStyle(
                              color: isDark
                                  ? const Color(0xFFA1A1AA)
                                  : const Color(0xFF71717A),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (activePotholeCount > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFF59E0B,
                                ).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    color: Color(0xFFF59E0B),
                                    size: 10,
                                  ),
                                  const SizedBox(width: 2.5),
                                  Text(
                                    '$activePotholeCount',
                                    style: const TextStyle(
                                      color: Color(0xFFF59E0B),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),

                // Action Buttons
                if (!_isNavigating) ...[
                  ElevatedButton.icon(
                    onPressed: () => _startTurnByTurnNavigation(activePotholeCount),
                    icon: const Icon(Icons.navigation_rounded, size: 16),
                    label: const Text(
                      'Start',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00796B),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: () =>
                        _setRouteSheetExpanded(!_isRouteSheetExpanded),
                    icon: Icon(
                      _isRouteSheetExpanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.format_list_bulleted_rounded,
                      size: 18,
                    ),
                    tooltip: _isRouteSheetExpanded ? 'Collapse' : 'Steps',
                    style: IconButton.styleFrom(
                      backgroundColor: isDark
                          ? const Color(0xFF27272A)
                          : const Color(0xFFF4F4F5),
                      foregroundColor: isDark ? Colors.white : Colors.black87,
                      padding: const EdgeInsets.all(8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _clearRouteState,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Close Route',
                    style: IconButton.styleFrom(
                      backgroundColor: isDark
                          ? const Color(0xFF27272A)
                          : const Color(0xFFF4F4F5),
                      foregroundColor: isDark
                          ? const Color(0xFFA1A1AA)
                          : const Color(0xFF71717A),
                      padding: const EdgeInsets.all(8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ] else ...[
                  // In Active Navigation Mode: Show Steps Toggle + End Navigation Button
                  IconButton(
                    onPressed: () =>
                        _setRouteSheetExpanded(!_isRouteSheetExpanded),
                    icon: Icon(
                      _isRouteSheetExpanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.format_list_bulleted_rounded,
                      size: 18,
                    ),
                    tooltip: _isRouteSheetExpanded ? 'Collapse' : 'Steps',
                    style: IconButton.styleFrom(
                      backgroundColor: isDark
                          ? const Color(0xFF27272A)
                          : const Color(0xFFF4F4F5),
                      foregroundColor: isDark ? Colors.white : Colors.black87,
                      padding: const EdgeInsets.all(8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    onPressed: _clearRouteState,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEF4444),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.close_rounded, size: 16),
                        SizedBox(width: 4),
                        Text(
                          'End',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),

            // Expanded Route Content: Turn-by-Turn Steps & Alternative Routes
            if (_isRouteSheetExpanded) ...[
              const SizedBox(height: 8),
              Divider(
                height: 1,
                color: isDark
                    ? const Color(0xFF27272A)
                    : const Color(0xFFE5E7EB),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _routeSteps.length,
                  separatorBuilder: (c, i) => Divider(
                    height: 1,
                    thickness: 0.8,
                    color: isDark
                        ? const Color(0xFF27272A)
                        : const Color(0xFFF4F4F5),
                  ),
                  itemBuilder: (c, i) {
                    final step = _routeSteps[i];
                    final isFirst = i == 0;
                    final isLast = i == _routeSteps.length - 1;
                    final isSelected = _selectedStepIndex == i;
                    return InkWell(
                      onTap: () {
                        setState(() {
                          _selectedStepIndex = i;
                        });
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
                              ? AppDesign.accent(isDark).withValues(alpha: 0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            _buildManeuverIcon(step, isFirst, isLast, isDark),
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

  Widget _buildTravelModeSelector(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF18181B) : const Color(0xFFF4F4F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _buildModeTab(
            mode: OsrmTravelMode.car,
            label: 'Car',
            icon: Icons.directions_car_rounded,
            isDark: isDark,
          ),
          _buildModeTab(
            mode: OsrmTravelMode.bike,
            label: 'Motorcycle',
            icon: Icons.two_wheeler_rounded,
            isDark: isDark,
          ),
          _buildModeTab(
            mode: OsrmTravelMode.foot,
            label: 'Walk',
            icon: Icons.directions_walk_rounded,
            isDark: isDark,
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
  }) {
    final isSelected = _travelMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (_travelMode != mode) {
            setState(() => _travelMode = mode);
            final dest =
                _destination ??
                (_routePoints.isNotEmpty ? _routePoints.last : null);
            if (dest != null) {
              _calculateRoute(dest);
            }
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? (isDark ? const Color(0xFF27272A) : Colors.white)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.35 : 0.08,
                      ),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: isSelected
                    ? (isDark ? Colors.white : const Color(0xFF00796B))
                    : (isDark
                          ? const Color(0xFFA1A1AA)
                          : const Color(0xFF71717A)),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                  color: isSelected
                      ? (isDark ? Colors.white : const Color(0xFF00796B))
                      : (isDark
                            ? const Color(0xFFA1A1AA)
                            : const Color(0xFF71717A)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedPotholeCard(PotholeMarker pothole, bool isDark) {
    final isApproved = pothole.status == 'approved';
    final isRejected = pothole.status == 'rejected';
    final Color statusColor = isApproved
        ? const Color(0xFF10B981)
        : (isRejected ? const Color(0xFFEF4444) : const Color(0xFFF59E0B));
    final IconData statusIcon = isApproved
        ? Icons.verified_rounded
        : (isRejected ? Icons.cancel_rounded : Icons.pending_actions_rounded);
    final String statusText = isApproved
        ? 'APPROVED'
        : (isRejected ? 'REJECTED' : 'PENDING');

    final String severity = pothole.overallSeverity.toLowerCase();
    final Color severityColor = severity == 'high'
        ? const Color(0xFFEF4444)
        : (severity == 'low'
              ? const Color(0xFFEAB308)
              : const Color(0xFFF97316));
    final String severityLabel = '${severity.toUpperCase()} SEV';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.fastOutSlowIn,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppDesign.surface(isDark),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppDesign.border(isDark), width: 1.2),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 20,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Photo Thumbnail with High-Res Tap Preview
          _buildPotholeImageThumbnail(pothole.imagePath, isDark),
          const SizedBox(width: 14),

          // Pothole Info & Actions
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Status Badge & Severity Row
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode)
                            .withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        '${pothole.primaryDpwhCode}: ${pothole.primaryDefect}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode),
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.8),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon, color: statusColor, size: 12),
                          const SizedBox(width: 4),
                          Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: statusColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: severityColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: severityColor.withValues(alpha: 0.8),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        severityLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: severityColor,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    if (pothole.potholeCount > 1)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${pothole.potholeCount} hazards',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: AppDesign.textSecondary(isDark),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),

                // GPS Location Tag & SLA
                Row(
                  children: [
                    const Icon(
                      Icons.pin_drop_rounded,
                      color: Color(0xFF38BDF8),
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'GPS: ${pothole.location.latitude.toStringAsFixed(5)}, ${pothole.location.longitude.toStringAsFixed(5)} • SLA: ${pothole.responseTime}',
                        style: TextStyle(
                          color: AppDesign.textPrimary(isDark),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (pothole.barangay.isNotEmpty || pothole.city.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      const Icon(
                        Icons.location_city_rounded,
                        color: Color(0xFF0284C7),
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'LGU: ${pothole.barangay.isNotEmpty ? pothole.barangay : 'Bulacan'}${pothole.city.isNotEmpty ? ', ${pothole.city}' : ''}',
                          style: const TextStyle(
                            color: Color(0xFF0284C7),
                            fontWeight: FontWeight.w700,
                            fontSize: 11.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),

                // Action: Full Report & Edit
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppDesign.accent(isDark),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
                        minimumSize: Size.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        elevation: 0,
                      ),
                      icon: const Icon(Icons.info_outline_rounded, size: 14),
                      label: const Text(
                        'Full Report',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () => _showPotholeDetails(pothole),
                    ),
                    if (pothole.docId != null) ...[
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF2563EB),
                          side: const BorderSide(color: Color(0xFF2563EB)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          minimumSize: Size.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.edit_note_rounded, size: 14),
                        label: const Text(
                          'Edit',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        onPressed: () => _showEditPotholeDialog(pothole),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // Close (✕) Button
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedPothole = null;
                });
              },
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
            ),
          ),
        ],
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
