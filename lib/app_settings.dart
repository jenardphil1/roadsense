import 'package:flutter/material.dart';

class AppSettings {
  static final AppSettings instance = AppSettings._();
  AppSettings._();

  /// Shared Theme Mode Notifier (ThemeMode.system, ThemeMode.dark, or ThemeMode.light)
  final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.system);

  /// Shared Pothole Marker Layer Visibility Notifier
  final ValueNotifier<bool> showPotholesNotifier = ValueNotifier<bool>(true);

  /// Admin Experimental: Manual Pothole Placement Notifier
  final ValueNotifier<bool> manualPotholePlacementNotifier = ValueNotifier<bool>(false);

  /// Developer Mode: Edit Current GPS Location Notifier
  final ValueNotifier<bool> devEditLocationNotifier = ValueNotifier<bool>(false);

  /// Developer & Simulation Tools Master Mode Notifier
  final ValueNotifier<bool> devMockModeNotifier = ValueNotifier<bool>(false);

  /// High-Contrast Black & White (Monochrome) Display Notifier
  final ValueNotifier<bool> highContrastMonochromeNotifier = ValueNotifier<bool>(false);

  /// Active Navigation Route State Notifier
  final ValueNotifier<bool> isRouteActiveNotifier = ValueNotifier<bool>(false);

  bool get isBlackAndWhite => highContrastMonochromeNotifier.value;

  bool get isDarkMode {
    if (themeModeNotifier.value == ThemeMode.system) {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    }
    return themeModeNotifier.value == ThemeMode.dark;
  }
  bool get showPotholes => showPotholesNotifier.value;
  bool get devMockModeEnabled => devMockModeNotifier.value;
  bool get isRouteActive => isRouteActiveNotifier.value;

  void setRouteActive(bool active) {
    if (isRouteActiveNotifier.value != active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isRouteActiveNotifier.value != active) {
          isRouteActiveNotifier.value = active;
        }
      });
    }
  }

  void toggleTheme(bool isDark) {
    themeModeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;
  }

  void toggleHighContrastMonochrome(bool enabled) {
    highContrastMonochromeNotifier.value = enabled;
  }

  void toggleShowPotholes(bool show) {
    showPotholesNotifier.value = show;
  }

  void toggleDevMockMode(bool enabled) {
    devMockModeNotifier.value = enabled;
    mobileDevMockLocationEnabled = enabled;
  }

  void toggleManualPotholePlacement(bool enabled) {
    manualPotholePlacementNotifier.value = enabled;
  }

  void toggleDevEditLocation(bool enabled) {
    devEditLocationNotifier.value = enabled;
  }

  // ── Web Platform Settings ──────────────────────────────────────────────
  final ValueNotifier<String> webMapStyleNotifier = ValueNotifier<String>('Google Maps');
  String get webMapStyle => webMapStyleNotifier.value;
  set webMapStyle(String value) => webMapStyleNotifier.value = value;
  double webConfidenceFilter = 0.20;
  bool webLiveSyncEnabled = true;
  String webExportFormat = 'GeoJSON'; // 'GeoJSON', 'CSV', 'PDF'
  bool webClusterMarkers = true;

  void resetWebSettingsToDefaults() {
    themeModeNotifier.value = ThemeMode.system;
    webMapStyleNotifier.value = 'Google Maps';
    webConfidenceFilter = 0.20;
    webLiveSyncEnabled = true;
    webExportFormat = 'GeoJSON';
    webClusterMarkers = true;
    showPotholesNotifier.value = true;
  }

  // ── Mobile Platform Settings ───────────────────────────────────────────
  double mobileAiConfidenceThreshold = 0.20;
  double mobileProximityDistanceMeters = 22.0;
  bool mobileVoiceAlertsEnabled = true;
  bool mobileHighAccuracyGps = true;
  bool mobileDevMockLocationEnabled = false;
  String mobileGpsAccuracyMode = 'High Accuracy'; // 'High Accuracy', 'Balanced'
}
