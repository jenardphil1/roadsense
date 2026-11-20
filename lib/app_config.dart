import 'package:flutter/foundation.dart';

/// Available sync backends for distress reports
enum SyncBackendType { firestore, supabase, fastApi }

/// Available base map tile providers
class TileProviderConfig {
  final String id;
  final String name;
  final String urlTemplate;
  final List<String> subdomains;
  final int maxZoom;
  final String attribution;

  const TileProviderConfig({
    required this.id,
    required this.name,
    required this.urlTemplate,
    this.subdomains = const ['a', 'b', 'c'],
    this.maxZoom = 19,
    this.attribution = '© OpenStreetMap contributors',
  });
}

/// Central application configuration honoring zero-budget & OSM/Nominatim policy constraints:
/// - Runtime switchable tile providers (no hard-coded tile URLs)
/// - Exact User-Agent compliance for OSM tile & geocoder calls
/// - Geocoding proxy endpoints (no direct device-to-Nominatim violation)
/// - Single sync backend selector (Firestore as determined by audit)
class AppConfig extends ChangeNotifier {
  static final AppConfig instance = AppConfig._();
  AppConfig._();

  // ── Identifiers & Headers ───────────────────────────────────────────────
  static const String appName = 'RoadSense DPWH';
  static const String appVersion = '1.0.0';
  static const String userAgent =
      'RoadSense-DPWH/1.0 (contact: thesis-audit@roadsense.local)';

  // ── Tile Providers ──────────────────────────────────────────────────────
  static const TileProviderConfig osmStandard = TileProviderConfig(
    id: 'osm_standard',
    name: 'OpenStreetMap Standard',
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    subdomains: [],
    maxZoom: 19,
    attribution: '© OpenStreetMap contributors',
  );

  static const TileProviderConfig cartoPositron = TileProviderConfig(
    id: 'carto_positron',
    name: 'CartoDB Positron',
    urlTemplate: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
    subdomains: ['a', 'b', 'c', 'd'],
    maxZoom: 20,
    attribution: '© OpenStreetMap contributors, © CARTO',
  );

  static const TileProviderConfig osmHot = TileProviderConfig(
    id: 'osm_hot',
    name: 'Humanitarian OSM',
    urlTemplate: 'https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
    subdomains: ['a', 'b'],
    maxZoom: 19,
    attribution:
        '© OpenStreetMap contributors, Tiles courtesy of Humanitarian OSM Team',
  );

  static const List<TileProviderConfig> availableTileProviders = [
    osmStandard,
    cartoPositron,
    osmHot,
  ];

  TileProviderConfig _activeTileProvider = osmStandard;
  TileProviderConfig get activeTileProvider => _activeTileProvider;

  void setActiveTileProvider(TileProviderConfig provider) {
    if (_activeTileProvider.id != provider.id) {
      _activeTileProvider = provider;
      notifyListeners();
    }
  }

  // ── Legal & Policy URLs ─────────────────────────────────────────────────
  static const String osmAttributionText = '© OpenStreetMap contributors';
  static const String osmCopyrightUrl =
      'https://www.openstreetmap.org/copyright';
  static const String osmReportIssueUrl =
      'https://www.openstreetmap.org/fixthemap';

  // ── Backend & Proxy Configuration ───────────────────────────────────────
  // Default points to backend proxy for Nominatim/Photon and Web YOLOv8 inference.
  String _backendBaseUrl = const String.fromEnvironment(
    'BACKEND_PROXY_URL',
    defaultValue: 'http://localhost:8000',
  );
  String get backendBaseUrl => _backendBaseUrl;

  set backendBaseUrl(String url) {
    if (_backendBaseUrl != url) {
      _backendBaseUrl = url.replaceAll(RegExp(r'/+$'), '');
      notifyListeners();
    }
  }

  /// Geocoder proxy URL (Submit-triggered only; rate capped at ≤1 req/s)
  String get geocodeProxyUrl => '$_backendBaseUrl/api/geocode';

  /// Suggestion search proxy URL (Photon proxy; debounced ≥ 400 ms)
  String get photonProxyUrl => '$_backendBaseUrl/api/photon';

  /// Web inference endpoint (FastAPI + YOLOv8; Android runs tflite in background isolate)
  String get webInferenceUrl => '$_backendBaseUrl/api/inference';

  // ── Sync Backend Selector ───────────────────────────────────────────────
  SyncBackendType _syncBackend = SyncBackendType.firestore;
  SyncBackendType get syncBackend => _syncBackend;

  void setSyncBackend(SyncBackendType backend) {
    if (_syncBackend != backend) {
      _syncBackend = backend;
      notifyListeners();
    }
  }

  // ── Performance & Policy Thresholds ─────────────────────────────────────
  /// Maximum records or payload size per batch sync
  static const int syncBatchMaxRecords = 10;
  static const int syncBatchMaxBytes = 5 * 1024 * 1024; // 5 MB

  /// Viewport query limit for map rendering
  static const int viewportQueryLimit = 500;

  /// Clustering threshold: Cluster markers below this zoom level
  static const double clusterMaxZoom = 15.0;

  /// Geolocation accuracy thresholds (meters)
  static const double gpsGoodAccuracyThresholdM = 8.0;
  static const double gpsAcceptableAccuracyThresholdM = 20.0;
}
