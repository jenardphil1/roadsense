import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vision/flutter_vision.dart';
import 'package:camera/camera.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'map_screen.dart';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_setup.dart';
import 'cloud_service.dart';
import 'road_report_cache.dart';
import 'verified_auth_gate.dart';
import 'admin_dashboard_screen.dart';
import 'profile_screen.dart';
import 'app_settings.dart';
import 'app_design.dart';
import 'dpwh_standards.dart';
import 'mobile_components.dart';
import 'mobile_tour.dart';
import 'model_detections.dart';
import 'live_detection_snapshot.dart';
import 'scan_frame_crop.dart';
import 'onboarding_screen.dart';
import 'pending_report_queue.dart';
import 'upload_error.dart';
import 'email_verification_view.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initializeFirebase();
  } catch (e) {
    print('Firebase initialization error: $e');
  }
  cameras = [];
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'RoadSense AI',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: AppDesign.buildTheme(isDark: false),
          darkTheme: AppDesign.buildTheme(isDark: true),
          home: const AppRoot(),
        );
      },
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  bool? _hasSeenOnboarding;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    if (kIsWeb) {
      if (mounted) setState(() => _hasSeenOnboarding = true);
      return;
    }
    final seen = await checkHasSeenOnboarding();
    if (mounted) {
      setState(() => _hasSeenOnboarding = seen);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasSeenOnboarding == null) {
      return Scaffold(
        backgroundColor: AppDesign.bg(AppSettings.instance.isDarkMode),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (!_hasSeenOnboarding!) {
      return OnboardingScreen(
        onComplete: () {
          if (mounted) setState(() => _hasSeenOnboarding = true);
        },
      );
    }

    return VerifiedAuthGate(
      authenticatedBuilder: (uid) {
        return FutureBuilder<String>(
          future: CloudService.instance.getUserRole(uid),
          builder: (context, roleSnapshot) {
            if (roleSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            final role = roleSnapshot.data ?? 'user';
            if (kIsWeb && (role == 'admin' || role == 'super_admin')) {
              return const AdminDashboardScreen();
            }
            return const MyHomePage(title: 'RoadSense AI');
          },
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {

  bool _isModelLoaded = false;
  FlutterVision? vision;

  CameraController? _cameraController;
  Size? _liveCameraViewSize;
  double? _livePreviewAspectRatio;
  bool _isDetecting = false;
  bool _isCapturingScan = false;
  final _liveBuffer = LiveDetectionBuffer();
  Timer? _liveExpiry;
  bool _scannerStarting = false;
  bool _cameraForeground = true;
  bool _cameraRecoveryAttempted = false;
  Future<void>? _cameraDisposal;
  Future<void>? _modelLoading;
  int _scanEpoch = 0;
  Timer? _detectionTimer;

  // State Management
  final GlobalKey<MapScreenState> _mapScreenKey = GlobalKey<MapScreenState>();
  bool _isRealtimeMode = false;
  bool _isSideOfRoadView = true;
  int _currentIndex = 0;

  bool _shouldSwapCrackOrientation() => _isSideOfRoadView;

  // Guided spotlight tour controller and real widget anchors
  final Map<String, GlobalKey> _reportGuideTargets = {
    'search': GlobalKey(),
    'status': GlobalKey(),
    'active': GlobalKey(),
    'trash': GlobalKey(),
  };
  final Map<String, GlobalKey> _profileGuideTargets = {
    'details': GlobalKey(),
    'settings': GlobalKey(),
    'help': GlobalKey(),
    'signout': GlobalKey(),
  };
  final MobileTourController _tourController = MobileTourController();
  final GlobalKey _tourMapSearchKey = GlobalKey();
  final GlobalKey _tourMapFiltersKey = GlobalKey();
  final GlobalKey _tourNavScanKey = GlobalKey();
  final GlobalKey _tourNavReportsKey = GlobalKey();
  final GlobalKey _tourNavProfileKey = GlobalKey();
  final GlobalKey _tourScannerStartKey = GlobalKey();
  final GlobalKey _tourScannerCloseKey = GlobalKey();
  final GlobalKey _tourScannerCaptureKey = GlobalKey();
  final GlobalKey _tourScannerPerspectiveKey = GlobalKey();
  final GlobalKey _tourReviewSummaryKey = GlobalKey();
  final GlobalKey _tourReviewRetakeKey = GlobalKey();
  final GlobalKey _tourReviewSubmitKey = GlobalKey();
  bool _isStartingCamera = false;
  String? _cameraError;
  bool _isOffline = false;
  StreamSubscription<dynamic>? _connectivitySubscription;
  List<PotholeMarker> _detectedPotholes = [];
  bool _isSending = false;
  bool _isAnalyzingPhoto = false;
  String? _photoDetectionError;
  final FlutterTts _flutterTts = FlutterTts();

  // Realtime state
  final ValueNotifier<List<Map<String, dynamic>>?> _cameraRecognitionsNotifier =
      ValueNotifier(null);

  // Static image state
  File? _staticImage;
  List<Map<String, dynamic>>? _staticRecognitions;
  final TextEditingController _reportNoteController = TextEditingController();
  int _staticImageHeight = 0;
  int _staticImageWidth = 0;
  late final Future<PendingReportQueue> _pendingReports;
  PendingReportQueue? _resolvedPendingQueue;
  Timer? _pendingUploadTimer;
  StreamSubscription<QuerySnapshot>? _potholeSubscription;
  StreamSubscription<QuerySnapshot>? _userPotholeSubscription;
  DateTime? _reportsLastUpdatedAt;
  bool _isUsingCachedData = false;
  int _loadPotholesSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pendingReports = getApplicationDocumentsDirectory().then((directory) {
      final queue = PendingReportQueue(
        Directory(p.join(directory.path, 'pending_reports')),
      );
      if (mounted) {
        setState(() => _resolvedPendingQueue = queue);
      }
      return queue;
    });
    _retryPendingReports();
    _pendingUploadTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _retryPendingReports(),
    );
    if (!kIsWeb) {
      vision = FlutterVision();
      _initTTS();
      _connectivitySubscription = watchSafeOfflineState((offline) {
        final wasOffline = _isOffline;
        if (mounted && _isOffline != offline) {
          setState(() => _isOffline = offline);
        }
        if (wasOffline && !offline) {
          _retryPendingReports();
        }
      });
      _tourController.load().then((_) {
        if (mounted) _maybeStartCurrentPageTour();
      });
    }
    _loadPotholesFromDB();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cameraForeground = true;
      _retryPendingReports();
      if (!kIsWeb && _currentIndex == 1 && !_isModelLoaded) {
        unawaited(_loadModel());
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cameraForeground = false;
      if (_isRealtimeMode || _scannerStarting || _cameraController != null) {
        unawaited(_stopRealtime());
      }
      if ((state == AppLifecycleState.paused ||
              state == AppLifecycleState.detached) &&
          _isModelLoaded &&
          !_isAnalyzingPhoto) {
        _isModelLoaded = false;
        unawaited(vision?.closeYoloModel() ?? Future<void>.value());
      }
    }
  }

  Future<void> _initTTS() async {
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setPitch(1.0);
    await _flutterTts.setSpeechRate(0.5);
  }

  PotholeMarker? _parseFirestoreReportDoc(
    QueryDocumentSnapshot doc, {
    required bool approvedOnly,
    String? currentUid,
    String? currentEmail,
  }) {
    try {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) return null;
      final latNum = data['latitude'];
      final lngNum = data['longitude'];
      if (latNum == null || lngNum == null) return null;
      final lat = (latNum is num)
          ? latNum.toDouble()
          : double.tryParse(latNum.toString());
      final lng = (lngNum is num)
          ? lngNum.toDouble()
          : double.tryParse(lngNum.toString());
      if (lat == null || lng == null) return null;

      final imageUrl = data['imageUrl'] as String? ?? '';
      final status = (data['status'] as String? ?? 'pending')
          .toLowerCase()
          .trim();
      final bool isResolved =
          data['isResolved'] == true ||
          status == 'resolved' ||
          status == 'fixed' ||
          status == 'closed';
      final bool isAccessible =
          data['isAccessible'] != false && data['accessible'] != false;
      if (status == 'deleted' ||
          status == 'rejected' ||
          isResolved ||
          !isAccessible) {
        return null;
      }

      final reporterEmail = (data['reporterEmail'] as String? ?? '').trim();
      final reporterUid = (data['reporterUid'] as String? ?? '').trim();
      if (approvedOnly) {
        if (status != 'approved') return null;
      } else if (status != 'approved') {
        final isMyUid =
            currentUid != null &&
            currentUid.isNotEmpty &&
            reporterUid == currentUid;
        final isMyEmail =
            currentEmail != null &&
            currentEmail.isNotEmpty &&
            reporterEmail.toLowerCase() == currentEmail.toLowerCase().trim();
        if (!isMyUid && !isMyEmail) return null;
      }

      final overallSeverity = (data['overallSeverity'] as String? ?? 'medium')
          .toLowerCase()
          .trim();
      final potholeCount = (data['potholeCount'] as num?)?.toInt() ?? 1;

      DateTime timestamp = DateTime.now();
      final rawTimestamp = data['timestamp'];
      if (rawTimestamp is Timestamp) {
        timestamp = rawTimestamp.toDate();
      } else if (rawTimestamp is int) {
        timestamp = DateTime.fromMillisecondsSinceEpoch(rawTimestamp);
      }

      final dpwhCode = data['primaryDpwhCode'] as String? ?? 'CODE 01';
      final defectName = DpwhStandards.reportDefectName(data);
      final responseTime = data['responseTime'] as String? ?? 'High Priority';
      final correctiveMeasure =
          data['correctiveMeasure'] as String? ??
          'Bituminous premix (hot) or penetration patching; add base material if needed.';
      final brgy = data['barangay'] as String? ?? '';
      final city = data['city'] as String? ?? '';
      final province = data['province'] as String? ?? '';
      final formatted = data['formattedAddress'] as String? ?? '';
      final String? canonicalDefectId =
          (data['canonicalDefectId'] as String?)?.trim().isNotEmpty == true
          ? (data['canonicalDefectId'] as String).trim()
          : ((data['defectClusterId'] as String?)?.trim().isNotEmpty == true
                ? (data['defectClusterId'] as String).trim()
                : null);
      final String? roadName =
          (data['roadName'] as String?)?.trim().isNotEmpty == true
          ? (data['roadName'] as String).trim()
          : ((data['streetName'] as String?)?.trim().isNotEmpty == true
                ? (data['streetName'] as String).trim()
                : null);

      List<Map<String, dynamic>>? parsedDetections;
      final dynamic rawDetections = data['detections'];
      if (rawDetections is List && rawDetections.isNotEmpty) {
        final list = <Map<String, dynamic>>[];
        for (final item in rawDetections) {
          if (item is Map) {
            list.add(Map<String, dynamic>.from(item));
          }
        }
        if (list.isNotEmpty) {
          parsedDetections = list;
        }
      } else if (data['defectClasses'] is List) {
        final list = (data['defectClasses'] as List)
            .whereType<String>()
            .where((s) => s.trim().isNotEmpty)
            .map((s) => <String, dynamic>{'className': s.trim()})
            .toList(growable: false);
        if (list.isNotEmpty) {
          parsedDetections = list;
        }
      }
      final double? roadBearingDeg =
          (data['roadBearingDeg'] as num?)?.toDouble() ??
          (data['bearingDeg'] as num?)?.toDouble() ??
          (data['headingDeg'] as num?)?.toDouble();
      final bool roadMatched = data['roadMatched'] == true;

      return PotholeMarker(
        docId: doc.id,
        location: LatLng(lat, lng),
        imagePath: imageUrl,
        timestamp: timestamp,
        status: status,
        overallSeverity: overallSeverity,
        potholeCount: potholeCount,
        reporterEmail: reporterEmail,
        reporterUid: reporterUid,
        primaryDpwhCode: dpwhCode,
        primaryDefect: defectName,
        responseTime: responseTime,
        correctiveMeasure: correctiveMeasure,
        detections: parsedDetections,
        barangay: brgy,
        city: city,
        province: province,
        formattedAddress: formatted,
        isResolved: isResolved,
        canonicalDefectId: canonicalDefectId,
        roadName: roadName,
        isAccessible: isAccessible,
        roadBearingDeg: roadBearingDeg,
        roadMatched: roadMatched,
      );
    } catch (docErr) {
      debugPrint('Skipping malformed pothole doc ${doc.id}: $docErr');
      return null;
    }
  }

  List<String> _extractCachedDefectClasses(
    List<Map<String, dynamic>>? detections,
    String fallbackPrimaryDefect,
  ) => DpwhStandards.extractCachedDefectClasses(
    detections,
    fallbackPrimaryDefect,
  );

  Future<List<PotholeMarker>> _fetchApprovedReportsInCorridor({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) async {
    try {
      final user = CloudService.instance.currentUser;
      final docs = await CloudService.instance.fetchApprovedReportsInCorridor(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
      );
      final markers = <PotholeMarker>[];
      for (final doc in docs) {
        final marker = _parseFirestoreReportDoc(
          doc,
          approvedOnly: true,
          currentUid: user?.uid,
          currentEmail: user?.email,
        );
        if (marker != null) {
          markers.add(marker);
        }
      }
      return markers;
    } catch (_) {
      return const <PotholeMarker>[];
    }
  }

  void _loadPotholesFromDB() {
    try {
      final int seq = ++_loadPotholesSeq;
      _potholeSubscription?.cancel();
      _userPotholeSubscription?.cancel();

      // Restore cached approved reports right away while network streams initialize.
      unawaited(() async {
        final cached = await RoadReportCache.loadApprovedReports();
        if (!mounted ||
            seq != _loadPotholesSeq ||
            cached == null ||
            _detectedPotholes.isNotEmpty) {
          return;
        }
        final restored = cached.records
            .where((r) => !r.isResolved)
            .map(
              (r) => PotholeMarker(
                docId: r.docId,
                location: LatLng(r.latitude, r.longitude),
                imagePath: '',
                timestamp: DateTime.fromMillisecondsSinceEpoch(r.updatedAtMs),
                status: r.status,
                potholeCount: r.potholeCount,
                primaryDpwhCode: r.primaryDpwhCode,
                primaryDefect: r.primaryDefect,
                barangay: r.barangay,
                city: r.city,
                province: r.province,
                formattedAddress: r.formattedAddress,
                isResolved: r.isResolved,
                canonicalDefectId: r.canonicalDefectId,
                roadName: r.roadName,
                detections: r.defectClasses.isNotEmpty
                    ? r.defectClasses
                          .map((c) => <String, dynamic>{'className': c})
                          .toList(growable: false)
                    : null,
                roadBearingDeg: r.roadBearingDeg,
                roadMatched: r.roadMatched,
              ),
            )
            .toList(growable: false);
        if (restored.isEmpty || !mounted || seq != _loadPotholesSeq) return;
        setState(() {
          _detectedPotholes = restored;
          _reportsLastUpdatedAt = cached.savedAt;
          _isUsingCachedData = true;
        });
      }());

      final currentUser = CloudService.instance.currentUser;
      final Map<String, PotholeMarker> approvedById = {};
      final Map<String, PotholeMarker> userOwnedById = {};

      void publishMerged({required bool fromApprovedStream}) {
        if (!mounted || seq != _loadPotholesSeq) return;
        final merged = <String, PotholeMarker>{
          ...userOwnedById,
          ...approvedById,
        };
        setState(() {
          _detectedPotholes = merged.values.toList(growable: false);
          if (fromApprovedStream) {
            _reportsLastUpdatedAt = DateTime.now();
            _isUsingCachedData = false;
          }
        });
      }

      _potholeSubscription = CloudService.instance
          .streamApprovedPotholes()
          .listen(
            (snapshot) {
              approvedById.clear();
              final cacheRecords = <CachedReportRecord>[];
              for (final doc in snapshot.docs) {
                final marker = _parseFirestoreReportDoc(
                  doc,
                  approvedOnly: true,
                  currentUid: currentUser?.uid,
                  currentEmail: currentUser?.email,
                );
                if (marker == null || marker.docId == null) continue;
                approvedById[marker.docId!] = marker;
                cacheRecords.add(
                  CachedReportRecord(
                    docId: marker.docId!,
                    canonicalDefectId: marker.canonicalDefectId,
                    latitude: marker.location.latitude,
                    longitude: marker.location.longitude,
                    primaryDefect: marker.primaryDefect,
                    primaryDpwhCode: marker.primaryDpwhCode,
                    status: marker.status,
                    isResolved: marker.isResolved,
                    potholeCount: marker.potholeCount,
                    barangay: marker.barangay,
                    city: marker.city,
                    province: marker.province,
                    formattedAddress: marker.formattedAddress,
                    roadName: marker.roadName,
                    updatedAtMs: marker.timestamp.millisecondsSinceEpoch,
                    defectClasses: _extractCachedDefectClasses(
                      marker.detections,
                      marker.primaryDefect,
                    ),
                    roadBearingDeg: marker.roadBearingDeg,
                    roadMatched: marker.roadMatched,
                  ),
                );
              }
              publishMerged(fromApprovedStream: true);
              unawaited(RoadReportCache.saveApprovedReports(cacheRecords));
            },
            onError: (e) {
              debugPrint("Error in streamApprovedPotholes: $e");
            },
          );

      if (currentUser != null) {
        _userPotholeSubscription = CloudService.instance
            .streamUserPotholes(currentUser.uid)
            .listen(
              (snapshot) {
                userOwnedById.clear();
                for (final doc in snapshot.docs) {
                  final marker = _parseFirestoreReportDoc(
                    doc,
                    approvedOnly: false,
                    currentUid: currentUser.uid,
                    currentEmail: currentUser.email,
                  );
                  if (marker == null || marker.docId == null) continue;
                  userOwnedById[marker.docId!] = marker;
                }
                publishMerged(fromApprovedStream: false);
              },
              onError: (e) {
                debugPrint("Error in streamUserPotholes: $e");
              },
            );
      }
    } catch (e) {
      debugPrint("Error loading Firebase potholes: $e");
    }
  }

  Future<void> _deleteDetectedPothole(PotholeMarker pothole) async {
    try {
      if (pothole.docId != null) {
        await CloudService.instance.deletePothole(pothole.docId!);
      } else {
        throw Exception('Marker not found in cloud database.');
      }

      if (pothole.imagePath.isNotEmpty) {
        final file = File(pothole.imagePath);
        if (file.existsSync()) {
          file.deleteSync();
        }
      }

      _loadPotholesFromDB();
    } catch (e) {
      print('Delete pothole error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not delete road defect marker.'),
          backgroundColor: AppDesign.danger,
        ),
      );
    }
  }

  Future<void> _addMarkerFromMap(LatLng location) async {
    String docId = 'local_${DateTime.now().millisecondsSinceEpoch}';
    try {
      final docRef = await CloudService.instance.addPotholeToCloud(
        location: location,
        imageUrl: '',
        overallSeverity: 'medium',
        potholeCount: 1,
      );
      docId = docRef.id;
    } catch (e) {
      print('Cloud write note (local fallback used for manual dev marker): $e');
    }
    final newMarker = PotholeMarker(
      docId: docId,
      location: location,
      imagePath: '',
      timestamp: DateTime.now(),
      status: 'approved',
      overallSeverity: 'medium',
      potholeCount: 1,
      reporterUid: CloudService.instance.currentUser?.uid ?? 'dev_user',
      reporterEmail:
          CloudService.instance.currentUser?.email ?? 'dev@roadsense.local',
    );
    if (mounted) {
      setState(() {
        _detectedPotholes.add(newMarker);
      });
    }
  }

  void _onTabSelected(int index) {
    if (_currentIndex == index) return;
    if (_tourController.isRunning) {
      _tourController.cancelWithoutCompleting();
    }
    if (index != 1 && _isRealtimeMode) {
      _stopRealtime();
    }
    setState(() => _currentIndex = index);
    if (!kIsWeb && index == 1 && !_isModelLoaded) {
      unawaited(_loadModel());
    }
    if (!kIsWeb) {
      unawaited(_maybeStartCurrentPageTour());
    }
  }

  Future<void> _maybeStartCurrentPageTour() async {
    if (kIsWeb || !mounted) return;
    switch (_currentIndex) {
      case 0:
        await _maybeStartMainTour();
      case 1:
        if (_staticImage != null) {
          await _maybeStartReviewTour();
        } else if (_isRealtimeMode) {
          await _maybeStartLiveScannerTour();
        } else {
          await _maybeStartScannerTour();
        }
      case 2:
        await _maybeStartReportsTour();
      case 3:
        await _maybeStartProfileTour();
    }
  }

  List<TourStepSpec> _buildMainTourSteps() {
    return [
      TourStepSpec(
        id: 'map_search',
        targetKey: _tourMapSearchKey,
        title: 'Search places & road hazards',
        description:
            'Search any barangay or road defect, or tap Directions to plan Point A to Point B.',
      ),
      TourStepSpec(
        id: 'map_filters',
        targetKey: _tourMapFiltersKey,
        title: 'Filters and defect layers',
        description:
            'Filter by potholes, alligator, longitudinal, and transverse cracks, or toggle pending vs. approved layers.',
      ),
      ...?_mapScreenKey.currentState?.mapControlGuideSteps,
      TourStepSpec(
        id: 'nav_scan',
        targetKey: _tourNavScanKey,
        title: 'Live AI road scanner',
        description:
            'Open the live camera scanner to detect road defects and capture frames for review.',
      ),
      TourStepSpec(
        id: 'nav_reports',
        targetKey: _tourNavReportsKey,
        title: 'Track your reports',
        description:
            'View queued uploads, Pending review status, and Approved reports.',
      ),
      TourStepSpec(
        id: 'nav_profile',
        targetKey: _tourNavProfileKey,
        title: 'Profile & page guides',
        description:
            'Manage your account, display preferences, voice alerts, and replay any page guide anytime.',
      ),
    ];
  }

  List<TourStepSpec> _buildSectionSteps({required bool isReports}) {
    final keys = isReports ? _reportGuideTargets : _profileGuideTargets;
    final definitions = isReports
        ? const [
            (
              'search',
              'Search your report history',
              'Filter saved and submitted reports by defect type or barangay. Tap Details on any card to inspect the photo and location.',
            ),
            (
              'status',
              'Understand report status',
              'On Device means upload is queued; Retry sends it again. Pending Review awaits verification. Approved Live appears on the public map.',
            ),
            (
              'active',
              'Active submissions',
              'Lists your local queued and cloud reports. Available edit and removal actions depend on review status.',
            ),
            (
              'trash',
              'Recover removed reports',
              'Removed pending or rejected reports move to Trash where you can Restore or permanently delete them.',
            ),
          ]
        : const [
            (
              'details',
              'Your account details',
              'Update your name and contact number, then tap Save Profile Details.',
            ),
            (
              'settings',
              'Display & map preferences',
              'Customize theme, high contrast B&W mode, map markers, and voice hazard warnings.',
            ),
            (
              'help',
              'Help & page guides',
              'Replay any section guide or reset all first-visit page guides whenever you need a refresher.',
            ),
            (
              'signout',
              'Signing out',
              'Sign out safely on shared devices. Queued offline reports stay saved on this device for your account.',
            ),
          ];
    return [
      for (final step in definitions)
        TourStepSpec(
          id: 'section_${step.$1}',
          targetKey: keys[step.$1]!,
          title: step.$2,
          description: step.$3,
        ),
    ];
  }

  Future<void> _startFirstVisitTourWhenReady({
    required MobileTourId id,
    required int expectedTabIndex,
    required List<TourStepSpec> Function() stepsBuilder,
    int maxAttempts = 1,
    bool force = false,
  }) async {
    if (kIsWeb || !mounted) return;
    await _tourController.ensureLoaded();
    if (!force && _tourController.isCompleted(id)) return;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      await Future<void>.delayed(
        Duration(milliseconds: attempt == 0 ? 380 : 250),
      );
      if (!mounted || _currentIndex != expectedTabIndex) return;
      if (!force && _tourController.isCompleted(id)) return;
      if (_tourController.startTour(id, stepsBuilder(), force: force)) {
        return;
      }
    }
  }

  Future<void> _maybeStartMainTour({bool force = false}) =>
      _startFirstVisitTourWhenReady(
        id: MobileTourId.main,
        expectedTabIndex: 0,
        stepsBuilder: _buildMainTourSteps,
        maxAttempts: 4,
        force: force,
      );

  Future<void> _maybeStartScannerTour({bool force = false}) async {
    if (kIsWeb || !mounted) return;
    await _tourController.ensureLoaded();
    if (!force && _tourController.isCompleted(MobileTourId.scanner)) return;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted ||
        _currentIndex != 1 ||
        _isRealtimeMode ||
        _staticImage != null) {
      return;
    }
    _tourController.startTour(
      MobileTourId.scanner,
      [
        TourStepSpec(
          id: 'scanner_start',
          targetKey: _tourScannerStartKey,
          title: 'Start Live AI Scanner',
          description:
              'Opens the real-time 4-class camera scanner to detect potholes and road cracks. Camera permission is requested only when you start.',
        ),
        TourStepSpec(
          id: 'scanner_close',
          targetKey: _tourScannerCloseKey,
          title: 'Return to map',
          description:
              'Close the scanner anytime without starting the camera or submitting anything.',
        ),
      ],
      force: force,
    );
  }

  Future<void> _maybeStartLiveScannerTour({bool force = false}) async {
    if (kIsWeb || !mounted) return;
    await _tourController.ensureLoaded();
    if (!force && _tourController.isCompleted(MobileTourId.liveScanner)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 380));
    if (!mounted ||
        _currentIndex != 1 ||
        !_isRealtimeMode ||
        _staticImage != null) {
      return;
    }
    _tourController.startTour(
      MobileTourId.liveScanner,
      [
        TourStepSpec(
          id: 'live_scanner_perspective',
          targetKey: _tourScannerPerspectiveKey,
          title: 'Side of road vs. Along road',
          description:
              'Pick "Side of road" when scanning from the roadside or "Along road" when facing down the lane so Longitudinal and Transverse cracks are labeled accurately.',
        ),
        TourStepSpec(
          id: 'live_scanner_capture',
          targetKey: _tourScannerCaptureKey,
          title: 'Save Scan Frame',
          description:
              'Hold steady over the defect, then tap Save Scan Frame to capture the visible cropped frame for review.',
        ),
        TourStepSpec(
          id: 'live_scanner_close',
          targetKey: _tourScannerCloseKey,
          title: 'Stop live scanner',
          description:
              'Turn off the live camera and return to the road map without saving anything.',
        ),
      ],
      force: force,
    );
  }

  Future<void> _maybeStartReviewTour({bool force = false}) async {
    if (kIsWeb || !mounted) return;
    await _tourController.ensureLoaded();
    if (!force && _tourController.isCompleted(MobileTourId.review)) return;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || _currentIndex != 1 || _staticImage == null) return;
    final steps = <TourStepSpec>[
      TourStepSpec(
        id: 'review_summary',
        targetKey: _tourReviewSummaryKey,
        title: 'Detected defect & saved frame',
        description:
            'Shows every detected DPWH class, confidence score, and cropped scan frame. Tap the photo to zoom; nothing is submitted yet.',
      ),
      TourStepSpec(
        id: 'review_submit',
        targetKey: _tourReviewSubmitKey,
        title: 'Submit for admin approval',
        description:
            'Attaches your GPS location and queues this report for LGU/DPWH verification before it appears on the public map.',
      ),
      TourStepSpec(
        id: 'review_retake',
        targetKey: _tourReviewRetakeKey,
        title: 'Retake scan',
        description:
            'Discard this saved frame and return to the live scanner to capture another.',
      ),
    ];
    _tourController.startTour(MobileTourId.review, steps, force: force);
  }

  Future<void> _maybeStartReportsTour({bool force = false}) =>
      _startFirstVisitTourWhenReady(
        id: MobileTourId.reports,
        expectedTabIndex: 2,
        stepsBuilder: () => _buildSectionSteps(isReports: true),
        maxAttempts: 8,
        force: force,
      );

  Future<void> _maybeStartProfileTour({bool force = false}) =>
      _startFirstVisitTourWhenReady(
        id: MobileTourId.profile,
        expectedTabIndex: 3,
        stepsBuilder: () => _buildSectionSteps(isReports: false),
        maxAttempts: 6,
        force: force,
      );

  Future<void> _replayAppTour() async {
    if (kIsWeb || !mounted) return;
    final mapState = _mapScreenKey.currentState;
    final bool hasDrivingGuide = mapState?.isDrivingActive ?? false;
    final bool hasSearchGuide = mapState?.isSearchOrDirectionsActive ?? false;
    final bool hasRoutePreviewGuide = mapState?.isRoutePreviewActive ?? false;
    final section = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('Help & app guide'),
                subtitle: Text(
                  'Choose a short guide. Skip anytime; each page guide also shows automatically the first time you visit it.',
                ),
              ),
              for (final item in [
                (
                  0,
                  Icons.map_outlined,
                  'Map & navigation',
                  'Search, filters, Point A to B route, compass, zoom and GPS',
                ),
                if (hasSearchGuide)
                  (
                    5,
                    Icons.search_rounded,
                    'Search & directions page',
                    'Point A/B inputs, swap, travel modes and Choose on map',
                  ),
                if (hasRoutePreviewGuide)
                  (
                    6,
                    Icons.alt_route_rounded,
                    'Route preview & comparison',
                    'Start driving, find fewer potholes and compare routes',
                  ),
                if (hasDrivingGuide)
                  (
                    7,
                    Icons.directions_car_rounded,
                    'Driving mode HUD',
                    'Camera angles, search, voice alerts, reroute and 3D vehicle drawer',
                  ),
                (
                  1,
                  Icons.camera_alt_outlined,
                  'Scan & live camera',
                  'Live AI road scanner, Save Scan Frame and review workflow',
                ),
                (
                  2,
                  Icons.receipt_long_outlined,
                  'My Reports',
                  'Local uploads, review status, search and report actions',
                ),
                (
                  3,
                  Icons.person_outline,
                  'Profile & settings',
                  'Account details, display options and signing out',
                ),
              ])
                ListTile(
                  leading: Icon(item.$2),
                  title: Text(item.$3),
                  subtitle: Text(item.$4),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, item.$1),
                ),
              if (_staticImage != null)
                ListTile(
                  leading: const Icon(Icons.fact_check_outlined),
                  title: const Text('Review & submit this scan'),
                  onTap: () => Navigator.pop(context, 4),
                ),
              const Divider(height: 8),
              ListTile(
                leading: const Icon(Icons.restart_alt_rounded),
                title: const Text('Reset all page guides'),
                subtitle: const Text(
                  'Show first-visit guides again whenever you enter any page',
                ),
                onTap: () => Navigator.pop(context, -1),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'These guides only auto-run once per page on your first visit, or anytime you replay them here.',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || section == null) return;
    _tourController.cancelWithoutCompleting();
    if (section == -1) {
      await _tourController.resetAllTours();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Page guides reset. Each page will show its guide on your next visit.',
          ),
        ),
      );
      await _maybeStartCurrentPageTour();
      return;
    }
    if (section == 5 || section == 6 || section == 7) {
      if (_isRealtimeMode) await _stopRealtime();
      if (!mounted) return;
      _onTabSelected(0);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted || _currentIndex != 0) return;
      if (section == 5) {
        _mapScreenKey.currentState?.startSearchOrDirectionsGuide(force: true);
      } else if (section == 6) {
        _mapScreenKey.currentState?.startRoutePreviewGuide(force: true);
      } else {
        _mapScreenKey.currentState?.startDrivingGuide(force: true);
      }
      return;
    }
    final targetIndex = section == 4 ? 1 : section;
    if (_isRealtimeMode && targetIndex != 1) await _stopRealtime();
    if (!mounted) return;
    _onTabSelected(targetIndex);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || _currentIndex != targetIndex) return;
    if (section == 0) {
      await _maybeStartMainTour(force: true);
    } else if (section == 1) {
      if (_staticImage != null) {
        await _maybeStartReviewTour(force: true);
      } else if (_isRealtimeMode) {
        await _maybeStartLiveScannerTour(force: true);
      } else {
        await _maybeStartScannerTour(force: true);
      }
    } else if (section == 4) {
      await _maybeStartReviewTour(force: true);
    } else if (section == 2) {
      await _maybeStartReportsTour(force: true);
    } else {
      await _maybeStartProfileTour(force: true);
    }
  }

  Future<void> _stopRealtime() async {
    _isRealtimeMode = false;
    _scanEpoch++;
    _liveExpiry?.cancel();
    _liveBuffer.clear();
    _detectionTimer?.cancel();
    _detectionTimer = null;
    _cameraRecognitionsNotifier.value = null;
    final controller = _cameraController;
    _cameraController = null;
    final previousDisposal = _cameraDisposal;
    final disposal = () async {
      await previousDisposal;
      if (controller == null) return;
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    }();
    _cameraDisposal = disposal;
    await disposal;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initCamera() async {
    await _cameraDisposal;
    final epoch = _scanEpoch;
    if (!mounted || !_cameraForeground || _currentIndex != 1) return;
    if (cameras.isEmpty && !kIsWeb) {
      try {
        cameras = await availableCameras();
      } catch (e) {
        print('Error querying available cameras: $e');
        cameras = [];
      }
    }
    if (cameras.isEmpty) return;
    try {
      if (_cameraController != null) {
        try {
          if (_cameraController!.value.isStreamingImages) {
            await _cameraController!.stopImageStream();
          }
          await _cameraController!.dispose();
        } catch (_) {}
        _cameraController = null;
      }
      if (!mounted || !_cameraForeground || epoch != _scanEpoch) return;
      final controller = CameraController(
        cameras[0],
        ResolutionPreset.high,
        enableAudio: false,
      );
      _cameraController = controller;
      await controller.initialize();
      if (!mounted ||
          !_cameraForeground ||
          epoch != _scanEpoch ||
          !identical(_cameraController, controller)) {
        // A pause or tab switch invalidated this startup while initialize awaited.
        if (identical(_cameraController, controller)) await _stopRealtime();
        return;
      }
      setState(() {});
    } catch (e) {
      print("Camera init error: $e");
      _cameraController = null;
    }
  }

  Future<void> _loadModel() => _modelLoading ??= _loadModelOnce().whenComplete(
    () => _modelLoading = null,
  );

  Future<void> _loadModelOnce() async {
    if (_isModelLoaded) return;
    try {
      final labels = (await rootBundle.loadString(
        DpwhStandards.labelsAsset,
      )).trim().split(RegExp(r'\r?\n'));
      DpwhStandards.validateModelLabels(labels);
      final loadWatch = Stopwatch()..start();
      for (final model in [
        if (Platform.isAndroid)
          'assets/dpwh_thesis_optimized/live_backbone.tflite',
        DpwhStandards.modelAsset,
      ]) {
        try {
          final split = model.endsWith('live_backbone.tflite');
          await const MethodChannel(
            'flutter_vision',
          ).invokeMethod('loadYoloModel', {
            'labels': DpwhStandards.labelsAsset,
            'modelPath': model,
            'modelVersion': 'yolov8',
            'quantization': false,
            'numThreads': 4,
            'useGpu': split,
            'isAsset': true,
            'rotation': 90,
            if (split)
              'headModelPath': 'assets/dpwh_thesis_optimized/live_head.tflite',
          });
          if (mounted) setState(() => _isModelLoaded = true);
          debugPrint(
            '[YOLO] DPWH v3 YOLOv8s model loaded ($model) in ${loadWatch.elapsedMilliseconds} ms; four supported classes (slots 0..3).',
          );
          return;
        } catch (error) {
          debugPrint('[YOLO] Could not load $model: $error');
        }
      }
      throw StateError('No compatible YOLOv8s road defect model could be loaded.');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Road defect model unavailable: $error'),
            backgroundColor: AppDesign.danger,
          ),
        );
      }
    }
  }

  Future<void> _toggleRealtime({bool recovering = false}) async {
    if (_scannerStarting || !_cameraForeground) return;
    if (!recovering) _cameraRecoveryAttempted = false;
    _scannerStarting = true;
    try {
      if (_isRealtimeMode) {
        await _stopRealtime();
      } else {
        if (mounted) {
          setState(() {
            _isStartingCamera = true;
            _cameraError = null;
          });
        }
        final startupEpoch = _scanEpoch;
        await Future.wait([
          if (!_isModelLoaded && !kIsWeb) _loadModel(),
          _initCamera(),
        ]);
        if (!mounted ||
            !_cameraForeground ||
            _currentIndex != 1 ||
            startupEpoch != _scanEpoch) {
          await _stopRealtime();
          return;
        }
        if (!_isModelLoaded) {
          if (mounted) {
            setState(() {
              _cameraError =
                  'Road defect detection model could not be loaded on this device.';
            });
          }
          return;
        }
        if (_cameraController == null ||
            !_cameraController!.value.isInitialized) {
          if (mounted) {
            setState(() {
              _cameraError =
                  'Camera access is unavailable or denied. Allow camera permission in system settings, then tap Retry Live Scanner.';
            });
          }
          return;
        }

        setState(() {
          _isRealtimeMode = true;
          _isStartingCamera = false;
          _cameraError = null;
          _staticImage = null;
          _cameraRecognitionsNotifier.value = null;
        });
        if (_tourController.activeTour == MobileTourId.scanner) {
          _tourController.cancelWithoutCompleting();
        }
        unawaited(_maybeStartLiveScannerTour());

        final epoch = ++_scanEpoch;
        _liveBuffer.clear();
        _liveExpiry?.cancel();
        // Drop ticks while inference runs or during cooldown; never queue old camera frames.
        _detectionTimer?.cancel();
        DateTime? lastCycleFinishedAt;
        bool lastCycleHadDetections = false;
        _detectionTimer = Timer.periodic(const Duration(milliseconds: 100), (
          timer,
        ) async {
          if (epoch != _scanEpoch ||
              !_isRealtimeMode ||
              _cameraController == null) {
            timer.cancel();
            return;
          }
          if (!_cameraForeground || _isDetecting || _isCapturingScan) return;
          if (lastCycleFinishedAt != null) {
            final int cooldownMs = lastCycleHadDetections ? 350 : 550;
            if (DateTime.now()
                    .difference(lastCycleFinishedAt!)
                    .inMilliseconds <
                cooldownMs) {
              return;
            }
          }
          final controller = _cameraController!;
          if (!controller.value.isInitialized ||
              controller.value.isTakingPicture) {
            return;
          }
          _isDetecting = true;
          XFile? photo;
          bool recoverCamera = false;
          final cycleWatch = Stopwatch()..start();
          final capturedAt = DateTime.now();
          try {
            photo = await controller.takePicture();
            if (!mounted || !_cameraForeground || epoch != _scanEpoch) return;
            final captureMs = cycleWatch.elapsedMilliseconds;
            final stopwatch = Stopwatch()..start();
            final bytes = await photo.readAsBytes();
            final response = await _inferNativePhoto(bytes);
            final imageWidth = response['width'] as int;
            final imageHeight = response['height'] as int;
            final rawResult = (response['detections'] as List)
                .map((d) => Map<String, dynamic>.from(d as Map))
                .toList();
            final result = _postProcessDetections(
              rawResult,
              imageWidth: imageWidth,
              imageHeight: imageHeight,
            );
            lastCycleHadDetections = result.isNotEmpty;

            debugPrint(
              '[YOLO LIVE] processing=${stopwatch.elapsedMilliseconds} ms; capture=$captureMs ms; total=${cycleWatch.elapsedMilliseconds} ms; detailRetry=false; detections=${result.length}',
            );
            if (mounted && _isRealtimeMode && epoch == _scanEpoch) {
              _liveBuffer.update(
                bytes,
                imageWidth,
                imageHeight,
                result,
                DateTime.now(),
                capturedAt: capturedAt,
              );
              _publishLiveSnapshot(epoch);
              debugPrint(
                '[YOLO TRACK] active=${_liveBuffer.activeCount(DateTime.now())}; '
                'ids=${_liveBuffer.current(DateTime.now())?.detections.map((d) => d['trackId']).toList()}; '
                'held=${_liveBuffer.isHeld}',
              );
              if (kDebugMode && result.isNotEmpty) {
                print('[YOLO LIVE] ${result.length} detections: $result');
              }
            }
          } catch (e) {
            print('[YOLO LIVE ERROR] $e');
            timer.cancel();
            final cameraUnbound =
                e is CameraException &&
                '${e.code} ${e.description}'.toLowerCase().contains(
                  'not bound to a valid camera',
                );
            recoverCamera =
                cameraUnbound &&
                !_cameraRecoveryAttempted &&
                mounted &&
                _cameraForeground &&
                _currentIndex == 1 &&
                epoch == _scanEpoch;
            if (recoverCamera) _cameraRecoveryAttempted = true;
            if (!recoverCamera && mounted && epoch == _scanEpoch) {
              setState(() => _isRealtimeMode = false);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    e is CameraException
                        ? 'Camera disconnected. Tap Retry to reopen the scanner.'
                        : 'Scanning stopped because inference failed: $e',
                  ),
                  duration: const Duration(seconds: 10),
                  action: SnackBarAction(
                    label: 'Retry',
                    onPressed: _toggleRealtime,
                  ),
                ),
              );
            }
          } finally {
            // Clean up the temp photo file
            if (photo != null) {
              try {
                await File(photo.path).delete();
              } catch (_) {}
            }
            lastCycleFinishedAt = DateTime.now();
            _isDetecting = false;
          }
          if (recoverCamera &&
              mounted &&
              _cameraForeground &&
              epoch == _scanEpoch) {
            await _stopRealtime();
            if (mounted && _cameraForeground && _currentIndex == 1) {
              await _toggleRealtime(recovering: true);
            }
          }
        });
      }
    } finally {
      _scannerStarting = false;
      if (mounted && _isStartingCamera) {
        setState(() => _isStartingCamera = false);
      }
    }
  }

  void _publishLiveSnapshot(int epoch) {
    final now = DateTime.now();
    _liveBuffer.expire(now);
    final snapshot = _liveBuffer.current(now);
    _cameraRecognitionsNotifier.value =
        DpwhStandards.remapDetectionsForPerspective(
          List.of(snapshot?.detections ?? []),
          swapLongitudinalTransverse: _shouldSwapCrackOrientation(),
        );
    _liveExpiry?.cancel();
    final remaining = _liveBuffer.untilExpiry(now);
    if (remaining != null) {
      _liveExpiry = Timer(remaining, () {
        if (mounted && _isRealtimeMode && epoch == _scanEpoch) {
          _publishLiveSnapshot(epoch);
        }
      });
    }
  }

  double _cameraPreviewDisplayAspectRatio(CameraController controller) {
    final value = controller.value;
    final rawRatio = value.aspectRatio;
    if (!rawRatio.isFinite || rawRatio <= 0) {
      return 3.0 / 4.0;
    }
    final orientation =
        value.previewPauseOrientation ??
        value.lockedCaptureOrientation ??
        value.deviceOrientation;
    final isLandscape =
        orientation == DeviceOrientation.landscapeLeft ||
        orientation == DeviceOrientation.landscapeRight;
    return isLandscape ? rawRatio : (1.0 / rawRatio);
  }

  Future<void> _captureFromStream() async {
    if (!_isRealtimeMode || _isCapturingScan) return;
    _isCapturingScan = true;
    final Size? captureViewSize = _liveCameraViewSize;
    final double? capturePreviewAspect = _livePreviewAspectRatio;
    try {
      final snapshot = _liveBuffer.current(DateTime.now());
      if (snapshot != null) {
        try {
          final directory = await getTemporaryDirectory();
          Uint8List outBytes = snapshot.bytes;
          int outWidth = snapshot.width;
          int outHeight = snapshot.height;
          List<Map<String, dynamic>> outDetections = snapshot.detections;
          String ext = 'jpg';

          if (snapshot.detections.isNotEmpty ||
              (captureViewSize != null &&
                  captureViewSize.width > 0 &&
                  captureViewSize.height > 0)) {
            try {
              final cropped = snapshot.detections.isNotEmpty
                  ? await cropImageBytesToHazardRegion(
                      snapshot.bytes,
                      detections: snapshot.detections,
                      detectionImageWidth: snapshot.width,
                      detectionImageHeight: snapshot.height,
                      fallbackViewSize: captureViewSize,
                      fallbackPreviewAspectRatio: capturePreviewAspect,
                    )
                  : await cropImageBytesToVisibleScan(
                      snapshot.bytes,
                      viewSize: captureViewSize!,
                      previewAspectRatio: capturePreviewAspect,
                    );
              outBytes = cropped.bytes;
              outWidth = cropped.width;
              outHeight = cropped.height;
              outDetections = remapDetectionsToCropRect(
                snapshot.detections,
                cropRect: cropped.cropRect,
                sourceWidth: cropped.sourceWidth,
                sourceHeight: cropped.sourceHeight,
                detectionImageWidth: snapshot.width,
                detectionImageHeight: snapshot.height,
                outputWidth: cropped.width,
                outputHeight: cropped.height,
              );
              ext = 'png';
            } catch (e) {
              debugPrint('[YOLO CAPTURE] Crop failed, using raw frame: $e');
            }
          }

          final file = File(
            p.join(
              directory.path,
              'roadsense_scan_${DateTime.now().microsecondsSinceEpoch}.$ext',
            ),
          );
          await file.writeAsBytes(outBytes, flush: true);
          debugPrint(
            '[YOLO CAPTURE] saved analyzed frame ${snapshot.detectedAt.toIso8601String()}; '
            'detections=${outDetections.length}; size=${outWidth}x$outHeight; ageMs=${DateTime.now().difference(snapshot.detectedAt).inMilliseconds}',
          );
          if (!mounted) return;
          await _stopRealtime();
          if (!mounted) return;
          _reportNoteController.clear();
          setState(() {
            _staticImage = file;
            _staticImageWidth = outWidth;
            _staticImageHeight = outHeight;
            _staticRecognitions = DpwhStandards.remapDetectionsForPerspective(
              outDetections,
              swapLongitudinalTransverse: _shouldSwapCrackOrientation(),
            );
            _photoDetectionError = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Saved the detected scan frame. Review it before submitting.',
              ),
            ),
          );
          if (_tourController.activeTour == MobileTourId.liveScanner) {
            _tourController.cancelWithoutCompleting();
          }
          _maybeStartReviewTour();
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Could not save the scan image. Please try again.',
                ),
              ),
            );
          }
        } finally {
          _isCapturingScan = false;
        }
        return;
      }
      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        return;
      }
      HapticFeedback.mediumImpact();

      // Keep scanning if capture must be retried while inference is busy.
      int waits = 0;
      while (_isDetecting && waits < 10) {
        await Future.delayed(const Duration(milliseconds: 100));
        waits++;
      }
      if (_isDetecting) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Finishing the current scan. Tap capture again shortly.',
              ),
            ),
          );
        }
        return;
      }

      if (!mounted || !_isRealtimeMode || _cameraController == null) return;
      _detectionTimer?.cancel();
      _detectionTimer = null;
      _scanEpoch++;
      try {
        final XFile photo = await _cameraController!.takePicture();
        await _stopRealtime();

        File imageFile = File(photo.path);
        if (captureViewSize != null &&
            captureViewSize.width > 0 &&
            captureViewSize.height > 0) {
          try {
            final rawBytes = await imageFile.readAsBytes();
            final cropped = await cropImageBytesToVisibleScan(
              rawBytes,
              viewSize: captureViewSize,
              previewAspectRatio: capturePreviewAspect,
            );
            final directory = await getTemporaryDirectory();
            final croppedFile = File(
              p.join(
                directory.path,
                'roadsense_scan_${DateTime.now().microsecondsSinceEpoch}.png',
              ),
            );
            await croppedFile.writeAsBytes(cropped.bytes, flush: true);
            try {
              await imageFile.delete();
            } catch (_) {}
            imageFile = croppedFile;
          } catch (e) {
            debugPrint(
              '[YOLO CAPTURE] Static crop failed, using raw photo: $e',
            );
          }
        }

        if (mounted) {
          _reportNoteController.clear();
          setState(() {
            _staticImage = imageFile;
            _staticRecognitions = null;
            _photoDetectionError = null;
          });
        }

        await _detectPotholeOnStatic(imageFile.path);
      } catch (e) {
        print('[YOLO] Capture error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to capture photo: $e'),
              backgroundColor: AppDesign.danger,
            ),
          );
        }
      }
    } finally {
      _isCapturingScan = false;
    }
  }

  Future<void> _detectPotholeOnStatic(String imagePath) async {
    if (_isAnalyzingPhoto) return;
    setState(() {
      _isAnalyzingPhoto = true;
      _photoDetectionError = null;
      _staticRecognitions = null;
    });
    try {
      if (!_isModelLoaded) {
        await _loadModel();
      }
      if (!_isModelLoaded) {
        throw StateError('Model could not load. Please try again.');
      }
      final bytes = await File(imagePath).readAsBytes();
      final full = await _inferNativePhoto(bytes);
      final detail = await _inferNativePhoto(bytes, detailPass: true);
      final imageWidth = full['width'] as int,
          imageHeight = full['height'] as int;
      final raw = [
        ...full['detections'] as List,
        ...detail['detections'] as List,
      ].map((d) => Map<String, dynamic>.from(d as Map)).toList();
      final result = mergeModelDetections(
        _postProcessDetections(
          raw,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ),
      );
      if (mounted) {
        setState(() {
          _staticImageWidth = imageWidth;
          _staticImageHeight = imageHeight;
        });
      }

      print("[YOLO STATIC] ${result.length} road defects detected: $result");

      if (mounted) {
        setState(() {
          _staticRecognitions = DpwhStandards.remapDetectionsForPerspective(
            result,
            swapLongitudinalTransverse: _isSideOfRoadView,
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _photoDetectionError =
              'Could not analyze this photo. Retake it and try again.',
        );
      }
      debugPrint('Photo inference failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isAnalyzingPhoto = false);
        if (_staticImage != null) {
          _maybeStartReviewTour();
        }
      }
    }
  }

  Future<Map<String, dynamic>> _inferNativePhoto(
    Uint8List bytes, {
    bool detailPass = false,
  }) async {
    final response = await const MethodChannel('flutter_vision')
        .invokeMapMethod<String, dynamic>('yoloOnImage', {
          'bytesList': bytes,
          'roadSensePrepare': true,
          'detailPass': detailPass,
          'iouThreshold': 0.45,
          'confThreshold': AppSettings.instance.mobileAiConfidenceThreshold,
          'classThreshold': AppSettings.instance.mobileAiConfidenceThreshold,
        });
    if (response == null) throw StateError('No inference response.');
    return response;
  }

  static List<Map<String, dynamic>> _postProcessDetections(
    List<Map<String, dynamic>> raw, {
    int imageWidth = DpwhStandards.inputSize,
    int imageHeight = DpwhStandards.inputSize,
  }) => filterModelDetections(
    raw,
    confidenceThreshold: AppSettings.instance.mobileAiConfidenceThreshold,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );

  /// Extracts one detection's physical damage magnitude ('low'/'medium'/'high')
  /// via [DpwhStandards.evaluateSeverity].
  static String getDetectionSeverity(
    Map<String, dynamic> det,
    double frameArea,
  ) {
    return DpwhStandards.evaluateSeverity(det, frameArea);
  }

  /// Highest physical damage magnitude among all detected defects in the image
  static String getOverallSeverity(
    List<Map<String, dynamic>> detections,
    double frameArea,
  ) {
    if (detections.isEmpty) return 'medium';
    bool hasHigh = false;
    bool hasMed = false;
    for (final det in detections) {
      final sev = getDetectionSeverity(det, frameArea);
      if (sev == 'high') hasHigh = true;
      if (sev == 'medium') hasMed = true;
    }
    if (hasHigh) return 'high';
    if (hasMed) return 'medium';
    return 'low';
  }

  /// Robust location getter that checks permissions and falls back to last known position
  Future<Position?> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return await Geolocator.getLastKnownPosition();
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return await Geolocator.getLastKnownPosition();
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return await Geolocator.getLastKnownPosition();
      }

      try {
        return await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 4),
          ),
        );
      } catch (_) {
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null) return lastKnown;
        return await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      print('Location fetch error: $e');
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _retryPendingReports({String? targetId}) async {
    final service = CloudService.instance;
    final uid = service.currentUser?.uid;
    if (uid == null) return;
    try {
      final queue = await _pendingReports;
      await queue.flush(
        uid,
        (item) => syncQueuedReportPayload(
          queue: queue,
          item: item,
          uploadImage: (bytes, {required String reportId}) {
            if (service.currentUser?.uid != uid) {
              throw ReportUploadException(
                category: ReportUploadErrorCategory.authentication,
                message: 'Account changed. Sign in again to retry upload.',
              );
            }
            return service.uploadReportImage(bytes, reportId: reportId);
          },
          saveReport: (reportId, data, imageUrl) async {
            if (service.currentUser?.uid != uid) {
              throw ReportUploadException(
                category: ReportUploadErrorCategory.authentication,
                message: 'Account changed. Sign in again to save this report.',
              );
            }
            final rawDetections = data['detections'];
            final detections = rawDetections is List
                ? rawDetections
                      .whereType<Map>()
                      .map((m) => Map<String, dynamic>.from(m))
                      .toList()
                : <Map<String, dynamic>>[];
            await service.addPotholeToCloud(
              reportId: reportId,
              location: LatLng(
                (data['latitude'] as num).toDouble(),
                (data['longitude'] as num).toDouble(),
              ),
              imageUrl: imageUrl,
              overallSeverity: (data['overallSeverity'] as String?) ?? 'medium',
              potholeCount: (data['potholeCount'] as num?)?.toInt() ?? 1,
              primaryDpwhCode: data['primaryDpwhCode'] as String?,
              primaryDefect: data['primaryDefect'] as String?,
              responseTime: data['responseTime'] as String?,
              correctiveMeasure: data['correctiveMeasure'] as String?,
              detections: detections,
              barangay: data['barangay'] as String?,
              city: data['city'] as String?,
              province: data['province'] as String?,
              formattedAddress: data['formattedAddress'] as String?,
              note: data['note'] as String?,
            );
          },
        ),
        targetId: targetId,
      );
    } catch (error) {
      final classified = classifyUploadError(error);
      debugPrint(
        'Pending reports retained (${classified.category.name}): ${classified.message}',
      );
    }
  }

  Future<void> _sendToMap() async {
    if (_isSending || _staticImage == null) return;
    if (_staticRecognitions == null || _staticRecognitions!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No supported road defects were detected in this image.',
          ),
        ),
      );
      return;
    }
    final verified = await showEmailVerificationRequiredDialog(
      context,
      isDark: AppSettings.instance.isDarkMode,
    );
    if (!verified || !mounted) return;
    final submittingUid = CloudService.instance.currentUser?.uid;
    setState(() => _isSending = true);

    try {
      // 1. Obtain GPS Location
      Position? position = await _getCurrentLocation();
      if (position == null) {
        throw StateError(
          'A GPS location is required before submitting a road report. Enable location access and retry.',
        );
      }
      final LatLng loc = LatLng(position.latitude, position.longitude);

      // 2. Save annotated image with bounding boxes
      final detections = _staticRecognitions ?? [];
      String savedPath;
      try {
        savedPath = await _saveAnnotatedImage(
          imageFile: _staticImage!,
          detections: detections,
          imgWidth: _staticImageWidth > 0 ? _staticImageWidth : 640,
          imgHeight: _staticImageHeight > 0 ? _staticImageHeight : 640,
        );
      } catch (e) {
        print("Annotated image save error, using original photo: $e");
        savedPath = _staticImage!.path;
      }

      // 4. Save pothole report to Firestore
      final int fw = _staticImageWidth > 0 ? _staticImageWidth : 640;
      final int fh = _staticImageHeight > 0 ? _staticImageHeight : 640;
      final double frameArea = fw.toDouble() * fh.toDouble();
      final overallSeverity = getOverallSeverity(detections, frameArea);
      final potholeCount = detections.isNotEmpty ? detections.length : 1;

      DpwhDefectClass primaryClass = DpwhStandards.pothole;
      if (detections.isNotEmpty) {
        // Accurately select the primary detected road distress item by top confidence
        Map<String, dynamic> topDet = detections.first;
        double topConf = -1.0;
        for (final det in detections) {
          final box = det['box'] as List<dynamic>?;
          final conf = (box != null && box.length > 4)
              ? (box[4] as num).toDouble()
              : 0.0;
          if (conf > topConf) {
            topConf = conf;
            topDet = det;
          }
        }
        primaryClass = DpwhStandards.classify(topDet['tag'] as String?);
      }

      final List<Map<String, dynamic>> parsedDetections = detections.map((det) {
        if (!det.containsKey('box')) return <String, dynamic>{};
        final box = det['box'] as List<dynamic>;
        final left = (box[0] as num).toDouble();
        final top = (box[1] as num).toDouble();
        final right = (box[2] as num).toDouble();
        final bottom = (box[3] as num).toDouble();
        final conf = box.length > 4 ? (box[4] as num).toDouble() : 0.0;
        final rawTag = det['tag'] as String? ?? '';
        final defectClass = DpwhStandards.classify(rawTag);
        final sev = DpwhStandards.evaluateSeverity(det, frameArea);
        return {
          'classId': defectClass.classId,
          'className': defectClass.name,
          'rawTag': rawTag,
          'dpwhCode': defectClass.code,
          'defectType': defectClass.name,
          'severity': sev,
          'confidence': conf,
          'responseTime': defectClass.responseTime,
          'correctiveMeasure': defectClass.correctiveMeasure,
          'unit': defectClass.unit,
          'box': [left, top, right, bottom],
        };
      }).toList();

      LguLocationInfo? lguInfo;
      try {
        lguInfo = await CloudService.instance.reverseGeocodeLgu(loc);
      } catch (_) {}

      final user = CloudService.instance.currentUser;
      if (user == null) throw StateError('Sign in before submitting a report.');
      if (user.uid != submittingUid) {
        throw StateError(
          'Account changed. Please retry from your own account.',
        );
      }
      final queue = await _pendingReports;
      final noteText = _reportNoteController.text.trim();
      final queuedId = await queue.enqueue(user.uid, savedPath, {
        'latitude': loc.latitude,
        'longitude': loc.longitude,
        'overallSeverity': overallSeverity,
        'potholeCount': potholeCount,
        'primaryDpwhCode': primaryClass.code,
        'primaryDefect': primaryClass.name,
        'responseTime': primaryClass.responseTime,
        'correctiveMeasure': primaryClass.correctiveMeasure,
        'detections': parsedDetections,
        'barangay': lguInfo?.barangay,
        'city': lguInfo?.city,
        'province': lguInfo?.province,
        'formattedAddress': lguInfo?.formattedAddress,
        if (noteText.isNotEmpty) 'note': noteText,
      });
      await _retryPendingReports();
      final pendingRecord = await queue.getById(
        queuedId,
        expectedUid: user.uid,
      );

      if (mounted) {
        _reportNoteController.clear();
        setState(() {
          _isSending = false;
          _staticImage = null;
          _staticRecognitions = null;
          _currentIndex = 0;
        });

        final statusMessage = pendingRecord != null
            ? queueStatusBannerForError(
                pendingRecord.errorCategory,
                pendingRecord.errorMessage,
              )
            : '$potholeCount road defect(s) submitted for admin review. Approved reports appear live on the map.';
        final statusColor =
            pendingRecord != null &&
                pendingRecord.syncState == PendingSyncState.failed &&
                pendingRecord.errorCategory !=
                    ReportUploadErrorCategory.connectivity
            ? AppDesign.warning
            : DpwhStandards.getCodeColor(primaryClass.code);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(statusMessage),
            backgroundColor: statusColor,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      final classified = classifyUploadError(e);
      debugPrint(
        '[UPLOAD] Error in _sendToMap (${classified.category.name}): ${classified.message}',
      );
      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: ${classified.message}'),
            backgroundColor: AppDesign.danger,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<String> _saveAnnotatedImage({
    required File imageFile,
    required List<Map<String, dynamic>> detections,
    required int imgWidth,
    required int imgHeight,
  }) async {
    final rawBytes = await imageFile.readAsBytes();
    ui.Codec? codec;
    ui.Image? srcImage;
    ui.Picture? picture;
    ui.Image? annotated;
    try {
      codec = await ui.instantiateImageCodec(rawBytes);
      final frame = await codec.getNextFrame();
      srcImage = frame.image;

      const double maxDim = 960.0;
      double scale = 1.0;
      if (srcImage.width > maxDim || srcImage.height > maxDim) {
        if (srcImage.width > srcImage.height) {
          scale = maxDim / srcImage.width;
        } else {
          scale = maxDim / srcImage.height;
        }
      }

      final int targetWidth = (srcImage.width * scale).round();
      final int targetHeight = (srcImage.height * scale).round();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
      );

      canvas.scale(scale);
      canvas.drawImage(srcImage, Offset.zero, Paint());

      for (final det in detections) {
        if (!det.containsKey('box')) continue;
        final box = det['box'] as List<dynamic>;
        final left = (box[0] as num).toDouble();
        final top = (box[1] as num).toDouble();
        final right = (box[2] as num).toDouble();
        final bottom = (box[3] as num).toDouble();
        final conf = box.length > 4 ? (box[4] as num).toDouble() * 100 : 0.0;

        final String rawTag = det['tag'] as String? ?? '';
        final DpwhDefectClass defectClass = DpwhStandards.classify(rawTag);
        final Color boxColor = defectClass.color;
        final Color textColor = boxColor.computeLuminance() > 0.55
            ? const Color(0xFF0F172A)
            : Colors.white;

        final boxPaint = Paint()
          ..color = boxColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = (srcImage.width / 200).clamp(2.0, 8.0);

        final bgPaint = Paint()..color = boxColor;

        canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), boxPaint);

        final fontSize = (srcImage.width / 36).clamp(11.0, 32.0);
        final labelH = fontSize + 8;
        final labelText =
            '[${defectClass.code}] ${defectClass.name} • ${conf.toStringAsFixed(0)}%';
        final labelW = fontSize * (labelText.length * 0.62);
        canvas.drawRect(
          Rect.fromLTWH(
            left,
            (top - labelH).clamp(0.0, srcImage.height.toDouble()),
            labelW,
            labelH,
          ),
          bgPaint,
        );

        final tp = TextPainter(
          text: TextSpan(
            text: labelText,
            style: TextStyle(
              color: textColor,
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        tp.layout(maxWidth: labelW);
        tp.paint(
          canvas,
          Offset(
            left + 4,
            (top - labelH + 3).clamp(3.0, srcImage.height.toDouble()),
          ),
        );
      }

      picture = recorder.endRecording();
      annotated = await picture.toImage(targetWidth, targetHeight);
      final byteData = await annotated.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final pngBytes = byteData!.buffer.asUint8List();

      final appDir = await getApplicationDocumentsDirectory();
      final potholeDir = Directory(p.join(appDir.path, 'potholes'));
      if (!potholeDir.existsSync()) potholeDir.createSync();
      final savedPath = p.join(
        potholeDir.path,
        'pothole_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await File(savedPath).writeAsBytes(pngBytes);
      return savedPath;
    } finally {
      annotated?.dispose();
      picture?.dispose();
      srcImage?.dispose();
      codec?.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _tourController.dispose();
    _liveExpiry?.cancel();
    _liveBuffer.clear();
    _pendingUploadTimer?.cancel();
    _potholeSubscription?.cancel();
    _userPotholeSubscription?.cancel();
    _detectionTimer?.cancel();
    _reportNoteController.dispose();
    _flutterTts.stop();
    vision?.closeYoloModel();
    if (_cameraController != null) {
      _cameraController!.dispose();
    }
    super.dispose();
  }

  List<Widget> _liveDetectionBoxes(Size size, LiveDetectionSnapshot snapshot) {
    final crop = computeVisibleScanCropRect(
      imageWidth: snapshot.width,
      imageHeight: snapshot.height,
      viewWidth: size.width,
      viewHeight: size.height,
      previewAspectRatio: _livePreviewAspectRatio,
    );
    if (crop.width <= 0 || crop.height <= 0) return const [];
    final sx = size.width / crop.width;
    final sy = size.height / crop.height;
    final detections = DpwhStandards.remapDetectionsForPerspective(
      snapshot.detections,
      swapLongitudinalTransverse: _shouldSwapCrackOrientation(),
    );
    return [
      for (final detection in detections)
        ..._liveDetectionBox(size, detection, crop, sx, sy),
    ];
  }

  List<Widget> _liveDetectionBox(
    Size size,
    Map<String, dynamic> detection,
    Rect crop,
    double sx,
    double sy,
  ) {
    final box = detection['box'] as List;
    final cls = DpwhStandards.activeClassForDetection(detection)!;
    final rawLeft = ((box[0] as num).toDouble() - crop.left) * sx;
    final rawTop = ((box[1] as num).toDouble() - crop.top) * sy;
    final rawRight = ((box[2] as num).toDouble() - crop.left) * sx;
    final rawBottom = ((box[3] as num).toDouble() - crop.top) * sy;
    if (rawRight <= 0 ||
        rawBottom <= 0 ||
        rawLeft >= size.width ||
        rawTop >= size.height) {
      return const [];
    }
    final left = rawLeft.clamp(0.0, size.width);
    final top = rawTop.clamp(0.0, size.height);
    final right = rawRight.clamp(0.0, size.width);
    final bottom = rawBottom.clamp(0.0, size.height);
    if (right - left < 2.0 || bottom - top < 2.0) {
      return const [];
    }
    return [
      Positioned(
        key: ValueKey('live-box-${detection['trackId']}'),
        left: left,
        top: top,
        width: right - left,
        height: bottom - top,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: cls.color, width: 3),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
      _buildDetectionLabelPositioned(
        viewSize: size,
        boxLeft: left,
        boxTop: top,
        boxRight: right,
        defectClass: cls,
        confidencePct: (box[4] as num).toDouble() * 100,
        animDuration: Duration.zero,
      ),
    ];
  }

  List<Widget> displayBoxesForStatic(
    Size viewSize,
    List<Map<String, dynamic>>? recs,
  ) {
    if (recs == null || recs.isEmpty) return [];
    if (_staticImageWidth == 0 || _staticImageHeight == 0) return [];

    final double viewW = viewSize.width;
    final double viewH = viewSize.height;
    final double imgW = _staticImageWidth.toDouble();
    final double imgH = _staticImageHeight.toDouble();

    // Calculate scale and offset for BoxFit.contain
    final double scale = (viewW / imgW < viewH / imgH)
        ? (viewW / imgW)
        : (viewH / imgH);
    final double renderedW = imgW * scale;
    final double renderedH = imgH * scale;
    final double offsetX = (viewW - renderedW) / 2.0;
    final double offsetY = (viewH - renderedH) / 2.0;

    final boxWidgets = <Widget>[];
    final labelWidgets = <Widget>[];

    for (final result in recs) {
      if (!result.containsKey("box")) continue;
      final box = result["box"] as List<dynamic>;
      final double left = (offsetX + (box[0] as num).toDouble() * scale).clamp(
        offsetX,
        offsetX + renderedW,
      );
      final double top = (offsetY + (box[1] as num).toDouble() * scale).clamp(
        offsetY,
        offsetY + renderedH,
      );
      final double right = (offsetX + (box[2] as num).toDouble() * scale).clamp(
        offsetX,
        offsetX + renderedW,
      );
      final double bottom = (offsetY + (box[3] as num).toDouble() * scale)
          .clamp(offsetY, offsetY + renderedH);
      final double confidence = box.length > 4
          ? (box[4] as num).toDouble() * 100
          : 0.0;
      final DpwhDefectClass defectClass = DpwhStandards.classify(
        result['tag'] as String? ?? '',
      );
      final Color boxColor = defectClass.color;

      boxWidgets.add(
        Positioned(
          left: left,
          top: top,
          width: (right - left).clamp(2.0, renderedW),
          height: (bottom - top).clamp(2.0, renderedH),
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(Radius.circular(10.0)),
                border: Border.all(color: boxColor, width: 3.0),
              ),
            ),
          ),
        ),
      );

      labelWidgets.add(
        _buildDetectionLabelPositioned(
          viewSize: viewSize,
          boxLeft: left,
          boxTop: top,
          boxRight: right,
          defectClass: defectClass,
          confidencePct: confidence,
        ),
      );
    }

    return [...boxWidgets, ...labelWidgets];
  }

  /// Renders the detection tag pill independently of narrow bounding-box widths
  /// so narrow cracks never force vertical character wrapping or edge clipping.
  Widget _buildDetectionLabelPositioned({
    required Size viewSize,
    required double boxLeft,
    required double boxTop,
    required double boxRight,
    required DpwhDefectClass defectClass,
    required double confidencePct,
    Duration? animDuration,
  }) {
    final Color boxColor = defectClass.color;
    final Color textColor = boxColor.computeLuminance() > 0.55
        ? const Color(0xFF0F172A)
        : Colors.white;
    final String label =
        '${defectClass.code} ${defectClass.name}${confidencePct > 0 ? " ${confidencePct.toStringAsFixed(0)}%" : ""}';

    final double safeTopMax = (viewSize.height - 32.0).clamp(
      6.0,
      viewSize.height,
    );
    final double preferredTop = boxTop >= 30.0 ? boxTop - 25.0 : boxTop + 4.0;
    final double pillTop = preferredTop.clamp(6.0, safeTopMax);
    final bool anchorRight = boxLeft > viewSize.width * 0.55;
    final double maxAvailableWidth = anchorRight
        ? (boxRight - 8.0).clamp(96.0, 232.0)
        : (viewSize.width - boxLeft - 8.0).clamp(96.0, 232.0);
    final double pillLeft = boxLeft.clamp(
      8.0,
      (viewSize.width - 104.0).clamp(8.0, viewSize.width),
    );
    final double pillRight = (viewSize.width - boxRight).clamp(
      8.0,
      (viewSize.width - 104.0).clamp(8.0, viewSize.width),
    );

    final Widget pill = IgnorePointer(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxAvailableWidth),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: boxColor,
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
        ),
      ),
    );

    if (animDuration != null) {
      return AnimatedPositioned(
        duration: animDuration,
        curve: Curves.easeOutCubic,
        left: anchorRight ? null : pillLeft,
        right: anchorRight ? pillRight : null,
        top: pillTop,
        child: pill,
      );
    }

    return Positioned(
      left: anchorRight ? null : pillLeft,
      right: anchorRight ? pillRight : null,
      top: pillTop,
      child: pill,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Scaffold(
        body: IndexedStack(
          index: _currentIndex == 0
              ? 0
              : (_currentIndex > 1 ? 1 : _currentIndex),
          children: [
            MapScreen(
              key: _mapScreenKey,
              detectedPotholes: _detectedPotholes,
              onDeleteDetectedPothole: _deleteDetectedPothole,
              onAddDetectedPothole: _addMarkerFromMap,
              corridorReportFetcher: _fetchApprovedReportsInCorridor,
              onOpenProfile: () => setState(() => _currentIndex = 1),
              isMapActive: _currentIndex == 0,
              reportsLastUpdatedAt: _reportsLastUpdatedAt,
              isUsingCachedData: _isUsingCachedData,
            ),
            ProfileScreen(
              onSwitchToMap: () => setState(() => _currentIndex = 0),
              onLocateOnMap: (location, docId, data) {
                setState(() => _currentIndex = 0);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _mapScreenKey.currentState?.locatePothole(
                    location,
                    docId,
                    data,
                  );
                });
              },
              onLocateAllOnMap: (locations, {String filterLabel = 'all'}) {
                setState(() => _currentIndex = 0);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _mapScreenKey.currentState?.locateAllPotholes(
                    locations,
                    filterLabel: filterLabel,
                  );
                });
              },
            ),
          ],
        ),
      );
    }

    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final bool appDark = Theme.of(context).brightness == Brightness.dark;
    final bool scannerDark = appDark;
    final String scannerTitle = _isRealtimeMode
        ? 'Live Scanner'
        : (_staticImage != null
              ? 'Capture Review'
              : (_isStartingCamera
                    ? 'Starting Camera'
                    : (_cameraError != null
                          ? 'Camera Unavailable'
                          : 'Road Scanner')));

    Widget scannerOverlay = Theme(
      data: AppDesign.buildTheme(isDark: scannerDark),
      child: Container(
        color: AppDesign.bg(scannerDark),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 14, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          RoadSenseLogo(size: 28, isDarkOverride: scannerDark),
                          const SizedBox(width: 10),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isRealtimeMode
                                  ? AppDesign.danger
                                  : (_cameraError != null
                                        ? AppDesign.warning
                                        : AppDesign.accent(scannerDark)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              scannerTitle,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppDesign.textPrimary(scannerDark),
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    MobileTouchIconButton(
                      targetKey: _staticImage == null
                          ? _tourScannerCloseKey
                          : null,
                      icon: Icons.close_rounded,
                      tooltip: 'Close scanner and return to map',
                      foregroundColor: AppDesign.textPrimary(scannerDark),
                      backgroundColor: AppDesign.sunken(scannerDark),
                      borderColor: AppDesign.border(scannerDark),
                      shape: BoxShape.rectangle,
                      onPressed: () async {
                        if (_tourController.isRunning) {
                          _tourController.cancelWithoutCompleting();
                        }
                        if (_isRealtimeMode) {
                          await _stopRealtime();
                        }
                        if (!mounted) return;
                        _reportNoteController.clear();
                        setState(() {
                          _currentIndex = 0;
                          _staticImage = null;
                          _staticRecognitions = null;
                          _photoDetectionError = null;
                          _cameraError = null;
                        });
                      },
                    ),
                  ],
                ),
              ),

              Divider(
                height: 1,
                color: AppDesign.border(scannerDark),
                thickness: 1,
              ),

              if (!_isRealtimeMode && _staticImage == null) ...[
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final media = MediaQuery.of(context);
                      final bool isLandscape =
                          media.size.width > media.size.height &&
                          media.size.height < 560;
                      if (isLandscape &&
                          !_isStartingCamera &&
                          _cameraError == null) {
                        return SafeArea(
                          top: false,
                          child: Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                12,
                                24,
                                56,
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 640),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              RoadSenseLogo(
                                                size: 52,
                                                isDarkOverride: scannerDark,
                                              ),
                                              const SizedBox(width: 14),
                                              Flexible(
                                                child: Text(
                                                  'Scan road defects',
                                                  style: TextStyle(
                                                    color: AppDesign.textPrimary(
                                                      scannerDark,
                                                    ),
                                                    fontSize: 22,
                                                    fontWeight: FontWeight.w800,
                                                    height: 1.15,
                                                    letterSpacing: -0.3,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 10),
                                          Text(
                                            'Hold steady in daylight to detect potholes and road cracks. Nothing is uploaded until you review.',
                                            style: TextStyle(
                                              color: AppDesign.textSecondary(
                                                scannerDark,
                                              ),
                                              fontSize: 12.5,
                                              height: 1.4,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    SizedBox(
                                      key: _tourScannerStartKey,
                                      width: 220,
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: AppDesign.brand,
                                          foregroundColor: Colors.white,
                                          minimumSize: const Size.fromHeight(48),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 12,
                                          ),
                                          elevation: 0,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                        ),
                                        onPressed: _toggleRealtime,
                                        icon: const Icon(
                                          Icons.radar_rounded,
                                          size: 20,
                                        ),
                                        label: const Text(
                                          'Start Live Scanner',
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
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
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 96),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: (constraints.maxHeight - 116).clamp(
                              0.0,
                              double.infinity,
                            ),
                          ),
                          child: Center(
                            child: _isStartingCamera
                                ? MobileStateCard(
                                    icon: Icons.cameraswitch_rounded,
                                    iconColor: AppDesign.accent(scannerDark),
                                    title: 'Preparing live scanner',
                                    message:
                                        'Loading the 4-class road defect detector and initializing camera preview.',
                                    isLoading: true,
                                  )
                                : _cameraError != null
                                ? MobileStateCard(
                                    icon: Icons.videocam_off_rounded,
                                    iconColor: AppDesign.warning,
                                    title: 'Camera unavailable',
                                    message: _cameraError!,
                                    primaryLabel: 'Retry Live Scanner',
                                    onPrimaryPressed: _toggleRealtime,
                                  )
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      RoadSenseLogo(
                                        size: 72,
                                        isDarkOverride: scannerDark,
                                      ),
                                      const SizedBox(height: 20),
                                      Text(
                                        'Scan road defects',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: AppDesign.textPrimary(
                                            scannerDark,
                                          ),
                                          fontSize: 26,
                                          fontWeight: FontWeight.w800,
                                          height: 1.15,
                                          letterSpacing: -0.3,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        'Hold steady in daylight to detect potholes, alligator cracks, longitudinal cracks, and transverse cracks. Nothing is uploaded until you review and submit.',
                                        style: TextStyle(
                                          color: AppDesign.textSecondary(
                                            scannerDark,
                                          ),
                                          fontSize: 13.5,
                                          height: 1.45,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 16),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        alignment: WrapAlignment.center,
                                        children: [
                                          for (final cls
                                              in DpwhStandards.allClasses)
                                            MobileDefectPill(
                                              defectClass: cls,
                                              showCode: true,
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 28),
                                      SizedBox(
                                        key: _tourScannerStartKey,
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: AppDesign.brand,
                                            foregroundColor: Colors.white,
                                            minimumSize: const Size.fromHeight(
                                              54,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 14,
                                            ),
                                            elevation: 0,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                          ),
                                          onPressed: _toggleRealtime,
                                          icon: const Icon(
                                            Icons.radar_rounded,
                                            size: 22,
                                          ),
                                          label: const Text(
                                            'Start Live Scanner',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ] else if (_isRealtimeMode) ...[
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final media = MediaQuery.of(context);
                      final bool isLandscape =
                          media.size.width > media.size.height &&
                          media.size.height < 560;
                      // LayoutBuilder gives the ACTUAL camera-preview area size,
                      // which is smaller than MediaQuery.size (excludes header + capture bar).
                      // Using the wrong (full-screen) size inflates scaleY and shifts
                      // every bounding box downward.
                      final Widget cameraStack = LayoutBuilder(
                        builder: (context, constraints) {
                      final cameraViewSize = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      _liveCameraViewSize = cameraViewSize;
                      _livePreviewAspectRatio =
                          (_cameraController != null &&
                              _cameraController!.value.isInitialized)
                          ? _cameraPreviewDisplayAspectRatio(_cameraController!)
                          : null;
                      return Stack(
                        children: [
                          if (_cameraController != null &&
                              _cameraController!.value.isInitialized)
                            Positioned.fill(
                              child: ClipRect(
                                child: FittedBox(
                                  fit: BoxFit.cover,
                                  child: SizedBox(
                                    width:
                                        (_livePreviewAspectRatio ??
                                            (3.0 / 4.0)) *
                                        1000.0,
                                    height: 1000.0,
                                    child: CameraPreview(_cameraController!),
                                  ),
                                ),
                              ),
                            ),
                          ValueListenableBuilder<List<Map<String, dynamic>>?>(
                            valueListenable: _cameraRecognitionsNotifier,
                            builder: (context, recs, _) {
                              final snapshot = _liveBuffer.current(
                                DateTime.now(),
                              );
                              final hasDetections =
                                  snapshot != null && !_liveBuffer.isHeld;
                              return Stack(
                                children: [
                                  if (hasDetections)
                                    ..._liveDetectionBoxes(
                                      cameraViewSize,
                                      snapshot,
                                    ),
                                  if (!hasDetections)
                                    Center(
                                      child: IgnorePointer(
                                        child: Container(
                                          width: 220,
                                          height: 220,
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: disableAnimations
                                                    ? 0.45
                                                    : 0.30,
                                              ),
                                              width: 1.5,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                          ),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 10,
                                                  left: 8,
                                                  right: 8,
                                                ),
                                                child: Text(
                                                  'Align road surface in frame',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha: 0.88,
                                                        ),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                              Icon(
                                                Icons.control_camera_rounded,
                                                color: Colors.white.withValues(
                                                  alpha: 0.35,
                                                ),
                                                size: 32,
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  bottom: 10,
                                                  left: 8,
                                                  right: 8,
                                                ),
                                                child: Text(
                                                  'Hold steady to lock detection',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha: 0.88,
                                                        ),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
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
                          Positioned(
                            top: 10,
                            right: 10,
                            child: SafeArea(
                              bottom: false,
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  key: _tourScannerPerspectiveKey,
                                  borderRadius: BorderRadius.circular(20),
                                  onTap: () {
                                    setState(() {
                                      _isSideOfRoadView = !_isSideOfRoadView;
                                    });
                                    _publishLiveSnapshot(_scanEpoch);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xCC0F172A),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: _isSideOfRoadView
                                            ? AppDesign.accent(
                                                true,
                                              ).withValues(alpha: 0.75)
                                            : Colors.white24,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.swap_horiz_rounded,
                                          size: 15,
                                          color: _isSideOfRoadView
                                              ? AppDesign.accent(true)
                                              : Colors.white70,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          _isSideOfRoadView
                                              ? 'Side of road'
                                              : 'Along road',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                      if (isLandscape) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: cameraStack),
                            Container(
                              width: 148,
                              color: AppDesign.bg(scannerDark),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              child: SafeArea(
                                left: false,
                                top: false,
                                child: Center(
                                  child: SizedBox(
                                    key: _tourScannerCaptureKey,
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppDesign.danger,
                                        foregroundColor: Colors.white,
                                        minimumSize: const Size(0, 64),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 12,
                                        ),
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                        ),
                                      ),
                                      onPressed: _captureFromStream,
                                      child: const Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.camera_alt_rounded,
                                            size: 24,
                                          ),
                                          SizedBox(height: 6),
                                          Text(
                                            'Save Frame',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Expanded(child: cameraStack),
                          Container(
                            color: AppDesign.bg(scannerDark),
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                            child: SafeArea(
                              top: false,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    key: _tourScannerCaptureKey,
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppDesign.danger,
                                        foregroundColor: Colors.white,
                                        minimumSize: const Size.fromHeight(58),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                        ),
                                      ),
                                      onPressed: _captureFromStream,
                                      icon: const Icon(
                                        Icons.camera_alt_rounded,
                                        size: 22,
                                      ),
                                      label: const Text(
                                        'Save Scan Frame',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.4,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Saves the detected frame for review — nothing is submitted yet.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: AppDesign.textSecondary(
                                        scannerDark,
                                      ),
                                      fontSize: 12,
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
                ),
              ] else if (_staticImage != null) ...[
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final media = MediaQuery.of(context);
                      final bool isLandscape =
                          media.size.width > media.size.height &&
                          media.size.height < 560;
                      return SafeArea(
                        top: false,
                        child: SingleChildScrollView(
                          padding: EdgeInsets.only(
                            bottom: isLandscape ? 72 : 112,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: isLandscape ? 720 : double.infinity,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                        GestureDetector(
                          onTap: () {
                            final imageFile = _staticImage;
                            if (imageFile == null) return;
                            showDialog<void>(
                              context: context,
                              builder: (dialogCtx) => Dialog.fullscreen(
                                backgroundColor: Colors.black,
                                child: Stack(
                                  children: [
                                    Center(
                                      child: InteractiveViewer(
                                        minScale: 1.0,
                                        maxScale: 5.0,
                                        child: Image.file(
                                          imageFile,
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      top:
                                          MediaQuery.paddingOf(dialogCtx).top +
                                          12,
                                      right: 16,
                                      child: MobileTouchIconButton(
                                        icon: Icons.close_rounded,
                                        tooltip: 'Close full-screen photo',
                                        backgroundColor: const Color(
                                          0xCC0F172A,
                                        ),
                                        foregroundColor: Colors.white,
                                        borderColor: Colors.white.withValues(
                                          alpha: 0.24,
                                        ),
                                        onPressed: () =>
                                            Navigator.of(dialogCtx).pop(),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                          child: Container(
                            color: Colors.black,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: isLandscape ? 150 : 220,
                                maxHeight: isLandscape
                                    ? (media.size.height * 0.52).clamp(
                                        150.0,
                                        220.0,
                                      )
                                    : (media.size.height * 0.48).clamp(
                                        220.0,
                                        440.0,
                                      ),
                              ),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final viewSize = Size(
                                    constraints.maxWidth,
                                    constraints.maxHeight,
                                  );
                                  return Stack(
                                    children: [
                                      Positioned.fill(
                                        child: Image.file(
                                          _staticImage!,
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                      ...displayBoxesForStatic(
                                        viewSize,
                                        _staticRecognitions,
                                      ),
                                      Positioned(
                                        top: 12,
                                        left: 12,
                                        right: 12,
                                        child: Wrap(
                                          spacing: 8,
                                          runSpacing: 6,
                                          alignment: WrapAlignment.spaceBetween,
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xCC0F172A),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.16),
                                                ),
                                              ),
                                              child: const Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.save_alt_rounded,
                                                    size: 14,
                                                    color: Colors.white,
                                                  ),
                                                  SizedBox(width: 6),
                                                  Text(
                                                    'Saved locally • Not submitted',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xCC0F172A),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.16),
                                                ),
                                              ),
                                              child: const Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.zoom_in_rounded,
                                                    size: 14,
                                                    color: Colors.white,
                                                  ),
                                                  SizedBox(width: 4),
                                                  Text(
                                                    'Tap photo to zoom',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                          decoration: BoxDecoration(
                            color: AppDesign.bg(scannerDark),
                            border: Border(
                              top: BorderSide(
                                color: AppDesign.border(scannerDark),
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const MobileReportLifecycleBanner(activeStage: 1),
                              if (_isOffline) ...[
                                const SizedBox(height: 12),
                                const MobileOfflineBanner(
                                  message:
                                      'You are offline. Submitting saves this report on your device and uploads it automatically for admin review when reconnected.',
                                ),
                              ],
                              const SizedBox(height: 12),
                              Container(
                                key: _tourReviewSummaryKey,
                                child: Builder(
                                  builder: (context) {
                                    if (_isAnalyzingPhoto) {
                                      return MobileStateCard(
                                        icon: Icons.manage_search_rounded,
                                        iconColor: AppDesign.accent(
                                          scannerDark,
                                        ),
                                        title: 'Analyzing road surface',
                                        message:
                                            'Checking the saved photo for potholes, alligator cracks, longitudinal cracks, and transverse cracks.',
                                        isLoading: true,
                                      );
                                    }
                                    final hasDetections =
                                        _staticRecognitions != null &&
                                        _staticRecognitions!.isNotEmpty;
                                    if (!hasDetections) {
                                      return MobileStateCard(
                                        icon: Icons.info_outline_rounded,
                                        iconColor: AppDesign.warning,
                                        title: _photoDetectionError != null
                                            ? 'Analysis unavailable'
                                            : 'No road defect detected',
                                        message:
                                            _photoDetectionError ??
                                            'Try retaking closer in good light covering a pothole, alligator crack, longitudinal crack, or transverse crack.',
                                      );
                                    }

                                    final detections = _staticRecognitions!;
                                    final Map<DpwhDefectClass, int>
                                    classCounts = {};
                                    double topConf = -1.0;
                                    DpwhDefectClass topClass =
                                        DpwhStandards.pothole;
                                    for (final det in detections) {
                                      final c = DpwhStandards.classify(
                                        det['tag'] as String?,
                                      );
                                      classCounts[c] =
                                          (classCounts[c] ?? 0) + 1;
                                      final box = det['box'] as List<dynamic>?;
                                      final conf =
                                          (box != null && box.length > 4)
                                          ? (box[4] as num).toDouble()
                                          : 0.0;
                                      if (conf > topConf) {
                                        topConf = conf;
                                        topClass = c;
                                      }
                                    }

                                    final int confPct =
                                        (topConf.clamp(0.0, 1.0) * 100).round();

                                    return MobileSectionCard(
                                      padding: const EdgeInsets.all(14),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 6,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              MobileDefectPill(
                                                defectClass: topClass,
                                                showCode: true,
                                              ),

                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 9,
                                                      vertical: 4,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: AppDesign.brandWash(
                                                    scannerDark,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        AppDesign.radiusPill,
                                                      ),
                                                  border: Border.all(
                                                    color:
                                                        AppDesign.brandBorder(
                                                          scannerDark,
                                                        ),
                                                  ),
                                                ),
                                                child: Text(
                                                  '${detections.length} ${detections.length == 1 ? 'defect' : 'defects'} • $confPct% AI match',
                                                  style: TextStyle(
                                                    color: AppDesign.accent(
                                                      scannerDark,
                                                    ),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (classCounts.length > 1 ||
                                              detections.length > 1) ...[
                                            const SizedBox(height: 10),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 6,
                                              children: [
                                                for (final entry
                                                    in classCounts.entries)
                                                  MobileDefectPill(
                                                    defectClass: entry.key,
                                                    showCode: true,
                                                  ),
                                              ],
                                            ),
                                          ],
                                          const SizedBox(height: 12),
                                          Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: AppDesign.sunken(
                                                scannerDark,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    AppDesign.radiusMd,
                                                  ),
                                              border: Border.all(
                                                color: AppDesign.border(
                                                  scannerDark,
                                                ),
                                              ),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '${topClass.name} • ${topClass.correctiveMeasure}',
                                                  style: TextStyle(
                                                    color:
                                                        AppDesign.textPrimary(
                                                          scannerDark,
                                                        ),
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  topClass.correctiveMeasure,
                                                  style: TextStyle(
                                                    color:
                                                        AppDesign.textSecondary(
                                                          scannerDark,
                                                        ),
                                                    fontSize: 12.5,
                                                    height: 1.4,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.my_location_rounded,
                                                size: 16,
                                                color: AppDesign.accent(
                                                  scannerDark,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'GPS location and barangay LGU zone attach automatically on submit. Reports appear on the public map after admin review.',
                                                  style: TextStyle(
                                                    color:
                                                        AppDesign.textSecondary(
                                                          scannerDark,
                                                        ),
                                                    fontSize: 12,
                                                    height: 1.35,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 12),

                              const SizedBox(height: 12),
                              SizedBox(
                                key: _tourReviewSubmitKey,
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed:
                                      _isSending ||
                                          _isAnalyzingPhoto ||
                                          (_staticRecognitions?.isEmpty ?? true)
                                      ? null
                                      : _sendToMap,
                                  style:
                                      AppDesign.primaryButtonStyle(
                                        isDark: scannerDark,
                                      ).copyWith(
                                        minimumSize:
                                            const WidgetStatePropertyAll(
                                              Size.fromHeight(54),
                                            ),
                                      ),
                                  icon: _isSending
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2.5,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.cloud_upload_rounded,
                                          size: 22,
                                        ),
                                  label: Text(
                                    _isSending
                                        ? 'Submitting report...'
                                        : (_isOffline
                                              ? 'Save & Queue Report Offline'
                                              : 'Submit Report'),
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                key: _tourReviewRetakeKey,
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _isAnalyzingPhoto || _isSending
                                      ? null
                                      : () {
                                          if (_tourController.activeTour ==
                                              MobileTourId.review) {
                                            _tourController
                                                .cancelWithoutCompleting();
                                          }
                                          _reportNoteController.clear();
                                          setState(() {
                                            _staticImage = null;
                                            _staticRecognitions = null;
                                            _photoDetectionError = null;
                                          });
                                          unawaited(_maybeStartScannerTour());
                                        },
                                  style:
                                      AppDesign.outlinedButtonStyle(
                                        isDark: scannerDark,
                                      ).copyWith(
                                        minimumSize:
                                            const WidgetStatePropertyAll(
                                              Size.fromHeight(50),
                                            ),
                                      ),
                                  icon: const Icon(
                                    Icons.replay_rounded,
                                    size: 20,
                                  ),
                                  label: const Text(
                                    'Retake Scan',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
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
            );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return ListenableBuilder(
      listenable: _tourController,
      builder: (context, _) {
        final bool isDark = Theme.of(context).brightness == Brightness.dark;
        final bool hideBottomNav =
            _currentIndex == 1 && (_isRealtimeMode || _staticImage != null);
        final Widget scaffold = Scaffold(
          extendBody: true,
          body: IndexedStack(
            index: _currentIndex,
            children: [
              MapScreen(
                key: _mapScreenKey,
                detectedPotholes: _detectedPotholes,
                onDeleteDetectedPothole: _deleteDetectedPothole,
                onAddDetectedPothole: _addMarkerFromMap,
                corridorReportFetcher: _fetchApprovedReportsInCorridor,
                onOpenProfile: () => _onTabSelected(3),
                onOpenScanner: () => _onTabSelected(1),
                onReplayTour: _replayAppTour,
                tourController: _tourController,
                tourSearchBarKey: _tourMapSearchKey,
                tourLayersFilterKey: _tourMapFiltersKey,
                isTourActive: _tourController.isRunning,
                isMapActive: _currentIndex == 0,
                reportsLastUpdatedAt: _reportsLastUpdatedAt,
                isUsingCachedData: _isUsingCachedData,
              ),
              scannerOverlay,
              ProfileScreen(
                section: ProfileScreenSection.reports,
                tourTargets: _reportGuideTargets,
                pendingQueue: _resolvedPendingQueue,
                onRetryPendingReports: _retryPendingReports,
                onSwitchToMap: () => _onTabSelected(0),
                onOpenScan: () => _onTabSelected(1),
                onReplayTour: _replayAppTour,
                onLocateOnMap: (location, docId, data) {
                  _onTabSelected(0);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _mapScreenKey.currentState?.locatePothole(
                      location,
                      docId,
                      data,
                    );
                  });
                },
                onLocateAllOnMap: (locations, {String filterLabel = 'all'}) {
                  _onTabSelected(0);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _mapScreenKey.currentState?.locateAllPotholes(
                      locations,
                      filterLabel: filterLabel,
                    );
                  });
                },
              ),
              ProfileScreen(
                section: ProfileScreenSection.profile,
                tourTargets: _profileGuideTargets,
                pendingQueue: _resolvedPendingQueue,
                onRetryPendingReports: _retryPendingReports,
                onSwitchToMap: () => _onTabSelected(0),
                onOpenScan: () => _onTabSelected(1),
                onReplayTour: _replayAppTour,
                onLocateOnMap: (location, docId, data) {
                  _onTabSelected(0);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _mapScreenKey.currentState?.locatePothole(
                      location,
                      docId,
                      data,
                    );
                  });
                },
                onLocateAllOnMap: (locations, {String filterLabel = 'all'}) {
                  _onTabSelected(0);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _mapScreenKey.currentState?.locateAllPotholes(
                      locations,
                      filterLabel: filterLabel,
                    );
                  });
                },
              ),
            ],
          ),
          bottomNavigationBar: ValueListenableBuilder<bool>(
            valueListenable: AppSettings.instance.isRouteActiveNotifier,
            builder: (context, isRouteActive, child) {
              if (isRouteActive || hideBottomNav) {
                return const SizedBox.shrink();
              }
              return MobileFloatingNavBar(
                currentIndex: _currentIndex,
                onTabSelected: _onTabSelected,
                isDark: isDark,
                disableAnimations: disableAnimations,
                scanKey: _tourNavScanKey,
                reportsKey: _tourNavReportsKey,
                profileKey: _tourNavProfileKey,
              );
            },
          ),
        );

        return Stack(
          children: [
            scaffold,
            SpotlightTourOverlay(controller: _tourController),
          ],
        );
      },
    );
  }
}
