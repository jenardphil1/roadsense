import 'dart:math' as math;
import 'dart:math' show cos, sin, sqrt, atan2;
import 'dart:ui' as ui show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart'
    show
        DragStartBehavior,
        PanGestureRecognizer,
        GestureDisposition,
        GestureRecognizer;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'app_settings.dart';
import 'app_design.dart';
import 'web_components.dart';
import 'web_design.dart';
import 'web_map_side_panel.dart';
import 'web_report_query.dart';
import 'dpwh_standards.dart';
import 'road_hazard_marker.dart';
import 'developer_markers.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:latlong2/latlong.dart' hide Path;
import 'maplibre_style.dart';
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
import 'sta_maria_sample_potholes.dart';
import 'route_pothole_advisor.dart';
import 'road_report_cache.dart';

part 'web_map_screen_cards_part.dart';

enum FollowMode { none, location, compass }

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

    // 1. Realistic ground shadow directly under the pin tip
    final pinH = h - 6;
    final shadowWidth = isLifted ? w * 0.54 : w * 0.44;
    final shadowHeight = isLifted ? 4.5 : 5.0;
    final shadowAlpha = isLifted ? 0.22 : 0.38;
    final shadowRect = Rect.fromCenter(
      center: Offset(w / 2, pinH + 1),
      width: shadowWidth,
      height: shadowHeight,
    );
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: shadowAlpha)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isLifted ? 3.5 : 2.5);
    canvas.drawOval(shadowRect, shadowPaint);

    // 2. Teardrop pin path
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

enum OsrmTravelMode { car, bike, foot }

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
  final String barangay;
  final String city;
  final String province;
  final String formattedAddress;
  final String note;
  final String rejectionReason;
  final DateTime? lastEditedAt;
  final DateTime? moderatedAt;
  final List<Map<String, dynamic>>? detections;
  final bool isResolved;
  final bool isAccessible;
  final String? canonicalDefectId;
  final String? roadName;
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
    this.responseTime = 'High Priority',
    this.correctiveMeasure =
        'Bituminous premix (hot) or penetration patching; add base material if needed.',
    this.barangay = '',
    this.city = '',
    this.province = '',
    this.formattedAddress = '',
    this.note = '',
    this.rejectionReason = '',
    this.lastEditedAt,
    this.moderatedAt,
    this.detections,
    this.isResolved = false,
    this.isAccessible = true,
    this.canonicalDefectId,
    this.roadName,
    this.roadBearingDeg,
    this.roadMatched = false,
  });

  WebReportItem toReportItem() {
    final resolvedId = (docId != null && docId!.isNotEmpty)
        ? docId!
        : (id != null ? id.toString() : '');
    return WebReportItem(
      docId: resolvedId,
      location: location,
      imageUrl: imagePath,
      timestamp: timestamp,
      status: status,
      severity: overallSeverity,
      potholeCount: potholeCount,
      primaryDefect: primaryDefect,
      primaryDpwhCode: primaryDpwhCode,
      responseTime: responseTime,
      correctiveMeasure: correctiveMeasure,
      barangay: barangay,
      city: city,
      province: province,
      formattedAddress: formattedAddress,
      note: note,
      rejectionReason: rejectionReason,
      reporterUid: reporterUid,
      detections: detections ?? const [],
      lastEditedAt: lastEditedAt,
      moderatedAt: moderatedAt,
    );
  }
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
  final bool showEmbeddedNavSwitcher;
  final String? currentUid;
  final bool isAdminUser;
  final bool isCloudLoading;
  final String? cloudError;
  final VoidCallback? onRetryCloud;
  final String? initialReportId;
  final ValueChanged<String?>? onSelectedReportChanged;
  final void Function(LatLng center, double zoom)? onSyncMapViewport;
  final DateTime? reportsLastUpdatedAt;
  final bool isUsingCachedData;
  final double routeCorridorMeters;

  const MapScreen({
    super.key,
    required this.detectedPotholes,
    this.onDeleteDetectedPothole,
    this.onAddDetectedPothole,
    this.onOpenProfile,
    this.isMapActive = true,
    this.showEmbeddedNavSwitcher = true,
    this.currentUid,
    this.isAdminUser = false,
    this.isCloudLoading = false,
    this.cloudError,
    this.onRetryCloud,
    this.initialReportId,
    this.onSelectedReportChanged,
    this.onSyncMapViewport,
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

  final MapController _mapController = MapController();
  ml.MapController? _mlController;
  ml.StyleController? _mlStyle;
  bool _mlStyleReady = false;
  bool? _mlLastIsDark;
  final ValueNotifier<({double bearing, double pitch})> _mlCameraTelemetry =
      ValueNotifier<({double bearing, double pitch})>((
        bearing: 0.0,
        pitch: 50.0,
      ));

  bool get _shouldUseWebVectorMap =>
      kIsWeb && AppSettings.instance.useVectorMapNotifier.value;

  String _colorHex(Color c) {
    final argb = c.toARGB32() & 0x00FFFFFF;
    return '#${argb.toRadixString(16).padLeft(6, '0')}';
  }

  Future<void> _syncWebMapLibreLayers(bool isDark) async {
    final style = _mlStyle;
    if (style == null || !_mlStyleReady || !mounted) return;
    try {
      final showMarkers = AppSettings.instance.showPotholesNotifier.value;
      final filtered = showMarkers
          ? _effectivePotholes
          : const <PotholeMarker>[];

      final hazardItems = filtered.map((p) {
        final cls = DpwhStandards.classifyByName(p.primaryDefect);
        final color = p.status == 'pending'
            ? const Color(0xFFF59E0B)
            : (p.status == 'rejected'
                  ? const Color(0xFF94A3B8)
                  : cls.color);
        return <String, Object?>{
          'id': p.docId ?? p.id?.toString() ?? '',
          'lat': p.location.latitude,
          'lng': p.location.longitude,
          'color': _colorHex(color),
          'defect': p.primaryDefect,
          'status': p.status,
        };
      });
      final hazardsGeoJson = RoadSenseMapLibreStyle.buildHazardsGeoJson(
        hazardItems,
      );

      final routes = <List<List<double>>>[
        for (final r in _alternativeRoutes)
          <List<double>>[
            for (final pt in r) <double>[pt.longitude, pt.latitude],
          ],
      ];
      final routesGeoJson = RoadSenseMapLibreStyle.buildRoutesGeoJson(
        routes,
        _selectedRouteIndex,
      );

      Future<void> upsertGeoJsonSource(String id, String data) async {
        final existing = style.sources[id];
        if (existing is ml.GeoJsonSource) {
          await style.sources.updateGeoJsonData(id, ml.GeoJsonData.text(data));
        } else {
          await style.sources.add(
            ml.GeoJsonSource.data(id: id, data: ml.GeoJsonData.text(data)),
          );
        }
      }

      if (style.sources['rs-web-poblacion-src'] == null) {
        await style.sources.add(
          ml.GeoJsonSource.data(
            id: 'rs-web-poblacion-src',
            data: ml.GeoJsonData.text(
              RoadSenseMapLibreStyle.buildPoblacionBoundaryGeoJson(),
            ),
          ),
        );
      }
      await upsertGeoJsonSource('rs-web-routes-src', routesGeoJson);
      await upsertGeoJsonSource('rs-web-hazards-src', hazardsGeoJson);

      if (style.layers['rs-web-poblacion-fill'] == null) {
        await style.layers.add(
          ml.FillStyleLayer(
            id: 'rs-web-poblacion-fill',
            sourceId: 'rs-web-poblacion-src',
            color: const ml.Expression.literal(Color(0x14DC2626)),
          ),
        );
      }

      if (style.layers['rs-web-poblacion-outline'] == null) {
        await style.layers.add(
          ml.LineStyleLayer(
            id: 'rs-web-poblacion-outline',
            sourceId: 'rs-web-poblacion-src',
            color: const ml.Expression.literal(Color(0xFFDC2626)),
            width: const ml.Expression.literal(2.2),
            dasharray: const ml.Expression.literal([2.5, 2.0]),
          ),
        );
      }

      if (style.layers['rs-web-routes-alt'] == null) {
        await style.layers.add(
          ml.LineStyleLayer(
            id: 'rs-web-routes-alt',
            sourceId: 'rs-web-routes-src',
            filter: const ml.Expression.raw(['==', ['get', 'isActive'], 0]),
            cap: const ml.Expression.literal(ml.LineCap.round),
            join: const ml.Expression.literal(ml.LineJoin.round),
            color: ml.Expression.literal(
              isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
            ),
            width: const ml.Expression.literal(4.5),
            opacity: const ml.Expression.literal(0.75),
          ),
        );
      }

      if (style.layers['rs-web-routes-casing'] == null) {
        await style.layers.add(
          ml.LineStyleLayer(
            id: 'rs-web-routes-casing',
            sourceId: 'rs-web-routes-src',
            filter: const ml.Expression.raw(['==', ['get', 'isActive'], 1]),
            cap: const ml.Expression.literal(ml.LineCap.round),
            join: const ml.Expression.literal(ml.LineJoin.round),
            color: const ml.Expression.literal(Color(0xFF1E3A8A)),
            width: const ml.Expression.literal(10.0),
          ),
        );
      }

      if (style.layers['rs-web-routes-active'] == null) {
        await style.layers.add(
          ml.LineStyleLayer(
            id: 'rs-web-routes-active',
            sourceId: 'rs-web-routes-src',
            filter: const ml.Expression.raw(['==', ['get', 'isActive'], 1]),
            cap: const ml.Expression.literal(ml.LineCap.round),
            join: const ml.Expression.literal(ml.LineJoin.round),
            color: const ml.Expression.literal(Color(0xFF38BDF8)),
            width: const ml.Expression.literal(6.0),
          ),
        );
      }

      if (style.layers['rs-web-hazards-circles'] == null) {
        await style.layers.add(
          ml.CircleStyleLayer(
            id: 'rs-web-hazards-circles',
            sourceId: 'rs-web-hazards-src',
            radius: const ml.Expression.literal(8.5),
            color: const ml.Expression.raw(['get', 'color']),
            strokeColor: const ml.Expression.literal(Colors.white),
            strokeWidth: const ml.Expression.literal(2.0),
            onClick: (event) {
              final id = event.feature.properties['id']?.toString();
              if (id == null || id.isEmpty) return;
              final match = _effectivePotholes.where(
                (p) => (p.docId ?? p.id?.toString() ?? '') == id,
              );
              if (match.isNotEmpty && mounted) {
                setState(() {
                  _selectedPothole = match.first;
                  _searchedPlace = null;
                });
              }
            },
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _toggleWeb3dPitch() async {
    final next3d = !AppSettings.instance.map3dTiltEnabledNotifier.value;
    AppSettings.instance.map3dTiltEnabledNotifier.value = next3d;
    final ctrl = _mlController;
    if (ctrl != null) {
      try {
        await ctrl.animateCamera(
          ml.CameraUpdate.position(pitch: next3d ? 50.0 : 0.0),
          animation: const ml.CameraAnimation.ease(
            duration: Duration(milliseconds: 380),
          ),
        );
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Widget _buildWebMapLibreMap(bool isDark) {
    final center = _initialUrlCenter ?? _currentPosition ?? _bulacanCenter;
    final initPitch = AppSettings.instance.map3dTiltEnabledNotifier.value
        ? 50.0
        : 0.0;
    if (_mlLastIsDark != null && _mlLastIsDark != isDark) {
      _mlStyleReady = false;
    }
    _mlLastIsDark = isDark;
    if (_mlStyleReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_syncWebMapLibreLayers(isDark));
        }
      });
    }
    return ml.MapLibreMap(
      options: ml.MapOptions(
        style: ml.MapStyle.json(
          RoadSenseMapLibreStyle.buildStyleJson(isDark: isDark),
        ),
        initCamera: ml.CameraUpdate.position(
          center: ml.Geographic(lon: center.longitude, lat: center.latitude),
          zoom: _initialUrlZoom ?? 15.0,
          pitch: initPitch,
        ),
        minZoom: 3.0,
        maxZoom: 20.0,
        maxPitch: 60.0,
      ),
      onMapCreated: (ctrl) {
        _mlController = ctrl;
      },
      onStyleLoaded: (style) {
        _mlStyle = style;
        _mlStyleReady = true;
        unawaited(_syncWebMapLibreLayers(isDark));
      },
      onCameraMove: (event) {
        _mlCameraTelemetry.value = (
          bearing: event.camera.bearing,
          pitch: event.camera.pitch,
        );
      },
    );
  }
  double _lastMarkerZoom = 15;
  LatLng? _currentPosition;
  bool _isLocationDisabled = false;
  bool _isPermissionDenied = false;
  bool _dismissedLocationBanner = false;
  PotholeMarker? _selectedPothole;
  String? _expandedClusterId;

  // Redesigned workspace state: unified query, filter drawer, legend, and pagination
  WebReportFilter _reportFilter = const WebReportFilter();
  bool _isFilterDrawerOpen = false;
  bool _isLegendOpen = false;
  bool _isSearchingPlaces = false;
  int _visibleResultLimit = 25;
  GeoBoundsBox? _currentMapBounds;
  bool _hasUnsearchedMapMove = false;
  String? _appliedInitialReportId;

  late final AnimationController _puckPulseController;
  Timer? _urlSyncDebounce;
  LatLng? _initialUrlCenter;
  double? _initialUrlZoom;

  /// Parses deep-linked coordinates from URL hash (supports `#/map?lat=...&lng=...&z=...`
  /// as well as legacy `#/@lat,lng,zoomz`).
  void _parseInitialUrlLocation() {
    if (!kIsWeb) return;
    try {
      final hash = html.window.location.hash;
      if (hash.isEmpty) return;

      final parsed = WebUrlState.parseHash(hash);
      if (parsed.lat != null && parsed.lng != null) {
        _initialUrlCenter = LatLng(parsed.lat!, parsed.lng!);
        if (parsed.zoom != null) _initialUrlZoom = parsed.zoom;
        return;
      }

      final match = RegExp(
        r'@(-?\d+\.?\d*),(-?\d+\.?\d*),?(\d+\.?\d*)?z?',
      ).firstMatch(hash);
      if (match != null) {
        final lat = double.tryParse(match.group(1) ?? '');
        final lng = double.tryParse(match.group(2) ?? '');
        final zoom = double.tryParse(match.group(3) ?? '');
        if (lat != null && lng != null) {
          _initialUrlCenter = LatLng(lat, lng);
          if (zoom != null) _initialUrlZoom = zoom;
        }
      }
    } catch (_) {}
  }

  /// Debounce-synchronizes browser URL hash with `#/map` viewport state through
  /// the web shell router without clobbering Flutter's history stack.
  void _syncUrlCoordinates(LatLng center, double zoom) {
    if (!kIsWeb || !widget.isMapActive || widget.onSyncMapViewport == null) {
      return;
    }
    _urlSyncDebounce?.cancel();
    _urlSyncDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || !widget.isMapActive) return;
      widget.onSyncMapViewport?.call(center, zoom);
    });
  }

  void _animatedMapMove(
    LatLng destLocation,
    double destZoom, {
    bool offsetForSidebar = false,
  }) {
    final mlCtrl = _mlController;
    if (_shouldUseWebVectorMap && mlCtrl != null) {
      unawaited(
        mlCtrl.animateCamera(
          ml.CameraUpdate.position(
            center: ml.Geographic(
              lon: destLocation.longitude,
              lat: destLocation.latitude,
            ),
            zoom: destZoom,
          ),
          animation: const ml.CameraAnimation.ease(
            duration: Duration(milliseconds: 550),
          ),
        ),
      );
    }
    try {
      final startLat = _mapController.camera.center.latitude;
      final startLng = _mapController.camera.center.longitude;
      final startZoom = _mapController.camera.zoom;

      // In the desktop split layout the FlutterMap canvas already sits to the
      // right of the docked workspace panel, so camera center equals canvas center.
      final double targetLng = destLocation.longitude;

      final latTween = Tween<double>(
        begin: startLat,
        end: destLocation.latitude,
      );
      final lngTween = Tween<double>(begin: startLng, end: targetLng);
      final zoomTween = Tween<double>(begin: startZoom, end: destZoom);

      final controller = AnimationController(
        duration: const Duration(milliseconds: 550),
        vsync: this,
      );

      final Animation<double> animation = CurvedAnimation(
        parent: controller,
        curve: Curves.easeOutCubic,
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

  /// Dynamically ensures that a tapped route endpoint (Point A or B) remains
  /// comfortably framed in the active viewport without EVER resetting or overriding
  /// the user's zoom level. If the point is close to the edge or covered by the
  /// floating drawer, it gently pans the map while strictly preserving zoom.
  void _ensureEndpointInView(LatLng point) {
    if (!mounted) return;
    try {
      final camera = _mapController.camera;
      final currentZoom = camera.zoom;
      final screenOffset = camera.latLngToScreenOffset(point);
      final size = MediaQuery.of(context).size;

      // Usable bounds within the screen
      final double leftMargin = (kIsWeb && !_isSidePanelCollapsed)
          ? (size.width < 900 ? 350.0 : 420.0)
          : 64.0;
      final double rightMargin = size.width - 64.0;
      final double topMargin = 90.0;
      final double bottomMargin = size.height - 70.0;

      double deltaX = 0;
      double deltaY = 0;

      if (screenOffset.dx < leftMargin) {
        deltaX = screenOffset.dx - leftMargin;
      } else if (screenOffset.dx > rightMargin) {
        deltaX = screenOffset.dx - rightMargin;
      }

      if (screenOffset.dy < topMargin) {
        deltaY = screenOffset.dy - topMargin;
      } else if (screenOffset.dy > bottomMargin) {
        deltaY = screenOffset.dy - bottomMargin;
      }

      // If comfortably inside visible area, do NOT move the camera at all!
      if (deltaX.abs() < 12 && deltaY.abs() < 12) return;

      final targetScreenCenter = Offset(
        size.width / 2 + deltaX,
        size.height / 2 + deltaY,
      );
      final newCenter = camera.screenOffsetToLatLng(targetScreenCenter);
      _animatedMapMove(newCenter, currentZoom);
    } catch (_) {}
  }

  /// Programmatically locates a scanned hazard on the map and focuses the camera.
  void locatePothole(
    LatLng location,
    String? docId, [
    Map<String, dynamic>? data,
  ]) {
    PotholeMarker? target;
    if (docId != null && docId.isNotEmpty) {
      for (final p in _effectivePotholes) {
        if (p.docId == docId) {
          target = p;
          break;
        }
      }
    }
    if (target == null) {
      for (final p in _effectivePotholes) {
        if ((p.location.latitude - location.latitude).abs() < 0.0001 &&
            (p.location.longitude - location.longitude).abs() < 0.0001) {
          target = p;
          break;
        }
      }
    }
    if (target == null && data != null) {
      final dpwhCode = data['primaryDpwhCode'] as String? ?? 'CODE 01';
      final defectClass =
          DpwhStandards.classForReport(data) ??
          DpwhStandards.classifyByCode(dpwhCode);
      target = PotholeMarker(
        docId: docId ?? '',
        location: location,
        imagePath: data['imageUrl'] as String? ?? '',
        timestamp:
            (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
        status: data['status'] as String? ?? 'pending',
        overallSeverity: data['overallSeverity'] as String? ?? 'medium',
        reporterEmail: data['reporterEmail'] as String? ?? '',
        reporterUid: data['reporterUid'] as String?,
        potholeCount: (data['potholeCount'] as num?)?.toInt() ?? 1,
        primaryDpwhCode: dpwhCode,
        primaryDefect: DpwhStandards.reportDefectName(data),
        responseTime:
            data['responseTime'] as String? ?? defectClass.responseTime,
        correctiveMeasure:
            data['correctiveMeasure'] as String? ??
            defectClass.correctiveMeasure,
        barangay: data['barangay'] as String? ?? '',
        city: data['city'] as String? ?? '',
        province: data['province'] as String? ?? '',
        formattedAddress: data['formattedAddress'] as String? ?? '',
        note: data['note'] as String? ?? '',
        rejectionReason: data['rejectionReason'] as String? ?? '',
        lastEditedAt: (data['lastEditedAt'] as Timestamp?)?.toDate(),
        moderatedAt: (data['moderatedAt'] as Timestamp?)?.toDate(),
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

    _setSelectedPothole(target, notify: true, animate: false);
    _stopRouteSimulation();
    setState(() {
      _resetRoutePlannerState();
      _isRoutePlanningMode = false;
      _searchedPlace = null;
      _suggestions = [];
      _isSearchHistoryOpen = false;
    });

    Future.delayed(const Duration(milliseconds: 220), () {
      if (mounted) _animatedMapMove(location, 17.5);
    });
  }

  void _setSelectedPothole(
    PotholeMarker? pothole, {
    bool notify = true,
    bool animate = true,
  }) {
    final docId = pothole?.docId;
    setState(() {
      _selectedPothole = pothole;
      _expandedClusterId = null;
      _isLegendOpen = false;
      _suggestions = [];
      _isSearchHistoryOpen = false;
      if (pothole != null) {
        _appliedInitialReportId = (docId != null && docId.isNotEmpty)
            ? docId
            : _appliedInitialReportId;
      }
    });
    if (notify) {
      widget.onSelectedReportChanged?.call(
        (docId != null && docId.isNotEmpty) ? docId : null,
      );
    }
    if (pothole != null && animate) {
      _animatedMapMove(pothole.location, 17.5);
    }
  }

  void _syncInitialReportSelection() {
    final desiredId = widget.initialReportId?.trim();
    if (desiredId == null || desiredId.isEmpty) {
      if (_appliedInitialReportId != null) {
        _appliedInitialReportId = null;
        if (_selectedPothole != null && mounted) {
          setState(() => _selectedPothole = null);
        }
      }
      return;
    }
    if (_appliedInitialReportId == desiredId &&
        _selectedPothole?.docId == desiredId) {
      return;
    }
    for (final p in _effectivePotholes) {
      if (p.docId == desiredId) {
        _appliedInitialReportId = desiredId;
        if (mounted) {
          setState(() {
            _selectedPothole = p;
            _isRoutePlanningMode = false;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _animatedMapMove(p.location, 17.5);
          });
        }
        return;
      }
    }
  }

  PotholeMarker? _findMarkerForItem(WebReportItem item) {
    if (item.docId.isNotEmpty) {
      for (final p in _effectivePotholes) {
        if (p.docId == item.docId) return p;
      }
    }
    for (final p in _effectivePotholes) {
      if ((p.location.latitude - item.location.latitude).abs() < 1e-6 &&
          (p.location.longitude - item.location.longitude).abs() < 1e-6) {
        return p;
      }
    }
    return null;
  }

  WebReportQueryResult _computeReportQuery() {
    final showRejected = _reportFilter.statuses.contains('rejected');
    final dataset = _effectivePotholes
        .where(
          (p) =>
              p.status != 'deleted' && (p.status != 'rejected' || showRejected),
        )
        .map((p) => p.toReportItem())
        .toList(growable: false);
    // Point A -> B and selected-place flows write the destination/place label
    // into _searchController, so keep map and list markers visible rather than
    // filtering reports by destination text or a stale area filter.
    final bool isRouteFlow =
        _isRoutePlanningMode || _destination != null || _routePoints.isNotEmpty;
    final bool isPlaceOrRouteQuery = isRouteFlow || _searchedPlace != null;
    final WebReportFilter effectiveFilter =
        isRouteFlow && _reportFilter.onlyInMapBounds
        ? _reportFilter.copyWith(onlyInMapBounds: false)
        : _reportFilter;
    return WebReportQueryEngine.execute(
      dataset: dataset,
      filter: effectiveFilter,
      query: isPlaceOrRouteQuery ? '' : _searchController.text,
      mapBounds: _currentMapBounds,
      referencePoint: _currentPosition,
    );
  }

  List<PotholeMarker> _markersForResult(WebReportQueryResult result) {
    final visibleIds = <String>{};
    final visibleCoords = <String>{};
    for (final item in result.items) {
      if (item.docId.isNotEmpty) visibleIds.add(item.docId);
      visibleCoords.add(_potholeKey(item.location));
    }
    return _effectivePotholes
        .where((p) {
          if (p.status == 'deleted') return false;
          if (p.status == 'rejected' &&
              !_reportFilter.statuses.contains('rejected')) {
            return false;
          }
          if (p.docId != null && p.docId!.isNotEmpty) {
            return visibleIds.contains(p.docId);
          }
          return visibleCoords.contains(_potholeKey(p.location));
        })
        .toList(growable: false);
  }

  List<WebUnifiedSearchSuggestion> _buildUnifiedSuggestions(
    List<WebReportItem> dataset,
  ) {
    final q = _searchController.text.trim();
    if (q.isEmpty) return const [];
    final reportMatches = WebReportQueryEngine.searchSuggestions(
      dataset: dataset,
      query: q,
      limit: 4,
    );
    return [
      for (final match in reportMatches)
        WebUnifiedSearchSuggestion.report(
          match.item,
          reportMatchReason: match.matchReason,
        ),
      for (final place in _suggestions)
        if (place is Map)
          WebUnifiedSearchSuggestion.place(Map<String, dynamic>.from(place)),
    ];
  }

  GeoBoundsBox? _readCameraBoundsBox() {
    try {
      final b = _mapController.camera.visibleBounds;
      return GeoBoundsBox(
        north: b.north,
        south: b.south,
        east: b.east,
        west: b.west,
      );
    } catch (_) {
      return null;
    }
  }

  void _updateReportFilter(WebReportFilter next) {
    final enableBounds = next.onlyInMapBounds && !_reportFilter.onlyInMapBounds;
    setState(() {
      _reportFilter = next;
      _visibleResultLimit = 25;
      if (enableBounds) {
        _currentMapBounds = _readCameraBoundsBox();
        _hasUnsearchedMapMove = false;
      } else if (!next.onlyInMapBounds) {
        _currentMapBounds = null;
        _hasUnsearchedMapMove = false;
      }
    });
  }

  void _searchThisAreaNow() {
    final box = _readCameraBoundsBox();
    if (box == null) return;
    setState(() {
      _currentMapBounds = box;
      _hasUnsearchedMapMove = false;
      if (!_reportFilter.onlyInMapBounds) {
        _reportFilter = _reportFilter.copyWith(onlyInMapBounds: true);
      }
      _visibleResultLimit = 25;
    });
  }

  Future<void> _openBarangayPicker() async {
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (_) => SantaMariaBarangayPickerDialog(
        initialSelection: _reportFilter.barangayKeys,
      ),
    );
    if (picked == null || !mounted) return;
    _updateReportFilter(_reportFilter.copyWith(barangayKeys: picked));
  }

  Future<void> _selectUnifiedSuggestion(
    WebUnifiedSearchSuggestion suggestion,
  ) async {
    if (suggestion.isReport && suggestion.report != null) {
      final marker = _findMarkerForItem(suggestion.report!);
      _searchFocusNode.unfocus();
      if (marker != null) {
        _setSelectedPothole(marker, notify: true, animate: true);
        if (mounted && MediaQuery.sizeOf(context).width < 900) {
          _openCompactReportSheet(marker);
        }
      }
      return;
    }
    if (suggestion.rawPlace != null) {
      await _selectPlaceSuggestion(suggestion.rawPlace!);
    }
  }

  Future<void> _selectPlaceSuggestion(Map<String, dynamic> suggestion) async {
    double? lat = double.tryParse((suggestion['lat'] ?? '').toString());
    double? lon = double.tryParse((suggestion['lon'] ?? '').toString());
    final bool needsGeocode = suggestion['_needs_geocode'] == true;
    final String queryStr =
        (suggestion['display_name'] ?? suggestion['_name'] ?? '').toString();

    if ((lat == null || lon == null || needsGeocode) && queryStr.isNotEmpty) {
      if (mounted) setState(() => _isSearchingPlaces = true);
      final resolved = await _geocodeQuery(queryStr);
      if (mounted) setState(() => _isSearchingPlaces = false);
      if (resolved == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not locate coordinates for "$queryStr".'),
            ),
          );
        }
        return;
      }
      lat = resolved.latitude;
      lon = resolved.longitude;
    }

    if (lat == null || lon == null) return;
    final enriched = Map<String, dynamic>.from(suggestion);
    enriched['lat'] = lat.toString();
    enriched['lon'] = lon.toString();
    _selectSuggestion(enriched);
  }

  Future<void> _confirmTrashReport(WebReportItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move report to Trash?'),
        content: const Text(
          'This removes the pending report from the map and moves it to your Trash in My Reports, where you can restore or permanently delete it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (isSampleStaMariaMarkerId(item.docId)) {
        final marker = _findMarkerForItem(item);
        if (marker != null) {
          await _deleteDetectedPothole(marker);
        }
      } else if (item.docId.isNotEmpty) {
        await CloudService.instance.userSoftDeletePothole(item.docId);
      } else {
        final marker = _findMarkerForItem(item);
        if (marker != null && widget.onDeleteDetectedPothole != null) {
          await _deleteDetectedPothole(marker);
        }
      }
      if (!mounted) return;
      _setSelectedPothole(null, notify: true, animate: false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Report moved to Trash.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not move report to Trash: ${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    }
  }

  Future<void> _handleAdminModeration(
    WebReportItem item,
    String newStatus,
  ) async {
    if (!widget.isAdminUser || item.docId.isEmpty) return;
    try {
      await CloudService.instance.updatePotholeStatus(item.docId, newStatus);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Report status updated to $newStatus.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Moderation failed: ${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
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
  List<Map<String, dynamic>> _searchHistory = [];
  bool _isSearchHistoryOpen = false;
  int _highlightedSuggestionIndex = -1;

  String _homeName = 'Home';
  String _homeAddress =
      'Mapulang Lupa Elementary School, Mapulang Lupa, Valenzuela';
  double _homeLat = 14.7019;
  double _homeLon = 121.0003;

  static final List<Map<String, dynamic>> _defaultSearchHistory = [
    {
      'name': 'Immaculate Conception I-College',
      'address': 'Bonifacio Street, Poblacion, Santa Maria, Bulacan',
      'lat': 14.8177,
      'lon': 120.9622,
      'status': 'Open • Closes 5PM',
    },
    {
      'name': 'Santa Maria Municipal Hall - Bulacan',
      'address': 'Poblacion, Santa Maria, Bulacan',
      'lat': 14.8193,
      'lon': 120.9604,
      'status': 'Closed • Opens 8AM Mon',
    },
    {
      'name': 'Municipal Hall Drive',
      'address': 'Poblacion, Santa Maria, Bulacan',
      'lat': 14.8191,
      'lon': 120.9605,
      'status': 'Open 24 hours',
    },
    {
      'name': 'N-la Cellphone Accessories & General M...',
      'address': 'Governor Fortunato Halili Avenue, Bagbagu...',
      'lat': 14.8115,
      'lon': 120.9520,
      'status': 'Open • Closes 8PM',
    },
    {
      'name': 'Gracia Motorcycle Shop and Supplies',
      'address': 'Quirino Highway, Gumaoc East, San Jose d...',
      'lat': 14.7991,
      'lon': 121.0689,
      'status': 'Closed • Opens 8AM Sat',
    },
    {
      'name': 'Real de Cacarong',
      'address': 'Pandi, Bulacan',
      'lat': 14.9042,
      'lon': 120.9677,
      'status': 'Historic Landmark',
    },
  ];

  LatLng? _customOrigin;
  bool _isRoutePlanningMode = false;
  bool _isSidePanelCollapsed = false;
  bool _isEditingOrigin = false;
  List<LatLng> _routePoints = [];
  List<List<LatLng>> _alternativeRoutes = [];
  List<int> _routePotholeCounts = [];
  List<double> _routeDurations = [];

  /// OSRM response code from the last routing request ('Ok', 'NoRoute',
  /// 'WaypointNotFound', ...). Lets the empty-routes error distinguish a
  /// genuinely unreachable destination from a connection failure.
  String _lastRoutingEngineCode = '';
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
  final Map<String, bool> _snappedWasVerified = {};

  List<dynamic> _suggestions = [];
  int _searchRevision = 0;
  Timer? _debounceTimer;
  Map<String, dynamic>? _searchedPlace;
  int _placeCardTab = 0;

  // Navigation / Follow Mode state
  FollowMode _followMode = FollowMode.location;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  LatLng? _destination;
  double? _lastGpsAccuracyMeters;
  double? _lastGpsSpeedMps;
  DateTime? _lastGpsTimestamp;

  /// True once the user has typed into the Point B (destination) field since
  /// the last successful route plan. [ _searchAndRoute ] re-geocodes the typed
  /// text instead of reusing a stale [_destination] when this is set, so new
  /// destinations replace the old camera target instead of routing to it.
  bool _destinationTextDirty = false;

  /// Same as [_destinationTextDirty] but for the Point A (origin) field, so a
  /// retyped origin overrides a stale [_customOrigin] instead of routing
  /// from the previously chosen starting point.
  bool _originTextDirty = false;

  final ValueNotifier<double?> _lastHeadingNotifier = ValueNotifier(null);
  List<LatLng> _potholesOnRoute = [];
  RouteComparisonResult? _routeComparison;
  PrecomputedRouteIndex? _activeRouteIndex;
  NavigationHazardTracker? _navigationTracker;
  NavigationHazardState? _navHazardState;
  bool _showPotholesAlongRouteOnly = false;
  bool _isSearchingAlternatives = false;
  bool _hasEvaluatedFewerPotholes = false;
  String? _routeErrorMessage;
  bool _routeUsingCachedGeometry = false;
  bool _isCompactRouteDrawerExpanded = true;

  // Pothole Proximity Alert & Route Advisor
  late final FlutterTts _tts = FlutterTts();
  String _nearestPotholeInfo = '';
  String? _nextPotholeEta;
  final Set<String> _alertedAt50m = {};
  bool _isInitialStartup = true;
  bool _showWarningBanner = false;
  bool _showHeatmap = false;
  final Set<String> _dismissedSampleIds = {};
  RouteSwitchSuggestion? _routeSwitchSuggestion;
  UpcomingHazardCountdown? _upcomingHazard;
  Timer? _simulationTimer;
  bool _isSimulatingRoute = false;
  double _simulatedChainMeters = 0.0;

  RouteBoundingBox? _lastMarkerViewportBounds;
  bool _pendingPostFrameViewportRebuild = false;

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
  }

  /// Filters [markers] to the current camera viewport (with buffer margin),
  /// recording [_lastMarkerViewportBounds] so subsequent pans/zooms or route
  /// camera fits refresh culled pins on demand. When the MapController has not
  /// rendered yet, every marker is kept visible.
  List<PotholeMarker> _filterMarkersInViewport(List<PotholeMarker> markers) {
    final bounds = _readMarkerViewportBounds();
    if (bounds == null) return markers;
    _lastMarkerViewportBounds = bounds;
    return markers.where((p) => bounds.containsWithMargin(p.location)).toList();
  }

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
  int _routingRequestSeq = 0;
  bool _isSearchVisible = true;

  // Point-to-Point Location Pill State (Draggable screen pill + interactive draggable map pin)
  Offset? _p2pPillOffset;
  bool _isP2pPillVisible = false;
  LatLng? _p2pPoint;
  String _p2pName = '';
  String _p2pAddress = '';
  double _p2pDistanceKm = 0.0;
  int _p2pMinutes = 0;
  int _p2pHazardCount = 0;

  bool _isPlacingMarker = false;
  LatLng? _pendingMarkerLocation;
  String _pendingMarkerDefect = DpwhStandards.pothole.name;

  void _setPendingMarkerDefect(String defect) {
    setState(() => _pendingMarkerDefect = defect);
  }
  Completer<LatLng?>? _pinPickerCompleter;

  static const double _snapRadiusMeters = 35.0;
  static const double _proximityCircleRadiusMeters = 22.0;
  static const double _offRouteRerouteThresholdMeters = 55.0;
  static const Duration _autoRerouteCooldown = Duration(seconds: 12);

  double get _routeCountToleranceMeters =>
      RouteCorridorConfig.effectiveCorridorMeters(
        baseCorridorMeters: widget.routeCorridorMeters,
        gpsAccuracyMeters: _lastGpsAccuracyMeters,
      );

  double get _routeWarningToleranceMeters => _routeCountToleranceMeters;

  RouteCorridorConfig get _corridorConfig =>
      RouteCorridorConfig(corridorMeters: _routeCountToleranceMeters);

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

      if (DeveloperMarkers.owns(_selectedPothole?.docId)) {
        final matching = _localDeveloperMarkers.where(
          (p) => p.docId == _selectedPothole!.docId,
        );
        _selectedPothole = matching.isEmpty ? null : matching.first;
      }
    });
    unawaited(_refreshRouteAwarePotholeState());
  }

  List<PotholeMarker> get _effectivePotholes => [
    ...widget.detectedPotholes.where((p) => !isSampleStaMariaMarkerId(p.docId)),
    ..._localDeveloperMarkers,
  ];

  bool _isReportExcluded(PotholeMarker p) {
    final normalizedStatus = p.status.trim().toLowerCase();
    return p.isResolved ||
        !p.isAccessible ||
        normalizedStatus == 'deleted' ||
        normalizedStatus == 'rejected' ||
        normalizedStatus == 'resolved' ||
        normalizedStatus == 'fixed' ||
        normalizedStatus == 'closed';
  }

  List<LatLng> get _allPotholeLocations => _effectivePotholes
      .where((p) => !_isReportExcluded(p))
      .map((p) => p.location)
      .toList();

  List<RouteHazardInput> _buildHazardInputs() {
    final List<RouteHazardInput> inputs = [];
    for (final p in _effectivePotholes) {
      if (_isReportExcluded(p)) continue;
      final key = _potholeKey(p.location);
      final snapped = _snappedPotholeCache[key] ?? p.location;
      final bool wasVerifiedSnap = _snappedWasVerified[key] == true;
      final String normalizedStatus = p.status.trim().toLowerCase();
      final String canonicalName = DpwhStandards.reportDefectName({
        'primaryDefect': p.primaryDefect,
        'primaryDpwhCode': p.primaryDpwhCode,
        'detections': p.detections,
      });
      final detectedDefects = DpwhStandards.extractDetectionClassNames(
        p.detections,
      );
      final String? docId = p.docId?.trim();
      final String? reportId = (docId != null && docId.isNotEmpty)
          ? docId
          : p.id?.toString();
      inputs.add(
        RouteHazardInput(
          location: snapped,
          rawLocation: p.location,
          defectName: canonicalName,
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
          roadMatched: wasVerifiedSnap || p.roadMatched,
          updatedAt: p.moderatedAt ?? p.lastEditedAt ?? p.timestamp,
        ),
      );
    }
    return inputs;
  }

  static const double _lookAheadOffset = 0.0018;

  static const String _orsApiKey = String.fromEnvironment('ORS_API_KEY');

  Map<String, String>? _safeHeaders([Map<String, String>? additional]) {
    final headers = <String, String>{};
    if (additional != null) headers.addAll(additional);
    if (!kIsWeb) {
      headers['User-Agent'] = 'RoadSense-GIS/1.0';
    }
    return headers.isEmpty ? null : headers;
  }

  @override
  void initState() {
    super.initState();
    DeveloperMarkers.instance.addListener(_onDeveloperMarkersChanged);
    AppSettings.instance.devMockModeNotifier.addListener(
      _onDeveloperMarkersChanged,
    );
    unawaited(DeveloperMarkers.instance.load().catchError((Object _) {}));

    _parseInitialUrlLocation();
    _puckPulseController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    )..repeat();
    if (_cachedGlobalPosition != null) {
      _currentPosition = _cachedGlobalPosition;
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
    AppSettings.instance.manualPinPickerRequestNotifier.addListener(
      _onManualPinPickerRequested,
    );
    AppSettings.instance.devEditLocationNotifier.addListener(
      _onDevEditLocationSettingChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncInitialReportSelection();
    });
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  bool _searchKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      if (_highlightedSuggestionIndex >= 0 ||
          _suggestions.isNotEmpty ||
          _isSearchHistoryOpen ||
          _isLegendOpen ||
          _selectedPothole != null) {
        setState(() {
          _highlightedSuggestionIndex = -1;
          _suggestions = [];
          _isSearchHistoryOpen = false;
          _isLegendOpen = false;
        });
        if (_selectedPothole != null) {
          _setSelectedPothole(null, notify: true, animate: false);
        }
        _searchFocusNode.unfocus();
        return true;
      }
      return false;
    }

    if (!_searchFocusNode.hasFocus) return false;
    final dataset = _effectivePotholes
        .where((p) => p.status != 'deleted')
        .map((p) => p.toReportItem())
        .toList(growable: false);
    final unified = _buildUnifiedSuggestions(dataset);
    if (unified.isEmpty) return false;

    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlightedSuggestionIndex = (_highlightedSuggestionIndex + 1).clamp(
          0,
          unified.length - 1,
        );
      });
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlightedSuggestionIndex = (_highlightedSuggestionIndex - 1).clamp(
          0,
          unified.length - 1,
        );
      });
      return true;
    }
    if (key == LogicalKeyboardKey.enter &&
        _highlightedSuggestionIndex >= 0 &&
        _highlightedSuggestionIndex < unified.length) {
      unawaited(_selectUnifiedSuggestion(unified[_highlightedSuggestionIndex]));
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

          // Auto-heal: update any legacy default items that have outdated coordinates
          bool needsSave = false;
          for (final def in _defaultSearchHistory) {
            final defName = (def['name'] ?? '').toString().toLowerCase();
            for (var h in _searchHistory) {
              final hName = (h['name'] ?? '').toString().toLowerCase();
              if (hName == defName ||
                  (defName.startsWith('immaculate') &&
                      hName.startsWith('immaculate')) ||
                  (defName.startsWith('santa maria municipal') &&
                      hName.startsWith('santa maria municipal')) ||
                  (defName.startsWith('municipal hall drive') &&
                      hName.startsWith('municipal hall drive')) ||
                  (defName.startsWith('n-la') && hName.startsWith('n-la')) ||
                  (defName.startsWith('gracia') &&
                      hName.startsWith('gracia')) ||
                  (defName.startsWith('real de cacarong') &&
                      hName.startsWith('real de cacarong'))) {
                if (h['lat'] != def['lat'] || h['lon'] != def['lon']) {
                  h['lat'] = def['lat'];
                  h['lon'] = def['lon'];
                  h['address'] = def['address'];
                  needsSave = true;
                }
              }
            }
          }
          if (needsSave) {
            _saveSearchHistory();
          }
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
          _originTextDirty = false;
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
          _destinationTextDirty = false;
        });
        _destinationFocusNode.unfocus();
        _showPointToPointPill(
          point: targetLocation,
          name: name,
          address: address,
        );
        if (_originController.text.trim().isEmpty) {
          _originController.text = 'Your location';
          _customOrigin = null;
        }
        final start =
            (_originController.text == 'Your location' || _customOrigin == null)
            ? (_currentPosition ?? _bulacanCenter)
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
        _destinationTextDirty = false;
        _originTextDirty = false;
      });

      _searchFocusNode.unfocus();
      _showPointToPointPill(
        point: targetLocation,
        name: name,
        address: address,
      );

      _addToSearchHistory(
        name: rawName == 'Home' && address.isNotEmpty ? address : rawName,
        address: (item['address'] ?? '').toString(),
        lat: lat,
        lon: lon,
        status: item['status']?.toString(),
      );

      _calculateRoute(
        targetLocation,
        customOrigin: _currentPosition ?? _bulacanCenter,
      );
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

  void _onManualPinPickerRequested() {
    if (!mounted) return;
    _beginMapPinPicker();
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
      _snappedWasVerified.clear();
      unawaited(_refreshRouteAwarePotholeState());
    }
    if (oldWidget.initialReportId != widget.initialReportId ||
        oldSig != newSig) {
      _syncInitialReportSelection();
    }
  }

  @override
  void dispose() {
    DeveloperMarkers.instance.removeListener(_onDeveloperMarkersChanged);
    AppSettings.instance.devMockModeNotifier.removeListener(
      _onDeveloperMarkersChanged,
    );

    AppSettings.instance.manualPotholePlacementNotifier.removeListener(
      _onManualPotholePlacementSettingChanged,
    );
    AppSettings.instance.manualPinPickerRequestNotifier.removeListener(
      _onManualPinPickerRequested,
    );
    AppSettings.instance.devEditLocationNotifier.removeListener(
      _onDevEditLocationSettingChanged,
    );
    if (_pinPickerCompleter != null && !_pinPickerCompleter!.isCompleted) {
      _pinPickerCompleter!.complete(null);
      _pinPickerCompleter = null;
    }
    _simulationTimer?.cancel();
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
    _urlSyncDebounce?.cancel();
    _puckPulseController.dispose();
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

    final double distToProj = Geolocator.distanceBetween(
      userPos.latitude,
      userPos.longitude,
      projPoint.latitude,
      projPoint.longitude,
    );
    if (distToProj > _offRouteRerouteThresholdMeters) {
      return [userPos, route.last];
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

    // Do not auto-switch routes silently; keep the selected route intact unless
    // the driver leaves it completely and needs off-route recalculation.
    final bool shouldReroute = activeDist > _offRouteRerouteThresholdMeters;
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

  void _startFollowing() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _compassSubscription?.cancel();
    _compassSubscription = null;

    if (!mounted ||
        !widget.isMapActive ||
        _isPermissionDenied ||
        _isLocationDisabled) {
      return;
    }

    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 3,
          ),
        ).listen(
          (Position position) {
            if (!widget.isMapActive || !mounted) return;
            final gpsPos = LatLng(position.latitude, position.longitude);
            _lastRealGpsPosition = gpsPos;
            _lastGpsAccuracyMeters = position.accuracy;
            _lastGpsSpeedMps = position.speed;
            _lastGpsTimestamp = position.timestamp;
            if (position.heading >= 0) {
              _lastHeadingNotifier.value = position.heading;
            }

            if (_useMockLocation) {
              return;
            }

            final newPos = gpsPos;
            if (mounted) {
              setState(() => _currentPosition = newPos);
            }
            _checkPotholeProximity(
              newPos,
              gpsAccuracyMeters: position.accuracy,
              headingDeg: position.heading >= 0 ? position.heading : null,
              speedMps: position.speed,
              timestamp: position.timestamp,
            );
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
          },
          onError: (Object error, StackTrace _) {
            debugPrint('Location stream unavailable: $error');
            _positionSubscription?.cancel();
            _positionSubscription = null;
            if (mounted && error is PermissionDeniedException) {
              setState(() => _isPermissionDenied = true);
            }
          },
          cancelOnError: true,
        );

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

  RouteHazardSummary? get _currentActiveRouteSummary {
    final RouteComparisonResult? comparison = _routeComparison;
    return _activeRouteIndex?.summary ??
        (comparison != null && _selectedRouteIndex < comparison.options.length
            ? comparison.options[_selectedRouteIndex].summary
            : null);
  }

  void _syncP2pSummaryForRoute(int routeIndex, {LatLng? destinationOverride}) {
    if (!_isP2pPillVisible ||
        routeIndex < 0 ||
        routeIndex >= _alternativeRoutes.length) {
      return;
    }
    final List<LatLng> route = _alternativeRoutes[routeIndex];
    final double distMeters = routeIndex < _routeDistances.length
        ? _routeDistances[routeIndex]
        : _calculatePolylineDistanceMeters(route);
    final double durSeconds = routeIndex < _routeDurations.length
        ? _routeDurations[routeIndex]
        : 0.0;
    final int hazardCount =
        (_activeRouteIndex != null &&
            _activeRouteIndex!.routeIndex == routeIndex)
        ? _activeRouteIndex!.summary.distinctPotholeCount
        : (routeIndex < _routePotholeCounts.length
              ? _routePotholeCounts[routeIndex]
              : _p2pHazardCount);
    final double accurateSeconds = _calculateAccurateEtaSeconds(
      durSeconds,
      distanceMeters: distMeters,
      potholeCount: hazardCount,
    );
    if (destinationOverride != null) {
      _p2pPoint = destinationOverride;
    } else if (_destination != null) {
      _p2pPoint = _destination;
    }
    _p2pDistanceKm = distMeters / 1000.0;
    _p2pMinutes = (accurateSeconds / 60).round().clamp(1, 999);
    _p2pHazardCount = hazardCount;
  }

  void _refreshProximityForActiveContext(int routeIndex) {
    if (_currentPosition != null) {
      _checkPotholeProximity(_currentPosition!);
      return;
    }
    if (_destination == null ||
        routeIndex < 0 ||
        routeIndex >= _alternativeRoutes.length) {
      return;
    }
    final List<LatLng> route = _alternativeRoutes[routeIndex];
    final LatLng? fallbackOrigin =
        _customOrigin ?? (route.isNotEmpty ? route.first : null);
    if (fallbackOrigin != null) {
      _checkPotholeProximity(fallbackOrigin, allowProximityAlarm: false);
    }
  }

  void _checkPotholeProximity(
    LatLng userPos, {
    double? gpsAccuracyMeters,
    double? headingDeg,
    double? speedMps,
    DateTime? timestamp,
    bool allowProximityAlarm = true,
  }) {
    if (!widget.isMapActive) return;
    List<LatLng> routeForChecks = _routePoints;
    List<LatLng> warningCandidates;
    List<LatLng>? activeRouteForAdvisor;

    final bool isUsingCustomOrigin =
        _customOrigin != null && _originController.text != 'Your location';
    final bool useRouteStartTracking =
        !allowProximityAlarm || (isUsingCustomOrigin && !_isSimulatingRoute);
    final bool canTriggerProximityAlarm =
        allowProximityAlarm && (!isUsingCustomOrigin || _isSimulatingRoute);

    if (_destination != null && _alternativeRoutes.isNotEmpty) {
      final int activeIndex = _selectedRouteIndex < _alternativeRoutes.length
          ? _selectedRouteIndex
          : 0;
      final activeRoute = _alternativeRoutes[activeIndex];
      activeRouteForAdvisor = activeRoute;
      routeForChecks = useRouteStartTracking
          ? activeRoute
          : _remainingRouteFromUser(activeRoute, userPos);
      if (_activeRouteIndex != null &&
          _activeRouteIndex!.routeIndex == activeIndex) {
        warningCandidates = _activeRouteIndex!.summary.potholeEncounters
            .map((e) => e.hazard.location)
            .toList(growable: false);
      } else {
        warningCandidates = _roadAlignedPotholeLocations()
            .where(
              (p) => _isPotholeOnRoute(
                p,
                routeForChecks,
                _routeWarningToleranceMeters,
              ),
            )
            .toList();
      }
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

    final bool inProximity =
        canTriggerProximityAlarm && absoluteMin <= _proximityCircleRadiusMeters;

    final List<LatLng> pendingPotholes =
        _activeRouteIndex != null &&
            _destination != null &&
            _alternativeRoutes.isNotEmpty
        ? _activeRouteIndex!.summary.potholeEncounters
              .map((e) => e.hazard.location)
              .toList(growable: false)
        : warningCandidates;

    NavigationHazardState? trackedState;
    UpcomingHazardCountdown? upcoming;
    final int activeIdxForTracker =
        _selectedRouteIndex < _alternativeRoutes.length
        ? _selectedRouteIndex
        : 0;
    final bool hasMatchingActiveIndex =
        activeRouteForAdvisor != null &&
        _activeRouteIndex != null &&
        _activeRouteIndex!.routeIndex == activeIdxForTracker;

    if (useRouteStartTracking && hasMatchingActiveIndex) {
      // Derive route-start hazard countdown directly without mutating the
      // live GPS NavigationHazardTracker when no GPS fix exists or previewing
      // a custom origin on web desktop.
      final encounters = _activeRouteIndex!.summary.potholeEncounters;
      final totalCount = _activeRouteIndex!.summary.distinctPotholeCount;
      final next = encounters.isEmpty ? null : encounters.first;
      trackedState = NavigationHazardState(
        status: next != null
            ? NavigationHazardStatus.hazardAhead
            : NavigationHazardStatus.clearAhead,
        userChainMeters: 0.0,
        distanceFromRouteMeters: 0.0,
        nextEncounter: next,
        distanceToNextMeters: next?.chainDistanceMeters,
        remainingPotholeCount: totalCount,
        totalRoutePotholeCount: totalCount,
        remainingEncounterCount: encounters.length,
        totalRouteEncounterCount: encounters.length,
      );
      if (next != null) {
        upcoming = UpcomingHazardCountdown(
          distanceMeters: next.chainDistanceMeters,
          defectName: next.hazard.defectName,
          dpwhCode: next.hazard.dpwhCode,
          barangay: next.hazard.barangay,
          potholeCount: next.hazard.potholeCount,
          isOnActiveRoute: true,
          location: next.hazard.location,
          encounterId: next.encounterId,
          remainingOnRoute: totalCount,
          totalOnRoute: totalCount,
        );
      }
    } else if (activeRouteForAdvisor != null &&
        _navigationTracker != null &&
        !useRouteStartTracking) {
      trackedState = _navigationTracker!.update(
        position: userPos,
        timestamp: timestamp ?? _lastGpsTimestamp,
        gpsAccuracyMeters: gpsAccuracyMeters ?? _lastGpsAccuracyMeters,
        headingDeg: headingDeg ?? _lastHeadingNotifier.value,
        speedMps: speedMps ?? _lastGpsSpeedMps,
        offRouteThresholdMeters: _offRouteRerouteThresholdMeters,
      );
      if (trackedState.nextEncounter != null &&
          trackedState.distanceToNextMeters != null) {
        final enc = trackedState.nextEncounter!;
        upcoming = UpcomingHazardCountdown(
          distanceMeters: trackedState.distanceToNextMeters!,
          defectName: enc.hazard.defectName,
          dpwhCode: enc.hazard.dpwhCode,
          barangay: enc.hazard.barangay,
          potholeCount: enc.hazard.potholeCount,
          isOnActiveRoute: true,
          location: enc.hazard.location,
          encounterId: enc.encounterId,
          remainingOnRoute: trackedState.remainingPotholeCount,
          totalOnRoute: trackedState.totalRoutePotholeCount,
        );
      }
    } else {
      upcoming = RoutePotholeAdvisor.findUpcomingHazard(
        userPos: userPos,
        hazards: _buildHazardInputs(),
        activeRoute: activeRouteForAdvisor,
        forceFromRouteStart: useRouteStartTracking,
        routeToleranceMeters: _routeCountToleranceMeters,
        roamingRadiusMeters: 600.0,
      );
    }

    String nearestInfo = 'Clear ahead';
    String? nextPotholeEta;

    if (upcoming != null) {
      final double nearestDistMeters = upcoming.distanceMeters;
      nearestInfo = nearestDistMeters >= 1000.0
          ? '${(nearestDistMeters / 1000.0).toStringAsFixed(1)} km'
          : '${nearestDistMeters.round()} m';

      if (activeRouteForAdvisor != null) {
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
            : _calculatePolylineDistanceMeters(activeRouteForAdvisor);

        double etaSeconds = 0;
        if (totalDist > 0 && totalDur > 0) {
          etaSeconds = (nearestDistMeters / totalDist) * totalDur;
        } else {
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
    }

    setState(() {
      _nearestPotholeInfo = nearestInfo;
      _nextPotholeEta = nextPotholeEta;
      _upcomingHazard = upcoming;
      _navHazardState = trackedState;
      if (_destination != null) {
        if (!_isDraggingEndpoint) {
          _routePoints = routeForChecks;
        }
        _potholesOnRoute = pendingPotholes;
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
    } else if (!canTriggerProximityAlarm || absoluteMin > 60) {
      _alertedAt50m.clear();
      if (_showWarningBanner) setState(() => _showWarningBanner = false);
    }

    _isInitialStartup = false;
  }

  void _onMapPositionChanged(MapCamera camera, bool hasGesture) {
    _syncUrlCoordinates(camera.center, camera.zoom);

    bool needsRebuild = false;
    if ((camera.zoom - _lastMarkerZoom).abs() >= .05) {
      _lastMarkerZoom = camera.zoom;
      needsRebuild = true;
    }

    if (hasGesture && _reportFilter.onlyInMapBounds && !_hasUnsearchedMapMove) {
      _hasUnsearchedMapMove = true;
      needsRebuild = true;
    }

    if (hasGesture && _followMode != FollowMode.none) {
      _followMode = FollowMode.none;
      needsRebuild = true;
    }

    if (_isPlacingMarker) {
      _pendingMarkerLocation = camera.center;
      needsRebuild = true;
    }

    if (_isEditingDevLocation && hasGesture) {
      _pendingDevLocation = camera.center;
      needsRebuild = true;
    }

    // Refresh viewport-culled pothole markers when the camera pans or zooms
    // beyond the buffered region (e.g., fitting a Point A to B route).
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
        onPickLocationOnMap: _pickManualMarkerLocationOnMap,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open local developer markers.'),
          ),
        );
      }
    } finally {
      if (mounted && _pinPickerCompleter == null) {
        _cancelMarkerPlacement();
      }
    }
  }

  void _beginMapPinPicker({LatLng? initialLocation}) {
    if (!mounted) return;
    if (_pinPickerCompleter != null && !_pinPickerCompleter!.isCompleted) {
      _pinPickerCompleter!.complete(null);
      _pinPickerCompleter = null;
    }
    final seed = initialLocation ?? _mapController.camera.center;
    setState(() {
      _isPlacingMarker = true;
      _pendingMarkerLocation = seed;
      _isEditingDevLocation = false;
      _pendingDevLocation = null;
    });
    if (initialLocation != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_isPlacingMarker) return;
        try {
          _mapController.move(initialLocation, _mapController.camera.zoom);
        } catch (_) {}
      });
    }
  }

  Future<LatLng?> _pickManualMarkerLocationOnMap(LatLng initialLocation) {
    if (!mounted) return Future.value(null);
    if (_pinPickerCompleter != null && !_pinPickerCompleter!.isCompleted) {
      _pinPickerCompleter!.complete(null);
    }
    final completer = Completer<LatLng?>();
    _pinPickerCompleter = completer;
    _beginMapPinPicker(initialLocation: initialLocation);
    return completer.future;
  }

  void _cancelMarkerPlacement() {
    final pendingCompleter = _pinPickerCompleter;
    _pinPickerCompleter = null;
    if (pendingCompleter != null && !pendingCompleter.isCompleted) {
      pendingCompleter.complete(null);
    }
    setState(() {
      _isPlacingMarker = false;
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
    final bool isUsingCustomOrigin =
        _customOrigin != null && _originController.text != 'Your location';

    setState(() {
      _useMockLocation = true;
      _isEditingDevLocation = false;
      _pendingDevLocation = null;
      _currentPosition = location;
      _followMode = FollowMode.location;
      _lastAutoRerouteAt = null;
      if (_destination != null && !isUsingCustomOrigin) {
        _rubberBandActiveRoute(newStart: location);
      }
    });

    if (AppSettings.instance.devEditLocationNotifier.value) {
      AppSettings.instance.devEditLocationNotifier.value = false;
    }

    _checkPotholeProximity(location);
    _mapController.move(location, _mapController.camera.zoom);
    if (_destination != null && !isUsingCustomOrigin) {
      await _calculateRoute(
        _destination!,
        customOrigin: location,
        fitCamera: false,
        silent: true,
      );
    } else {
      await _autoAdjustRouteToCurrentPath(location);
    }

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
    final bool isUsingCustomOrigin =
        _customOrigin != null && _originController.text != 'Your location';
    final LatLng? nextPos = livePosition ?? _currentPosition;

    setState(() {
      _useMockLocation = false;
      _isEditingDevLocation = false;
      _pendingDevLocation = null;
      if (livePosition != null) {
        _currentPosition = livePosition;
      }
      _followMode = FollowMode.location;
      _lastAutoRerouteAt = null;
      if (_destination != null && !isUsingCustomOrigin && nextPos != null) {
        _rubberBandActiveRoute(newStart: nextPos);
      }
    });

    if (_currentPosition != null) {
      _checkPotholeProximity(_currentPosition!);
      _mapController.move(_currentPosition!, _mapController.camera.zoom);
      if (_destination != null && !isUsingCustomOrigin) {
        unawaited(
          _calculateRoute(
            _destination!,
            customOrigin: _currentPosition!,
            fitCamera: false,
            silent: true,
          ),
        );
      } else {
        unawaited(_autoAdjustRouteToCurrentPath(_currentPosition!));
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Returned to real GPS location.')),
    );
  }

  Future<void> _confirmMarkerPlacement() async {
    LatLng location;
    try {
      location = _mapController.camera.center;
    } catch (_) {
      location = _pendingMarkerLocation ?? _bulacanCenter;
    }
    final pendingCompleter = _pinPickerCompleter;
    _pinPickerCompleter = null;
    setState(() {
      _isPlacingMarker = false;
      _pendingMarkerLocation = null;
    });
    if (AppSettings.instance.manualPotholePlacementNotifier.value) {
      AppSettings.instance.manualPotholePlacementNotifier.value = false;
    }
    if (pendingCompleter != null) {
      if (!pendingCompleter.isCompleted) {
        pendingCompleter.complete(location);
      }
      return;
    }
    await showDeveloperMarkerEditor(
      context,
      location: location,
      initialDefect: _pendingMarkerDefect,
      onPickLocationOnMap: _pickManualMarkerLocationOnMap,
    );
  }

  void _onSearchChanged(String query) {
    final revision = ++_searchRevision;
    _highlightedSuggestionIndex = -1;
    _debounceTimer?.cancel();
    final normalized = _normalizeQuery(query.trim());
    final canFetchPlaces = normalized.length >= 3;
    setState(() {
      _suggestions = !canFetchPlaces
          ? []
          : _fetchLocalBarangayCandidates(normalized).take(8).toList();
      _isSearchingPlaces = canFetchPlaces;
      _visibleResultLimit = 25;
    });
    if (!canFetchPlaces) return;
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted && revision == _searchRevision) {
        _fetchSuggestions(query, revision);
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
                          '${d['className'] ?? d['defectClass'] ?? d['defectType'] ?? d['rawTag'] ?? d['tag'] ?? d['classId'] ?? ''}',
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

  Future<void> _ensurePotholeSnapCache({int? requestSeq}) async {
    final double snapRadius = math.min(
      _snapRadiusMeters,
      _routeCountToleranceMeters,
    );
    final List<LatLng> candidates = _alternativeRoutes.isNotEmpty
        ? _allPotholeLocations.where((p) {
            return _alternativeRoutes.any(
              (r) => RouteBoundingBox.fromPoints(
                r,
                bufferMeters: snapRadius + 15.0,
              ).contains(p),
            );
          }).toList()
        : _allPotholeLocations;

    final missing = candidates
        .where((p) => !_snappedPotholeCache.containsKey(_potholeKey(p)))
        .toList();
    if (missing.isEmpty) return;

    // Without an OpenRouteService key, skip external snap calls immediately and
    // record coordinates as unverified (count will be marked approximate).
    if (_orsApiKey.trim().isEmpty) {
      for (final p in missing) {
        final key = _potholeKey(p);
        _snappedPotholeCache[key] = p;
        _snappedWasVerified[key] = false;
      }
      return;
    }

    const int batchSize = 30;
    for (int i = 0; i < missing.length; i += batchSize) {
      if (requestSeq != null && requestSeq != _routingRequestSeq) return;
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

        final response = await http
            .post(
              url,
              headers: _safeHeaders({
                'Authorization': _orsApiKey,
                'Content-Type': 'application/json',
              }),
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 5));

        if (requestSeq != null && requestSeq != _routingRequestSeq) return;

        if (response.statusCode != 200) {
          for (final p in batch) {
            final key = _potholeKey(p);
            _snappedPotholeCache[key] = p;
            _snappedWasVerified[key] = false;
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
        }
      } catch (_) {
        for (final p in batch) {
          final key = _potholeKey(p);
          _snappedPotholeCache[key] = p;
          _snappedWasVerified[key] = false;
        }
      }
    }
  }

  List<LatLng> _roadAlignedPotholeLocations() {
    return _allPotholeLocations
        .map((p) => _snappedPotholeCache[_potholeKey(p)] ?? p)
        .toList();
  }

  List<RouteStepRoadSpan> _toStepRoadSpans(int routeIdx) {
    if (routeIdx < 0 || routeIdx >= _alternativeRouteSteps.length) {
      return const [];
    }
    return _alternativeRouteSteps[routeIdx]
        .map(
          (s) => RouteStepRoadSpan(roadName: s.roadName, location: s.location),
        )
        .toList(growable: false);
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
      if (roads.isNotEmpty) return 'Via ${roads.join(' & ')}';
    }
    return routeIndex == 0
        ? 'Primary road'
        : 'Alternate route ${routeIndex + 1}';
  }

  Future<void> _refreshRouteAwarePotholeState({int? requestSeq}) async {
    if (_alternativeRoutes.isEmpty) {
      if (_currentPosition != null) {
        _checkPotholeProximity(_currentPosition!);
      }
      return;
    }

    await _ensurePotholeSnapCache(requestSeq: requestSeq);
    if (!mounted || (requestSeq != null && requestSeq != _routingRequestSeq)) {
      return;
    }

    final hazards = _buildHazardInputs();
    final List<String?> viaList = List<String?>.generate(
      _alternativeRoutes.length,
      (i) => _routeViaSummary(i),
      growable: false,
    );
    final List<List<RouteStepRoadSpan>> spansByRoute =
        List<List<RouteStepRoadSpan>>.generate(
          _alternativeRoutes.length,
          (i) => _toStepRoadSpans(i),
          growable: false,
        );

    final comparison = RoutePotholeAdvisor.evaluateAlternatives(
      routes: _alternativeRoutes,
      distancesMeters: _routeDistances,
      durationsSeconds: _routeDurations,
      hazards: hazards,
      viaSummaries: viaList,
      stepsByRoute: spansByRoute,
      corridorConfig: _corridorConfig,
    );

    final List<int> updatedCounts = List<int>.generate(
      _alternativeRoutes.length,
      (i) {
        final opt = comparison.options
            .cast<RouteComparisonOption?>()
            .firstWhere((o) => o?.routeIndex == i, orElse: () => null);
        if (opt != null) return opt.summary.distinctPotholeCount;
        return PrecomputedRouteIndex.build(
          route: _alternativeRoutes[i],
          hazards: hazards,
          routeIndex: i,
          routeDistanceMeters: i < _routeDistances.length
              ? _routeDistances[i]
              : null,
          durationSeconds: i < _routeDurations.length
              ? _routeDurations[i]
              : 0.0,
          config: _corridorConfig,
          steps: i < spansByRoute.length ? spansByRoute[i] : const [],
        ).summary.distinctPotholeCount;
      },
      growable: false,
    );

    final int activeIndex = _selectedRouteIndex < _alternativeRoutes.length
        ? _selectedRouteIndex
        : 0;
    final PrecomputedRouteIndex activeIndexBuilt = PrecomputedRouteIndex.build(
      route: _alternativeRoutes[activeIndex],
      hazards: hazards,
      routeIndex: activeIndex,
      routeDistanceMeters: activeIndex < _routeDistances.length
          ? _routeDistances[activeIndex]
          : null,
      durationSeconds: activeIndex < _routeDurations.length
          ? _routeDurations[activeIndex]
          : 0.0,
      config: _corridorConfig,
      steps: activeIndex < spansByRoute.length
          ? spansByRoute[activeIndex]
          : const [],
    );

    final List<LatLng> onRoute = activeIndexBuilt.summary.potholeEncounters
        .map((e) => e.hazard.location)
        .toList(growable: false);

    final RouteSwitchSuggestion? suggestion =
        RoutePotholeAdvisor.buildSwitchSuggestion(
          currentRouteIndex: activeIndex,
          hazardCounts: updatedCounts,
          distancesMeters: _routeDistances,
          durationsSeconds: _routeDurations,
        );

    if (!mounted) return;
    setState(() {
      _selectedRouteIndex = activeIndex;
      if (_alternativeRouteSteps.isNotEmpty &&
          activeIndex < _alternativeRouteSteps.length) {
        _routeSteps = _alternativeRouteSteps[activeIndex];
      }
      _routeComparison = comparison;
      _activeRouteIndex = activeIndexBuilt;
      if (_navigationTracker == null) {
        _navigationTracker = NavigationHazardTracker(activeIndexBuilt);
      } else {
        _navigationTracker!.replaceRouteIndex(activeIndexBuilt);
      }
      _routePotholeCounts = updatedCounts;
      _potholesOnRoute = onRoute;
      _routeSwitchSuggestion = suggestion;
      _syncP2pSummaryForRoute(activeIndex);
    });

    _refreshProximityForActiveContext(activeIndex);
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
    });
    _checkPotholeProximity(path.first);
    _animatedMapMove(path.first, 16.5);

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
      if (mounted) {
        setState(() => _currentPosition = nextPos);
      }
      _checkPotholeProximity(nextPos);
      if (_followMode != FollowMode.none) {
        _mapController.move(nextPos, _mapController.camera.zoom);
      }
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

  void _rubberBandActiveRoute({LatLng? newStart, LatLng? newEnd}) {
    final LatLng start =
        newStart ?? _customOrigin ?? _currentPosition ?? _bulacanCenter;
    final LatLng? end = newEnd ?? _destination;
    if (end == null) return;

    List<LatLng> updated;
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
        updated = [start, end];
      } else {
        updated = List<LatLng>.from(_routePoints);
        if (newStart != null) {
          updated[0] = newStart;
        }
        if (newEnd != null) {
          updated[updated.length - 1] = newEnd;
        }
      }
    } else {
      updated = [start, end];
    }

    _routePoints = updated;
    if (_alternativeRoutes.isNotEmpty) {
      final int idx = _selectedRouteIndex < _alternativeRoutes.length
          ? _selectedRouteIndex
          : 0;
      _alternativeRoutes[idx] = updated;
    }
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
    if (routes.isEmpty || routes.length >= 3) return;
    await _ensurePotholeSnapCache(requestSeq: requestSeq);
    if (!mounted || requestSeq != _routingRequestSeq) return;
    final List<LatLng> hazards = _buildHazardInputs()
        .where((h) => h.isEligibleForPublicRouteCount && h.containsPotholeClass)
        .map((h) => h.location)
        .toList(growable: false);
    if (hazards.isEmpty) return;

    final int primaryHazards = hazards
        .where(
          (h) => _isPotholeOnRoute(h, routes.first, _routeCountToleranceMeters),
        )
        .length;
    if (primaryHazards == 0) return;

    final List<LatLng> bypassWaypoints =
        RoutePotholeAdvisor.buildAvoidanceWaypoints(
          primaryRoute: routes.first,
          hazards: hazards,
          routeToleranceMeters: _routeCountToleranceMeters,
        );
    if (bypassWaypoints.isEmpty) return;

    final String baseHost = _travelMode == OsrmTravelMode.bike
        ? 'https://routing.openstreetmap.de/routed-bike/route/v1/driving'
        : _travelMode == OsrmTravelMode.foot
        ? 'https://routing.openstreetmap.de/routed-foot/route/v1/driving'
        : 'https://router.project-osrm.org/route/v1/driving';

    for (final wp in bypassWaypoints) {
      if (routes.length >= 3 || !mounted || requestSeq != _routingRequestSeq) {
        return;
      }
      try {
        Uri url = Uri.parse(
          '$baseHost/'
          '${start.longitude},${start.latitude};'
          '${wp.longitude},${wp.latitude};'
          '${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&steps=true&annotations=true',
        );
        var res = await http.get(url).timeout(const Duration(seconds: 6));
        if (res.statusCode != 200 && _travelMode != OsrmTravelMode.car) {
          url = Uri.parse(
            'https://router.project-osrm.org/route/v1/driving/'
            '${start.longitude},${start.latitude};'
            '${wp.longitude},${wp.latitude};'
            '${destination.longitude},${destination.latitude}'
            '?overview=full&geometries=geojson&steps=true&annotations=true',
          );
          res = await http.get(url).timeout(const Duration(seconds: 6));
        }
        if (res.statusCode != 200) continue;

        final data = jsonDecode(res.body);
        final List osrmRoutes = data['routes'] ?? [];
        for (final r in osrmRoutes.take(1)) {
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
          if (_travelMode == OsrmTravelMode.bike &&
              duration < (distance / 4.5)) {
            duration = distance / 4.16;
          } else if (_travelMode == OsrmTravelMode.foot &&
              duration < (distance / 1.5)) {
            duration = distance / 1.33;
          }

          final List<RouteStep> parsedSteps = _parseOsrmSteps(
            r as Map<String, dynamic>,
          );

          routes.add(points);
          durations.add(duration);
          distances.add(distance);
          stepsByRoute.add(parsedSteps);
        }
      } catch (_) {
        // Ignore single bypass probe failures; primary OSRM routes remain valid.
      }
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

  Future<void> _useCurrentLocationForOrigin() async {
    await _determinePosition(requestPermission: true);
    if (!mounted) return;
    if (_isPermissionDenied ||
        _isLocationDisabled ||
        _currentPosition == null) {
      setState(() {
        _routeErrorMessage = _isPermissionDenied
            ? 'Location permission is required to use your current location, or enter a starting address.'
            : 'Location services are disabled. Turn on GPS or type a starting address.';
      });
      return;
    }
    setState(() {
      _routeErrorMessage = null;
      _originController.text = 'Your location';
      _customOrigin = null;
      _originTextDirty = false;
      _isEditingOrigin = false;
      _suggestions = [];
    });
    if (_destination != null) {
      await _calculateRoute(_destination!, customOrigin: _currentPosition);
    }
  }

  void _resetRoutePlannerState({bool clearDestination = true}) {
    if (clearDestination) {
      _destination = null;
    }
    _routePoints = [];
    _alternativeRoutes = [];
    _routeDistances = [];
    _routeDurations = [];
    _routePotholeCounts = [];
    _routeSteps = [];
    _alternativeRouteSteps = [];
    _routeSwitchSuggestion = null;
    _upcomingHazard = null;
    _potholesOnRoute = [];
    _routeComparison = null;
    _activeRouteIndex = null;
    _navigationTracker?.reset();
    _navHazardState = null;
    _showPotholesAlongRouteOnly = false;
    _isSearchingAlternatives = false;
    _hasEvaluatedFewerPotholes = false;
    _routeErrorMessage = null;
    _routeUsingCachedGeometry = false;
    _nearestPotholeInfo = '';
    _nextPotholeEta = null;
    _showWarningBanner = false;
    AppSettings.instance.setRouteActive(false);
  }

  List<PotholeMarker> _markersForMapDisplay(List<PotholeMarker> baseMarkers) {
    if (!_showPotholesAlongRouteOnly || _activeRouteIndex == null) {
      return baseMarkers;
    }
    final encounters = _activeRouteIndex!.summary.potholeEncounters;
    if (encounters.isEmpty) return const [];
    final Set<String> docIds = {};
    final Set<String> canonicalIds = {};
    for (final e in encounters) {
      final rid = e.hazard.reportId;
      if (rid != null && rid.isNotEmpty) docIds.add(rid);
      canonicalIds.add(e.canonicalKey);
    }
    return baseMarkers
        .where((m) {
          final doc = m.docId ?? m.id;
          if (doc != null && docIds.contains(doc)) return true;
          final canon = m.canonicalDefectId?.trim().toLowerCase();
          if (canon != null &&
              canon.isNotEmpty &&
              canonicalIds.contains('canon:$canon')) {
            return true;
          }
          return encounters.any(
            (e) =>
                Geolocator.distanceBetween(
                  e.hazard.location.latitude,
                  e.hazard.location.longitude,
                  m.location.latitude,
                  m.location.longitude,
                ) <
                2.0,
          );
        })
        .toList(growable: false);
  }

  void _focusRouteEncounter(RouteHazardEncounter encounter) {
    PotholeMarker? matched;
    for (final m in _effectivePotholes) {
      final doc = m.docId ?? m.id;
      if (encounter.hazard.reportId != null &&
          doc == encounter.hazard.reportId) {
        matched = m;
        break;
      }
      if (Geolocator.distanceBetween(
            m.location.latitude,
            m.location.longitude,
            encounter.hazard.location.latitude,
            encounter.hazard.location.longitude,
          ) <
          2.0) {
        matched = m;
        break;
      }
    }
    if (matched != null) {
      _setSelectedPothole(matched, notify: true, animate: true);
    } else {
      _animatedMapMove(encounter.hazard.location, 17.5, offsetForSidebar: true);
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

    final List<List<RouteStep>> allSteps = stepsByRoute ?? [];
    final List<String?> viaList = List<String?>.generate(routes.length, (i) {
      if (i < allSteps.length && allSteps[i].isNotEmpty) {
        final seen = <String>{};
        final roads = <String>[];
        for (final step in allSteps[i]) {
          final raw = step.roadName.trim();
          if (raw.isEmpty) continue;
          final k = raw.toLowerCase();
          if (k == 'road' || k == 'unnamed road' || seen.contains(k)) continue;
          seen.add(k);
          roads.add(raw);
          if (roads.length >= 2) break;
        }
        if (roads.isNotEmpty) return 'Via ${roads.join(' & ')}';
      }
      return i == 0 ? 'Primary road' : 'Alternate route ${i + 1}';
    }, growable: false);

    // Pre-commit route state synchronously, then refine road snapping asynchronously.
    _alternativeRoutes = routes;
    _alternativeRouteSteps = allSteps;
    _routeDistances = distances;
    _routeDurations = durations;

    await _ensurePotholeSnapCache(requestSeq: requestSeq);
    if (!mounted || (requestSeq != null && requestSeq != _routingRequestSeq)) {
      return;
    }

    final hazards = _buildHazardInputs();
    final spansByRoute = List<List<RouteStepRoadSpan>>.generate(
      routes.length,
      (i) => i < allSteps.length
          ? allSteps[i]
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

    final comparison = RoutePotholeAdvisor.evaluateAlternatives(
      routes: routes,
      distancesMeters: distances,
      durationsSeconds: durations,
      hazards: hazards,
      viaSummaries: viaList,
      stepsByRoute: spansByRoute,
      corridorConfig: _corridorConfig,
    );

    final List<int> potholeCounts = List<int>.generate(routes.length, (i) {
      final opt = comparison.options.cast<RouteComparisonOption?>().firstWhere(
        (o) => o?.routeIndex == i,
        orElse: () => null,
      );
      if (opt != null) return opt.summary.distinctPotholeCount;
      return PrecomputedRouteIndex.build(
        route: routes[i],
        hazards: hazards,
        routeIndex: i,
        routeDistanceMeters: i < distances.length ? distances[i] : null,
        durationSeconds: i < durations.length ? durations[i] : 0.0,
        config: _corridorConfig,
        steps: i < spansByRoute.length ? spansByRoute[i] : const [],
      ).summary.distinctPotholeCount;
    }, growable: false);

    const int initialRouteIndex = 0;
    final List<LatLng> initialRoute = routes[initialRouteIndex];
    final List<RouteStep> initialSteps =
        allSteps.isNotEmpty && allSteps.length > initialRouteIndex
        ? allSteps[initialRouteIndex]
        : [];
    final PrecomputedRouteIndex activeBuilt = PrecomputedRouteIndex.build(
      route: initialRoute,
      hazards: hazards,
      routeIndex: initialRouteIndex,
      routeDistanceMeters: distances[initialRouteIndex],
      durationSeconds: durations[initialRouteIndex],
      config: _corridorConfig,
      steps: initialRouteIndex < spansByRoute.length
          ? spansByRoute[initialRouteIndex]
          : const [],
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
    }

    if (!mounted) return;
    setState(() {
      _alternativeRoutes = routes;
      _alternativeRouteSteps = allSteps;
      _routeSteps = initialSteps;
      _showTurnByTurnSheet = false;
      _routeComparison = comparison;
      _activeRouteIndex = activeBuilt;
      if (_navigationTracker == null) {
        _navigationTracker = NavigationHazardTracker(activeBuilt);
      } else {
        _navigationTracker!.replaceRouteIndex(activeBuilt);
      }
      _navHazardState = null;
      _routePotholeCounts = potholeCounts;
      _potholesOnRoute = activeBuilt.summary.potholeEncounters
          .map((e) => e.hazard.location)
          .toList(growable: false);
      _routeDurations = durations;
      _routeDistances = distances;
      _selectedRouteIndex = initialRouteIndex;
      _lastMatchedSegmentIndex = 0;
      _routePoints = initialRoute;
      _destination = destination;
      _destinationTextDirty = false;
      _isRouting = false;
      _routeErrorMessage = null;
      _routeUsingCachedGeometry = fromCache;
      _isSearchVisible = true;
      _isCompactRouteDrawerExpanded = true;
      _followMode = FollowMode.none;
      _nearestPotholeInfo = 'Clear ahead';
      _upcomingHazard = null;
      _recomputeRouteSuggestion();
      _syncP2pSummaryForRoute(
        initialRouteIndex,
        destinationOverride: destination,
      );
    });

    if (fitCamera) _fitCameraToRoute(initialRoute);
    _refreshProximityForActiveContext(initialRouteIndex);
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

    final mlCtrl = _mlController;
    if (_shouldUseWebVectorMap && mlCtrl != null) {
      unawaited(
        mlCtrl.animateCamera(
          ml.CameraUpdate.bounds(
            ml.GeoBox(
              west: minLng,
              south: minLat,
              east: maxLng,
              north: maxLat,
            ),
            padding: const EdgeInsets.only(
              top: 140,
              bottom: 180,
              left: 60,
              right: 60,
            ),
            maxZoom: 17.5,
          ),
          animation: const ml.CameraAnimation.ease(
            duration: Duration(milliseconds: 550),
          ),
        ),
      );
    }

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
    final hazards = _buildHazardInputs();
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
      steps: _toStepRoadSpans(index),
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
      if (_navigationTracker == null) {
        _navigationTracker = NavigationHazardTracker(activeBuilt);
      } else {
        _navigationTracker!.replaceRouteIndex(activeBuilt);
      }
      _navHazardState = null;
      if (index < _routePotholeCounts.length) {
        final nextCounts = List<int>.from(_routePotholeCounts);
        nextCounts[index] = activeBuilt.summary.distinctPotholeCount;
        _routePotholeCounts = nextCounts;
      }
      _potholesOnRoute = activeBuilt.summary.potholeEncounters
          .map((e) => e.hazard.location)
          .toList(growable: false);
      if (_isSimulatingRoute) {
        _simulatedChainMeters = 0.0;
      }
      _recomputeRouteSuggestion();
      _syncP2pSummaryForRoute(index);
    });
    _refreshProximityForActiveContext(index);
  }

  /// Cycles between all available alternative and optimized routes
  void _cycleRoutes() {
    if (_alternativeRoutes.isEmpty) return;
    final nextIndex = (_selectedRouteIndex + 1) % _alternativeRoutes.length;
    _selectActiveRoute(nextIndex);
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

  static const List<Map<String, dynamic>> _bulacanLandmarks = [
    {
      'name': 'Immaculate Conception I-College',
      'aliases': [
        'immaculate conception',
        'ici college',
        'ici',
        'icat',
        'immaculate conception academy',
        'bonifacio',
      ],
      'address': 'Bonifacio Street, Poblacion, Santa Maria, Bulacan',
      'municipality': 'Santa Maria',
      'lat': 14.8177,
      'lon': 120.9622,
    },
    {
      'name': 'Santa Maria Municipal Hall - Bulacan',
      'aliases': [
        'santa maria municipal hall',
        'munisipyo',
        'sta maria town hall',
        'sta. maria municipal hall',
        'santa maria municipal',
      ],
      'address': 'C. de Guzman Street, Poblacion, Santa Maria, Bulacan',
      'municipality': 'Santa Maria',
      'lat': 14.8193,
      'lon': 120.9604,
    },
    {
      'name': 'Municipal Hall Drive',
      'aliases': ['municipal hall drive', 'municipal grounds', 'hall drive'],
      'address': 'Poblacion, Santa Maria, Bulacan',
      'municipality': 'Santa Maria',
      'lat': 14.8191,
      'lon': 120.9605,
    },
    {
      'name': 'N-la Cellphone Accessories & General Merchandise',
      'aliases': [
        'n-la cellphone',
        'nla cellphone',
        'n-la',
        'nla',
        'bagbaguin',
      ],
      'address':
          'Governor Fortunato Halili Avenue, Bagbaguin, Santa Maria, Bulacan',
      'municipality': 'Santa Maria',
      'lat': 14.8115,
      'lon': 120.9520,
    },
    {
      'name': 'Gracia Motorcycle Shop and Supplies',
      'aliases': [
        'gracia motorcycle',
        'gracia shop',
        'gracia motor',
        'gracia',
        'gumaoc',
      ],
      'address': 'Quirino Highway, Gumaoc East, San Jose del Monte, Bulacan',
      'municipality': 'San Jose del Monte',
      'lat': 14.7991,
      'lon': 121.0689,
    },
    {
      'name': 'Real de Cacarong',
      'aliases': [
        'real de cacarong',
        'kakarong de sili',
        'inang filipina shrine',
        'cacarong',
        'cacarong matanda',
      ],
      'address': 'Barangay Cacarong Matanda, Pandi, Bulacan',
      'municipality': 'Pandi',
      'lat': 14.9042,
      'lon': 120.9677,
    },
  ];

  /// Instant local search matcher for Philippine & Bulacan Barangays and Key Landmarks
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

    // 1. Search Known Landmarks first for highest accuracy
    for (final l in _bulacanLandmarks) {
      final name = l['name'] as String;
      final addr = l['address'] as String;
      final lat = (l['lat'] as num).toDouble();
      final lon = (l['lon'] as num).toDouble();
      final aliases = l['aliases'] as List<String>;
      final nameClean = name.toLowerCase();

      final loc = LatLng(lat, lon);
      final dist = _calculateDistanceKm(refPos, loc);

      double score = 0.0;
      if (nameClean == clean || aliases.any((a) => a == clean)) {
        score = 260.0;
      } else if (nameClean.startsWith(clean) ||
          aliases.any((a) => a.startsWith(clean))) {
        score = 230.0;
      } else if (nameClean.contains(clean) ||
          aliases.any((a) => a.contains(clean))) {
        score = 200.0;
      }

      if (score > 0) {
        if (dist != double.infinity) {
          score += (1.0 / (dist + 1.0)) * 50.0;
        }
        matches.add({
          'lat': lat.toString(),
          'lon': lon.toString(),
          '_name': name,
          '_short_addr': addr,
          'display_name': '$name, $addr',
          '_distance_km': dist,
          '_score': score,
          '_is_landmark': true,
          '_source': 'Bulacan Landmark Registry',
        });
      }
    }

    // 2. Search Barangays
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

    // Ensure every one of the 24 official Santa Maria barangays is discoverable
    // locally even when its coordinates resolve dynamically via geocoding.
    final cleanNorm = clean.replaceAll('barangay ', '').trim();
    if (cleanNorm.isNotEmpty) {
      for (final entry in santaMariaBarangayCatalog) {
        final alreadyMatched = matches.any(
          (m) =>
              WebReportQueryEngine.normalizeSearchText(
                (m['_name'] ?? '').toString(),
              ) ==
              entry.key,
        );
        if (alreadyMatched) continue;
        final double score;
        if (entry.key == cleanNorm) {
          score = 195.0;
        } else if (entry.key.startsWith(cleanNorm)) {
          score = 155.0;
        } else if (entry.key.contains(cleanNorm) ||
            'santa maria ${entry.key}'.contains(cleanNorm)) {
          score = 125.0;
        } else {
          continue;
        }
        matches.add({
          if (entry.hasCoordinates) 'lat': entry.lat!.toString(),
          if (entry.hasCoordinates) 'lon': entry.lon!.toString(),
          '_name': 'Barangay ${entry.name}',
          '_short_addr': 'Santa Maria, Bulacan',
          'display_name': entry.fullLabel,
          '_distance_km': double.infinity,
          '_score': score,
          '_is_barangay': true,
          '_needs_geocode': !entry.hasCoordinates,
          '_source': 'Official Santa Maria Directory',
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

  // Brgy. Poblacion, Santa Maria, Bulacan Center & Coordinates
  static const LatLng _bulacanCenter = LatLng(
    14.8194,
    120.9565,
  ); // Brgy. Poblacion, Santa Maria, Bulacan

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
          .get(url, headers: _safeHeaders())
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
          .get(url, headers: _safeHeaders())
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

  Future<void> _fetchSuggestions(String query, int revision) async {
    try {
      final top5 = await _combinedSuggestions(_normalizeQuery(query));
      if (mounted && revision == _searchRevision) {
        setState(() {
          _suggestions = top5;
          _isSearchingPlaces = false;
        });
      }
    } catch (e) {
      if (mounted && revision == _searchRevision) {
        setState(() => _isSearchingPlaces = false);
      }
      print("Multi-Source Autocomplete Error: $e");
    }
  }

  Future<List<Map<String, dynamic>>> _combinedSuggestions(
    String normalizedQuery,
  ) async {
    final List<Map<String, dynamic>> allCandidates = [];

    // Local instant Bulacan Barangay matches (<1ms)
    final localMatches = _fetchLocalBarangayCandidates(normalizedQuery);
    allCandidates.addAll(localMatches);

    // Asynchronous network geocoders
    final results = await Future.wait([
      _fetchPhotonOsmCandidates(normalizedQuery),
      _fetchNominatimCandidates(normalizedQuery),
      _fetchGeoapifyCandidates(normalizedQuery),
    ]);
    for (final list in results) {
      allCandidates.addAll(list);
    }

    // Deduplicate results by place name or coordinates. The hardcoded LGU
    // registry coordinates are approximate (~500m off), so when a network
    // geocoder reports the same place, adopt its precise coordinates instead.
    final List<Map<String, dynamic>> merged = [];
    for (final candidate in allCandidates) {
      final candName = (candidate['_name'] ?? '').toString().toLowerCase();
      final candLat = double.tryParse(candidate['lat'].toString()) ?? 0;
      final candLon = double.tryParse(candidate['lon'].toString()) ?? 0;

      int dupIndex = -1;
      for (int k = 0; k < merged.length; k++) {
        final existing = merged[k];
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
        if ((nameMatch && distDiff < 0.08) || distDiff < 0.0005) {
          dupIndex = k;
          break;
        }
      }

      if (dupIndex == -1) {
        merged.add(candidate);
        continue;
      }

      // Network geocoders report more precise coordinates than the hardcoded
      // registry — upgrade the merged entry when the precise source arrives.
      final dupSource = (candidate['_source'] ?? '').toString().toLowerCase();
      final exSource = (merged[dupIndex]['_source'] ?? '')
          .toString()
          .toLowerCase();
      final bool candIsNetwork = dupSource != 'bulacan lgu registry';
      final bool mergedIsRegistry = exSource == 'bulacan lgu registry';
      if (candIsNetwork && mergedIsRegistry) {
        merged[dupIndex] = candidate;
      } else {
        final mergedScore =
            (merged[dupIndex]['_score'] as num?)?.toDouble() ?? 0.0;
        final candScore = (candidate['_score'] as num?)?.toDouble() ?? 0.0;
        if (candScore > mergedScore) merged[dupIndex] = candidate;
      }
    }

    // Sort by combined score descending
    merged.sort(
      (a, b) => (b['_score'] as double).compareTo(a['_score'] as double),
    );

    return merged.take(8).toList();
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

    // Texts and locations swapped together; any pending typed-change from
    // before the swap is now obsolete.
    _originTextDirty = false;
    _destinationTextDirty = false;

    setState(() {});
    if (_originController.text.isNotEmpty &&
        _searchController.text.isNotEmpty) {
      _searchAndRoute();
    }
  }

  void _selectSuggestion(dynamic suggestion) {
    _searchRevision++;
    _debounceTimer?.cancel();
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
          _originTextDirty = false;
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
          _destinationTextDirty = false;
        });
        _destinationFocusNode.unfocus();
        _showPointToPointPill(
          point: selectedLoc,
          name: name,
          address: shortAddr.isNotEmpty
              ? shortAddr
              : (suggestion['display_name'] ?? '').toString(),
        );
        if (_originController.text.trim().isEmpty) {
          _originController.text = 'Your location';
          _customOrigin = null;
        }
        final start =
            (_originController.text == 'Your location' || _customOrigin == null)
            ? (_currentPosition ?? _bulacanCenter)
            : _customOrigin;
        _calculateRoute(selectedLoc, customOrigin: start);
      }
    } else {
      final addressText = shortAddr.isNotEmpty
          ? shortAddr
          : (suggestion['display_name'] ?? '').toString();
      final double distMeters = Geolocator.distanceBetween(
        (_currentPosition ?? _bulacanCenter).latitude,
        (_currentPosition ?? _bulacanCenter).longitude,
        lat,
        lon,
      );
      _stopRouteSimulation();
      setState(() {
        _isRoutePlanningMode = false;
        _isEditingOrigin = false;
        _searchController.text = name;
        _suggestions = [];
        _isSearchHistoryOpen = false;
        _selectedPothole = null;
        _appliedInitialReportId = null;
        _isSearchingPlaces = false;
        _resetRoutePlannerState();
        _isP2pPillVisible = false;
        _searchedPlace = {
          'name': name,
          'address': addressText,
          'location': selectedLoc,
          'distanceKm': distMeters / 1000.0,
          'category': suggestion['_is_barangay'] == true
              ? 'BARANGAY / LGU'
              : 'PLACE / ADDRESS',
        };
      });
      widget.onSelectedReportChanged?.call(null);
      _searchFocusNode.unfocus();
      _addToSearchHistory(name: name, address: addressText, lat: lat, lon: lon);
      _animatedMapMove(
        selectedLoc,
        suggestion['_is_barangay'] == true ? 15.2 : 16.5,
      );
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
          .get(url, headers: _safeHeaders())
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final addr = (data['address'] as Map<String, dynamic>?) ?? {};

        // 1. Street / Road / Landmark
        String road = addr['house_number'] != null
            ? '${addr['house_number']} ${addr['road'] ?? ''}'.trim()
            : (addr['road'] ??
                      addr['pedestrian'] ??
                      addr['amenity'] ??
                      addr['building'] ??
                      '')
                  .toString()
                  .trim();

        // 2. Philippine Barangay (Suburb, Village, Quarter, Neighbourhood, District)
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

        // 3. City / Municipality
        String city =
            (addr['city'] ??
                    addr['town'] ??
                    addr['municipality'] ??
                    addr['county'] ??
                    '')
                .toString()
                .trim();

        // 4. Province
        String province = (addr['province'] ?? addr['state'] ?? 'Bulacan')
            .toString()
            .trim();

        // Structured Philippine Address Format
        String primary = '';
        String secondary = '';

        if (road.isNotEmpty) {
          primary = road;
          secondary = [
            if (brgy.isNotEmpty && brgy != road) brgy,
            if (city.isNotEmpty) city,
            if (province.isNotEmpty && province != city) province,
          ].join(', ');
        } else if (brgy.isNotEmpty) {
          primary = brgy;
          secondary = [
            if (city.isNotEmpty) city,
            if (province.isNotEmpty && province != city) province,
          ].join(', ');
        } else {
          primary = city.isNotEmpty
              ? city
              : (data['display_name'] ?? '').toString().split(',').first.trim();
          secondary = province;
        }

        List<String> parts = [primary.trim(), secondary.trim()];
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
    final normalized = _normalizeQuery(text);

    // Direct numeric coordinate check: "lat, lng" or "lat, lon"
    final coordMatch = RegExp(
      r'^\s*(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)\s*$',
    ).firstMatch(normalized);
    if (coordMatch != null) {
      final lat = double.tryParse(coordMatch.group(1) ?? '');
      final lon = double.tryParse(coordMatch.group(2) ?? '');
      if (lat != null &&
          lon != null &&
          lat >= -90 &&
          lat <= 90 &&
          lon >= -180 &&
          lon <= 180) {
        return LatLng(lat, lon);
      }
    }

    final refPos = _currentPosition ?? _bulacanCenter;
    final viewbox =
        '${refPos.longitude - 0.75},${refPos.latitude + 0.75},${refPos.longitude + 0.75},${refPos.latitude - 0.75}';

    // 1. Primary: OSM Nominatim Geocoding API with viewport bias
    try {
      final nomUrl = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': normalized,
        'format': 'json',
        'limit': '1',
        'countrycodes': 'ph',
        'viewbox': viewbox,
        'bounded': '0',
      });
      final nomRes = await http
          .get(nomUrl, headers: _safeHeaders())
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

    // 1b. Fallback: Query with country context if not specified
    if (!normalized.toLowerCase().contains('philippines')) {
      try {
        final fallbackUrl =
            Uri.https('nominatim.openstreetmap.org', '/search', {
              'q': '$normalized, Philippines',
              'format': 'json',
              'limit': '1',
              'countrycodes': 'ph',
            });
        final fallbackRes = await http
            .get(fallbackUrl, headers: _safeHeaders())
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

    // 2. Secondary: Photon OSM Geocoding API (filtered for Philippines)
    try {
      final photUrl = Uri.https('photon.komoot.io', '/api/', {
        'q': normalized,
        'lat': refPos.latitude.toString(),
        'lon': refPos.longitude.toString(),
        'limit': '5',
      });
      final photRes = await http
          .get(photUrl, headers: _safeHeaders())
          .timeout(const Duration(seconds: 4));
      if (photRes.statusCode == 200) {
        final payload = jsonDecode(photRes.body) as Map<String, dynamic>;
        final features = (payload['features'] as List?) ?? [];
        for (final item in features) {
          final props = (item['properties'] as Map<String, dynamic>?) ?? {};
          final country = (props['country'] ?? props['countrycode'] ?? '')
              .toString()
              .toLowerCase();
          if (country.isNotEmpty &&
              country != 'philippines' &&
              country != 'ph') {
            continue;
          }
          final geometry = (item['geometry'] as Map<String, dynamic>?) ?? {};
          final coords = (geometry['coordinates'] as List?) ?? [0, 0];
          final lat = ((coords.length > 1 ? coords[1] : 0) as num).toDouble();
          final lon = ((coords.isNotEmpty ? coords[0] : 0) as num).toDouble();
          if (lat != 0 && lon != 0) return LatLng(lat, lon);
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
          .get(geoUrl, headers: _safeHeaders())
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

    // 4. Last Fallback: Local Bulacan Barangay Registry (high confidence exact matches only)
    final localMatches = _fetchLocalBarangayCandidates(normalized);
    if (localMatches.isNotEmpty) {
      final best = localMatches.first;
      final bestScore = (best['_score'] as num?)?.toDouble() ?? 0.0;
      if (bestScore >= 200.0) {
        final lat = double.tryParse(best['lat'].toString());
        final lon = double.tryParse(best['lon'].toString());
        if (lat != null && lon != null) return LatLng(lat, lon);
      }
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
        if (_currentPosition == null) {
          await _determinePosition(requestPermission: true);
        }
        start = _currentPosition ?? _bulacanCenter;
      } else {
        start = await _geocodeQuery(_originController.text);
        if (start != null) {
          _customOrigin = start;
        } else {
          start = _currentPosition ?? _bulacanCenter;
        }
      }
    }
    final int seq = ++_routingRequestSeq;
    if (!silent) {
      _stopRouteSimulation();
      setState(() {
        _isRouting = true;
        _routeErrorMessage = null;
        _hasEvaluatedFewerPotholes = false;
      });
    } else {
      // Dynamic recalculation: keep existing route polylines rendered seamlessly
      if (!_isRouting && mounted) {
        setState(() {
          _isRouting = true;
          _routeErrorMessage = null;
          _rubberBandActiveRoute(newStart: start, newEnd: destination);
        });
      } else {
        _rubberBandActiveRoute(newStart: start, newEnd: destination);
      }
    }

    List<List<LatLng>> routes = [];
    List<double> durations = [];
    List<double> distances = [];
    List<List<RouteStep>> stepsByRoute = [];
    bool loadedFromCache = false;
    _lastRoutingEngineCode = '';

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

      var osrmRes = await http.get(osrmUrl).timeout(const Duration(seconds: 8));
      if (osrmRes.statusCode != 200 && _travelMode != OsrmTravelMode.car) {
        final fallbackUrl = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/'
          '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
          '?overview=full&geometries=geojson&alternatives=3&steps=true&annotations=true',
        );
        osrmRes = await http
            .get(fallbackUrl)
            .timeout(const Duration(seconds: 8));
      }

      if (osrmRes.statusCode == 200) {
        final data = jsonDecode(osrmRes.body);
        final List osrmRoutes = data['routes'] ?? [];
        _lastRoutingEngineCode = (data['code'] ?? '').toString();
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
    if (routes.isEmpty && _orsApiKey.isNotEmpty) {
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
              headers: _safeHeaders({
                'Authorization': _orsApiKey,
                'Content-Type': 'application/json',
              }),
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
      final code = _lastRoutingEngineCode.toLowerCase();
      final noRoad =
          code.contains('noroute') ||
          code.contains('waypointnotfound') ||
          code.contains('notraceroute');
      final String errMsg = noRoad
          ? 'No road path found to that destination.'
          : 'Unable to calculate route right now. Active route preserved — check your connection and retry.';
      if (mounted && seq == _routingRequestSeq) {
        setState(() {
          _isRouting = false;
          _routeErrorMessage = errMsg;
        });
      }
      if (mounted && !silent && seq == _routingRequestSeq) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errMsg),
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

    if (!mounted || seq != _routingRequestSeq) return;

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

  Future<void> _activateWebGps() async {
    await _determinePosition(requestPermission: true);
    if (!mounted) return;
    if (_isPermissionDenied || _isLocationDisabled || _currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Allow Location access in your browser address bar, then tap Enable GPS again.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _determinePosition({bool requestPermission = true}) async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        setState(() {
          _isLocationDisabled = true;
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
          });
        }
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() {
          _isPermissionDenied = true;
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

    final Color severityColor = const Color(0xFF0284C7);

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
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
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
                          'ROAD DEFECT DETAILS',
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
                            color: DpwhStandards.getClassColor(
                              pothole.primaryDefect,
                            ).withValues(alpha: isDark ? 0.12 : 0.07),
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
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: DpwhStandards.getClassColor(
                                        pothole.primaryDefect,
                                      ),
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
                                        color: isDark
                                            ? Colors.white
                                            : const Color(0xFF0F172A),
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFF2563EB,
                                      ).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: const Color(0xFF2563EB),
                                      ),
                                    ),
                                    child: Text(
                                      pothole.correctiveMeasure,
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
                                  color: isDark
                                      ? const Color(0xFF94A3B8)
                                      : const Color(0xFF64748B),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                pothole.correctiveMeasure,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.35,
                                  color: isDark
                                      ? const Color(0xFFE2E8F0)
                                      : const Color(0xFF1E293B),
                                ),
                              ),
                              if (pothole.detections != null &&
                                  pothole.detections!.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Divider(
                                  height: 1,
                                  color: DpwhStandards.getClassColor(
                                    pothole.primaryDefect,
                                  ).withValues(alpha: 0.2),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'YOLOv8 Distress Detections (${pothole.detections!.length}):',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: isDark
                                        ? const Color(0xFF94A3B8)
                                        : const Color(0xFF64748B),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                ...pothole.detections!.map((det) {
                                  final name =
                                      det['className'] as String? ?? 'Distress';
                                  final conf =
                                      (det['confidence'] as num?)?.toDouble() ??
                                      0.0;
                                  final code = det['dpwhCode'] as String? ?? '';
                                  final cls = DpwhStandards.classifyByName(
                                    name,
                                  );
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 2.5,
                                    ),
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
                                              color: isDark
                                                  ? Colors.white70
                                                  : Colors.black87,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '${(conf * 100).toStringAsFixed(1)}% conf',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: isDark
                                                ? const Color(0xFF94A3B8)
                                                : const Color(0xFF64748B),
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
    if (DeveloperMarkers.owns(pothole.docId)) {
      await showDeveloperMarkerEditor(
        context,
        location: pothole.location,
        markerId: pothole.docId,
        onPickLocationOnMap: _pickManualMarkerLocationOnMap,
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
                  width: 380,
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
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black.withValues(alpha: 0.94),
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.network(
                imagePath,
                fit: BoxFit.contain,
                loadingBuilder: (ctx, child, progress) {
                  if (progress == null) return child;
                  return const SizedBox(
                    width: 240,
                    height: 200,
                    child: Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  );
                },
                errorBuilder: (ctx, e, st) => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white70,
                        size: 56,
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Photo could not be loaded.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  tooltip: 'Close photo',
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
          _destinationTextDirty = true;
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
          _destinationTextDirty = false;
          _originTextDirty = false;
        });

        _searchFocusNode.unfocus();
        _showPointToPointPill(point: destLoc, name: destQuery);
        await _calculateRoute(destLoc, customOrigin: _currentPosition);
        return;
      }

      // Route Planning Mode (Point A → Point B)
      LatLng? destLoc = _destination;
      // Re-geocode when no destination is resolved yet, or when the user has
      // retyped Point B — otherwise the route targets the OLD destination
      // while the field shows the NEW text.
      if (destLoc == null ||
          destQuery == 'Your location' ||
          _destinationTextDirty) {
        if (destQuery == 'Your location') {
          if (_currentPosition == null) {
            await _determinePosition(requestPermission: true);
          }
          destLoc = _currentPosition ?? _bulacanCenter;
          _destination = destLoc;
        } else {
          destLoc = await _geocodeQuery(destQuery);
          if (destLoc == null) {
            _destinationTextDirty = true;
            throw 'Destination location not found.';
          }
          _destination = destLoc;
        }
        _destinationTextDirty = false;
        _showPointToPointPill(point: destLoc, name: destQuery);
      }

      // 2. Resolve Start Origin (Point A)
      LatLng? originLoc;
      if (originQuery.isEmpty || originQuery == 'Your location') {
        _customOrigin = null;
        _originTextDirty = false;
        if (_currentPosition == null) {
          await _determinePosition(requestPermission: true);
        }
        originLoc = _currentPosition ?? _bulacanCenter;
      } else {
        // Re-geocode retyped origin text - a stale _customOrigin (Point A
        // chosen earlier) must not silently override the text the user sees.
        if (_customOrigin != null && !_originTextDirty) {
          originLoc = _customOrigin;
        } else {
          originLoc = await _geocodeQuery(originQuery);
          if (originLoc == null) {
            _originTextDirty = true;
            throw 'Start location (Point A) not found.';
          }
          _customOrigin = originLoc;
          _originTextDirty = false;
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
    if (DeveloperMarkers.owns(pothole.docId)) {
      await DeveloperMarkers.instance.remove(pothole.docId!);
      return;
    }

    if (isSampleStaMariaMarkerId(pothole.docId)) {
      setState(() {
        _dismissedSampleIds.add(pothole.docId!);
        _snappedPotholeCache.remove(_potholeKey(pothole.location));
      });
      await _refreshRouteAwarePotholeState();
      return;
    }

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

  /// Map rotation, or 0° before the FlutterMap widget has rendered — the
  /// MapController throws if read before then, and this is used during build.
  double get _safeMapRotation {
    try {
      return _mapController.camera.rotation;
    } catch (_) {
      return 0.0;
    }
  }

  double _bearingBetweenDeg(LatLng a, LatLng b) {
    final double lat1 = a.latitude * math.pi / 180.0;
    final double lat2 = b.latitude * math.pi / 180.0;
    final double dLon = (b.longitude - a.longitude) * math.pi / 180.0;
    final double y = math.sin(dLon) * math.cos(lat2);
    final double x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  LatLng _interpolateLatLng(LatLng a, LatLng b, double t) {
    final double clamped = t.clamp(0.0, 1.0);
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * clamped,
      a.longitude + (b.longitude - a.longitude) * clamped,
    );
  }

  List<Widget> _buildStepTurnArrowOverlay(List<LatLng> route, LatLng stepLoc) {
    if (route.length < 2) return const [];
    final List<double> cumDist = List<double>.filled(route.length, 0.0);
    for (int i = 1; i < route.length; i++) {
      cumDist[i] =
          cumDist[i - 1] +
          Geolocator.distanceBetween(
            route[i - 1].latitude,
            route[i - 1].longitude,
            route[i].latitude,
            route[i].longitude,
          );
    }
    int bestIdx = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < route.length; i++) {
      final double d = Geolocator.distanceBetween(
        route[i].latitude,
        route[i].longitude,
        stepLoc.latitude,
        stepLoc.longitude,
      );
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    final double targetBack = (cumDist[bestIdx] - 10.0).clamp(
      0.0,
      cumDist[bestIdx],
    );
    final double targetFwd = (cumDist[bestIdx] + 12.0).clamp(
      cumDist[bestIdx],
      cumDist.last,
    );
    final List<LatLng> arrowPts = [];
    for (int i = bestIdx; i > 0; i--) {
      if (cumDist[i - 1] <= targetBack) {
        final double segLen = cumDist[i] - cumDist[i - 1];
        final double t = segLen > 0.01
            ? (targetBack - cumDist[i - 1]) / segLen
            : 0.0;
        arrowPts.add(_interpolateLatLng(route[i - 1], route[i], t));
        for (int j = i; j <= bestIdx; j++) {
          arrowPts.add(route[j]);
        }
        break;
      }
    }
    if (arrowPts.isEmpty) {
      arrowPts.addAll(route.sublist(0, bestIdx + 1));
    }
    for (int i = bestIdx; i < route.length - 1; i++) {
      if (cumDist[i + 1] >= targetFwd) {
        final double segLen = cumDist[i + 1] - cumDist[i];
        final double t = segLen > 0.01
            ? (targetFwd - cumDist[i]) / segLen
            : 1.0;
        arrowPts.add(_interpolateLatLng(route[i], route[i + 1], t));
        break;
      } else {
        arrowPts.add(route[i + 1]);
      }
    }
    if (arrowPts.length < 2) return const [];
    final double bearingDeg = _bearingBetweenDeg(
      arrowPts[arrowPts.length - 2],
      arrowPts.last,
    );
    final double bearingRad = bearingDeg * math.pi / 180.0;
    return [
      PolylineLayer(
        polylines: [
          Polyline(
            points: arrowPts,
            color: Colors.white,
            strokeWidth: 7.5,
            strokeCap: StrokeCap.round,
            strokeJoin: StrokeJoin.round,
          ),
        ],
      ),
      MarkerLayer(
        markers: [
          Marker(
            point: arrowPts.last,
            width: 24,
            height: 24,
            rotate: false,
            child: IgnorePointer(
              child: Transform.rotate(
                angle: bearingRad,
                child: const Icon(
                  Icons.navigation_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  List<LatLng> _computeDistinctRouteBadgePoints(List<List<LatLng>> routes) {
    if (routes.isEmpty) return const [];

    List<LatLng> sampleRoute(List<LatLng> pts) {
      if (pts.length <= 2) return pts;
      final int start = (pts.length * 0.12).floor().clamp(1, pts.length - 2);
      final int end = (pts.length * 0.88).ceil().clamp(
        start + 1,
        pts.length - 1,
      );
      final int span = end - start;
      final int step = math.max(1, (span / 40).ceil());
      final List<LatLng> sampled = [];
      for (int i = start; i < end; i += step) {
        sampled.add(pts[i]);
      }
      if (sampled.isEmpty) {
        sampled.add(pts[pts.length ~/ 2]);
      }
      return sampled;
    }

    double approxMeters(LatLng a, LatLng b) {
      final double dLat = (a.latitude - b.latitude) * 111320.0;
      final double cosLat = math.cos(a.latitude * math.pi / 180.0);
      final double dLon = (a.longitude - b.longitude) * 111320.0 * cosLat;
      return math.sqrt(dLat * dLat + dLon * dLon);
    }

    final List<List<LatLng>> samples = routes.map(sampleRoute).toList();
    final List<LatLng> placed = [];
    const List<double> fallbackFractions = [0.35, 0.65, 0.50];

    for (int rIdx = 0; rIdx < routes.length; rIdx++) {
      final List<LatLng> pts = routes[rIdx];
      if (pts.length <= 2) {
        placed.add(pts.isNotEmpty ? pts.first : _bulacanCenter);
        continue;
      }

      final List<LatLng> candidates = samples[rIdx];
      LatLng bestPt = candidates[candidates.length ~/ 2];
      double bestScore = -1.0;
      double bestOtherDist = 0.0;

      for (final p in candidates) {
        double minOtherDist = double.infinity;
        for (int oIdx = 0; oIdx < samples.length; oIdx++) {
          if (oIdx == rIdx) continue;
          for (final q in samples[oIdx]) {
            final double d = approxMeters(p, q);
            if (d < minOtherDist) minOtherDist = d;
          }
        }
        if (minOtherDist == double.infinity) minOtherDist = 0.0;

        double minPlacedDist = double.infinity;
        for (final prev in placed) {
          final double d = approxMeters(p, prev);
          if (d < minPlacedDist) minPlacedDist = d;
        }
        final double placedBonus = minPlacedDist == double.infinity
            ? 0.0
            : 0.6 * math.min(minPlacedDist, 1500.0);
        final double score = minOtherDist + placedBonus;
        if (score > bestScore) {
          bestScore = score;
          bestPt = p;
          bestOtherDist = minOtherDist;
        }
      }

      if (bestOtherDist < 30.0) {
        final double frac =
            fallbackFractions[rIdx % fallbackFractions.length];
        bestPt = pts[(pts.length * frac).round().clamp(1, pts.length - 2)];
      }
      placed.add(bestPt);
    }
    return placed;
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
    List<String> secondaryDefects = const [],
    int count = 1,
    double size = 38,
    bool isSelected = false,
  }) => RoadHazardMarker(
    primaryDefect: primaryDefect,
    secondaryDefects: secondaryDefects,
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
            left: centerXY - 24,
            top: centerXY - 24,
            width: 48,
            height: 48,
            child: WebMapMarkerButton(
              label: 'Collapse nearby reports',
              onTap: () {
                setState(() {
                  _expandedClusterId = null;
                });
              },
              child: Center(
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
          ),

          // 3. Child Pothole Nodes
          for (int i = 0; i < count; i++) ...[
            Positioned(
              left: centerXY + childOffsets[i].dx - 24,
              top: centerXY + childOffsets[i].dy - 24,
              child: WebMapMarkerButton(
                label:
                    '${cluster.items[i].primaryDefect} (${cluster.items[i].primaryDpwhCode}), ${cluster.items[i].status}',
                onTap: () {
                  final item = cluster.items[i];
                  if (DeveloperMarkers.owns(item.docId)) {
                    _startMarkerPlacement(item);
                    return;
                  }
                  _setSelectedPothole(item, notify: true, animate: false);
                  if (kIsWeb && MediaQuery.sizeOf(context).width < 900) {
                    _openCompactReportSheet(item);
                  }
                },
                child: SizedBox.square(
                  dimension: 48,
                  child: Center(
                    child: _buildSpiderChildNode(
                      pothole: cluster.items[i],
                      isSelected:
                          _selectedPothole == cluster.items[i] ||
                          (_selectedPothole?.docId != null &&
                              _selectedPothole?.docId ==
                                  cluster.items[i].docId) ||
                          (_selectedPothole != null &&
                              _selectedPothole!.location.latitude ==
                                  cluster.items[i].location.latitude &&
                              _selectedPothole!.location.longitude ==
                                  cluster.items[i].location.longitude),
                      isDark: isDark,
                    ),
                  ),
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
    secondaryDefects: DpwhStandards.extractDetectionClassNames(
      pothole.detections,
    ),
    status: pothole.status,
    size: 32,
    isSelected: isSelected,
    compact: false,
  );

  int _countNearbyPlaceHazards(LatLng? target) {
    if (target == null) return 0;
    int count = 0;
    for (final p in _effectivePotholes) {
      if (p.status == 'deleted' || p.status == 'rejected') continue;
      final d = Geolocator.distanceBetween(
        target.latitude,
        target.longitude,
        p.location.latitude,
        p.location.longitude,
      );
      if (d <= 1000) count++;
    }
    return count;
  }

  void _startDirectionsToPoint(LatLng dest, {String? label}) {
    setState(() {
      _isRoutePlanningMode = true;
      _isEditingOrigin = false;
      _destination = dest;
      if (label != null && label.trim().isNotEmpty) {
        _searchController.text = label.trim();
      }
      if (_originController.text.trim().isEmpty) {
        _originController.text = 'Your location';
        _customOrigin = null;
      }
      _destinationTextDirty = false;
      _originTextDirty = false;
      _searchedPlace = null;
      _isLegendOpen = false;
    });
    _calculateRoute(
      dest,
      customOrigin:
          (_originController.text == 'Your location' || _customOrigin == null)
          ? (_currentPosition ?? _bulacanCenter)
          : _customOrigin,
    );
  }

  Widget _buildWorkspacePanelWidget({
    required bool isDark,
    required WebReportQueryResult queryResult,
    required List<WebUnifiedSearchSuggestion> unifiedSuggestions,
    required Widget routePlannerContent,
    bool showCollapseButton = true,
  }) {
    final LatLng? searchedLoc = _searchedPlace?['location'] is LatLng
        ? _searchedPlace!['location'] as LatLng
        : null;
    final selectedItem = _selectedPothole?.toReportItem();
    return WebMapWorkspacePanel(
      searchController: _searchController,
      searchFocusNode: _searchFocusNode,
      searchQuery: _searchController.text,
      isSearchingPlaces: _isSearchingPlaces,
      isSearchHistoryOpen: _isSearchHistoryOpen,
      unifiedSuggestions: unifiedSuggestions,
      highlightedSuggestionIndex: _highlightedSuggestionIndex,
      searchHistory: _searchHistory,
      searchedPlace: _searchedPlace,
      nearbyPlaceHazardCount: _countNearbyPlaceHazards(searchedLoc),
      onClearSearchedPlace: () => setState(() => _searchedPlace = null),
      onDirectionsToPlace: (loc) => _startDirectionsToPoint(
        loc,
        label: (_searchedPlace?['name'] ?? '').toString(),
      ),
      filter: _reportFilter,
      onFilterChanged: _updateReportFilter,
      isFilterDrawerOpen: _isFilterDrawerOpen,
      onToggleFilterDrawer: () =>
          setState(() => _isFilterDrawerOpen = !_isFilterDrawerOpen),
      onOpenBarangayPicker: _openBarangayPicker,
      queryResult: queryResult,
      visibleResultLimit: _visibleResultLimit,
      onLoadMoreResults: () => setState(() => _visibleResultLimit += 25),
      selectedReport: selectedItem,
      onSelectReport: (item) {
        final marker = _findMarkerForItem(item);
        if (marker != null) {
          _setSelectedPothole(marker, notify: true, animate: true);
        }
      },
      onBackToResults: () =>
          _setSelectedPothole(null, notify: true, animate: false),
      currentUid: widget.currentUid,
      isAdminUser: widget.isAdminUser,
      hasUserLocation: _currentPosition != null,
      onEnableGps: () => unawaited(_activateWebGps()),
      isCloudLoading: widget.isCloudLoading,
      cloudError: widget.cloudError,
      onRetryCloud: widget.onRetryCloud ?? () {},
      onOpenRoutePlanner: () {
        setState(() {
          _isRoutePlanningMode = true;
          if (_originController.text.trim().isEmpty) {
            _originController.text = 'Your location';
            _customOrigin = null;
          }
        });
      },
      routePlannerContent: routePlannerContent,
      isRoutePlanningMode: _isRoutePlanningMode,
      onSearchChanged: _onSearchChanged,
      onSubmitSearch: () {
        if (unifiedSuggestions.isNotEmpty) {
          unawaited(_selectUnifiedSuggestion(unifiedSuggestions.first));
          return;
        }
        final q = _searchController.text.trim();
        if (q.isEmpty) return;
        unawaited(() async {
          final resolved = await _geocodeQuery(_normalizeQuery(q));
          if (!mounted || resolved == null) return;
          _selectSuggestion({
            'lat': resolved.latitude.toString(),
            'lon': resolved.longitude.toString(),
            '_name': q,
            '_short_addr': 'Bulacan, Philippines',
            'display_name': q,
          });
        }());
      },
      onClearSearch: () {
        _debounceTimer?.cancel();
        _searchRevision++;
        setState(() {
          _searchController.clear();
          _suggestions = [];
          _isSearchingPlaces = false;
          _highlightedSuggestionIndex = -1;
          _searchedPlace = null;
        });
      },
      onSelectSuggestion: (s) => unawaited(_selectUnifiedSuggestion(s)),
      onSelectHistoryItem: (item) => unawaited(
        _selectPlaceSuggestion({
          'lat': (item['lat'] ?? _bulacanCenter.latitude).toString(),
          'lon': (item['lon'] ?? _bulacanCenter.longitude).toString(),
          '_name': item['name'] ?? 'Saved Place',
          '_short_addr': item['address'] ?? '',
          'display_name': item['address'] ?? item['name'] ?? '',
        }),
      ),
      onRemoveHistoryItem: _removeFromSearchHistory,
      onClearHistory: _clearSearchHistory,
      onMoveSuggestionHighlight: (idx) =>
          setState(() => _highlightedSuggestionIndex = idx),
      onCenterReportOnMap: (item) {
        _animatedMapMove(item.location, 17.8);
      },
      onViewFullPhoto: _showFullScreenPhoto,
      onEditReport: null,
      onDeleteReport: _confirmTrashReport,
      onAdminModerate: widget.isAdminUser ? _handleAdminModeration : null,
      onCollapsePanel: showCollapseButton
          ? () => setState(() => _isSidePanelCollapsed = true)
          : null,
    );
  }

  Widget _buildCompactTopBar({
    required bool isDark,
    required WebReportQueryResult queryResult,
    required List<WebUnifiedSearchSuggestion> unifiedSuggestions,
    required Widget routePlannerContent,
  }) {
    final activeFilters = _reportFilter.activeFilterCount;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WebCard(
          elevated: true,
          padding: const EdgeInsets.symmetric(
            horizontal: WebDesign.space2,
            vertical: WebDesign.space1,
          ),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: 18,
                color: WebDesign.textMuted(isDark),
              ),
              const SizedBox(width: WebDesign.space2),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) {
                    if (unifiedSuggestions.isNotEmpty) {
                      unawaited(
                        _selectUnifiedSuggestion(unifiedSuggestions.first),
                      );
                    }
                  },
                  decoration: InputDecoration(
                    hintText: 'Search Bulacan, barangay, or #ID',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded, size: 16),
                            onPressed: () {
                              _debounceTimer?.cancel();
                              setState(() {
                                _searchController.clear();
                                _suggestions = [];
                                _isSearchingPlaces = false;
                                _searchedPlace = null;
                              });
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: WebDesign.space1),
              OutlinedButton.icon(
                onPressed: () => _openCompactFiltersSheet(isDark),
                icon: Icon(
                  Icons.tune_rounded,
                  size: 16,
                  color: activeFilters > 0
                      ? WebDesign.brandOnSurface(isDark)
                      : null,
                ),
                label: Text(
                  activeFilters > 0 ? 'Filters ($activeFilters)' : 'Filters',
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, WebDesign.touchTarget),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  side: BorderSide(
                    color: activeFilters > 0
                        ? WebDesign.brand(isDark)
                        : WebDesign.border(isDark),
                  ),
                ),
              ),
              const SizedBox(width: WebDesign.space1),
              ElevatedButton(
                onPressed: () => _openCompactReportsSheet(isDark, queryResult),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, WebDesign.touchTarget),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text('List (${queryResult.items.length})'),
              ),
            ],
          ),
        ),
        if (unifiedSuggestions.isNotEmpty) ...[
          const SizedBox(height: WebDesign.space2),
          WebCard(
            elevated: true,
            padding: EdgeInsets.zero,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: unifiedSuggestions.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: WebDesign.border(isDark)),
                itemBuilder: (ctx, i) {
                  final entry = unifiedSuggestions[i];
                  if (entry.isReport && entry.report != null) {
                    final r = entry.report!;
                    final cls =
                        DpwhStandards.classForReport({
                          'primaryDefect': r.primaryDefect,
                          'primaryDpwhCode': r.primaryDpwhCode,
                        }) ??
                        DpwhStandards.pothole;
                    return ListTile(
                      dense: true,
                      leading: RoadDefectGlyph(
                        classId: cls.classId,
                        size: 22,
                        color: cls.color,
                      ),
                      title: Text(
                        '${r.primaryDefect} · #${r.shortId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        entry.reportMatchReason ?? r.locationLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => unawaited(_selectUnifiedSuggestion(entry)),
                    );
                  }
                  final place = entry.rawPlace ?? const {};
                  final name =
                      (place['_name'] ?? place['display_name'] ?? 'Location')
                          .toString();
                  final addr =
                      (place['_short_addr'] ?? place['display_name'] ?? '')
                          .toString();
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: addr.isEmpty
                        ? null
                        : Text(
                            addr,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () => unawaited(_selectUnifiedSuggestion(entry)),
                  );
                },
              ),
            ),
          ),
        ] else if (_searchedPlace != null &&
            !_isRoutePlanningMode &&
            _selectedPothole == null) ...[
          const SizedBox(height: WebDesign.space2),
          WebCard(
            elevated: true,
            padding: const EdgeInsets.all(WebDesign.space3),
            child: Row(
              children: [
                Icon(
                  Icons.place_rounded,
                  color: WebDesign.brandOnSurface(isDark),
                ),
                const SizedBox(width: WebDesign.space2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (_searchedPlace!['name'] ?? 'Place').toString(),
                        style: Theme.of(context).textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${_countNearbyPlaceHazards(_searchedPlace!['location'] as LatLng?)} hazards within 1 km',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () {
                    final loc = _searchedPlace?['location'] as LatLng?;
                    if (loc != null) {
                      _startDirectionsToPoint(
                        loc,
                        label: (_searchedPlace?['name'] ?? '').toString(),
                      );
                    }
                  },
                  child: const Text('Directions'),
                ),
                IconButton(
                  tooltip: 'Dismiss place',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => setState(() => _searchedPlace = null),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openCompactFiltersSheet(bool isDark) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: WebDesign.surface(isDark),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.82,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        WebDesign.space4,
                        WebDesign.space3,
                        WebDesign.space2,
                        WebDesign.space2,
                      ),
                      child: Row(
                        children: [
                          Text(
                            'Filter Road Reports',
                            style: Theme.of(sheetCtx).textTheme.titleMedium,
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: !_reportFilter.hasAnyFilter
                                ? null
                                : () {
                                    _updateReportFilter(
                                      _reportFilter.clearAll(),
                                    );
                                    setSheetState(() {});
                                  },
                            child: const Text('Reset'),
                          ),
                          IconButton(
                            tooltip: 'Close filters',
                            onPressed: () => Navigator.of(sheetCtx).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: WebDesign.border(isDark)),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(WebDesign.space4),
                        child: WebMapFilterControls(
                          filter: _reportFilter,
                          onChanged: (next) {
                            _updateReportFilter(next);
                            setSheetState(() {});
                          },
                          onOpenBarangayPicker: () async {
                            await _openBarangayPicker();
                            setSheetState(() {});
                          },
                        ),
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

  Future<void> _openCompactReportsSheet(
    bool isDark,
    WebReportQueryResult queryResult,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: WebDesign.surface(isDark),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        final items = queryResult.items;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetCtx).height * 0.78,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    WebDesign.space4,
                    WebDesign.space3,
                    WebDesign.space2,
                    WebDesign.space2,
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Matching Reports (${items.length})',
                        style: Theme.of(sheetCtx).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Close reports list',
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: WebDesign.border(isDark)),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(WebDesign.space5),
                            child: EmptyState(
                              icon: Icons.filter_alt_off_outlined,
                              title: 'No matching reports',
                              message:
                                  'Adjust your search or active filters to see reports here.',
                              action: _reportFilter.hasAnyFilter
                                  ? OutlinedButton(
                                      onPressed: () {
                                        _updateReportFilter(
                                          _reportFilter.clearAll(),
                                        );
                                        Navigator.of(sheetCtx).pop();
                                      },
                                      child: const Text('Reset filters'),
                                    )
                                  : null,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(WebDesign.space3),
                          itemCount: items.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: WebDesign.space2),
                          itemBuilder: (ctx, i) {
                            final item = items[i];
                            return WebReportSummaryCard(
                              report: item,
                              isSelected: _selectedPothole?.docId == item.docId,
                              onTap: () {
                                Navigator.of(sheetCtx).pop();
                                final marker = _findMarkerForItem(item);
                                if (marker != null) {
                                  _setSelectedPothole(
                                    marker,
                                    notify: true,
                                    animate: true,
                                  );
                                  _openCompactReportSheet(marker);
                                }
                              },
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
  }

  Future<void> _openCompactReportSheet(PotholeMarker pothole) async {
    final isDark = AppSettings.instance.isDarkMode;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: WebDesign.surface(isDark),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        final item = pothole.toReportItem();
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetCtx).height * 0.82,
            child: WebReportDetailPanel(
              report: item,
              currentUid: widget.currentUid,
              isAdminUser: widget.isAdminUser,
              onBack: () {
                Navigator.of(sheetCtx).pop();
                _setSelectedPothole(null, notify: true, animate: false);
              },
              onCenterOnMap: () {
                Navigator.of(sheetCtx).pop();
                _animatedMapMove(item.location, 17.8);
              },
              onViewFullPhoto: () => _showFullScreenPhoto(item.imageUrl),
              onEditReport: null,
              onDeleteReport: () {
                Navigator.of(sheetCtx).pop();
                _confirmTrashReport(item);
              },
              onAdminModerate: widget.isAdminUser
                  ? (status) => _handleAdminModeration(item, status)
                  : null,
            ),
          ),
        );
      },
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
            final double viewportHeight = MediaQuery.sizeOf(context).height;
            final bool isPhoneLandscape =
                viewportWidth > viewportHeight && viewportHeight < 560;
            final bool isCompactViewport = viewportWidth < 420;
            final bool isCompactWorkspace = kIsWeb && viewportWidth < 900;
            final double sidePanelWidth = viewportWidth < 1180
                ? WebDesign.mapPanelCompactWidth
                : WebDesign.mapPanelWidth;

            final WebReportQueryResult queryResult = _computeReportQuery();
            final List<PotholeMarker> filteredMarkers = _markersForMapDisplay(
              _markersForResult(queryResult),
            );
            final List<WebUnifiedSearchSuggestion> unifiedSuggestions =
                _buildUnifiedSuggestions(queryResult.items);

            final bool isClearAhead =
                _nearestPotholeInfo.isEmpty ||
                _nearestPotholeInfo == 'Clear ahead';
            final int activeRouteIndex =
                _alternativeRoutes.isNotEmpty &&
                    _selectedRouteIndex < _alternativeRoutes.length
                ? _selectedRouteIndex
                : 0;
            final RouteHazardSummary? activeSummary =
                _activeRouteIndex?.summary ??
                (_routeComparison != null &&
                        activeRouteIndex < _routeComparison!.options.length
                    ? _routeComparison!.options[activeRouteIndex].summary
                    : null);
            final int activePotholeCount =
                (_destination != null || _routePoints.isNotEmpty)
                ? (activeSummary?.distinctPotholeCount ??
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

            final Widget routePlannerWidget = _buildRoutePlanningContent(
              isDark: isDark,
              isClearAhead: isClearAhead,
              distStr: distStr,
              totalEtaStr: totalEtaStr,
              activePotholeCount: activePotholeCount,
            );

            final Widget mapCanvasStack = Stack(
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
                    child: _shouldUseWebVectorMap
                        ? _buildWebMapLibreMap(isDark)
                        : FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter:
                            _initialUrlCenter ??
                            _currentPosition ??
                            _bulacanCenter,
                        initialZoom: _initialUrlZoom ?? 15.0,
                        minZoom: 3.0,
                        maxZoom: 19.0,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                          pinchMoveThreshold: 35.0,
                          scrollWheelVelocity: 0.005,
                        ),
                        onPositionChanged: _onMapPositionChanged,
                        onTap: (_, point) {
                          if (_isPlacingMarker) {
                            setState(() => _pendingMarkerLocation = point);
                            _animatedMapMove(
                              point,
                              _mapController.camera.zoom,
                            );
                          } else if (_isEditingDevLocation) {
                            setState(() => _pendingDevLocation = point);
                          } else if (_isRoutePlanningMode) {
                            // Route Planning Mode: tapping the map sets Point A or Point B directly
                            if (_isSearchHistoryOpen ||
                                _suggestions.isNotEmpty) {
                              setState(() {
                                _isSearchHistoryOpen = false;
                                _suggestions = [];
                              });
                              _searchFocusNode.unfocus();
                              _originFocusNode.unfocus();
                              _destinationFocusNode.unfocus();
                            }

                            // 1. If user tapped directly on an alternative route, select that route
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

                              if (tappedIndex != null &&
                                  tappedIndex != _selectedRouteIndex) {
                                _selectActiveRoute(tappedIndex);
                                return;
                              }
                            }

                            if (_isEditingOrigin) {
                              // User is choosing Point A (Starting Point)
                              final coordStr =
                                  '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';
                              setState(() {
                                _customOrigin = point;
                                _originController.text = coordStr;
                                _originTextDirty = false;
                                _suggestions = [];
                                _isSearchHistoryOpen = false;
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
                              final dest =
                                  _destination ??
                                  (_routePoints.isNotEmpty
                                      ? _routePoints.last
                                      : null);
                              if (dest != null) {
                                _ensureEndpointInView(point);
                                _calculateRoute(
                                  dest,
                                  customOrigin: point,
                                  fitCamera: false,
                                  silent: true,
                                );
                              }
                            } else {
                              // User is choosing Point B (Destination)
                              final coordStr =
                                  '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';
                              setState(() {
                                _destination = point;
                                _searchController.text = coordStr;
                                _destinationTextDirty = false;
                                _suggestions = [];
                                _isSearchHistoryOpen = false;
                              });
                              _showPointToPointPill(
                                point: point,
                                autoRoute: false,
                              );
                              _rubberBandActiveRoute(newEnd: point);
                              _reverseGeocodeLabel(point).then((label) {
                                if (mounted &&
                                    _destination == point &&
                                    label.isNotEmpty) {
                                  setState(
                                    () => _searchController.text = label,
                                  );
                                }
                              });
                              if (_originController.text.trim().isEmpty) {
                                _originController.text = 'Your location';
                                _customOrigin = null;
                              }
                              final start =
                                  (_originController.text == 'Your location' ||
                                      _customOrigin == null)
                                  ? (_currentPosition ?? _bulacanCenter)
                                  : _customOrigin;
                              _ensureEndpointInView(point);
                              _calculateRoute(
                                point,
                                customOrigin: start,
                                fitCamera: false,
                                silent: true,
                              );
                            }
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
                                _searchedPlace != null ||
                                _suggestions.isNotEmpty ||
                                _isSearchHistoryOpen) {
                              setState(() {
                                _selectedPothole = null;
                                _searchedPlace = null;
                              });
                            }

                            if (_isP2pPillVisible && _p2pPoint != null) {
                              final double dist = Geolocator.distanceBetween(
                                _p2pPoint!.latitude,
                                _p2pPoint!.longitude,
                                point.latitude,
                                point.longitude,
                              );
                              if (dist < 10.0) {
                                setState(() {
                                  _isP2pPillVisible = false;
                                  _p2pPoint = null;
                                  _tappedPoint = null;
                                  if (!_isRoutePlanningMode) {
                                    _stopRouteSimulation();
                                    _resetRoutePlannerState();
                                  }
                                });
                                return;
                              }
                            }

                            setState(() {
                              _tappedRequestSeq++;
                              _tappedPoint = point;
                              _tappedPointLabel = '';
                              _tappedPointSecondary = '';
                            });
                            _resolveTappedLabel(_tappedRequestSeq);
                            _showPointToPointPill(point: point);
                          }
                        },
                      ),
                      children: [
                        ValueListenableBuilder<String>(
                          valueListenable:
                              AppSettings.instance.webMapStyleNotifier,
                          builder: (context, mapStyle, _) {
                            String url;
                            List<String>? subdomains;
                            if (mapStyle == 'Satellite') {
                              url =
                                  'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
                            } else if (mapStyle == 'Dark Canvas') {
                              url =
                                  'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';
                            } else if (mapStyle == 'OpenStreetMap') {
                              url =
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
                            } else {
                              url =
                                  'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}';
                              subdomains = const ['0', '1', '2', '3'];
                            }
                            return TileLayer(
                              key: ValueKey(mapStyle),
                              urlTemplate: url,
                              subdomains: subdomains ?? const ['a', 'b', 'c'],
                              userAgentPackageName:
                                  'com.example.pothole_scanner',
                              tileDisplay: const TileDisplay.fadeIn(
                                duration: Duration(milliseconds: 120),
                              ),
                              panBuffer: 2,
                              keepBuffer: 6,
                              minZoom: 3,
                              maxZoom: 20,
                              maxNativeZoom: 20,
                            );
                          },
                        ),
                        // Route Polylines (Google Maps Style: Bold Main + Faint Alternatives)
                        if (_alternativeRoutes.isNotEmpty)
                          PolylineLayer(
                            polylines: [
                              // 1. Draw unselected alternative routes as faint slate/grey lines
                              if (!_isDraggingEndpoint)
                                ..._alternativeRoutes
                                    .asMap()
                                    .entries
                                    .where((e) => e.key != _selectedRouteIndex)
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
                              ..._buildEndpointConnectorPolylines(
                                activeRoutePolyline,
                              ),
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
                              ..._buildEndpointConnectorPolylines(_routePoints),
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
                        if (_selectedStepIndex != null &&
                            _selectedStepIndex! < _routeSteps.length &&
                            activeRoutePolyline.length >= 2)
                          ..._buildStepTurnArrowOverlay(
                            activeRoutePolyline,
                            _routeSteps[_selectedStepIndex!].location,
                          ),
                        if (_showHeatmap)
                          CircleLayer(
                            key: const ValueKey('pothole_heatmap'),
                            circles: filteredMarkers.map((p) {
                              final severity = p.overallSeverity.toLowerCase();
                              final Color color = severity == 'high'
                                  ? const Color(0xFFEF4444)
                                  : severity == 'low'
                                  ? const Color(0xFFEAB308)
                                  : const Color(0xFF0284C7);
                              return CircleMarker(
                                point: p.location,
                                radius: 110,
                                useRadiusInMeter: true,
                                color: color.withValues(alpha: 0.38),
                                borderColor: color.withValues(alpha: 0.85),
                                borderStrokeWidth: 2,
                              );
                            }).toList(),
                          ),
                        MarkerLayer(
                          markers: [
                            if (_currentPosition != null)
                              Marker(
                                point: _currentPosition!,
                                width: 48,
                                height: 48,
                                child: Center(
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      // Google Maps Breathing Radar Pulse Halo
                                      AnimatedBuilder(
                                        animation: _puckPulseController,
                                        builder: (context, _) {
                                          final t = _puckPulseController.value;
                                          final haloSize = 18.0 + t * 28.0;
                                          final haloOpacity = (1.0 - t) * 0.42;
                                          return Container(
                                            width: haloSize,
                                            height: haloSize,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: const Color(
                                                0xFF1A73E8,
                                              ).withValues(alpha: haloOpacity),
                                            ),
                                          );
                                        },
                                      ),
                                      // Core Google Blue Dot
                                      Container(
                                        width: 18,
                                        height: 18,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: const Color(0xFF1A73E8),
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
                                    ],
                                  ),
                                ),
                              ),
                            if (_searchedPlace != null &&
                                _searchedPlace!['location'] is LatLng)
                              Marker(
                                key: const ValueKey('searched_place_pin'),
                                point: _searchedPlace!['location'] as LatLng,
                                width: 44,
                                height: 44,
                                child: Tooltip(
                                  message:
                                      (_searchedPlace!['name'] ??
                                              'Searched place')
                                          .toString(),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: WebDesign.brand(isDark),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2.5,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.25,
                                          ),
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.place_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ),
                            // Tappable clustered pothole markers with 10m Radial Spider Tree expansion
                            ..._clusterPotholes(
                              _filterMarkersInViewport(filteredMarkers),
                              radiusMeters: 10.0,
                            ).map((cluster) {
                              if (cluster.isSingle) {
                                final pothole = cluster.singleItem;
                                final bool isSelected =
                                    _selectedPothole != null &&
                                    (_selectedPothole == pothole ||
                                        (_selectedPothole!.docId != null &&
                                            pothole.docId != null &&
                                            _selectedPothole!.docId ==
                                                pothole.docId) ||
                                        (_selectedPothole!.location.latitude ==
                                                pothole.location.latitude &&
                                            _selectedPothole!
                                                    .location
                                                    .longitude ==
                                                pothole.location.longitude));
                                final double baseMarkerSize =
                                    _getDynamicMarkerSize();
                                final double dynamicSize = isSelected
                                    ? (baseMarkerSize * 1.35).clamp(24.0, 56.0)
                                    : baseMarkerSize;
                                return Marker(
                                  key: ValueKey(
                                    'detected_${pothole.id ?? pothole.docId ?? pothole.timestamp.millisecondsSinceEpoch}',
                                  ),
                                  point: pothole.location,
                                  width: math.max(48, dynamicSize + 26),
                                  height: math.max(48, dynamicSize + 26),
                                  child: WebMapMarkerButton(
                                    label:
                                        '${pothole.primaryDefect} (${pothole.primaryDpwhCode}), ${pothole.status}',
                                    onTap: () {
                                      if (DeveloperMarkers.owns(
                                        pothole.docId,
                                      )) {
                                        _startMarkerPlacement(pothole);
                                        return;
                                      }

                                      _searchFocusNode.unfocus();
                                      _originFocusNode.unfocus();
                                      _destinationFocusNode.unfocus();
                                      setState(() {
                                        _searchedPlace = null;
                                        _isSearchHistoryOpen = false;
                                      });
                                      _setSelectedPothole(
                                        pothole,
                                        notify: true,
                                        animate: true,
                                      );
                                      if (isCompactWorkspace) {
                                        _openCompactReportSheet(pothole);
                                      }
                                    },
                                    child: Center(
                                      child: _buildUnifiedPotholeIcon(
                                        status: pothole.status,
                                        severity: pothole.overallSeverity,
                                        primaryDefect: pothole.primaryDefect,
                                        secondaryDefects: DpwhStandards
                                            .extractDetectionClassNames(
                                              pothole.detections,
                                            ),
                                        count: pothole.potholeCount,
                                        size: dynamicSize,
                                        isSelected: isSelected,
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
                                return Marker(
                                  key: ValueKey('cluster_${cluster.id}'),
                                  point: cluster.center,
                                  width: 48,
                                  height: 48,
                                  child: WebMapMarkerButton(
                                    label:
                                        'Expand ${cluster.items.length} nearby reports',
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
                                    child: Center(
                                      child: SizedBox.square(
                                        dimension: (_getDynamicMarkerSize() + 4)
                                            .clamp(22.0, 34.0),
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            Container(
                                              width:
                                                  (_getDynamicMarkerSize() + 4)
                                                      .clamp(22.0, 34.0),
                                              height:
                                                  (_getDynamicMarkerSize() + 4)
                                                      .clamp(22.0, 34.0),
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
                                    ),
                                  ),
                                );
                              }
                            }),

                            // Custom Start Location Pin (Draggable — shown whenever an active route/destination exists)
                            if (_customOrigin != null || _destination != null)
                              _buildDraggableEndpointPin(
                                point:
                                    _customOrigin ??
                                    _currentPosition ??
                                    _bulacanCenter,
                                kind: 1,
                                color: const Color(0xFF0284C7),
                              ),

                            // Destination Location Pin (Draggable)
                            if (_destination != null)
                              _buildDraggableEndpointPin(
                                point: _destination!,
                                kind: 2,
                                color: const Color(0xFFFB7185),
                              ),

                            // Active Selected Turn-by-Turn Maneuver Dot (Clean, High-Visibility Google Maps / OSRM Waypoint Dot)
                            if (_selectedStepIndex != null &&
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
                                          color: const Color(0xFF2563EB),
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
                              for (final int rIdx in [
                                for (
                                  int i = 0;
                                  i < _alternativeRoutes.length;
                                  i++
                                )
                                  if (i != _selectedRouteIndex) i,
                                if (_selectedRouteIndex >= 0 &&
                                    _selectedRouteIndex <
                                        _alternativeRoutes.length)
                                  _selectedRouteIndex,
                              ])
                                if (_alternativeRoutes[rIdx].length > 2)
                                  Marker(
                                    key: ValueKey('route_eta_badge_$rIdx'),
                                    point: _computeDistinctRouteBadgePoints(
                                      _alternativeRoutes,
                                    )[rIdx],
                                    width: 158,
                                    height: 38,
                                    rotate: true,
                                    child: Builder(
                                      builder: (context) {
                                        final int rHazards =
                                            rIdx < _routePotholeCounts.length
                                            ? _routePotholeCounts[rIdx]
                                            : 0;
                                        final bool isSelected =
                                            rIdx == _selectedRouteIndex;
                                        final bool isRecommended =
                                            _routeSwitchSuggestion
                                                ?.recommendedRouteIndex ==
                                            rIdx;
                                        return GestureDetector(
                                          onTap: () => _selectActiveRoute(rIdx),
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                              milliseconds: 200,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isSelected
                                                  ? const Color(0xFF2563EB)
                                                  : (isRecommended
                                                        ? const Color(
                                                            0xFF059669,
                                                          )
                                                        : (isDark
                                                              ? const Color(
                                                                  0xFF1E293B,
                                                                )
                                                              : Colors.white)),
                                              borderRadius:
                                                  BorderRadius.circular(18),
                                              border: Border.all(
                                                color:
                                                    (isSelected ||
                                                        isRecommended)
                                                    ? Colors.white
                                                    : (isDark
                                                          ? const Color(
                                                              0xFF475569,
                                                            )
                                                          : const Color(
                                                              0xFFCBD5E1,
                                                            )),
                                                width: isSelected ? 2.0 : 1.2,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: isSelected
                                                      ? const Color(
                                                          0xFF2563EB,
                                                        ).withValues(
                                                          alpha: 0.45,
                                                        )
                                                      : Colors.black26,
                                                  blurRadius: 6,
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
                                                      (isSelected ||
                                                          isRecommended)
                                                      ? Colors.white
                                                      : (isDark
                                                            ? Colors.white70
                                                            : const Color(
                                                                0xFF5F6368,
                                                              )),
                                                ),
                                                const SizedBox(width: 4),
                                                Flexible(
                                                  child: Text(
                                                    rIdx <
                                                            _routeDurations
                                                                .length
                                                        ? (isSelected
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
                                                                      rHazards,
                                                                ))
                                                        : 'Route ${rIdx + 1}',
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 11.0,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color:
                                                          (isSelected ||
                                                              isRecommended)
                                                          ? Colors.white
                                                          : (isDark
                                                                ? Colors.white
                                                                : const Color(
                                                                    0xFF202124,
                                                                  )),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 5),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 5,
                                                        vertical: 1.5,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: rHazards == 0
                                                        ? const Color(
                                                            0xFF10B981,
                                                          ).withValues(
                                                            alpha: 0.22,
                                                          )
                                                        : const Color(
                                                            0xFFF59E0B,
                                                          ).withValues(
                                                            alpha: 0.25,
                                                          ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    rHazards == 0
                                                        ? 'Clear'
                                                        : '$rHazards⚠️',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color:
                                                          (isSelected ||
                                                              isRecommended)
                                                          ? Colors.white
                                                          : (rHazards == 0
                                                                ? const Color(
                                                                    0xFF047857,
                                                                  )
                                                                : const Color(
                                                                    0xFFB45309,
                                                                  )),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                            ],

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

                // 1. Desktop collapsed panel reopen pill OR <900px compact docked search bar
                if (kIsWeb &&
                    widget.isMapActive &&
                    !isCompactWorkspace &&
                    _isSidePanelCollapsed)
                  Positioned(
                    top: 16,
                    left: 16,
                    child: Semantics(
                      button: true,
                      label: 'Show search and reports panel',
                      child: Material(
                        color: WebDesign.surface(isDark),
                        elevation: 2,
                        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                        child: InkWell(
                          onTap: () =>
                              setState(() => _isSidePanelCollapsed = false),
                          borderRadius: BorderRadius.circular(
                            WebDesign.radiusSm,
                          ),
                          child: Container(
                            height: WebDesign.touchTarget,
                            padding: const EdgeInsets.symmetric(
                              horizontal: WebDesign.space3,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: WebDesign.border(isDark),
                              ),
                              borderRadius: BorderRadius.circular(
                                WebDesign.radiusSm,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.menu_open_rounded, size: 18),
                                const SizedBox(width: WebDesign.space2),
                                Text(
                                  'Search & Reports (${queryResult.items.length})',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (kIsWeb && widget.isMapActive && isCompactWorkspace)
                  Positioned(
                    top: isPhoneLandscape ? 8 : 12,
                    left: 12,
                    right: isPhoneLandscape ? null : 12,
                    child: isPhoneLandscape
                        ? ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.min(360.0, viewportWidth * 0.48),
                            ),
                            child: _buildCompactTopBar(
                              isDark: isDark,
                              queryResult: queryResult,
                              unifiedSuggestions: unifiedSuggestions,
                              routePlannerContent: routePlannerWidget,
                            ),
                          )
                        : _buildCompactTopBar(
                            isDark: isDark,
                            queryResult: queryResult,
                            unifiedSuggestions: unifiedSuggestions,
                            routePlannerContent: routePlannerWidget,
                          ),
                  ),

                // Explicit user-driven spatial bounds refresh ("Search this area")
                if (kIsWeb &&
                    widget.isMapActive &&
                    _reportFilter.onlyInMapBounds &&
                    _hasUnsearchedMapMove)
                  Positioned(
                    top: isCompactWorkspace ? 74 : 16,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: ElevatedButton.icon(
                        onPressed: _searchThisAreaNow,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Search this area'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                        ),
                      ),
                    ),
                  ),

                // Standalone fallback top-right toggle (suppressed when WebAppShellHeader hosts Map)
                if (kIsWeb &&
                    widget.isMapActive &&
                    widget.showEmbeddedNavSwitcher)
                  Positioned(
                    top: 16,
                    right: isCompactViewport ? 12 : 20,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: viewportWidth - (isCompactViewport ? 24 : 40),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: _buildTopRightMapProfileToggle(
                          isMapActive: true,
                        ),
                      ),
                    ),
                  ),

                // 3. Natural Upper-Side Pothole Countdown Notification
                if (_showMarkers &&
                    (_upcomingHazard != null ||
                        _navHazardState != null ||
                        _showWarningBanner ||
                        (_destination != null &&
                            _alternativeRoutes.isNotEmpty)))
                  Positioned(
                    top:
                        (isPhoneLandscape && isCompactWorkspace)
                        ? 8
                        : ((_reportFilter.onlyInMapBounds &&
                                  _hasUnsearchedMapMove)
                              ? (isCompactWorkspace ? 122 : 66)
                              : (isCompactWorkspace ? 72 : 16)),
                    left: isCompactWorkspace
                        ? (isPhoneLandscape
                              ? (12 + math.min(360.0, viewportWidth * 0.48) + 10)
                              : 12)
                        : (_isSidePanelCollapsed ? 228 : 16),
                    right: isCompactWorkspace
                        ? 12
                        : (widget.showEmbeddedNavSwitcher ? 180 : 80),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: viewportWidth >= 720 && viewportWidth < 1080
                              ? 360
                              : 430,
                        ),
                        child: _buildWebPotholeWarningBanner(
                          isDark: isDark,
                          activePotholeCount: activePotholeCount,
                          nearestInfo: _nearestPotholeInfo,
                          nextPotholeEta: _nextPotholeEta,
                        ),
                      ),
                    ),
                  ),

                // 3b. Responsive <900px Bottom Route Planning Drawer
                if (kIsWeb &&
                    widget.isMapActive &&
                    isCompactWorkspace &&
                    _isRoutePlanningMode)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: _buildCompactRouteBottomDrawer(
                      isDark: isDark,
                      distStr: distStr,
                      totalEtaStr: totalEtaStr,
                      activePotholeCount: activePotholeCount,
                      routePlannerWidget: routePlannerWidget,
                    ),
                  ),

                // 5. Location Permission Warning (Only when permission denied)
                if (widget.isMapActive &&
                    !_isRoutePlanningMode &&
                    !_dismissedLocationBanner &&
                    (_isLocationDisabled || _isPermissionDenied))
                  Positioned(
                    top: isCompactWorkspace ? 76 : 16,
                    right: 16,
                    left: isCompactWorkspace ? 16 : null,
                    child: Align(
                      alignment: Alignment.topRight,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: _buildLocationPermissionCard(isDark),
                      ),
                    ),
                  ),
                if (_isPlacingMarker)
                  ..._buildManualPinPickerOverlays(
                    isDark: isDark,
                    isCompactWorkspace: isCompactWorkspace,
                  ),

                if (_isEditingDevLocation && _pendingDevLocation != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: _isSearchVisible
                        ? (_showWarningBanner ? 186 : 130)
                        : (_showWarningBanner ? 76 : 20),
                    child: SafeArea(
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                                      backgroundColor: const Color(0xFF2563EB),
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

                // Optional developer tools are hidden in the normal map.
                if (AppSettings.instance.devMockModeEnabled)
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
                          child: const Icon(Icons.science_rounded, size: 20),
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
                                color: const Color(
                                  0xFF2563EB,
                                ).withValues(alpha: 0.35),
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
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.25,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
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

                      // Unified Modern GIS Control Dock
                      if (AppSettings.instance.devMockModeEnabled) ...[
                        FloatingActionButton.small(
                          heroTag: 'developer_custom_markers',
                          tooltip: 'Custom markers (local)',
                          onPressed: _startMarkerPlacement,
                          child: const Icon(Icons.add_location_alt_outlined),
                        ),
                        const SizedBox(height: 12),
                      ],
                      _buildGisControlDock(isDark),
                    ],
                  ),
                ),

                // Point-to-Point Location Pill (Draggable anywhere on screen, eye-friendly design)
                if (_isP2pPillVisible && _p2pPoint != null)
                  _p2pPillOffset == null
                      ? Positioned(
                          left: 0,
                          right: 0,
                          bottom: 28,
                          child: SafeArea(
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: _buildPointToPointPill(isDark),
                              ),
                            ),
                          ),
                        )
                      : Positioned(
                          left: _p2pPillOffset!.dx,
                          top: _p2pPillOffset!.dy,
                          child: SafeArea(
                            child: _buildPointToPointPill(isDark),
                          ),
                        )
                else if (_tappedPoint != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 28,
                    child: SafeArea(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
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

                // Map key popover (defect shapes/colors & status explanation)
                if (_isLegendOpen)
                  Positioned(
                    right: 76,
                    bottom: 84,
                    child: SafeArea(
                      child: WebMapLegendCard(
                        onClose: () => setState(() => _isLegendOpen = false),
                      ),
                    ),
                  ),

                // Non-web fallback overlays only (web desktop uses docked left rail; <900px uses modal bottom sheets)
                if (!kIsWeb && _selectedPothole != null)
                  Positioned(
                    left: isCompactViewport ? 16 : 20,
                    right: isCompactViewport ? 16 : null,
                    bottom: 24,
                    child: SafeArea(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isCompactViewport
                              ? (viewportWidth - 32)
                              : 480.0,
                        ),
                        child: _buildSelectedPotholeCard(
                          _selectedPothole!,
                          isDark,
                        ),
                      ),
                    ),
                  ),
                if (!kIsWeb &&
                    _searchedPlace != null &&
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
              ],
            );

            return Scaffold(
              body: kIsWeb && !isCompactWorkspace
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!_isSidePanelCollapsed)
                          SizedBox(
                            width: sidePanelWidth,
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border(
                                  right: BorderSide(
                                    color: WebDesign.border(isDark),
                                  ),
                                ),
                              ),
                              child: _buildWorkspacePanelWidget(
                                isDark: isDark,
                                queryResult: queryResult,
                                unifiedSuggestions: unifiedSuggestions,
                                routePlannerContent: routePlannerWidget,
                              ),
                            ),
                          ),
                        Expanded(child: mapCanvasStack),
                      ],
                    )
                  : mapCanvasStack,
            );
          },
        );
      },
    );
  }

  Widget _buildTurnByTurnInPlanner({
    required bool isDark,
    required String distStr,
    required String durStr,
  }) {
    final Color cardBorder = AppDesign.border(isDark);
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);
    const Color brandBlue = Color(0xFF2563EB);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Subheader with Back Button and Steps Count
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            border: Border(bottom: BorderSide(color: cardBorder, width: 1)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                color: brandBlue,
                tooltip: 'Back to route overview',
                onPressed: () => setState(() => _showTurnByTurnSheet = false),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Turn-by-Turn Steps',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: textColor,
                      ),
                    ),
                    Text(
                      '${_routeSteps.length} maneuvers • $distStr ($durStr)',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: subtextColor,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.close_rounded, size: 18, color: subtextColor),
                tooltip: 'Close directions steps',
                onPressed: () => setState(() => _showTurnByTurnSheet = false),
              ),
            ],
          ),
        ),

        // Scrollable Step List
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                _animatedMapMove(step.location, 17.5, offsetForSidebar: true);
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
                      ? brandBlue.withValues(alpha: isDark ? 0.20 : 0.08)
                      : isCurrent
                      ? const Color(
                          0xFF10B981,
                        ).withValues(alpha: isDark ? 0.18 : 0.07)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: isSelected
                      ? const Border(
                          left: BorderSide(color: brandBlue, width: 3.5),
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
                    _buildManeuverIcon(step, isFirst, isLast, isDark),
                    const SizedBox(width: 12),
                    Expanded(child: _buildStepText(step, isDark)),
                    const SizedBox(width: 10),
                    if (!isLast)
                      _formatStepDistanceWidget(step.distanceMeters, isDark),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildCompactRouteBottomDrawer({
    required bool isDark,
    required String distStr,
    required String totalEtaStr,
    required int activePotholeCount,
    required Widget routePlannerWidget,
  }) {
    final Color surface = WebDesign.surface(isDark);
    final Color border = WebDesign.border(isDark);
    final String headline = _routePoints.isEmpty
        ? 'Plan route'
        : '${distStr.isNotEmpty ? distStr : '0 m'} · ${totalEtaStr.isNotEmpty ? totalEtaStr : '-- min'} · '
              '${activePotholeCount == 0 ? 'No reported potholes' : '$activePotholeCount reported pothole${activePotholeCount == 1 ? '' : 's'}'}';

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          setState(() {
            if (_suggestions.isNotEmpty) {
              _suggestions = [];
            } else if (_isCompactRouteDrawerExpanded) {
              _isCompactRouteDrawerExpanded = false;
            } else {
              _isRoutePlanningMode = false;
            }
          });
        },
      },
      child: Material(
        color: surface,
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        child: Builder(
          builder: (context) {
            final size = MediaQuery.sizeOf(context);
            final bool isPhoneLandscape =
                size.width > size.height && size.height < 560;
            return Align(
              alignment: Alignment.bottomLeft,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: border),
                ),
                constraints: BoxConstraints(
                  maxWidth: isPhoneLandscape
                      ? math.min(360.0, size.width * 0.48)
                      : double.infinity,
                  maxHeight: isPhoneLandscape
                      ? (_isCompactRouteDrawerExpanded
                            ? (size.height * 0.46).clamp(140.0, 220.0)
                            : 52.0)
                      : (_isCompactRouteDrawerExpanded
                            ? (size.height * 0.58).clamp(240.0, 520.0)
                            : 64.0),
                ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () => setState(
                  () => _isCompactRouteDrawerExpanded =
                      !_isCompactRouteDrawerExpanded,
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.directions_rounded,
                          size: 18,
                          color: WebDesign.brand(isDark),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppDesign.textPrimary(isDark),
                            ),
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: _isCompactRouteDrawerExpanded
                              ? 'Collapse route sheet'
                              : 'Expand route sheet',
                          child: Icon(
                            _isCompactRouteDrawerExpanded
                                ? Icons.keyboard_arrow_down_rounded
                                : Icons.keyboard_arrow_up_rounded,
                            color: AppDesign.textSecondary(isDark),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_isCompactRouteDrawerExpanded)
                Expanded(child: routePlannerWidget),
            ],
          ),
        ),
            );
          },
        ),
      ),
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

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          setState(() {
            if (_suggestions.isNotEmpty) {
              _suggestions = [];
            } else {
              _isRoutePlanningMode = false;
              _showTurnByTurnSheet = false;
              _isEditingOrigin = false;
            }
          });
        },
      },
      child: Container(
        constraints: BoxConstraints(
          maxHeight: (MediaQuery.sizeOf(context).height - 48).clamp(
            360.0,
            780.0,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Top Travel Mode Row ──
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: brandBlue,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.directions_rounded,
                      color: Colors.white,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 8),
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
                  IconButton(
                    icon: Icon(
                      Icons.chevron_left_rounded,
                      color: subtextColor,
                      size: 22,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    tooltip: 'Collapse directions panel',
                    onPressed: () {
                      setState(() {
                        _isSidePanelCollapsed = true;
                      });
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      color: subtextColor,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    tooltip: 'Close directions',
                    onPressed: () {
                      setState(() {
                        _isRoutePlanningMode = false;
                        _showTurnByTurnSheet = false;
                        _suggestions = [];
                        _isEditingOrigin = false;
                      });
                    },
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: cardBorder),

            // ── Origin & Destination Inputs with Swap & "Use current location" ──
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
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
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Starting Point Input
                            Container(
                              constraints: const BoxConstraints(minHeight: 40),
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: _isEditingOrigin
                                      ? brandBlue
                                      : (isDark
                                            ? const Color(0xFF475569)
                                            : const Color(0xFFCBD5E1)),
                                  width: _isEditingOrigin ? 1.8 : 1.2,
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
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
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 8,
                                            ),
                                      ),
                                      onTap: () => setState(
                                        () => _isEditingOrigin = true,
                                      ),
                                      onChanged: (val) {
                                        setState(() => _isEditingOrigin = true);
                                        _originTextDirty = true;
                                        _onSearchChanged(val);
                                      },
                                      onSubmitted: (_) {
                                        if (_originController.text.isNotEmpty) {
                                          if (_searchController
                                              .text
                                              .isNotEmpty) {
                                            _searchAndRoute();
                                          } else {
                                            _destinationFocusNode
                                                .requestFocus();
                                          }
                                        }
                                      },
                                    ),
                                  ),
                                  if (_originController.text.isNotEmpty)
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      icon: Icon(
                                        Icons.clear_rounded,
                                        size: 15,
                                        color: subtextColor,
                                      ),
                                      tooltip: 'Clear starting point',
                                      onPressed: () {
                                        _stopRouteSimulation();
                                        setState(() {
                                          _originController.clear();
                                          _customOrigin = null;
                                          _originTextDirty = false;
                                          _suggestions = [];
                                          _resetRoutePlannerState(
                                            clearDestination: false,
                                          );
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
                              constraints: const BoxConstraints(minHeight: 40),
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: !_isEditingOrigin
                                      ? brandBlue
                                      : (isDark
                                            ? const Color(0xFF475569)
                                            : const Color(0xFFCBD5E1)),
                                  width: !_isEditingOrigin ? 1.8 : 1.2,
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
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
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 8,
                                            ),
                                      ),
                                      onTap: () => setState(
                                        () => _isEditingOrigin = false,
                                      ),
                                      onChanged: (val) {
                                        setState(
                                          () => _isEditingOrigin = false,
                                        );
                                        _destinationTextDirty = true;
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
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      icon: Icon(
                                        Icons.clear_rounded,
                                        size: 15,
                                        color: subtextColor,
                                      ),
                                      tooltip: 'Clear destination',
                                      onPressed: () {
                                        _stopRouteSimulation();
                                        setState(() {
                                          _searchRevision++;
                                          _debounceTimer?.cancel();
                                          _searchController.clear();
                                          _destinationTextDirty = false;
                                          _suggestions = [];
                                          _resetRoutePlannerState();
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
                          child: const Icon(
                            Icons.swap_vert_rounded,
                            color: brandBlue,
                            size: 20,
                          ),
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                        tooltip: 'Reverse starting point and destination',
                        onPressed: _swapOriginDestination,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Semantics(
                      button: true,
                      label: 'Use current location as starting point',
                      child: TextButton.icon(
                        onPressed: () =>
                            unawaited(_useCurrentLocationForOrigin()),
                        icon: const Icon(Icons.my_location_rounded, size: 16),
                        label: const Text('Use current location'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 38),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          foregroundColor: brandBlue,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            if (_isRouting) ...[
              const LinearProgressIndicator(minHeight: 2),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Text(
                  'Finding road routes and checking reported potholes...',
                  style: TextStyle(fontSize: 12, color: subtextColor),
                ),
              ),
            ],

            if (_isPermissionDenied || _isLocationDisabled)
              Container(
                margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.location_off_rounded,
                      size: 16,
                      color: Color(0xFFB45309),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isPermissionDenied
                            ? 'Location permission is blocked. Enter a starting point or tap the map.'
                            : 'GPS is off. Enter a starting point or enable location.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark
                              ? const Color(0xFFFDE68A)
                              : const Color(0xFF92400E),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            if (_routeErrorMessage != null)
              Container(
                margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 16,
                      color: Color(0xFFB91C1C),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _routeErrorMessage!,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark
                              ? const Color(0xFFFCA5A5)
                              : const Color(0xFF991B1B),
                        ),
                      ),
                    ),
                    if (_destination != null)
                      TextButton(
                        onPressed: () =>
                            unawaited(_calculateRoute(_destination!)),
                        child: const Text('Retry'),
                      ),
                  ],
                ),
              ),

            Divider(height: 1, thickness: 1, color: cardBorder),

            // ── Scrollable Body: Route Summary OR Suggestions OR History & Presets OR Turn-by-Turn Steps ──
            Flexible(
              child: SingleChildScrollView(
                child: _suggestions.isNotEmpty
                    ? _buildSuggestionsListInPlanner(isDark)
                    : (_routePoints.isNotEmpty
                          ? (_showTurnByTurnSheet && _routeSteps.isNotEmpty
                                ? _buildTurnByTurnInPlanner(
                                    isDark: isDark,
                                    distStr: distStr,
                                    durStr: totalEtaStr,
                                  )
                                : _buildRouteSummaryInPlanner(
                                    isDark: isDark,
                                    isClearAhead: isClearAhead,
                                    distStr: distStr,
                                    totalEtaStr: totalEtaStr,
                                    activePotholeCount: activePotholeCount,
                                  ))
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_destination == null)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      12,
                                      14,
                                      4,
                                    ),
                                    child: Text(
                                      'Enter a destination or tap the map to view route pothole counts.',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: subtextColor,
                                      ),
                                    ),
                                  ),
                                _buildHistoryAndPresetsInPlanner(isDark),
                              ],
                            )),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _applyMapState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  @visibleForTesting
  Future<void> debugApplyRoutesForTest({
    required List<List<LatLng>> routes,
    required List<double> durations,
    required List<double> distances,
    required LatLng destination,
    List<List<RouteStep>>? stepsByRoute,
    LatLng? customOrigin,
    String? originLabel,
    String? destinationLabel,
    bool showP2pPill = false,
  }) async {
    _customOrigin = customOrigin;
    if (originLabel != null) {
      _originController.text = originLabel;
    }
    _destination = destination;
    if (destinationLabel != null) {
      _searchController.text = destinationLabel;
    }
    _isRoutePlanningMode = true;
    _isP2pPillVisible = showP2pPill;
    if (showP2pPill) {
      _p2pName = destinationLabel ?? 'Destination';
    }
    await _processRoutes(
      routes,
      durations,
      distances,
      destination,
      stepsByRoute: stepsByRoute,
      fitCamera: false,
    );
  }

  @visibleForTesting
  RouteComparisonResult? get debugRouteComparison => _routeComparison;

  @visibleForTesting
  RouteHazardSummary? get debugActiveRouteSummary => _currentActiveRouteSummary;

  @visibleForTesting
  int get debugP2pHazardCount => _p2pHazardCount;
}
