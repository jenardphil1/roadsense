import 'dart:math' as math;
import 'dart:math' show cos, sin, sqrt, atan2;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show
        DragStartBehavior,
        PanGestureRecognizer,
        GestureDisposition,
        GestureRecognizer;
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
import 'package:flutter_tts/flutter_tts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:universal_html/html.dart' as html;
import 'cloud_service.dart';
import 'settings_dialog.dart';
import 'map_scale_bar.dart';

enum FollowMode { none, location, compass }

class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  @override
  void addPointer(PointerDownEvent event) {
    super.addPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _PinTipClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
  }

  @override
  bool shouldReclip(_PinTipClipper oldClipper) => false;
}

/// 3 Travel Modes supported by Project-OSRM & OpenStreetMap
enum OsrmTravelMode { car, bike, foot }

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
      ..color = Colors.black.withValues(alpha: isDark ? 0.35 : 0.18)
      ..strokeWidth = 3.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);

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
  bool _isLoadingLocation = true;
  bool _isLocationDisabled = false;
  bool _isPermissionDenied = false;
  PotholeMarker? _selectedPothole;
  String? _expandedClusterId;

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
      final dpwhCode = data['primaryDpwhCode'] as String? ?? 'CODE 01';
      final defectClass = DpwhStandards.classifyByCode(dpwhCode);
      target = PotholeMarker(
        docId: docId ?? '',
        location: location,
        imagePath: data['imageUrl'] as String? ?? '',
        timestamp:
            (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
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

  // Navigation state
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _originController = TextEditingController(
    text: 'Your location',
  );
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _originFocusNode = FocusNode();
  final FocusNode _destinationFocusNode = FocusNode();
  List<Map<String, dynamic>> _searchHistory = [];
  bool _isSearchHistoryOpen = false;
  int _highlightedSuggestionIndex = -1;

  String _homeName = 'Home';
  String _homeAddress =
      'Mapulang Lupa Elementary School, Mapulang Lupa, Valenzuela';
  double _homeLat = 14.6948;
  double _homeLon = 120.9996;

  static final List<Map<String, dynamic>> _defaultSearchHistory = [
    {
      'name': 'Immaculate Conception I-College',
      'address': 'Bonifacio Street, Poblacion, Santa Maria, Bulacan',
      'lat': 14.8193,
      'lon': 120.9610,
      'status': 'Open • Closes 5PM',
    },
    {
      'name': 'Santa Maria Municipal Hall - Bulacan',
      'address': 'Poblacion, Santa Maria, Bulacan',
      'lat': 14.8188,
      'lon': 120.9592,
      'status': 'Closed • Opens 8AM Mon',
    },
    {
      'name': 'Municipal Hall Drive',
      'address': 'Poblacion, Santa Maria, Bulacan',
      'lat': 14.8198,
      'lon': 120.9585,
      'status': 'Open 24 hours',
    },
    {
      'name': 'N-la Cellphone Accessories & General M...',
      'address': 'Governor Fortunato Halili Avenue, Bagbagu...',
      'lat': 14.8215,
      'lon': 120.9632,
      'status': 'Open • Closes 8PM',
    },
    {
      'name': 'Gracia Motorcycle Shop and Supplies',
      'address': 'Quirino Highway, Gumaoc East, San Jose d...',
      'lat': 14.8102,
      'lon': 121.0450,
      'status': 'Closed • Opens 8AM Sat',
    },
    {
      'name': 'Real de Cacarong',
      'address': 'Pandi, Bulacan',
      'lat': 14.8694,
      'lon': 120.9578,
      'status': 'Historic Landmark',
    },
  ];

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
  bool _showTurnByTurnSheet = false;
  bool _isRouting = false;
  bool _isAutoRerouting = false;
  DateTime? _lastAutoRerouteAt;
  bool _useMockLocation = false;
  LatLng? _lastRealGpsPosition;
  bool _isDevToolsVisible = false;
  bool _isEditingDevLocation = false;
  LatLng? _pendingDevLocation;
  bool _isMapDragging = false;

  final bool _showMarkers = true;
  final Map<String, LatLng> _snappedPotholeCache = {};

  List<dynamic> _suggestions = [];
  Timer? _debounceTimer;
  Map<String, dynamic>? _searchedPlace;
  int _placeCardTab = 0;

  // Navigation / Follow Mode state
  FollowMode _followMode = FollowMode.location;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  LatLng? _destination;
  final ValueNotifier<double?> _lastHeadingNotifier = ValueNotifier(null);
  List<LatLng> _potholesOnRoute = [];

  // Pothole Proximity Alert
  late final FlutterTts _tts = FlutterTts();
  String _nearestPotholeInfo = '';
  String? _nextPotholeEta;
  bool _inProximityWarning = false;
  final Set<String> _alertedAt50m = {};
  double _debugClosestDist = 9999.0;
  bool _isInitialStartup = true;
  bool _showWarningBanner = false;
  bool _showHeatmap = false;
  LatLngBounds get _visibleBounds => _mapController.camera.visibleBounds;
  bool _isDraggingEndpoint = false;
  int _draggingEndpointKind = 0;
  Offset? _endpointDragScreenBase;
  Offset _endpointDragAccum = Offset.zero;
  double _endpointDragDistance = 0.0;
  DateTime _endpointPressStart = DateTime.now();
  Timer? _liveRerouteTimer;
  bool _silentRouting = false;
  LatLng? _tappedPoint;
  String _tappedPointLabel = '';
  String _tappedPointSecondary = '';
  int _tappedRequestSeq = 0;
  bool _isSearchVisible = true;
  bool _isPlacingMarker = false;
  bool _isSavingPlacedMarker = false;
  LatLng? _pendingMarkerLocation;

  final List<LatLng> _hardcodedPotholes = [];

  static const double _etaBufferFactor = 1.35;
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
    if (_cachedGlobalPosition != null) {
      _currentPosition = _cachedGlobalPosition;
      _isLoadingLocation = false;
    }
    _determinePosition(requestPermission: false);
    _loadSearchHistory();
    _loadHomePreset();
    _searchFocusNode.addListener(_onFocusChanged);
    _originFocusNode.addListener(_onFocusChanged);
    _destinationFocusNode.addListener(_onFocusChanged);
    HardwareKeyboard.instance.addHandler(_searchKeyHandler);
    if (!kIsWeb) {
      _tts.setLanguage('en-US');
      _tts.setSpeechRate(0.5);
      _tts.setVolume(1.0);
    }
    AppSettings.instance.manualPotholePlacementNotifier.addListener(
      _onManualPotholePlacementSettingChanged,
    );
    AppSettings.instance.devEditLocationNotifier.addListener(
      _onDevEditLocationSettingChanged,
    );
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  bool _searchKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (!_searchFocusNode.hasFocus) return false;
    final key = event.logicalKey;
    if (_suggestions.isEmpty) return false;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlightedSuggestionIndex = (_highlightedSuggestionIndex + 1).clamp(
          0,
          _suggestions.length - 1,
        );
      });
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlightedSuggestionIndex = (_highlightedSuggestionIndex - 1).clamp(
          0,
          _suggestions.length - 1,
        );
      });
      return true;
    }
    if (key == LogicalKeyboardKey.enter &&
        _highlightedSuggestionIndex >= 0 &&
        _highlightedSuggestionIndex < _suggestions.length) {
      _selectSuggestion(_suggestions[_highlightedSuggestionIndex]);
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _highlightedSuggestionIndex = -1);
      return true;
    }
    return false;
  }

  Future<void> _loadSearchHistory() async {
    try {
      if (kIsWeb) {
        final saved = html.window.localStorage['map_search_history'];
        if (saved != null) {
          final List decoded = jsonDecode(saved) as List;
          _searchHistory = decoded
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        } else {
          // First time initialization only
          _searchHistory = List<Map<String, dynamic>>.from(
            _defaultSearchHistory,
          );
          _saveSearchHistory();
        }
      }
    } catch (_) {}

    if (mounted) setState(() {});
  }

  void _saveSearchHistory() {
    try {
      if (kIsWeb) {
        html.window.localStorage['map_search_history'] = jsonEncode(
          _searchHistory,
        );
      }
    } catch (_) {}
  }

  void _addToSearchHistory({
    required String name,
    required String address,
    required double lat,
    required double lon,
    String? status,
  }) {
    _searchHistory.removeWhere(
      (item) =>
          (item['name'] ?? '').toString() == name ||
          (double.tryParse(item['lat']?.toString() ?? '') == lat &&
              double.tryParse(item['lon']?.toString() ?? '') == lon),
    );
    _searchHistory.insert(0, {
      'name': name,
      'address': address,
      'lat': lat,
      'lon': lon,
      'status': status ?? 'Searched location',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (_searchHistory.length > 20) {
      _searchHistory = _searchHistory.sublist(0, 20);
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

  Future<void> _loadHomePreset() async {
    try {
      if (kIsWeb) {
        final saved = html.window.localStorage['map_home_preset'];
        if (saved != null) {
          final Map<String, dynamic> decoded =
              jsonDecode(saved) as Map<String, dynamic>;
          _homeName = decoded['name']?.toString() ?? 'Home';
          _homeAddress =
              decoded['address']?.toString() ??
              'Mapulang Lupa Elementary School, Mapulang Lupa, Valenzuela';
          _homeLat =
              double.tryParse(decoded['lat']?.toString() ?? '') ?? 14.6948;
          _homeLon =
              double.tryParse(decoded['lon']?.toString() ?? '') ?? 120.9996;
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _saveHomePreset() {
    try {
      if (kIsWeb) {
        html.window.localStorage['map_home_preset'] = jsonEncode({
          'name': _homeName,
          'address': _homeAddress,
          'lat': _homeLat,
          'lon': _homeLon,
        });
      }
    } catch (_) {}
  }

  void _editHomeLocationDialog() {
    final nameCtrl = TextEditingController(text: _homeName);
    final addrCtrl = TextEditingController(text: _homeAddress);
    final addrFocus = FocusNode();
    final isDark = AppSettings.instance.isDarkMode;
    Timer? debounce;

    showDialog(
      context: context,
      builder: (ctx) {
        final List<Map<String, dynamic>> suggestions = [];
        bool searched = false;

        void runSearch(void Function(void Function()) setD, String q) async {
          if (q.trim().length < 3) {
            setD(() {
              suggestions.clear();
            });
            return;
          }
          try {
            final top5 = await _combinedSuggestions(_normalizeQuery(q));
            if (!ctx.mounted) return;
            setD(() {
              suggestions
                ..clear()
                ..addAll(top5);
              searched = true;
            });
          } catch (_) {
            if (!ctx.mounted) return;
            setD(() {
              suggestions.clear();
              searched = true;
            });
          }
        }

        void pickSuggestion(void Function(void Function()) setD, Map s) {
          final name = (s['_name'] ?? s['display_name'] ?? '').toString();
          setD(() {
            addrCtrl.text = name;
            suggestions.clear();
          });
        }

        return StatefulBuilder(
          builder: (ctx, setD) {
            return AlertDialog(
              backgroundColor: AppDesign.surface(isDark),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Icon(Icons.home_rounded, color: AppDesign.accent(isDark)),
                  const SizedBox(width: 8),
                  Text(
                    'Set Home Location',
                    style: TextStyle(
                      color: AppDesign.textPrimary(isDark),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 340,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: nameCtrl,
                        style: TextStyle(
                          color: AppDesign.textPrimary(isDark),
                          fontSize: 13.5,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Label (e.g. Home)',
                          labelStyle: TextStyle(
                            color: AppDesign.textSecondary(isDark),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: addrCtrl,
                        focusNode: addrFocus,
                        autofocus: true,
                        style: TextStyle(
                          color: AppDesign.textPrimary(isDark),
                          fontSize: 13.5,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Address or Place Name',
                          labelStyle: TextStyle(
                            color: AppDesign.textSecondary(isDark),
                          ),
                          suffixIcon: suggestions.isNotEmpty
                              ? IconButton(
                                  icon: Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: AppDesign.textSecondary(isDark),
                                  ),
                                  onPressed: () => setD(suggestions.clear),
                                )
                              : null,
                        ),
                        onChanged: (v) {
                          debounce?.cancel();
                          debounce = Timer(
                            const Duration(milliseconds: 350),
                            () => runSearch(setD, v),
                          );
                        },
                      ),
                      if (suggestions.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          constraints: const BoxConstraints(maxHeight: 190),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF1E293B)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isDark
                                  ? const Color(0xFF334155)
                                  : const Color(0xFFE2E8F0),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: isDark ? 0.45 : 0.14,
                                ),
                                blurRadius: 14,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: suggestions.length,
                            separatorBuilder: (c, i) => Divider(
                              height: 1,
                              thickness: 0.7,
                              color: isDark
                                  ? const Color(0xFF334155)
                                  : const Color(0xFFF1F5F9),
                            ),
                            itemBuilder: (c, i) {
                              final s = suggestions[i];
                              final name =
                                  (s['_name'] ?? s['display_name'] ?? '')
                                      .toString();
                              final shortAddr = (s['_short_addr'] ?? '')
                                  .toString();
                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => pickSuggestion(setD, s),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 9,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.place_rounded,
                                          size: 16,
                                          color: Color(0xFF2563EB),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: isDark
                                                      ? Colors.white
                                                      : const Color(0xFF0F172A),
                                                ),
                                              ),
                                              if (shortAddr.isNotEmpty &&
                                                  shortAddr != name)
                                                Text(
                                                  shortAddr,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: isDark
                                                        ? const Color(
                                                            0xFF94A3B8,
                                                          )
                                                        : const Color(
                                                            0xFF64748B,
                                                          ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        )
                      else if (searched && addrCtrl.text.trim().length >= 3)
                        Padding(
                          padding: const EdgeInsets.only(top: 10, left: 2),
                          child: Text(
                            'No matches found. You can still save this address.',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppDesign.textSecondary(isDark),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      if (_currentPosition != null)
                        TextButton.icon(
                          onPressed: () {
                            addrCtrl.text = 'Current GPS Location';
                            setD(suggestions.clear);
                          },
                          icon: const Icon(Icons.my_location_rounded, size: 16),
                          label: const Text('Use current GPS location as Home'),
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
                  onPressed: () async {
                    final newName = nameCtrl.text.trim().isEmpty
                        ? 'Home'
                        : nameCtrl.text.trim();
                    final newAddr = addrCtrl.text.trim();
                    if (newAddr.isEmpty) return;

                    if (newAddr == 'Current GPS Location' &&
                        _currentPosition != null) {
                      setState(() {
                        _homeName = newName;
                        _homeAddress = 'Current GPS Location';
                        _homeLat = _currentPosition!.latitude;
                        _homeLon = _currentPosition!.longitude;
                      });
                      _saveHomePreset();
                      Navigator.of(ctx).pop();
                      return;
                    }

                    try {
                      final coords = await _geocodeQuery(newAddr);
                      setState(() {
                        _homeName = newName;
                        _homeAddress = newAddr;
                        if (coords != null) {
                          _homeLat = coords.latitude;
                          _homeLon = coords.longitude;
                        }
                      });
                      _saveHomePreset();
                    } catch (_) {
                      setState(() {
                        _homeName = newName;
                        _homeAddress = newAddr;
                      });
                      _saveHomePreset();
                    }
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      debounce?.cancel();
      nameCtrl.dispose();
      addrCtrl.dispose();
      addrFocus.dispose();
    });
  }

  void _selectHistoryItem(Map<String, dynamic> item) {
    final rawName = (item['name'] ?? '').toString();
    final address = (item['address'] ?? '').toString();
    final String name = rawName == 'Home' && address.isNotEmpty
        ? address
        : (rawName.isNotEmpty ? rawName : address);
    final lat = double.tryParse(item['lat']?.toString() ?? '') ?? 0.0;
    final lon = double.tryParse(item['lon']?.toString() ?? '') ?? 0.0;
    if (lat == 0.0 && lon == 0.0) return;
    final LatLng targetLocation = LatLng(lat, lon);

    if (_isRoutePlanningMode) {
      if (_isEditingOrigin) {
        setState(() {
          _originController.text = name;
          _customOrigin = targetLocation;
          _suggestions = [];
          _isSearchHistoryOpen = false;
        });
        _originFocusNode.unfocus();
        final dest =
            _destination ??
            (_routePoints.isNotEmpty ? _routePoints.last : null);
        if (dest != null) {
          _calculateRoute(dest, customOrigin: targetLocation);
        } else {
          _animatedMapMove(targetLocation, 16.0);
        }
      } else {
        setState(() {
          _searchController.text = name;
          _destination = targetLocation;
          _suggestions = [];
          _isSearchHistoryOpen = false;
        });
        _destinationFocusNode.unfocus();
        final start =
            (_originController.text == 'Your location' || _customOrigin == null)
            ? _currentPosition
            : _customOrigin;
        _calculateRoute(targetLocation, customOrigin: start);
      }
    } else {
      // Direct Point A to Point B Routing on History Click
      setState(() {
        _isRoutePlanningMode = true;
        _isEditingOrigin = false;
        _searchController.text = name;
        _destination = targetLocation;
        _originController.text = 'Your location';
        _customOrigin = null;
        _suggestions = [];
        _isSearchHistoryOpen = false;
        _selectedPothole = null;
        _searchedPlace = null;
      });

      _searchFocusNode.unfocus();

      _addToSearchHistory(
        name: rawName == 'Home' && address.isNotEmpty ? address : rawName,
        address: (item['address'] ?? '').toString(),
        lat: lat,
        lon: lon,
        status: item['status']?.toString(),
      );

      _calculateRoute(targetLocation, customOrigin: _currentPosition);
    }
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
    AppSettings.instance.manualPotholePlacementNotifier.removeListener(
      _onManualPotholePlacementSettingChanged,
    );
    AppSettings.instance.devEditLocationNotifier.removeListener(
      _onDevEditLocationSettingChanged,
    );
    _searchFocusNode.removeListener(_onFocusChanged);
    _originFocusNode.removeListener(_onFocusChanged);
    _destinationFocusNode.removeListener(_onFocusChanged);
    HardwareKeyboard.instance.removeHandler(_searchKeyHandler);
    _searchFocusNode.dispose();
    _originFocusNode.dispose();
    _destinationFocusNode.dispose();
    _searchController.dispose();
    _originController.dispose();
    _debounceTimer?.cancel();
    _liveRerouteTimer?.cancel();
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();
    if (!kIsWeb) _tts.stop();
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
          if (mounted) {
            setState(() => _currentPosition = newPos);
          }
          _checkPotholeProximity(newPos);
          unawaited(_autoAdjustRouteToCurrentPath(newPos));

          if (_followMode != FollowMode.none) {
            if (_destination != null) {
              double heading = _lastHeadingNotifier.value ?? position.heading;
              final LatLng cameraCenter = _lookAheadPoint(
                newPos,
                heading,
                _lookAheadOffset,
              );
              _mapController.move(cameraCenter, _mapController.camera.zoom);
            } else {
              _mapController.move(newPos, _mapController.camera.zoom);
            }
          }
        });

    if (!kIsWeb) {
      int lastCompassTime = 0;
      _compassSubscription = FlutterCompass.events?.listen((
        CompassEvent event,
      ) {
        if (!widget.isMapActive || !mounted) return;
        if (event.heading == null) return;

        final int now = DateTime.now().millisecondsSinceEpoch;
        double heading = event.heading!;

        if (_lastHeadingNotifier.value != null) {
          double diff =
              (heading - _lastHeadingNotifier.value! + 180) % 360 - 180;
          if (diff.abs() < 2.0 && (now - lastCompassTime) < 100) return;
          heading = _lastHeadingNotifier.value! + diff * 0.2;
        }

        lastCompassTime = now;
        if (mounted) {
          _lastHeadingNotifier.value = heading;
        }

        if (_followMode == FollowMode.compass) {
          _mapController.rotate((360 - heading) % 360);

          if (_currentPosition != null) {
            if (_destination != null) {
              final cameraCenter = _lookAheadPoint(
                _currentPosition!,
                heading,
                _lookAheadOffset,
              );
              _mapController.move(cameraCenter, _mapController.camera.zoom);
            } else {
              _mapController.move(
                _currentPosition!,
                _mapController.camera.zoom,
              );
            }
          }
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
      for (final pothole in warningCandidates) {
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
      for (final pothole in warningCandidates) {
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
      _debugClosestDist = absoluteMin;
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

    if (inProximity && closestPotholeKey != null) {
      if (!_alertedAt50m.contains(closestPotholeKey)) {
        _alertedAt50m.add(closestPotholeKey);

        if (_showMarkers) {
          setState(() => _showWarningBanner = true);
          if (!_isInitialStartup && !kIsWeb) {
            _tts.speak('Warning! Pothole nearby.');
          }
        }
      }
    } else if (absoluteMin > 60) {
      _alertedAt50m.clear();
      if (_showWarningBanner) setState(() => _showWarningBanner = false);
    }

    _isInitialStartup = false;
  }

  void _onMapPositionChanged(MapCamera camera, bool hasGesture) {
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
      _isDevToolsVisible = true;
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
    if (_highlightedSuggestionIndex != -1) {
      _highlightedSuggestionIndex = -1;
    }
    if (_debounceTimer?.isActive ?? false) _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (query.length > 2) {
        _fetchSuggestions(query);
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
        );

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
    bool fitCamera = true,
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

    final bool compactViewport = mounted
        ? MediaQuery.sizeOf(context).width < 600
        : false;
    setState(() {
      _alternativeRoutes = routes;
      _alternativeRouteSteps = allSteps;
      _routeSteps = initialSteps;
      _showTurnByTurnSheet = initialSteps.isNotEmpty && !compactViewport;
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

    if (fitCamera) _fitCameraToRoute(initialRoute);
    await _refreshRouteAwarePotholeState();
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
    _updatePotholesOnActiveRoute(showToast: true);
  }

  /// Cycles between all available alternative and optimized routes
  void _cycleRoutes() {
    if (_alternativeRoutes.isEmpty) return;
    final nextIndex = (_selectedRouteIndex + 1) % _alternativeRoutes.length;
    _selectActiveRoute(nextIndex);
  }

  Future<void> _updatePotholesOnActiveRoute({bool showToast = false}) async {
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

  String _normalizeQuery(String rawQuery) {
    String normalized = rawQuery.trim();
    if (normalized.length > 100) {
      normalized = normalized.substring(0, 100).trim();
    }
    final lower = normalized.toLowerCase();

    // Standardize abbreviation aliases (e.g. Sta. -> Santa)
    normalized = normalized.replaceAll(
      RegExp(r'\bsta\.?\b', caseSensitive: false),
      'Santa',
    );

    // Popular local search aliases
    if (lower.contains('sm sta maria') ||
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

    return normalized;
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
  static const String _locationIqApiKey = 'pk.558af026585218dd26639ce26f14feeb';

  // Bulacan Province Center & Coordinates
  static const LatLng _bulacanCenter = LatLng(
    14.8192,
    120.9634,
  ); // Santa Maria / Malolos Bulacan

  Future<List<Map<String, dynamic>>> _fetchGeoapifyCandidates(
    String normalizedQuery,
  ) async {
    try {
      final Map<String, String> queryParams = {
        'text': normalizedQuery,
        'apiKey': _geoapifyApiKey,
        'filter':
            'countrycode:ph,rect:120.65,14.65,121.35,15.20', // Rectangular bounding over Bulacan Province
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
        'limit': '10',
      });

      final res = await http
          .get(url, headers: {'User-Agent': 'PotholeScannerApp/1.0'})
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
        final String name = (item['name'] ?? displayName.split(',').first)
            .toString();
        final addr = (item['address'] as Map<String, dynamic>?) ?? {};
        final String shortAddr = [
          addr['road'] ?? addr['suburb'] ?? '',
          addr['city'] ?? addr['town'] ?? addr['municipality'] ?? '',
          addr['state'] ?? addr['province'] ?? '',
        ].where((e) => e.isNotEmpty).join(', ');

        final double distanceKm = _calculateDistanceKm(refPos, candidateLoc);

        double score = 0.0;
        final String nameLower = name.toLowerCase();
        final String queryLower = normalizedQuery.toLowerCase();

        if (nameLower == queryLower) {
          score += 110.0;
        } else if (nameLower.startsWith(queryLower)) {
          score += 55.0;
        } else if (nameLower.contains(queryLower)) {
          score += 28.0;
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
      final top5 = await _combinedSuggestions(_normalizeQuery(query));
      if (mounted) {
        setState(() => _suggestions = top5);
      }
    } catch (e) {
      print("Multi-Source Autocomplete Error: $e");
    }
  }

  Future<List<Map<String, dynamic>>> _combinedSuggestions(
    String normalizedQuery,
  ) async {
    final List<Map<String, dynamic>> allCandidates = [];
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

    return merged.take(5).toList();
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
    if (_originController.text.isNotEmpty &&
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

    if (_isRoutePlanningMode) {
      if (_isEditingOrigin) {
        setState(() {
          _originController.text = name;
          _customOrigin = selectedLoc;
          _suggestions = [];
        });
        _originFocusNode.unfocus();
        final dest =
            _destination ??
            (_routePoints.isNotEmpty ? _routePoints.last : null);
        if (dest != null) {
          _calculateRoute(dest, customOrigin: selectedLoc);
        } else {
          _animatedMapMove(selectedLoc, 16.0);
        }
      } else {
        setState(() {
          _searchController.text = name;
          _destination = selectedLoc;
          _suggestions = [];
        });
        _destinationFocusNode.unfocus();
        final start =
            (_originController.text == 'Your location' || _customOrigin == null)
            ? _currentPosition
            : _customOrigin;
        _calculateRoute(selectedLoc, customOrigin: start);
      }
    } else {
      // Direct Point A to Point B Routing on Suggestion Click
      setState(() {
        _isRoutePlanningMode = true;
        _isEditingOrigin = false;
        _searchController.text = name;
        _destination = selectedLoc;
        _originController.text = 'Your location';
        _customOrigin = null;
        _suggestions = [];
        _isSearchHistoryOpen = false;
        _selectedPothole = null;
        _searchedPlace = null;
      });

      _searchFocusNode.unfocus();

      _addToSearchHistory(
        name: name,
        address: shortAddr.isNotEmpty
            ? shortAddr
            : (suggestion['display_name'] ?? '').toString(),
        lat: lat,
        lon: lon,
      );

      _calculateRoute(selectedLoc, customOrigin: _currentPosition);
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

  static final Map<String, LatLng?> _geocodeCache = {};
  static final Map<String, List<String>> _reverseGeocodeCache = {};

  Future<List<String>> _reverseGeocodeParts(LatLng point) async {
    final key =
        '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}';
    final cached = _reverseGeocodeCache[key];
    if (cached != null) return cached;
    try {
      final url = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat': point.latitude.toString(),
        'lon': point.longitude.toString(),
        'format': 'json',
        'zoom': '18',
        'addressdetails': '1',
      });
      final res = await http
          .get(url, headers: {'User-Agent': 'PotholeScannerApp/1.0'})
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final addr = (data['address'] as Map<String, dynamic>?) ?? {};
        String primary = addr['house_number'] != null
            ? '${addr['house_number']} ${addr['road'] ?? ''}'.trim()
            : (addr['road'] ?? '').toString();
        if (primary.trim().isEmpty) {
          primary = [
            addr['pedestrian'],
            addr['neighbourhood'],
            addr['quarter'],
            addr['suburb'],
            addr['village'],
            addr['hamlet'],
          ].where((e) => e != null && e.toString().isNotEmpty).join(' ');
        }
        final String secondary = [
          addr['city'] ??
              addr['town'] ??
              addr['municipality'] ??
              addr['village'],
          addr['state'] ?? addr['province'],
        ].where((e) => e != null && e.toString().isNotEmpty).join(', ');
        List<String> parts = [primary.trim(), secondary];
        if (parts[0].isEmpty) {
          parts[0] = (data['display_name'] ?? '')
              .toString()
              .split(',')
              .first
              .trim();
        }
        if (_reverseGeocodeCache.length > 200) _reverseGeocodeCache.clear();
        _reverseGeocodeCache[key] = parts;
        return parts;
      }
    } catch (_) {}
    return [
      '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
      '',
    ];
  }

  Future<String> _reverseGeocodeLabel(LatLng point) async {
    final parts = await _reverseGeocodeParts(point);
    return parts.where((e) => e.isNotEmpty).join(', ');
  }

  Future<LatLng?> _geocodeQuery(String query) async {
    final text = query.trim();
    if (text.isEmpty || text == 'Your location') return null;
    final cacheKey = text.toLowerCase();
    if (_geocodeCache.containsKey(cacheKey)) {
      return _geocodeCache[cacheKey];
    }
    final result = await _geocodeQueryUncached(text);
    if (_geocodeCache.length > 200) _geocodeCache.clear();
    _geocodeCache[cacheKey] = result;
    return result;
  }

  Future<LatLng?> _geocodeQueryUncached(String text) async {
    // 1. Primary: OSM Nominatim Geocoding API
    try {
      final nomUrl = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': text,
        'format': 'json',
        'limit': '1',
        'countrycodes': 'ph',
      });
      final nomRes = await http
          .get(nomUrl, headers: {'User-Agent': 'PotholeScannerApp/1.0'})
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
          .get(photUrl, headers: {'User-Agent': 'PotholeScannerApp/1.0'})
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

    return null;
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
        final String? modifier = maneuver['modifier'] as String?;
        final List locCoords = (maneuver['location'] as List?) ?? [0, 0];
        final LatLng loc = LatLng(
          (locCoords.length > 1 ? locCoords[1] as num : 0).toDouble(),
          (locCoords.isNotEmpty ? locCoords[0] as num : 0).toDouble(),
        );

        final String name = (step['name'] as String? ?? '').trim();
        final double dist = (step['distance'] as num? ?? 0.0).toDouble();
        final double dur = (step['duration'] as num? ?? 0.0).toDouble();

        String instruction = '';
        if (type == 'depart') {
          instruction = 'Head ${modifier ?? 'northeast'}';
        } else if (type == 'arrive') {
          instruction = modifier != null
              ? 'You have arrived at your destination, on the $modifier'
              : 'You have arrived at your destination';
        } else if (type == 'turn' || type == 'end of road') {
          final modStr = modifier ?? 'ahead';
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
              'Keep ${modifier ?? 'right'}${name.isNotEmpty ? ' onto $name' : ''}';
        } else if (type == 'merge') {
          instruction =
              'Merge ${modifier ?? 'onto road'}${name.isNotEmpty ? ' onto $name' : ''}';
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
            modifier: modifier,
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
    if (!silent) {
      setState(() {
        _isRouting = true;
        _alternativeRoutes = [];
        _routePotholeCounts = [];
        _routeSteps = [];
        _alternativeRouteSteps = [];
      });
    }

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
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("📍 Unable to calculate route to destination."),
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
    );
  }

  Future<void> _determinePosition({bool requestPermission = true}) async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        setState(() {
          _isLocationDisabled = true;
          _isLoadingLocation = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('📍 Location services are turned OFF.'),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'ENABLE',
              textColor: Colors.white,
              onPressed: () async {
                await Geolocator.openLocationSettings();
              },
            ),
          ),
        );
      }
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      if (requestPermission) {
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

  Future<void> _showPotholeDetails(PotholeMarker pothole) async {
    final currentUser = CloudService.instance.currentUser;
    String role = 'user';
    if (currentUser != null) {
      role = await CloudService.instance.getUserRole(currentUser.uid);
    }
    final bool isAdminUser = (role == 'admin' || role == 'super_admin');

    if (!mounted) return;

    final isDark = AppSettings.instance.isDarkMode;
    final isApproved = pothole.status == 'approved';
    final isRejected = pothole.status == 'rejected';

    final Color statusColor = isApproved
        ? const Color(0xFF10B981)
        : (isRejected ? const Color(0xFFEF4444) : const Color(0xFFF59E0B));
    final IconData statusIcon = isApproved
        ? Icons.verified_rounded
        : (isRejected ? Icons.cancel_rounded : Icons.schedule_rounded);
    final String statusLabel = isApproved
        ? 'VERIFIED'
        : (isRejected ? 'REJECTED' : 'PENDING REVIEW');

    final isHighSeverity = pothole.overallSeverity.toLowerCase() == 'high';
    final isMediumSeverity = pothole.overallSeverity.toLowerCase() == 'medium';

    final Color severityColor = isHighSeverity
        ? const Color(0xFFEF4444)
        : (isMediumSeverity
              ? const Color(0xFFF97316)
              : const Color(0xFFEAB308));

    final String severityLabel = isHighSeverity
        ? 'HIGH SEVERITY'
        : (isMediumSeverity ? 'MEDIUM SEVERITY' : 'LOW SEVERITY');

    final String docIdStr = pothole.docId != null && pothole.docId!.isNotEmpty
        ? (pothole.docId!.length > 8
              ? pothole.docId!.substring(0, 8).toUpperCase()
              : pothole.docId!.toUpperCase())
        : (pothole.id != null ? '#${pothole.id}' : '#POTHOLE');

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final screenWidth = MediaQuery.of(ctx).size.width;
        final isMobile = screenWidth < 600;

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isMobile ? 14 : 24,
            vertical: isMobile ? 20 : 32,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 620, maxHeight: 820),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF334155)
                    : const Color(0xFFE2E8F0),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.6 : 0.2),
                  blurRadius: 32,
                  spreadRadius: 2,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 16, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF2563EB,
                          ).withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.report_problem_rounded,
                          color: Color(0xFF2563EB),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Pothole Hazard Report',
                                  style: TextStyle(
                                    color: isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A),
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF334155)
                                        : const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    docIdStr,
                                    style: TextStyle(
                                      color: isDark
                                          ? const Color(0xFF94A3B8)
                                          : const Color(0xFF64748B),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Surveyed road surface telemetry and hazard inspection',
                              style: TextStyle(
                                color: isDark
                                    ? const Color(0xFF94A3B8)
                                    : const Color(0xFF64748B),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(statusIcon, color: statusColor, size: 13),
                            const SizedBox(width: 5),
                            Text(
                              statusLabel,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                          size: 20,
                        ),
                        splashRadius: 18,
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFF1F5F9),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: () {
                            if (pothole.imagePath.isNotEmpty) {
                              _showFullScreenPhoto(pothole.imagePath);
                            }
                          },
                          child: Container(
                            width: double.infinity,
                            height: 220,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF0F172A)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF334155)
                                    : const Color(0xFFE2E8F0),
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
                                                return const Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                        color: Color(
                                                          0xFF2563EB,
                                                        ),
                                                        strokeWidth: 2,
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
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Color(0xDD0F172A),
                                        ],
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.pin_drop_rounded,
                                              color: Color(0xFF38BDF8),
                                              size: 15,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              '${pothole.location.latitude.toStringAsFixed(5)}, ${pothole.location.longitude.toStringAsFixed(5)}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                fontFamily: 'monospace',
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (pothole.imagePath.isNotEmpty)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.black45,
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: const Row(
                                              children: [
                                                Icon(
                                                  Icons.fullscreen_rounded,
                                                  color: Colors.white,
                                                  size: 14,
                                                ),
                                                SizedBox(width: 4),
                                                Text(
                                                  'View Fullscreen',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ],
                                            ),
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
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: severityColor.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: severityColor.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: severityColor.withValues(alpha: 0.18),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.warning_amber_rounded,
                                  color: severityColor,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      severityLabel,
                                      style: TextStyle(
                                        color: severityColor,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      pothole.potholeCount > 1
                                          ? 'Cluster of ${pothole.potholeCount} recorded surface depressions in proximity'
                                          : 'Single distinct road surface depression requiring driver caution',
                                      style: TextStyle(
                                        color: isDark
                                            ? const Color(0xFFCBD5E1)
                                            : const Color(0xFF475569),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'TELEMETRY & HAZARD ATTRIBUTION',
                          style: TextStyle(
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF64748B),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.explore_rounded,
                                iconColor: const Color(0xFF2563EB),
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
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.person_rounded,
                                iconColor: const Color(0xFF10B981),
                                title: 'REPORTED BY',
                                value:
                                    pothole.reporterEmail ??
                                    'RoadSense Surveyor',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.calendar_today_rounded,
                                iconColor: const Color(0xFFF59E0B),
                                title: 'TIMESTAMP',
                                value:
                                    '${pothole.timestamp.year}-${pothole.timestamp.month.toString().padLeft(2, '0')}-${pothole.timestamp.day.toString().padLeft(2, '0')} • ${pothole.timestamp.hour.toString().padLeft(2, '0')}:${pothole.timestamp.minute.toString().padLeft(2, '0')}',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildTelemetryCard(
                                icon: Icons.shield_rounded,
                                iconColor: const Color(0xFF8B5CF6),
                                title: 'CLASSIFICATION',
                                value: 'Surface Obstruction Zone',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'DPWH ROAD MAINTENANCE SPECIFICATIONS',
                          style: TextStyle(
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF64748B),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode)
                                .withValues(alpha: isDark ? 0.12 : 0.07),
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
                                        color: isDark ? Colors.white : const Color(0xFF0F172A),
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
                                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                pothole.correctiveMeasure,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.35,
                                  color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                                ),
                              ),
                              if (pothole.detections != null && pothole.detections!.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Divider(
                                  height: 1,
                                  color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode).withValues(alpha: 0.2),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'YOLOv8 Distress Detections (${pothole.detections!.length}):',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                ...pothole.detections!.map((det) {
                                  final name = det['className'] as String? ?? 'Distress';
                                  final conf = (det['confidence'] as num?)?.toDouble() ?? 0.0;
                                  final code = det['dpwhCode'] as String? ?? '';
                                  final cls = DpwhStandards.classifyByName(name);
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2.5),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: BoxDecoration(
                                            color: cls.color,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          code.isNotEmpty ? '[$code] ' : '',
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11,
                                            color: cls.color,
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            name,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: isDark ? Colors.white70 : Colors.black87,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '${(conf * 100).toStringAsFixed(1)}% conf',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
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
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2563EB),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(Icons.near_me_rounded, size: 18),
                            label: const Text(
                              'Focus on Map & Center View',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              setState(() {
                                _selectedPothole = pothole;
                              });
                              _animatedMapMove(pothole.location, 17.5);
                            },
                          ),
                        ),
                        if (isAdminUser) ...[
                          const SizedBox(height: 20),
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: isDark
                                ? const Color(0xFF334155)
                                : const Color(0xFFF1F5F9),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'ADMINISTRATIVE REVIEW CONTROLS',
                            style: TextStyle(
                              color: Color(0xFFF59E0B),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              if (pothole.docId != null &&
                                  pothole.status != 'approved') ...[
                                Expanded(
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF10B981),
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.check_circle_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Approve',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
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
                                const SizedBox(width: 8),
                              ],
                              if (pothole.docId != null &&
                                  pothole.status != 'rejected') ...[
                                Expanded(
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFF59E0B),
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.cancel_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Reject',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
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
                                const SizedBox(width: 8),
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
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.edit_note_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Edit',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    onPressed: () {
                                      Navigator.of(ctx).pop();
                                      _showEditPotholeDialog(pothole);
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Expanded(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFFEF4444),
                                    side: const BorderSide(
                                      color: Color(0xFFEF4444),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 16,
                                  ),
                                  label: const Text(
                                    'Delete',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onPressed: () async {
                                    Navigator.of(ctx).pop();
                                    try {
                                      await _deleteDetectedPothole(pothole);
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
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
        );
      },
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
                  width: 380,
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
    final isDark = AppSettings.instance.isDarkMode;
    return Container(
      color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.no_photography_rounded,
              size: 38,
              color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
            ),
            const SizedBox(height: 8),
            Text(
              'No inspection photo captured',
              style: TextStyle(
                color: isDark
                    ? const Color(0xFF64748B)
                    : const Color(0xFF94A3B8),
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
    final isDark = AppSettings.instance.isDarkMode;
    return MouseRegion(
      cursor: onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: iconColor, size: 15),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.6,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onTap != null)
                    Icon(
                      Icons.copy_rounded,
                      size: 13,
                      color: isDark
                          ? const Color(0xFF64748B)
                          : const Color(0xFF94A3B8),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontSize: 12.5,
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
                  imagePath.startsWith('http') || imagePath.startsWith('blob:')
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
        final destLoc = await _geocodeQuery(destQuery);
        if (destLoc == null) {
          throw 'Location "$destQuery" not found.';
        }

        setState(() {
          _isRoutePlanningMode = true;
          _isEditingOrigin = false;
          _destination = destLoc;
          _originController.text = 'Your location';
          _customOrigin = null;
          _selectedPothole = null;
          _suggestions = [];
          _searchedPlace = null;
        });

        _searchFocusNode.unfocus();
        await _calculateRoute(destLoc, customOrigin: _currentPosition);
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
            action: SnackBarAction(
              label: 'RETRY',
              textColor: Colors.white,
              onPressed: () => _searchAndRoute(),
            ),
          ),
        );
      }
    }
  }

  double _calculateAccurateEtaSeconds(
    double rawSeconds, {
    double distanceMeters = 0,
    int potholeCount = 0,
    OsrmTravelMode? mode,
  }) {
    if (rawSeconds <= 0 && distanceMeters <= 0) return 0;

    final OsrmTravelMode activeMode = mode ?? _travelMode;

    // Estimate distance in km if not passed
    final double distKm = distanceMeters > 0
        ? distanceMeters / 1000.0
        : (rawSeconds * 0.010);

    double estimatedMinutes;

    if (activeMode == OsrmTravelMode.foot) {
      // Pedestrian Walking Speed: ~4.8 km/h (12.5 minutes per km)
      if (rawSeconds > (distKm * 600)) {
        estimatedMinutes = rawSeconds / 60.0;
      } else {
        estimatedMinutes = distKm * 12.5;
      }
      return (estimatedMinutes * 60.0).clamp(60.0, 864000.0);
    } else if (activeMode == OsrmTravelMode.bike) {
      // Bicycle / Cycling Speed: ~15 km/h (4.0 minutes per km)
      if (rawSeconds > (distKm * 200)) {
        estimatedMinutes = rawSeconds / 60.0;
      } else {
        estimatedMinutes = distKm * 4.0;
      }
      double adjustedSeconds = estimatedMinutes * 60.0;
      if (potholeCount > 0) {
        adjustedSeconds += (potholeCount * 10.0);
      }
      return adjustedSeconds.clamp(60.0, 864000.0);
    } else {
      // Realistic Philippine Driving Speed Profiles:
      // - Short local city/barangay traffic (0 - 8 km): ~20 km/h (3.0 mins per km)
      // - Medium arterial highway (8 km - 35 km): ~26 km/h (2.3 mins per km)
      // - Long expressway / tollway (> 35 km): ~55 km/h (1.1 mins per km)
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
  }

  String _formatEta(
    double seconds, {
    double distanceMeters = 0,
    int potholeCount = 0,
    OsrmTravelMode? mode,
  }) {
    if (seconds <= 0 && distanceMeters <= 0) return '--';
    final double finalSeconds = _calculateAccurateEtaSeconds(
      seconds,
      distanceMeters: distanceMeters,
      potholeCount: potholeCount,
      mode: mode,
    );
    final totalMinutes = (finalSeconds / 60).round();
    if (totalMinutes < 1) return '<1 min';
    if (totalMinutes < 60) return '$totalMinutes min';
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (m == 0) return '${h}h';
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

    // 1. Pending report indicator tag ("YOU 🕒")
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
                  Icon(Icons.schedule_rounded, size: 8, color: Colors.white),
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

    // 2. Multi-pothole count badge
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
          .map(
            (p) => '${p.id ?? p.docId ?? p.timestamp.millisecondsSinceEpoch}',
          )
          .join('_');

      clusters.add(PotholeCluster(id: id, center: center, items: group));
    }

    return clusters;
  }

  /// Builds the radial Spider Tree marker with connecting stems and anchor ring
  Widget _severityBreakdownDot(Color color, int count) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 1.2),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 2),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

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

          // 2. Center Anchor Ring
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
              left: centerXY + childOffsets[i].dx - 16,
              top: centerXY + childOffsets[i].dy - 16,
              child: GestureDetector(
                onTap: () {
                  final item = cluster.items[i];
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
      child: Center(child: Icon(nodeIcon, size: 16, color: Colors.white)),
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
            final bool isDark = AppSettings.instance.isDarkMode;
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
                ? (activeRouteIndex < _routePotholeCounts.length &&
                          _routePotholeCounts[activeRouteIndex] > 0
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

            return Scaffold(
              body: _isLoadingLocation && _currentPosition == null
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text("Locating you on the map..."),
                        ],
                      ),
                    )
                  : Stack(
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
                                  flags:
                                      InteractiveFlag.all &
                                      ~InteractiveFlag.rotate,
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
                                    // Any map tap closes the search dropdowns first
                                    if (_isSearchHistoryOpen ||
                                        _suggestions.isNotEmpty) {
                                      setState(() {
                                        _isSearchHistoryOpen = false;
                                        _suggestions = [];
                                      });
                                      _searchFocusNode.unfocus();
                                      _originFocusNode.unfocus();
                                      _destinationFocusNode.unfocus();
                                      return;
                                    }

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
                                        _searchedPlace != null ||
                                        _suggestions.isNotEmpty ||
                                        _isSearchHistoryOpen) {
                                      setState(() {
                                        _selectedPothole = null;
                                        _searchedPlace = null;
                                      });
                                    }

                                    // Any map tap while the bar is open closes it
                                    if (_tappedPoint != null) {
                                      setState(() {
                                        _tappedRequestSeq++;
                                        _tappedPoint = null;
                                        _tappedPointLabel = '';
                                        _tappedPointSecondary = '';
                                      });
                                      return;
                                    }

                                    setState(() {
                                      _tappedRequestSeq++;
                                      _tappedPoint = point;
                                      _tappedPointLabel = '';
                                      _tappedPointSecondary = '';
                                    });
                                    _resolveTappedLabel(_tappedRequestSeq);
                                  }
                                },
                              ),
                              children: [
                                ValueListenableBuilder<String>(
                                  valueListenable:
                                      AppSettings.instance.webMapStyleNotifier,
                                  builder: (context, mapStyle, _) {
                                    String url;
                                    if (mapStyle == 'Satellite') {
                                      url =
                                          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
                                    } else if (mapStyle == 'Dark Canvas') {
                                      url =
                                          'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';
                                    } else {
                                      url =
                                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
                                    }
                                    return TileLayer(
                                      key: ValueKey(mapStyle),
                                      urlTemplate: url,
                                      userAgentPackageName:
                                          'com.example.pothole_scanner',
                                      tileDisplay: const TileDisplay.fadeIn(
                                        duration: Duration(milliseconds: 120),
                                      ),
                                      panBuffer: 2,
                                      keepBuffer: 6,
                                      minZoom: 3,
                                      maxZoom: 19,
                                      maxNativeZoom: 19,
                                    );
                                  },
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
                                        color: const Color(0xFF2563EB),
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
                                if (_showHeatmap)
                                  CircleLayer(
                                    key: const ValueKey('pothole_heatmap'),
                                    circles: widget.detectedPotholes
                                        .where(
                                          (p) =>
                                              p.status != 'deleted' &&
                                              p.status != 'rejected',
                                        )
                                        .map((p) {
                                          final severity = p.overallSeverity
                                              .toLowerCase();
                                          final Color color = severity == 'high'
                                              ? const Color(0xFFEF4444)
                                              : severity == 'low'
                                              ? const Color(0xFFEAB308)
                                              : const Color(0xFFF97316);
                                          return CircleMarker(
                                            point: p.location,
                                            radius: 110,
                                            useRadiusInMeter: true,
                                            color: color.withValues(
                                              alpha: 0.38,
                                            ),
                                            borderColor: color.withValues(
                                              alpha: 0.85,
                                            ),
                                            borderStrokeWidth: 2,
                                          );
                                        })
                                        .toList(),
                                  ),
                                MarkerLayer(
                                  markers: [
                                    if (_currentPosition != null)
                                      Marker(
                                        point: _currentPosition!,
                                        width: 28,
                                        height: 28,
                                        child: Center(
                                          child: Container(
                                            width: 20,
                                            height: 20,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: const Color(0xFF2563EB),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Colors.black26,
                                                  blurRadius: 6,
                                                  spreadRadius: 1,
                                                ),
                                              ],
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 2.5,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    // Tappable clustered pothole markers with 10m Radial Spider Tree expansion
                                    ..._clusterPotholes(
                                      widget.detectedPotholes
                                          .where(
                                            (p) =>
                                                p.status != 'deleted' &&
                                                p.status != 'rejected',
                                          )
                                          .where(
                                            (p) => _visibleBounds.contains(
                                              p.location,
                                            ),
                                          )
                                          .toList(),
                                      radiusMeters: 10.0,
                                    ).map((cluster) {
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
                                              if (_selectedPothole != null ||
                                                  _searchedPlace != null ||
                                                  _suggestions.isNotEmpty ||
                                                  _isSearchHistoryOpen) {
                                                setState(() {
                                                  _selectedPothole = null;
                                                  _searchedPlace = null;
                                                  _suggestions = [];
                                                  _isSearchHistoryOpen = false;
                                                });
                                                _searchFocusNode.unfocus();
                                                _originFocusNode.unfocus();
                                                _destinationFocusNode.unfocus();
                                              }
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
                                              severity: pothole.overallSeverity,
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
                                                _expandedClusterId = cluster.id;
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
                                                        color: Colors.black38,
                                                        blurRadius: 6,
                                                        offset: Offset(0, 2),
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
                                                Builder(
                                                  builder: (context) {
                                                    int highCount = 0;
                                                    int medCount = 0;
                                                    int lowCount = 0;
                                                    for (final item
                                                        in cluster.items) {
                                                      final s = item
                                                          .overallSeverity
                                                          .toLowerCase();
                                                      if (s == 'high') {
                                                        highCount++;
                                                      } else if (s == 'low') {
                                                        lowCount++;
                                                      } else {
                                                        medCount++;
                                                      }
                                                    }
                                                    return Positioned(
                                                      bottom: -10,
                                                      left: -6,
                                                      right: -6,
                                                      child: Row(
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .center,
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          if (highCount > 0)
                                                            _severityBreakdownDot(
                                                              const Color(
                                                                0xFFEF4444,
                                                              ),
                                                              highCount,
                                                            ),
                                                          if (medCount > 0)
                                                            _severityBreakdownDot(
                                                              const Color(
                                                                0xFFF97316,
                                                              ),
                                                              medCount,
                                                            ),
                                                          if (lowCount > 0)
                                                            _severityBreakdownDot(
                                                              const Color(
                                                                0xFFEAB308,
                                                              ),
                                                              lowCount,
                                                            ),
                                                        ],
                                                      ),
                                                    );
                                                  },
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
                                                          BorderRadius.circular(
                                                            10,
                                                          ),
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

                                    // Custom Start Location Pin (Blue, Draggable — shown even when origin is "Your location")
                                    if (_customOrigin != null ||
                                        (_destination != null &&
                                            _currentPosition != null))
                                      _buildDraggableEndpointPin(
                                        point:
                                            _customOrigin ?? _currentPosition!,
                                        kind: 1,
                                        color: const Color(0xFF2563EB),
                                      ),

                                    // Destination Location Pin (Red, Draggable)
                                    if (_destination != null)
                                      _buildDraggableEndpointPin(
                                        point: _destination!,
                                        kind: 2,
                                        color: const Color(0xFFEA4335),
                                      ),

                                    // Tapped location dot (Google Maps style drop)
                                    if (_tappedPoint != null)
                                      Marker(
                                        key: const ValueKey('tapped_point'),
                                        point: _tappedPoint!,
                                        width: 20,
                                        height: 20,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.white,
                                            border: Border.all(
                                              color: const Color(0xFFEA4335),
                                              width: 2,
                                            ),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Colors.black38,
                                                blurRadius: 4,
                                                offset: Offset(0, 1),
                                              ),
                                            ],
                                          ),
                                          child: Center(
                                            child: Container(
                                              width: 7,
                                              height: 7,
                                              decoration: const BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: Color(0xFFEA4335),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),

                                    // Active Selected Turn-by-Turn Maneuver Dot (Clean, High-Visibility Google Maps / OSRM Waypoint Dot)
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
                                              // 1. Translucent Focus Glow Ring (Leaves map roads 100% visible)
                                              Container(
                                                width: 32,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: const Color(
                                                    0xFF2563EB,
                                                  ).withValues(alpha: 0.25),
                                                ),
                                              ),
                                              // 2. High-Visibility Crisp Focus Core Dot
                                              Container(
                                                width: 15,
                                                height: 15,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: const Color(
                                                    0xFF2563EB,
                                                  ),
                                                  border: Border.all(
                                                    color: Colors.white,
                                                    width: 2.5,
                                                  ),
                                                  boxShadow: const [
                                                    BoxShadow(
                                                      color: Colors.black45,
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
                                                      ? const Color(0xFF2563EB)
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
                                                              0xFF2563EB,
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
                                            color: const Color(0xFF2563EB),
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

                        // 1. Floating Top-Left Search Bar, Route Planner, & Dropdowns (Web)
                        if (kIsWeb && widget.isMapActive)
                          Positioned(
                            top: 16,
                            left: isCompactViewport ? 12 : 20,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: isCompactViewport
                                    ? (viewportWidth - 24)
                                    : viewportWidth < 900
                                    ? 330.0
                                    : 396.0,
                                maxHeight:
                                    (MediaQuery.of(context).size.height - 32)
                                        .clamp(200.0, 760.0),
                              ),
                              child: _isRoutePlanningMode
                                  ? Container(
                                      decoration: BoxDecoration(
                                        color: isDark
                                            ? const Color(0xFF1E293B)
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: isDark
                                              ? const Color(0xFF334155)
                                              : const Color(0xFFE2E8F0),
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withValues(
                                              alpha: isDark ? 0.45 : 0.15,
                                            ),
                                            blurRadius: 18,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: _buildRoutePlanningContent(
                                        isDark: isDark,
                                        isClearAhead: isClearAhead,
                                        distStr: distStr,
                                        totalEtaStr: totalEtaStr,
                                        activePotholeCount: activePotholeCount,
                                      ),
                                    )
                                  : Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _buildFloatingSearchBar(
                                          isDark: isDark,
                                          isCompactViewport: isCompactViewport,
                                        ),
                                        if (_suggestions.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxHeight: 280,
                                            ),
                                            child: _buildSuggestionsDropdown(
                                              isDark,
                                            ),
                                          ),
                                        ] else if (_isSearchHistoryOpen &&
                                            _searchController.text.isEmpty &&
                                            _searchHistory.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxHeight: 340,
                                            ),
                                            child: _buildSearchHistoryDropdown(
                                              isDark,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                            ),
                          ),

                        // 2. Floating Top-Right Map / Profile / Settings Switcher (Web)
                        if (kIsWeb && widget.isMapActive)
                          Positioned(
                            top: 16,
                            right: isCompactViewport ? 12 : 20,
                            child: _buildTopRightMapProfileToggle(
                              isMapActive: true,
                            ),
                          ),

                        // 3. Floating Pothole Hazard Warning Banner (Web)
                        if (_showWarningBanner &&
                            _showMarkers &&
                            !_isLocationDisabled &&
                            !_isPermissionDenied)
                          Positioned(
                            top: 16,
                            left: isCompactViewport ? 12 : 430,
                            right: isCompactViewport ? 12 : 360,
                            child: Center(
                              child: _buildWebPotholeWarningBanner(
                                activePotholeCount: activePotholeCount,
                                nearestInfo: _nearestPotholeInfo,
                                nextPotholeEta: _nextPotholeEta,
                              ),
                            ),
                          ),

                        // 5. Location Permission Warning (Only when permission denied) — centered
                        if (widget.isMapActive &&
                            !_isRoutePlanningMode &&
                            (_isLocationDisabled || _isPermissionDenied))
                          Positioned.fill(
                            child: Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: isCompactViewport ? 20 : 0,
                                ),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 440,
                                  ),
                                  child: _buildLocationPermissionCard(isDark),
                                ),
                              ),
                            ),
                          ),
                        if (_isPlacingMarker && _pendingMarkerLocation != null)
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: _isSearchVisible
                                ? (_showWarningBanner ? 186 : 130)
                                : (_showWarningBanner ? 76 : 20),
                            child: SafeArea(
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  12,
                                  14,
                                  12,
                                ),
                                decoration: BoxDecoration(
                                  color: _inProximityWarning
                                      ? const Color(0xF2B72A2A)
                                      : const Color(0xF20F2C25),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: _inProximityWarning
                                        ? const Color(0x80FFFFFF)
                                        : const Color(0x803EC9A7),
                                    width: 1,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black45,
                                      blurRadius: 12,
                                      offset: Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'Move map or tap to place marker',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Lat ${_pendingMarkerLocation!.latitude.toStringAsFixed(6)} • Lng ${_pendingMarkerLocation!.longitude.toStringAsFixed(6)}',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.82,
                                        ),
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: _isSavingPlacedMarker
                                                ? null
                                                : _cancelMarkerPlacement,
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: Colors.white,
                                              side: const BorderSide(
                                                color: Color(0x80FFFFFF),
                                              ),
                                            ),
                                            child: const Text('Cancel'),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: ElevatedButton(
                                            onPressed: _isSavingPlacedMarker
                                                ? null
                                                : _confirmMarkerPlacement,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFF2563EB,
                                              ),
                                              foregroundColor: Colors.white,
                                            ),
                                            child: _isSavingPlacedMarker
                                                ? const SizedBox(
                                                    height: 16,
                                                    width: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white,
                                                        ),
                                                  )
                                                : const Text('OK'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                        if (_isEditingDevLocation &&
                            _pendingDevLocation != null)
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: _isSearchVisible
                                ? (_showWarningBanner ? 186 : 130)
                                : (_showWarningBanner ? 76 : 20),
                            child: SafeArea(
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  12,
                                  14,
                                  12,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xF21C2C45),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0x805EA2FF),
                                    width: 1,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black45,
                                      blurRadius: 12,
                                      offset: Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'Developer mode: edit current location',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Move the map or tap anywhere, then apply to test dynamic pathing.',
                                      style: TextStyle(
                                        color: Color(0xFFE0E9F8),
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Lat ${_pendingDevLocation!.latitude.toStringAsFixed(6)} • Lng ${_pendingDevLocation!.longitude.toStringAsFixed(6)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: _cancelDevLocationEdit,
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: Colors.white,
                                              side: const BorderSide(
                                                color: Color(0x80FFFFFF),
                                              ),
                                            ),
                                            child: const Text('Cancel'),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: ElevatedButton(
                                            onPressed: _applyDevLocationEdit,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFF2563EB,
                                              ),
                                              foregroundColor: Colors.white,
                                            ),
                                            child: const Text('Apply location'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                        // LEFT SIDE ACTION BUTTONS (Dev Tools)
                        Positioned(
                          left: 16,
                          bottom: 118,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FloatingActionButton(
                                heroTag: 'map_dev_tools_btn',
                                mini: true,
                                onPressed: () {
                                  setState(() {
                                    _isDevToolsVisible = !_isDevToolsVisible;
                                    if (!_isDevToolsVisible) {
                                      _isEditingDevLocation = false;
                                      _pendingDevLocation = null;
                                    }
                                  });
                                },
                                backgroundColor: _isDevToolsVisible
                                    ? const Color(0xFF2563EB)
                                    : Colors.white.withValues(alpha: 0.9),
                                foregroundColor: _isDevToolsVisible
                                    ? Colors.white
                                    : const Color(0xFF2563EB),
                                elevation: 3,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Icon(
                                  Icons.science_rounded,
                                  size: 20,
                                ),
                              ),
                              if (_isDevToolsVisible) const SizedBox(height: 8),
                              if (_isDevToolsVisible)
                                FloatingActionButton(
                                  heroTag: 'map_dev_edit_location_btn',
                                  mini: true,
                                  onPressed: _isEditingDevLocation
                                      ? _cancelDevLocationEdit
                                      : _startDevLocationEdit,
                                  backgroundColor: _isEditingDevLocation
                                      ? const Color(0xFF8E2B2B)
                                      : const Color(0xFF1C2C45),
                                  foregroundColor: Colors.white,
                                  elevation: 3,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(
                                    _isEditingDevLocation
                                        ? Icons.close_rounded
                                        : Icons.edit_location_alt_rounded,
                                    size: 18,
                                  ),
                                ),
                              if (_isDevToolsVisible) const SizedBox(height: 8),
                              if (_isDevToolsVisible)
                                FloatingActionButton(
                                  heroTag: 'map_dev_use_gps_btn',
                                  mini: true,
                                  onPressed: _resetToRealLocation,
                                  backgroundColor: Colors.white,
                                  foregroundColor: const Color(0xFF1666A9),
                                  elevation: 3,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Icon(
                                    Icons.gps_fixed_rounded,
                                    size: 18,
                                  ),
                                ),
                            ],
                          ),
                        ),

                        // RIGHT SIDE ACTION BUTTONS (Google Maps Controls Stack)
                        Positioned(
                          right: 16,
                          bottom: 32,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              // Route Switcher / Cycle Controller
                              if (_alternativeRoutes.length > 1) ...[
                                Container(
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2563EB),
                                    borderRadius: BorderRadius.circular(21),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF2563EB)
                                            .withValues(alpha: 0.35),
                                        blurRadius: 10,
                                        offset: const Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: _cycleRoutes,
                                      borderRadius: BorderRadius.circular(21),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.alt_route_rounded,
                                              color: Colors.white,
                                              size: 18,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Route ${_selectedRouteIndex + 1}/${_alternativeRoutes.length}',
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
                                const SizedBox(height: 12),
                              ],

                              // 0. Standalone Floating Directions Action Button (Point A to Point B)
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2563EB),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(
                                        0xFF2563EB,
                                      ).withValues(alpha: 0.35),
                                      blurRadius: 10,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: IconButton(
                                  icon: const Icon(
                                    Icons.directions_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                  onPressed: () {
                                    setState(() => _isRoutePlanningMode = true);
                                    if (_routePoints.isNotEmpty) {
                                      _calculateRoute(_routePoints.last);
                                    } else if (_searchController
                                        .text
                                        .isNotEmpty) {
                                      _searchAndRoute();
                                    }
                                  },
                                  tooltip:
                                      'Get Directions (Point A to Point B)',
                                ),
                              ),
                              const SizedBox(height: 12),

                              // 1. Google Maps Navigation / Compass Mode Toggle
                              Container(
                                width: 44,
                                height: 44,
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
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: IconButton(
                                  icon: Icon(
                                    _followMode == FollowMode.compass
                                        ? Icons.explore_rounded
                                        : Icons.navigation_rounded,
                                    color: _followMode == FollowMode.compass
                                        ? AppDesign.accent(isDark)
                                        : AppDesign.textSecondary(isDark),
                                    size: 22,
                                  ),
                                  onPressed: _toggleFollowMode,
                                  tooltip: 'Toggle Compass / Navigation Mode',
                                ),
                              ),

                              const SizedBox(height: 12),

                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: _showHeatmap
                                      ? AppDesign.accent(isDark)
                                      : AppDesign.surface(isDark),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppDesign.border(isDark),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: isDark ? 0.3 : 0.12,
                                      ),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: IconButton(
                                  icon: Icon(
                                    Icons.layers_rounded,
                                    color: _showHeatmap
                                        ? Colors.white
                                        : AppDesign.textSecondary(isDark),
                                    size: 22,
                                  ),
                                  onPressed: () {
                                    setState(
                                      () => _showHeatmap = !_showHeatmap,
                                    );
                                    if (_showHeatmap &&
                                        widget.detectedPotholes.isEmpty) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'No reported hazards to show on the heatmap yet.',
                                          ),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  },
                                  tooltip: 'Toggle Pothole Heatmap',
                                ),
                              ),

                              const SizedBox(height: 12),

                              // 2. Google Maps Zoom Controls Connected Vertical Pill
                              Container(
                                width: 44,
                                decoration: BoxDecoration(
                                  color: AppDesign.surface(isDark),
                                  borderRadius: BorderRadius.circular(22),
                                  border: Border.all(
                                    color: AppDesign.border(isDark),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: isDark ? 0.3 : 0.12,
                                      ),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        Icons.add_rounded,
                                        color: AppDesign.textPrimary(isDark),
                                        size: 20,
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
                                      icon: Icon(
                                        Icons.remove_rounded,
                                        color: AppDesign.textPrimary(isDark),
                                        size: 20,
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

                              const SizedBox(height: 12),

                              // 3. Google Maps Target My Location Button
                              Container(
                                width: 44,
                                height: 44,
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
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: IconButton(
                                  icon: Icon(
                                    Icons.my_location_rounded,
                                    color: AppDesign.accent(isDark),
                                    size: 22,
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

                        // Tapped location bar (bottom center)
                        if (_tappedPoint != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 28,
                            child: SafeArea(
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: _buildTappedLocationBar(isDark),
                                ),
                              ),
                            ),
                          ),

                        // Zoom-based distance scale bar (Google Maps style, always visible)
                        Positioned(
                          right: 76,
                          bottom: 36,
                          child: SafeArea(
                            child: MapScaleBar(
                              controller: _mapController,
                              isDark: isDark,
                            ),
                          ),
                        ),

                        // 4. Floating Inspector Details Overlay Card (When a Pothole Marker is Selected)
                        if (_selectedPothole != null)
                          Positioned(
                            left: isCompactViewport
                                ? 16
                                : (_showTurnByTurnSheet &&
                                          _routePoints.isNotEmpty
                                      ? null
                                      : 16),
                            right: isCompactViewport
                                ? 16
                                : (_showTurnByTurnSheet &&
                                          _routePoints.isNotEmpty
                                      ? 16
                                      : null),
                            bottom: 24,
                            child: SafeArea(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: isCompactViewport
                                      ? (viewportWidth - 32)
                                      : 520.0,
                                ),
                                child: _buildSelectedPotholeCard(
                                  _selectedPothole!,
                                  isDark,
                                ),
                              ),
                            ),
                          ),

                        // 5. Google Maps Style Searched Place Details Card
                        if (_searchedPlace != null &&
                            _selectedPothole == null &&
                            _routePoints.isEmpty)
                          Positioned(
                            left: 16,
                            right: isCompactViewport ? 16 : null,
                            bottom: 24,
                            child: SafeArea(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: isCompactViewport
                                      ? (viewportWidth - 32)
                                      : 420.0,
                                ),
                                child: _buildSearchedPlaceCard(isDark),
                              ),
                            ),
                          ),

                        // 6. Turn-by-Turn Directions Left-Aligned / Bottom Overlay Sheet
                        if (_showTurnByTurnSheet &&
                            _routePoints.isNotEmpty &&
                            _routeSteps.isNotEmpty &&
                            (!isCompactViewport || _selectedPothole == null))
                          Positioned(
                            left: isCompactViewport ? 12 : 16,
                            right: isCompactViewport ? 12 : null,
                            bottom: 16,
                            child: SafeArea(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: isCompactViewport
                                      ? (viewportWidth - 24)
                                      : 420.0,
                                ),
                                child: _buildTurnByTurnSheet(isDark),
                              ),
                            ),
                          ),
                      ],
                    ),
            );
          },
        );
      },
    );
  }

  Widget _buildRoutePlanningContent({
    required bool isDark,
    required bool isClearAhead,
    required String distStr,
    required String totalEtaStr,
    required int activePotholeCount,
  }) {
    final Color cardBorder = AppDesign.border(isDark);
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);
    const Color brandBlue = Color(0xFF2563EB);

    return Container(
      constraints: const BoxConstraints(maxHeight: 580),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top Travel Mode Row matching Google Maps Web ──
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                // Active Directions Mode Pill
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: brandBlue,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: brandBlue.withValues(alpha: 0.35),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.directions_rounded,
                    color: Colors.white,
                    size: 19,
                  ),
                ),
                const SizedBox(width: 8),

                // 3 OSRM Travel Modes: Driving (car), Bicycle (bike), Walking (foot)
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildModeIconButton(
                        icon: Icons.directions_car_rounded,
                        mode: OsrmTravelMode.car,
                        label: 'Driving',
                        isDark: isDark,
                      ),
                      _buildModeIconButton(
                        icon: Icons.directions_bike_rounded,
                        mode: OsrmTravelMode.bike,
                        label: 'Bicycle',
                        isDark: isDark,
                      ),
                      _buildModeIconButton(
                        icon: Icons.directions_walk_rounded,
                        mode: OsrmTravelMode.foot,
                        label: 'Walking',
                        isDark: isDark,
                      ),
                    ],
                  ),
                ),

                // Close Button
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: subtextColor,
                    size: 20,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  tooltip: 'Close directions',
                  onPressed: () {
                    setState(() {
                      _isRoutePlanningMode = false;
                      _suggestions = [];
                      _isEditingOrigin = false;
                    });
                  },
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: cardBorder),

          // ── Origin & Destination Inputs with Dotted Connector & Swap Button ──
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Left Column: Circle + Dots + Pin
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDark
                              ? Colors.white70
                              : const Color(0xFF64748B),
                          width: 2.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Container(
                      width: 2.5,
                      height: 2.5,
                      decoration: BoxDecoration(
                        color: subtextColor.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Container(
                      width: 2.5,
                      height: 2.5,
                      decoration: BoxDecoration(
                        color: subtextColor.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Container(
                      width: 2.5,
                      height: 2.5,
                      decoration: BoxDecoration(
                        color: subtextColor.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Icon(
                      Icons.place_rounded,
                      color: Color(0xFFEF4444),
                      size: 16,
                    ),
                  ],
                ),

                const SizedBox(width: 10),

                // Center Column: 2 Text Input Boxes
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Starting Point Input
                      Container(
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _isEditingOrigin
                                ? brandBlue
                                : (isDark
                                      ? const Color(0xFF475569)
                                      : const Color(0xFFCBD5E1)),
                            width: _isEditingOrigin ? 1.5 : 1.2,
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _originController,
                                focusNode: _originFocusNode,
                                style: TextStyle(
                                  fontSize: 13.0,
                                  color: textColor,
                                  fontWeight: FontWeight.w500,
                                ),
                                decoration: InputDecoration(
                                  hintText:
                                      "Choose starting point, or click on the map",
                                  hintStyle: TextStyle(
                                    color: subtextColor,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.normal,
                                  ),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                                onTap: () =>
                                    setState(() => _isEditingOrigin = true),
                                onChanged: (val) {
                                  setState(() => _isEditingOrigin = true);
                                  _onSearchChanged(val);
                                },
                                onSubmitted: (_) {
                                  if (_originController.text.isNotEmpty) {
                                    if (_searchController.text.isNotEmpty) {
                                      _searchAndRoute();
                                    } else {
                                      _destinationFocusNode.requestFocus();
                                    }
                                  }
                                },
                              ),
                            ),
                            if (_originController.text.isNotEmpty)
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 24,
                                  minHeight: 24,
                                ),
                                icon: Icon(
                                  Icons.clear_rounded,
                                  size: 15,
                                  color: subtextColor,
                                ),
                                tooltip: 'Clear starting point',
                                onPressed: () {
                                  setState(() {
                                    _originController.clear();
                                    _customOrigin = null;
                                    _suggestions = [];
                                    _routePoints = [];
                                    _alternativeRoutes = [];
                                    _isEditingOrigin = true;
                                  });
                                  _originFocusNode.requestFocus();
                                },
                              ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 8),

                      // Destination Input
                      Container(
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: !_isEditingOrigin
                                ? brandBlue
                                : (isDark
                                      ? const Color(0xFF475569)
                                      : const Color(0xFFCBD5E1)),
                            width: !_isEditingOrigin ? 1.5 : 1.2,
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                focusNode: _destinationFocusNode,
                                style: TextStyle(
                                  fontSize: 13.0,
                                  color: textColor,
                                  fontWeight: FontWeight.w500,
                                ),
                                decoration: InputDecoration(
                                  hintText: "Choose destination...",
                                  hintStyle: TextStyle(
                                    color: subtextColor,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.normal,
                                  ),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                                onTap: () =>
                                    setState(() => _isEditingOrigin = false),
                                onChanged: (val) {
                                  setState(() => _isEditingOrigin = false);
                                  _onSearchChanged(val);
                                },
                                onSubmitted: (val) {
                                  if (val.isNotEmpty) _searchAndRoute();
                                },
                              ),
                            ),
                            if (_searchController.text.isNotEmpty)
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 24,
                                  minHeight: 24,
                                ),
                                icon: Icon(
                                  Icons.clear_rounded,
                                  size: 15,
                                  color: subtextColor,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _searchController.clear();
                                    _destination = null;
                                    _suggestions = [];
                                    _routePoints = [];
                                    _alternativeRoutes = [];
                                    _isEditingOrigin = false;
                                  });
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // Right Column: Swap Button
                IconButton(
                  icon: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF475569)
                            : const Color(0xFFCBD5E1),
                        width: 1.2,
                      ),
                    ),
                    child: Icon(
                      Icons.swap_vert_rounded,
                      color: brandBlue,
                      size: 20,
                    ),
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  tooltip: 'Reverse starting point and destination',
                  onPressed: _swapOriginDestination,
                ),
              ],
            ),
          ),

          Divider(height: 1, thickness: 1, color: cardBorder),

          // ── Scrollable Body: Route Summary OR Suggestions OR History & Presets ──
          Flexible(
            child: SingleChildScrollView(
              child: _suggestions.isNotEmpty
                  ? _buildSuggestionsListInPlanner(isDark)
                  : (_routePoints.isNotEmpty
                        ? _buildRouteSummaryInPlanner(
                            isDark: isDark,
                            isClearAhead: isClearAhead,
                            distStr: distStr,
                            totalEtaStr: totalEtaStr,
                            activePotholeCount: activePotholeCount,
                          )
                        : _buildHistoryAndPresetsInPlanner(isDark)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteSummaryInPlanner({
    required bool isDark,
    required bool isClearAhead,
    required String distStr,
    required String totalEtaStr,
    required int activePotholeCount,
  }) {
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);
    const Color brandBlue = Color(0xFF2563EB);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Primary Route Summary Card
        Container(
          margin: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              totalEtaStr.isNotEmpty ? totalEtaStr : 'Ready',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF10B981),
                                letterSpacing: -0.5,
                              ),
                            ),
                            if (distStr.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Text(
                                '($distStr)',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: subtextColor,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Fastest route • Usual traffic',
                          style: TextStyle(fontSize: 12, color: subtextColor),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _showTurnByTurnSheet = !_showTurnByTurnSheet;
                      });
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _showTurnByTurnSheet
                            ? brandBlue
                            : brandBlue.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.list_alt_rounded,
                            color: _showTurnByTurnSheet
                                ? Colors.white
                                : brandBlue,
                            size: 16,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'Steps',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: _showTurnByTurnSheet
                                  ? Colors.white
                                  : brandBlue,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Road Safety / Hazard Status Chip
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: activePotholeCount == 0
                      ? const Color(0xFF10B981).withValues(alpha: 0.12)
                      : const Color(0xFFEF4444).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: activePotholeCount == 0
                        ? const Color(0xFF10B981).withValues(alpha: 0.3)
                        : const Color(0xFFEF4444).withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      activePotholeCount == 0
                          ? Icons.shield_rounded
                          : Icons.warning_amber_rounded,
                      size: 16,
                      color: activePotholeCount == 0
                          ? const Color(0xFF10B981)
                          : const Color(0xFFEF4444),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        activePotholeCount == 0
                            ? 'Route Clear • 0 Reported Potholes'
                            : '$activePotholeCount pothole hazard${activePotholeCount > 1 ? 's' : ''} detected on this route line${_nearestPotholeInfo.isNotEmpty && _nearestPotholeInfo != 'Clear ahead' ? ' • Next in $_nearestPotholeInfo${_nextPotholeEta != null ? ' (ETA: $_nextPotholeEta)' : ''}' : ''}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: activePotholeCount == 0
                              ? const Color(0xFF10B981)
                              : const Color(0xFFEF4444),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 2. Alternative Routes Selection (if any)
        if (_alternativeRoutes.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Wrap(
              spacing: 8,
              children: List.generate(_alternativeRoutes.length, (idx) {
                final isSelected = _selectedRouteIndex == idx;
                final int hazardsOnRoute = idx < _routePotholeCounts.length
                    ? _routePotholeCounts[idx]
                    : 0;
                final int minHazards = _routePotholeCounts.isEmpty
                    ? 0
                    : _routePotholeCounts.reduce((a, b) => a < b ? a : b);
                final bool isSafest =
                    _routePotholeCounts.isNotEmpty &&
                    hazardsOnRoute == minHazards;
                final String hazardBadge = isSafest && minHazards == 0
                    ? ' • Safest 🛡️'
                    : hazardsOnRoute > 0
                    ? ' • $hazardsOnRoute ⚠️'
                    : ' • Clear';
                final routeDist = idx < _routeDistances.length
                    ? '${(_routeDistances[idx] / 1000).toStringAsFixed(1)} km'
                    : '';
                final routeDur = idx < _routeDurations.length
                    ? _formatEta(
                        _routeDurations[idx],
                        distanceMeters: idx < _routeDistances.length
                            ? _routeDistances[idx]
                            : 0,
                        potholeCount: hazardsOnRoute,
                      )
                    : '';

                return ChoiceChip(
                  label: Text(
                    'Route ${idx + 1}: $routeDur ($routeDist)$hazardBadge',
                  ),
                  selected: isSelected,
                  onSelected: (_) => _selectActiveRoute(idx),
                  selectedColor: brandBlue.withValues(alpha: 0.2),
                  labelStyle: TextStyle(
                    fontSize: 11.5,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isSelected ? brandBlue : textColor,
                  ),
                );
              }),
            ),
          ),

        // 3. Delays & Road Disruptions Footer
        Container(
          margin: const EdgeInsets.fromLTRB(14, 4, 14, 14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Delays & Hazards',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Usual road conditions calculated in ETA',
                style: TextStyle(fontSize: 11.5, color: subtextColor),
              ),
              const SizedBox(height: 4),
              Text(
                activePotholeCount > 0
                    ? '$activePotholeCount pothole hazard${activePotholeCount > 1 ? 's' : ''} located directly on your route path.'
                    : 'No reported pothole hazards along this route path.',
                style: TextStyle(
                  fontSize: 11.0,
                  fontWeight: FontWeight.w600,
                  color: activePotholeCount > 0
                      ? const Color(0xFFEF4444)
                      : subtextColor.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWebPotholeWarningBanner({
    int activePotholeCount = 0,
    String? nearestInfo,
    String? nextPotholeEta,
  }) {
    final bool isOnRoute = _destination != null || _routePoints.isNotEmpty;

    final String distText =
        (nearestInfo != null &&
            nearestInfo.isNotEmpty &&
            nearestInfo != 'Clear ahead')
        ? ' • $nearestInfo ahead'
        : '';

    // If on route, show ETA on next pothole ahead. If not searching any location, strictly NO ETA!
    final String etaText =
        (isOnRoute && nextPotholeEta != null && nextPotholeEta.isNotEmpty)
        ? ' • ETA: $nextPotholeEta'
        : '';

    final String routeInfo = (isOnRoute && activePotholeCount > 0)
        ? ' ($activePotholeCount on route)'
        : '';

    final String title = isOnRoute
        ? 'POTHOLE HAZARD AHEAD'
        : 'POTHOLE HAZARD NEARBY';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFDC2626),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFCA5A5), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.red.withValues(alpha: 0.45),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFDC2626),
              size: 16,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '$title$distText$etaText$routeInfo • SLOW DOWN',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeIconButton({
    required IconData icon,
    required OsrmTravelMode mode,
    required String label,
    required bool isDark,
  }) {
    final bool isSelected = _travelMode == mode;
    const Color brandBlue = Color(0xFF2563EB);
    final Color subtextColor = AppDesign.textSecondary(isDark);

    return InkWell(
      onTap: () {
        setState(() => _travelMode = mode);
        if (_searchController.text.isNotEmpty &&
            _originController.text.isNotEmpty) {
          _searchAndRoute();
        } else if (_destination != null) {
          _calculateRoute(_destination!);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? brandBlue : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Icon(
          icon,
          size: 20,
          color: isSelected ? brandBlue : subtextColor,
        ),
      ),
    );
  }

  Widget _buildHistoryAndPresetsInPlanner(bool isDark) {
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);
    const Color brandBlue = Color(0xFF2563EB);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. "Your location" Quick Item
        InkWell(
          onTap: () {
            if (_currentPosition != null) {
              if (_isEditingOrigin) {
                setState(() {
                  _originController.text = 'Your location';
                  _customOrigin = null;
                });
              } else {
                setState(() {
                  _searchController.text = 'Your location';
                  _destination = _currentPosition;
                });
              }
              if (_originController.text.isNotEmpty &&
                  _searchController.text.isNotEmpty) {
                _searchAndRoute();
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: brandBlue.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.my_location_rounded,
                    color: brandBlue,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  'Your location',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: brandBlue,
                  ),
                ),
              ],
            ),
          ),
        ),

        // 2. "Home" Preset Item
        InkWell(
          onTap: () {
            _selectHistoryItem({
              'name': _homeName,
              'address': _homeAddress,
              'lat': _homeLat,
              'lon': _homeLon,
              'status': 'Home location',
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF0F172A)
                        : const Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.home_outlined,
                    color: isDark ? Colors.white70 : const Color(0xFF475569),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _homeName,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      Text(
                        _homeAddress,
                        style: TextStyle(fontSize: 11.5, color: subtextColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _editHomeLocationDialog,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Edit',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: brandBlue,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        Divider(
          height: 1,
          thickness: 0.8,
          color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
        ),

        // 3. Recent History List
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: _searchHistory.length,
          itemBuilder: (ctx, i) {
            final h = _searchHistory[i];
            final name = (h['name'] ?? '').toString();
            final address = (h['address'] ?? '').toString();
            final status = h['status']?.toString();
            final bool isClosed =
                status?.toLowerCase().contains('closed') == true;

            return Material(
              color: Colors.transparent,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => _selectHistoryItem(h),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF0F172A)
                                      : const Color(0xFFF1F5F9),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.schedule_rounded,
                                  color: subtextColor,
                                  size: 16,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (address.isNotEmpty)
                                    Text(
                                      address,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: subtextColor,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  if (status != null && status.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        status,
                                        style: TextStyle(
                                          fontSize: 11.0,
                                          fontWeight: FontWeight.w600,
                                          color: isClosed
                                              ? const Color(0xFFEF4444)
                                              : const Color(0xFF10B981),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: subtextColor,
                    ),
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    tooltip: 'Remove',
                    onPressed: () => _removeFromSearchHistory(i),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            );
          },
        ),

        // 4. Delays & Road Disruptions Footer matching Screenshot
        Container(
          margin: const EdgeInsets.all(14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Delays',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Light traffic in this area',
                style: TextStyle(fontSize: 11.5, color: subtextColor),
              ),
              const SizedBox(height: 4),
              Text(
                'No known road disruptions. Pothole hazards will show on route.',
                style: TextStyle(
                  fontSize: 11.0,
                  color: subtextColor.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestionsListInPlanner(bool isDark) {
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);
    const Color brandBlue = Color(0xFF2563EB);

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _suggestions.length,
      separatorBuilder: (ctx, i) => Divider(
        height: 1,
        thickness: 0.8,
        color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
      ),
      itemBuilder: (ctx, i) {
        final s = _suggestions[i];
        final name = s['_name'] ?? s['display_name'];
        final shortAddr = s['_short_addr'] ?? '';
        return InkWell(
          onTap: () => _selectSuggestion(s),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: brandBlue.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.place_rounded,
                    color: brandBlue,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (shortAddr.isNotEmpty && shortAddr != name)
                        Text(
                          shortAddr,
                          style: TextStyle(fontSize: 11.5, color: subtextColor),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLocationPermissionCard(bool isDark) {
    final bool isLocationOff = _isLocationDisabled;
    final Color statusColor = isLocationOff
        ? AppDesign.warning
        : AppDesign.accent(isDark);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      decoration: BoxDecoration(
        color: AppDesign.surface(isDark),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppDesign.border(isDark), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.1),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isLocationOff
                ? Icons.location_off_rounded
                : Icons.my_location_rounded,
            color: statusColor,
            size: 24,
          ),
          const SizedBox(height: 12),
          Text(
            isLocationOff ? 'Location Disabled' : 'Location Permission Needed',
            style: TextStyle(
              color: AppDesign.textPrimary(isDark),
              fontSize: 15.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isLocationOff
                ? 'Turn on GPS for live pothole warnings.'
                : 'Grant access for live pothole warnings.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppDesign.textSecondary(isDark),
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          TextButton(
            onPressed: () async {
              if (isLocationOff) {
                await Geolocator.openLocationSettings();
              } else {
                await _determinePosition(requestPermission: true);
              }
            },
            style: TextButton.styleFrom(
              foregroundColor: statusColor,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: statusColor.withValues(alpha: 0.4)),
              ),
            ),
            child: Text(
              isLocationOff ? 'Turn On GPS' : 'Grant Access',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceTab(int index, String label, bool isDark) {
    final isSelected = _placeCardTab == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _placeCardTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected
                    ? const Color(0xFF00796B)
                    : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              color: isSelected
                  ? (isDark ? Colors.white : const Color(0xFF00796B))
                  : (isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCircularAction({
    required IconData icon,
    required String label,
    required bool isPrimary,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isPrimary
                    ? const Color(0xFF00796B)
                    : (isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE0F2F1)),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: isPrimary ? Colors.white : const Color(0xFF00796B),
                size: 22,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : const Color(0xFF334155),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceInfoRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isDark,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: const Color(0xFF00796B)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF1E293B),
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
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
    final String category =
        _searchedPlace!['category'] as String? ?? 'DESTINATION';

    return Container(
      constraints: const BoxConstraints(maxHeight: 520, maxWidth: 420),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Hero Image / Visual Banner Header
              Stack(
                children: [
                  Container(
                    height: 120,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isDark
                            ? [
                                const Color(0xFF0F172A),
                                const Color(0xFF1E293B),
                                const Color(0xFF003853),
                              ]
                            : [
                                const Color(0xFF0288D1),
                                const Color(0xFF0097A7),
                                const Color(0xFF00796B),
                              ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.18),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.location_city_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Text(
                                name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 36),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Floating Close Button (✕)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _searchedPlace = null;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // 2. Title & Rating Block
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 17.5,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : const Color(0xFF202124),
                      ),
                    ),
                    if (address.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        address,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF5F6368),
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Text(
                          '4.8',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFF59E0B),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Row(
                          children: [
                            Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                            Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                            Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                            Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                            Icon(
                              Icons.star_half_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                          ],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '(OSM Verified)',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF5F6368),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF334155)
                                : const Color(0xFFF1F3F4),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            category,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.white70
                                  : const Color(0xFF3C4043),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // 3. Tab Bar (Overview, Routes & Safety, About)
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE2E8F0),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    _buildPlaceTab(0, 'Overview', isDark),
                    _buildPlaceTab(1, 'Routes & Safety', isDark),
                    _buildPlaceTab(2, 'About', isDark),
                  ],
                ),
              ),

              // 4. Circular Actions Row (Directions, A->B Plan, Hazards, Share)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildCircularAction(
                      icon: Icons.directions_rounded,
                      label: 'Directions',
                      isPrimary: true,
                      isDark: isDark,
                      onTap: () {
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
                    ),
                    _buildCircularAction(
                      icon: Icons.alt_route_rounded,
                      label: 'A → B Plan',
                      isPrimary: false,
                      isDark: isDark,
                      onTap: () {
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
                    ),
                    _buildCircularAction(
                      icon: Icons.warning_amber_rounded,
                      label: 'Hazards',
                      isPrimary: false,
                      isDark: isDark,
                      onTap: () {
                        _animatedMapMove(loc, 17.0);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Scanning hazards near $name...'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                    _buildCircularAction(
                      icon: Icons.share_rounded,
                      label: 'Share',
                      isPrimary: false,
                      isDark: isDark,
                      onTap: () {
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
                    ),
                  ],
                ),
              ),

              Divider(
                height: 1,
                thickness: 1,
                color: isDark
                    ? const Color(0xFF334155)
                    : const Color(0xFFF1F5F9),
              ),

              // 5. Details List (Address, ETA, Coordinates, Safety)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    _buildPlaceInfoRow(
                      icon: Icons.location_on_rounded,
                      title: address.isNotEmpty ? address : name,
                      subtitle: distKm > 0
                          ? '${distKm.toStringAsFixed(1)} km from your location (approx. $estMinutes min)'
                          : 'Bulacan, Philippines',
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),
                    _buildPlaceInfoRow(
                      icon: Icons.alt_route_rounded,
                      title: 'Project-OSRM & OpenStreetMap',
                      subtitle:
                          'Lat ${loc.latitude.toStringAsFixed(5)}, Lng ${loc.longitude.toStringAsFixed(5)}',
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),
                    _buildPlaceInfoRow(
                      icon: Icons.shield_rounded,
                      title: 'Pothole Scanner AI Active',
                      subtitle: 'Automatic safe path & proximity alerts ready',
                      isDark: isDark,
                    ),
                  ],
                ),
              ),

              // 6. Bottom Primary CTA Button
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00796B),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.navigation_rounded, size: 18),
                    label: const Text(
                      'Start A → B Navigation',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
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
                  ),
                ),
              ),
            ],
          ),
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

    final type = step.maneuverType.toLowerCase();
    final modifier = (step.modifier ?? '').toLowerCase();

    IconData iconData = Icons.navigation_rounded;

    if (modifier.contains('slight right') ||
        modifier.contains('sharp right') ||
        modifier == 'right') {
      iconData = Icons.turn_right_rounded;
    } else if (modifier.contains('slight left') ||
        modifier.contains('sharp left') ||
        modifier == 'left') {
      iconData = Icons.turn_left_rounded;
    } else if (modifier.contains('uturn')) {
      iconData = Icons.u_turn_left_rounded;
    } else if (type == 'roundabout' || type == 'rotary') {
      iconData = Icons.roundabout_right_rounded;
    } else if (type == 'fork') {
      iconData = modifier.contains('left')
          ? Icons.fork_left_rounded
          : Icons.fork_right_rounded;
    } else if (type == 'merge') {
      iconData = Icons.merge_rounded;
    } else {
      iconData = Icons.straight_rounded;
    }

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
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
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
            label: 'Bike',
            icon: Icons.directions_bike_rounded,
            isDark: isDark,
          ),
          _buildModeTab(
            mode: OsrmTravelMode.foot,
            label: 'Foot',
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
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: isSelected
                ? (isDark ? const Color(0xFF1E293B) : Colors.white)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.3 : 0.08,
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
                size: 16,
                color: isSelected
                    ? const Color(0xFF2563EB)
                    : (isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF64748B)),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? (isDark ? Colors.white : const Color(0xFF0F172A))
                      : (isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTurnByTurnSheet(bool isDark) {
    if (_routePoints.isEmpty || _routeSteps.isEmpty) {
      return const SizedBox.shrink();
    }

    final Set<String> roads = {};
    for (final step in _routeSteps) {
      if (step.roadName.isNotEmpty) roads.add(step.roadName);
    }
    final String roadSummary = roads.isNotEmpty
        ? roads.take(2).join(', ')
        : (_searchController.text.isNotEmpty
              ? _searchController.text
              : 'Selected Route');

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

    final String distStr = activeDistance >= 1000
        ? '${(activeDistance / 1000).toStringAsFixed(1)} km'
        : '${activeDistance.round()} m';
    final String durStr = _formatEta(
      activeDuration,
      distanceMeters: activeDistance,
      potholeCount: _selectedRouteIndex < _routePotholeCounts.length
          ? _routePotholeCounts[_selectedRouteIndex]
          : _potholesOnRoute.length,
    );

    return Container(
      constraints: const BoxConstraints(maxHeight: 440),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 20,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Bar with OSRM Brand and Title
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.alt_route_rounded,
                        color: Color(0xFF2563EB),
                        size: 16,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'OSRM',
                        style: TextStyle(
                          color: Color(0xFF2563EB),
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        roadSummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.white
                              : const Color(0xFF1E293B),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$distStr, $durStr',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: isDark ? Colors.white60 : const Color(0xFF64748B),
                  ),
                  onPressed: () => setState(() => _showTurnByTurnSheet = false),
                ),
              ],
            ),
          ),

          // 3 Travel Modes Selector Bar (Car, Bike, Foot)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _buildTravelModeSelector(isDark),
          ),

          const SizedBox(height: 10),
          Divider(
            height: 1,
            thickness: 1,
            color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
          ),

          // Turn-by-Turn Steps List
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _routeSteps.length,
              separatorBuilder: (ctx, i) => Divider(
                height: 1,
                thickness: 0.8,
                color: isDark
                    ? const Color(0xFF334155).withValues(alpha: 0.5)
                    : const Color(0xFFF1F5F9),
              ),
              itemBuilder: (ctx, i) {
                final step = _routeSteps[i];
                final isFirst = i == 0;
                final isLast = i == _routeSteps.length - 1;
                final isSelected = _selectedStepIndex == i;
                final bool isCurrent =
                    _selectedStepIndex == null &&
                    !isSelected &&
                    i == _computedCurrentStepIndex();

                return InkWell(
                  onTap: () {
                    if (_selectedStepIndex == i) {
                      setState(() => _selectedStepIndex = null);
                      return;
                    }
                    setState(() {
                      _selectedStepIndex = i;
                    });
                    _animatedMapMove(step.location, 17.5);
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: EdgeInsets.symmetric(
                      horizontal: isSelected ? 10 : 8,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(
                              0xFF2563EB,
                            ).withValues(alpha: isDark ? 0.20 : 0.08)
                          : isCurrent
                          ? const Color(
                              0xFF10B981,
                            ).withValues(alpha: isDark ? 0.18 : 0.07)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border: isSelected
                          ? const Border(
                              left: BorderSide(
                                color: Color(0xFF2563EB),
                                width: 3.5,
                              ),
                            )
                          : isCurrent
                          ? const Border(
                              left: BorderSide(
                                color: Color(0xFF10B981),
                                width: 3.5,
                              ),
                            )
                          : null,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Maneuver Icon
                        _buildManeuverIcon(step, isFirst, isLast, isDark),
                        const SizedBox(width: 14),
                        // Step text with bold road name
                        Expanded(child: _buildStepText(step, isDark)),
                        const SizedBox(width: 12),
                        // Distance label on right
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
      ),
    );
  }

  void _onEndpointPanStart(int kind) {
    final LatLng? point = kind == 1
        ? (_customOrigin ?? (_destination != null ? _currentPosition : null))
        : _destination;
    if (point == null) return;
    _endpointPressStart = DateTime.now();
    _endpointDragDistance = 0.0;
    setState(() {
      _draggingEndpointKind = kind;
      _isDraggingEndpoint = true;
      _endpointDragAccum = Offset.zero;
      _endpointDragScreenBase = _mapController.camera.latLngToScreenOffset(
        point,
      );
    });
    _liveRerouteTimer?.cancel();
    _liveRerouteTimer = Timer.periodic(
      const Duration(milliseconds: 850),
      (_) => _rerouteFromEndpoints(),
    );
  }

  void _onEndpointPanUpdate(DragUpdateDetails details) {
    final Offset? base = _endpointDragScreenBase;
    if (!_isDraggingEndpoint || base == null) return;
    _endpointDragAccum += details.delta;
    _endpointDragDistance += details.delta.distance;
    final LatLng moved = _mapController.camera.screenOffsetToLatLng(
      base + _endpointDragAccum,
    );
    final String coords =
        '${moved.latitude.toStringAsFixed(5)}, ${moved.longitude.toStringAsFixed(5)}';
    setState(() {
      if (_draggingEndpointKind == 1) {
        _customOrigin = moved;
        if (_originController.text != coords) _originController.text = coords;
      } else {
        _destination = moved;
        if (_searchController.text != coords) _searchController.text = coords;
      }
    });
  }

  void _onEndpointPanEnd(DragEndDetails details) {
    if (!_isDraggingEndpoint) return;
    _liveRerouteTimer?.cancel();
    _endpointDragScreenBase = null;
    final int kind = _draggingEndpointKind;
    final bool wasTap =
        DateTime.now().difference(_endpointPressStart).inMilliseconds < 350 &&
        _endpointDragDistance < 8.0;
    setState(() => _isDraggingEndpoint = false);

    if (wasTap) {
      _handleEndpointTap(kind);
      return;
    }
    _rerouteFromEndpoints();
    _resolveDraggedLabel(kind);
  }

  void _handleEndpointTap(int kind) {
    final LatLng? loc = kind == 1
        ? (_customOrigin ?? _currentPosition)
        : _destination;
    if (loc == null || !mounted) return;
    setState(() {
      _tappedRequestSeq++;
      _tappedPoint = loc;
      _tappedPointLabel = '';
    });
    _resolveTappedLabel(_tappedRequestSeq);
  }

  Future<void> _resolveTappedLabel(int seq) async {
    final LatLng? point = _tappedPoint;
    if (point == null) return;
    final parts = await _reverseGeocodeParts(point);
    if (!mounted || seq != _tappedRequestSeq || _tappedPoint != point) {
      return;
    }
    setState(() {
      _tappedPointLabel = parts[0];
      _tappedPointSecondary = parts.length > 1 ? parts[1] : '';
    });
  }

  void _routeToTappedPoint() {
    final LatLng? loc = _tappedPoint;
    if (loc == null || !mounted) return;
    final String combined = [
      _tappedPointLabel,
      _tappedPointSecondary,
    ].where((e) => e.isNotEmpty).join(', ');
    setState(() {
      _isRoutePlanningMode = true;
      _destination = loc;
      _searchController.text = combined.isEmpty
          ? '${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)}'
          : combined;
      _tappedPoint = null;
      _tappedPointLabel = '';
      _tappedPointSecondary = '';
    });
    _calculateRoute(loc, customOrigin: _customOrigin);
  }

  Widget _buildTappedLocationBar(bool isDark) {
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);
    const Color brandBlue = Color(0xFF2563EB);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 7, 7),
      decoration: BoxDecoration(
        color: AppDesign.surface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppDesign.border(isDark)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.18),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.place_rounded, color: Color(0xFFEA4335), size: 17),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 210),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _tappedPointLabel.isEmpty
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 11,
                            height: 11,
                            child: CircularProgressIndicator(strokeWidth: 1.6),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Loading…',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: subtextColor,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        _tappedPointLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                if (_tappedPointSecondary.isNotEmpty)
                  Text(
                    _tappedPointSecondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: subtextColor),
                  ),
                Text(
                  '${_tappedPoint!.latitude.toStringAsFixed(5)}, ${_tappedPoint!.longitude.toStringAsFixed(5)}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: subtextColor.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            icon: Icon(Icons.close_rounded, size: 15, color: subtextColor),
            tooltip: 'Dismiss',
            onPressed: () => setState(() {
              _tappedPoint = null;
              _tappedPointLabel = '';
              _tappedPointSecondary = '';
            }),
          ),
          const SizedBox(width: 3),
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: brandBlue,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: brandBlue.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
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
              tooltip: 'Point A to Point B',
              onPressed: _routeToTappedPoint,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _resolveDraggedLabel(int kind) async {
    final LatLng? point = kind == 1
        ? (_customOrigin ?? _currentPosition)
        : _destination;
    if (point == null || !mounted) return;
    final String label = await _reverseGeocodeLabel(point);
    if (!mounted || _isDraggingEndpoint) return;
    setState(() {
      if (kind == 1) {
        _originController.text = label;
      } else {
        _searchController.text = label;
      }
    });
  }

  Future<void> _rerouteFromEndpoints() async {
    final LatLng? dest = _destination;
    if (dest == null || _silentRouting || _isRouting) return;
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

  void _onEndpointPanCancel() {
    _liveRerouteTimer?.cancel();
    _endpointDragScreenBase = null;
    if (!_isDraggingEndpoint) return;
    setState(() => _isDraggingEndpoint = false);
  }

  Marker _buildDraggableEndpointPin({
    required LatLng point,
    required int kind,
    required Color color,
  }) {
    final bool active = _isDraggingEndpoint && _draggingEndpointKind == kind;
    final String label = kind == 1 ? 'A' : 'B';
    return Marker(
      key: ValueKey('endpoint_pin_$kind'),
      point: point,
      width: 44,
      height: 56,
      child: Listener(
        onPointerCancel: (_) => _onEndpointPanCancel(),
        child: MouseRegion(
          cursor: active
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory<GestureRecognizer>>{
              _EagerPanGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    _EagerPanGestureRecognizer
                  >(() => _EagerPanGestureRecognizer(), (instance) {
                    instance.dragStartBehavior = DragStartBehavior.down;
                    instance.onStart = (_) => _onEndpointPanStart(kind);
                    instance.onUpdate = _onEndpointPanUpdate;
                    instance.onEnd = _onEndpointPanEnd;
                    instance.onCancel = _onEndpointPanCancel;
                  }),
            },
            child: Transform.scale(
              scale: active ? 1.12 : 1.0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black45,
                          blurRadius: active ? 10 : 5,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
                  ClipPath(
                    clipper: _PinTipClipper(),
                    child: Container(width: 10, height: 6, color: color),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  int _computedCurrentStepIndex() {
    final pos = _currentPosition;
    if (pos == null || _routeSteps.isEmpty) return -1;
    int bestIdx = -1;
    double bestDist = double.infinity;
    for (int i = 0; i < _routeSteps.length; i++) {
      final loc = _routeSteps[i].location;
      final d = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        loc.latitude,
        loc.longitude,
      );
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  Widget _buildSelectedPotholeCard(PotholeMarker pothole, bool isDark) {
    final isApproved = pothole.status == 'approved';
    final isRejected = pothole.status == 'rejected';
    final Color statusColor = isApproved
        ? const Color(0xFF10B981)
        : (isRejected ? const Color(0xFFEF4444) : const Color(0xFFF59E0B));
    final IconData statusIcon = isApproved
        ? Icons.verified_rounded
        : (isRejected ? Icons.cancel_rounded : Icons.schedule_rounded);
    final String statusText = isApproved
        ? 'VERIFIED LIVE'
        : (isRejected ? 'REJECTED' : 'PENDING REVIEW');

    final String severity = pothole.overallSeverity.toLowerCase();
    final Color severityColor = severity == 'high'
        ? const Color(0xFFEF4444)
        : (severity == 'low'
              ? const Color(0xFFEAB308)
              : const Color(0xFFF97316));
    final IconData severityIcon = severity == 'high'
        ? Icons.dangerous_rounded
        : (severity == 'low'
              ? Icons.warning_amber_rounded
              : Icons.warning_rounded);
    final String severityLabel = severity == 'high'
        ? 'HIGH SEVERITY'
        : (severity == 'low' ? 'LOW SEVERITY' : 'MEDIUM SEVERITY');

    final String docIdStr = pothole.docId != null && pothole.docId!.isNotEmpty
        ? (pothole.docId!.length > 8
              ? pothole.docId!.substring(0, 8).toUpperCase()
              : pothole.docId!.toUpperCase())
        : (pothole.id != null ? '#${pothole.id}' : '#POTHOLE');

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
          width: 1.5,
        ),
        boxShadow: [
          // Ambient colored glow matching severity
          BoxShadow(
            color: severityColor.withValues(alpha: isDark ? 0.32 : 0.20),
            blurRadius: 28,
            spreadRadius: 2,
            offset: const Offset(0, 6),
          ),
          // Deep drop shadow
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.65 : 0.18),
            blurRadius: 36,
            spreadRadius: 4,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(21),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. Top Severity Accent Stripe
            Container(
              height: 4.5,
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [severityColor, statusColor]),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top Title & Badges Bar
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Hazard Icon Pill
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: severityColor.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: severityColor.withValues(alpha: 0.4),
                            width: 1.2,
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            severityIcon,
                            color: severityColor,
                            size: 18,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Road Surface Hazard',
                                  style: TextStyle(
                                    color: isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15.5,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF334155)
                                        : const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: isDark
                                          ? const Color(0xFF475569)
                                          : const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  child: Text(
                                    docIdStr,
                                    style: TextStyle(
                                      color: isDark
                                          ? const Color(0xFF94A3B8)
                                          : const Color(0xFF64748B),
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 1),
                            Text(
                              'Surveyed road telemetry & optical hazard alert',
                              style: TextStyle(
                                color: isDark
                                    ? const Color(0xFF94A3B8)
                                    : const Color(0xFF64748B),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Close Button
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedPothole = null;
                            });
                          },
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF334155)
                                  : const Color(0xFFF1F5F9),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF475569)
                                    : const Color(0xFFE2E8F0),
                              ),
                            ),
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: isDark
                                  ? const Color(0xFFCBD5E1)
                                  : const Color(0xFF475569),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Middle Section: Thumbnail + Detailed Telemetry Badges
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Photo Thumbnail with Tap Preview
                      _buildPotholeImageThumbnail(pothole.imagePath, isDark),
                      const SizedBox(width: 14),

                      // Info Badges Column
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Status & Severity Row
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode)
                                        .withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: DpwhStandards.getCodeColor(pothole.primaryDpwhCode)
                                          .withValues(alpha: 0.7),
                                      width: 1.1,
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
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2563EB).withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: const Color(0xFF2563EB).withValues(alpha: 0.6),
                                      width: 1.1,
                                    ),
                                  ),
                                  child: Text(
                                    'SLA: ${pothole.responseTime}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF2563EB),
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: statusColor.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: statusColor.withValues(alpha: 0.5),
                                      width: 1.1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        statusIcon,
                                        color: statusColor,
                                        size: 12,
                                      ),
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
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: severityColor.withValues(
                                      alpha: 0.14,
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: severityColor.withValues(
                                        alpha: 0.5,
                                      ),
                                      width: 1.1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        severityIcon,
                                        color: severityColor,
                                        size: 12,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        severityLabel,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          color: severityColor,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (pothole.potholeCount > 1)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF334155)
                                          : const Color(0xFFF1F5F9),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isDark
                                            ? const Color(0xFF475569)
                                            : const Color(0xFFE2E8F0),
                                      ),
                                    ),
                                    child: Text(
                                      '${pothole.potholeCount} hazards cluster',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        color: isDark
                                            ? const Color(0xFF94A3B8)
                                            : const Color(0xFF64748B),
                                      ),
                                    ),
                                  ),
                              ],
                            ),

                            const SizedBox(height: 8),

                            // Interactive GPS Pill
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
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
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF0F172A)
                                        : const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isDark
                                          ? const Color(0xFF334155)
                                          : const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.gps_fixed_rounded,
                                        color: Color(0xFF2563EB),
                                        size: 13,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        '${pothole.location.latitude.toStringAsFixed(5)}, ${pothole.location.longitude.toStringAsFixed(5)}',
                                        style: TextStyle(
                                          color: isDark
                                              ? Colors.white
                                              : const Color(0xFF0F172A),
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.copy_rounded,
                                        size: 11.5,
                                        color: isDark
                                            ? const Color(0xFF94A3B8)
                                            : const Color(0xFF64748B),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'DPWH Action: ${pothole.correctiveMeasure}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Actions: Get Directions & Full Report
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 42,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2563EB),
                              foregroundColor: Colors.white,
                              elevation: 2,
                              shadowColor: const Color(
                                0xFF2563EB,
                              ).withValues(alpha: 0.4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                            ),
                            icon: const Icon(Icons.near_me_rounded, size: 17),
                            label: const Text(
                              'Get Directions',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.2,
                              ),
                            ),
                            onPressed: () {
                              setState(() {
                                _destination = pothole.location;
                                _isRoutePlanningMode = false;
                                _searchController.text =
                                    'Hazard (${pothole.location.latitude.toStringAsFixed(4)}, ${pothole.location.longitude.toStringAsFixed(4)})';
                              });
                              _calculateRoute(pothole.location);
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(
                          height: 42,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: isDark
                                  ? Colors.white
                                  : const Color(0xFF0F172A),
                              backgroundColor: isDark
                                  ? const Color(0xFF334155)
                                  : const Color(0xFFF8FAFC),
                              side: BorderSide(
                                color: isDark
                                    ? const Color(0xFF475569)
                                    : const Color(0xFFCBD5E1),
                                width: 1.2,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                            ),
                            icon: const Icon(
                              Icons.assignment_rounded,
                              size: 17,
                              color: Color(0xFF2563EB),
                            ),
                            label: const Text(
                              'Full Report',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            onPressed: () => _showPotholeDetails(pothole),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPotholeImageThumbnail(String imagePath, bool isDark) {
    if (imagePath.startsWith('http') || imagePath.startsWith('blob:')) {
      return GestureDetector(
        onTap: () => _openImagePreview(imagePath),
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.network(
                  imagePath,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      _placeholderThumb(isDark),
                ),
              ),
              Positioned(
                bottom: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24, width: 0.8),
                  ),
                  child: const Icon(
                    Icons.zoom_in_rounded,
                    color: Colors.white,
                    size: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return _placeholderThumb(isDark);
  }

  Widget _placeholderThumb(bool isDark) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.no_photography_rounded,
            color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
            size: 28,
          ),
          const SizedBox(height: 4),
          Text(
            'No Image',
            style: TextStyle(
              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
              fontSize: 9.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
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
    const Color accentColor = Color(0xFF2563EB);
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
                showDialog(
                  context: context,
                  barrierDismissible: true,
                  builder: (ctx) => WebSettingsDialog(
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

  Widget _buildFloatingSearchBar({
    required bool isDark,
    required bool isCompactViewport,
  }) {
    final Color cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final Color cardBorder = isDark
        ? const Color(0xFF334155)
        : const Color(0xFFCBD5E1);
    final Color textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final Color subtextColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);
    const Color brandBlue = Color(0xFF2563EB);

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: _searchFocusNode.hasFocus ? brandBlue : cardBorder,
          width: _searchFocusNode.hasFocus ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.12),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.search_rounded,
            color: _searchFocusNode.hasFocus ? brandBlue : subtextColor,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              style: TextStyle(
                fontSize: 13.5,
                color: textColor,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                hintText: isCompactViewport
                    ? 'Search map...'
                    : 'Search location, destination...',
                hintStyle: TextStyle(
                  color: isDark ? Colors.white38 : const Color(0xFF94A3B8),
                  fontSize: 13.0,
                  fontWeight: FontWeight.normal,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onTap: () {
                setState(() {
                  _isSearchHistoryOpen = true;
                });
              },
              onChanged: (val) {
                setState(() {
                  if (val.trim().isEmpty) {
                    _isSearchHistoryOpen = true;
                    _suggestions = [];
                  } else {
                    _isSearchHistoryOpen = false;
                  }
                });
                _onSearchChanged(val);
              },
              onSubmitted: (val) {
                if (val.isNotEmpty) _searchAndRoute();
              },
            ),
          ),
          if (_searchController.text.isNotEmpty)
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: Icon(Icons.clear_rounded, size: 16, color: subtextColor),
              onPressed: () {
                setState(() {
                  _searchController.clear();
                  _suggestions = [];
                  _routePoints = [];
                  _alternativeRoutes = [];
                  _destination = null;
                  _isSearchHistoryOpen = true;
                });
              },
            ),
          if (_isRouting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: brandBlue,
                ),
              ),
            ),
          Container(
            height: 22,
            width: 1,
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            margin: const EdgeInsets.symmetric(horizontal: 4),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Directions / Plan Route',
            icon: const Icon(
              Icons.directions_rounded,
              size: 22,
              color: brandBlue,
            ),
            onPressed: () {
              setState(() {
                _isRoutePlanningMode = true;
                _originController.text = 'Your location';
                _customOrigin = null;
                _isEditingOrigin = false;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionsDropdown(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.14),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: _suggestions.length,
        separatorBuilder: (ctx, i) => Divider(
          height: 1,
          thickness: 0.8,
          color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
        ),
        itemBuilder: (ctx, i) {
          final s = _suggestions[i];
          final name = s['_name'] ?? s['display_name'];
          final shortAddr = s['_short_addr'] ?? '';
          final bool isHighlighted = i == _highlightedSuggestionIndex;
          return InkWell(
            onTap: () => _selectSuggestion(s),
            child: Container(
              color: isHighlighted
                  ? const Color(0xFF2563EB).withValues(alpha: 0.10)
                  : Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isHighlighted
                          ? const Color(0xFF2563EB)
                          : const Color(0xFF2563EB).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.place_rounded,
                      color: isHighlighted
                          ? Colors.white
                          : const Color(0xFF2563EB),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (shortAddr.isNotEmpty && shortAddr != name)
                          Text(
                            shortAddr,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: isDark
                                  ? const Color(0xFF94A3B8)
                                  : const Color(0xFF64748B),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchHistoryDropdown(bool isDark) {
    final Color cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final Color cardBorder = isDark
        ? const Color(0xFF334155)
        : const Color(0xFFE2E8F0);
    final Color textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final Color subtextColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);
    const Color brandBlue = Color(0xFF2563EB);

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.14),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Recent Searches & Clear All
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history_rounded, size: 16, color: brandBlue),
                    const SizedBox(width: 6),
                    Text(
                      'Recent Searches',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: _clearSearchHistory,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Clear all',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: brandBlue,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Divider(
            height: 1,
            thickness: 0.8,
            color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
          ),

          // Search History Items List
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _searchHistory.length,
              separatorBuilder: (ctx, i) => Divider(
                height: 1,
                thickness: 0.8,
                color: isDark
                    ? const Color(0xFF334155)
                    : const Color(0xFFF1F5F9),
              ),
              itemBuilder: (ctx, i) {
                final h = _searchHistory[i];
                final name = (h['name'] ?? '').toString();
                final address = (h['address'] ?? '').toString();
                final status = h['status']?.toString();
                final bool isClosed =
                    status?.toLowerCase().contains('closed') == true;

                return Material(
                  color: Colors.transparent,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => _selectHistoryItem(h),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF0F172A)
                                        : const Color(0xFFF1F5F9),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.schedule_rounded,
                                    color: subtextColor,
                                    size: 15,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: TextStyle(
                                          fontSize: 13.0,
                                          fontWeight: FontWeight.w600,
                                          color: textColor,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (address.isNotEmpty)
                                        Text(
                                          address,
                                          style: TextStyle(
                                            fontSize: 11.0,
                                            color: subtextColor,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                                if (status != null && status.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Text(
                                      status,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: isClosed
                                            ? const Color(0xFFEF4444)
                                            : const Color(0xFF10B981),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: subtextColor,
                        ),
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        tooltip: 'Remove',
                        onPressed: () => _removeFromSearchHistory(i),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                );
              },
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
