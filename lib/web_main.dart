/// Web-only entry point.
/// This file is completely free of dart:io so Flutter Web does not crash.
library;

import 'road_sense_brand.dart';

import 'dart:async';
import 'package:flutter/foundation.dart'
    show SynchronousFuture, ValueListenable;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';
import 'firebase_setup.dart';
import 'cloud_service.dart';
import 'dpwh_standards.dart';
import 'verified_auth_gate.dart';
import 'admin_dashboard_screen.dart';
import 'settings_dialog.dart';
import 'web_components.dart';
import 'web_profile_screen.dart';
import 'web_map_screen.dart';
import 'web_report_query.dart';
import 'app_settings.dart';
import 'web_design.dart';
import 'road_report_cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Catch any Flutter framework errors and display them
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };

  try {
    await initializeFirebase();
  } catch (e, stack) {
    debugPrint('Firebase initialization error: $e\n$stack');
  }
  runApp(const WebApp());
}

class _WebRouteInformationParser extends RouteInformationParser<WebUrlState> {
  const _WebRouteInformationParser();

  @override
  Future<WebUrlState> parseRouteInformation(RouteInformation routeInformation) {
    return SynchronousFuture<WebUrlState>(
      WebUrlState.parseUri(routeInformation.uri),
    );
  }

  @override
  RouteInformation restoreRouteInformation(WebUrlState configuration) {
    return RouteInformation(uri: configuration.toUri());
  }
}

class _WebRouterDelegate extends RouterDelegate<WebUrlState>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<WebUrlState> {
  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  final ValueNotifier<WebUrlState> urlNotifier = ValueNotifier<WebUrlState>(
    const WebUrlState(),
  );

  @override
  WebUrlState get currentConfiguration => urlNotifier.value;

  void pushUrlState(WebUrlState next) {
    if (urlNotifier.value == next) return;
    urlNotifier.value = next;
    notifyListeners();
  }

  void replaceUrlState(BuildContext context, WebUrlState next) {
    if (urlNotifier.value == next) return;
    Router.neglect(context, () {
      urlNotifier.value = next;
      notifyListeners();
    });
  }

  @override
  Future<void> setNewRoutePath(WebUrlState configuration) {
    if (urlNotifier.value != configuration) {
      urlNotifier.value = configuration;
      notifyListeners();
    }
    return SynchronousFuture<void>(null);
  }

  @override
  void dispose() {
    urlNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navigatorKey,
      pages: [
        MaterialPage<void>(
          key: const ValueKey('roadsense-web-root'),
          child: VerifiedAuthGate(
            authenticatedBuilder: (uid) =>
                _RoleRouter(uid: uid, routerDelegate: this),
          ),
        ),
      ],
      onDidRemovePage: (page) {},
    );
  }
}

class WebApp extends StatefulWidget {
  const WebApp({super.key});

  @override
  State<WebApp> createState() => _WebAppState();
}

class _WebAppState extends State<WebApp> {
  late final _WebRouterDelegate _routerDelegate = _WebRouterDelegate();
  final _WebRouteInformationParser _routeParser =
      const _WebRouteInformationParser();

  @override
  void dispose() {
    _routerDelegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp.router(
          title: 'RoadSense — GIS Platform',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          // The web UI has its own design system (lib/web_design.dart) so it can
          // evolve without touching AppDesign, which the mobile app compiles
          // against. See CLAUDE.md section 1.
          theme: WebDesign.buildTheme(isDark: false),
          darkTheme: WebDesign.buildTheme(isDark: true),
          routeInformationParser: _routeParser,
          routerDelegate: _routerDelegate,
          builder: (context, child) {
            ErrorWidget.builder = (FlutterErrorDetails details) =>
                _FatalErrorScreen(details: details);
            return child ?? const SizedBox.shrink();
          },
        );
      },
    );
  }
}

/// Last-resort error surface.
///
/// Rendered by [ErrorWidget.builder], which runs outside the widget tree, so it
/// reads the theme from [AppSettings] rather than an inherited [Theme].
class _FatalErrorScreen extends StatelessWidget {
  final FlutterErrorDetails details;

  const _FatalErrorScreen({required this.details});

  @override
  Widget build(BuildContext context) {
    final isDark = AppSettings.instance.isDarkMode;
    final danger = WebDesign.danger(isDark);

    return Scaffold(
      backgroundColor: WebDesign.bg(isDark),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(WebDesign.space8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(WebDesign.space4),
                  decoration: BoxDecoration(
                    color: danger.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.error_outline_rounded,
                    color: danger,
                    size: WebDesign.iconXl,
                  ),
                ),
                const SizedBox(height: WebDesign.space5),
                Text(
                  'Something went wrong',
                  style: WebDesign.textTheme(isDark, 'Roboto').headlineSmall,
                ),
                const SizedBox(height: WebDesign.space2),
                Text(
                  'The page hit an unexpected error. Reloading usually clears it.',
                  textAlign: TextAlign.center,
                  style: WebDesign.textTheme(isDark, 'Roboto').bodyMedium,
                ),
                const SizedBox(height: WebDesign.space5),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(WebDesign.space4),
                  decoration: BoxDecoration(
                    color: WebDesign.sunken(isDark),
                    borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                    border: Border.all(color: WebDesign.border(isDark)),
                  ),
                  child: SelectableText(
                    details.exceptionAsString(),
                    style: WebDesign.textTheme(isDark, 'Roboto').bodySmall,
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

/// Splash shown while Firebase resolves auth and the account role.
class _SplashLoader extends StatelessWidget {
  const _SplashLoader();

  @override
  Widget build(BuildContext context) {
    final isDark = AppSettings.instance.isDarkMode;
    final text = WebDesign.textTheme(isDark, 'Roboto');

    return Scaffold(
      backgroundColor: WebDesign.bg(isDark),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const RoadSenseBrand(size: 76, showWordmark: true),
            const SizedBox(height: WebDesign.space5),
            Text('GIS & Road Infrastructure Platform', style: text.bodySmall),
            const SizedBox(height: WebDesign.space10),
            SizedBox(
              width: WebDesign.iconLg,
              height: WebDesign.iconLg,
              child: CircularProgressIndicator(
                color: WebDesign.brand(isDark),
                strokeWidth: 2.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cached Role Router to prevent full screen loading flashes on re-renders
class _RoleRouter extends StatefulWidget {
  final String uid;
  final _WebRouterDelegate routerDelegate;

  const _RoleRouter({required this.uid, required this.routerDelegate});

  @override
  State<_RoleRouter> createState() => _RoleRouterState();
}

class _RoleRouterState extends State<_RoleRouter> {
  late Future<String> _roleFuture;

  @override
  void initState() {
    super.initState();
    _roleFuture = CloudService.instance.getUserRole(widget.uid);
  }

  @override
  void didUpdateWidget(covariant _RoleRouter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) {
      _roleFuture = CloudService.instance.getUserRole(widget.uid);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _roleFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _SplashLoader();
        }
        final role = snapshot.data ?? 'user';
        if (role == 'admin' || role == 'super_admin') {
          return const AdminDashboardScreen();
        }
        return _WebUserHome(
          urlListenable: widget.routerDelegate.urlNotifier,
          onPushUrlState: widget.routerDelegate.pushUrlState,
          onReplaceUrlState: widget.routerDelegate.replaceUrlState,
        );
      },
    );
  }
}

/// Web Application for User / Surveyor Accounts with Dedicated Page Navigation
class _WebUserHome extends StatefulWidget {
  final ValueListenable<WebUrlState> urlListenable;
  final void Function(WebUrlState next) onPushUrlState;
  final void Function(BuildContext context, WebUrlState next) onReplaceUrlState;

  const _WebUserHome({
    required this.urlListenable,
    required this.onPushUrlState,
    required this.onReplaceUrlState,
  });

  @override
  State<_WebUserHome> createState() => _WebUserHomeState();
}

class _WebUserHomeState extends State<_WebUserHome> {
  late WebShellRoute _activeRoute = widget.urlListenable.value.route;
  late String? _selectedReportId = widget.urlListenable.value.selectedReportId;
  List<PotholeMarker> _potholes = [];
  int _myReportsCount = 0;
  bool _isCloudLoading = true;
  String? _cloudError;
  bool _hasUnsavedProfileChanges = false;
  String _displayName = 'Road Surveyor';
  bool _isEmailVerified = true;
  String _roleLabel = 'Road Surveyor';

  DateTime? _reportsLastUpdatedAt;
  bool _isUsingCachedData = false;

  StreamSubscription<QuerySnapshot>? _potholesSub;
  StreamSubscription<QuerySnapshot>? _myPotholesSub;
  StreamSubscription<DocumentSnapshot>? _userMetaSub;
  final Map<String, Map<String, dynamic>> _approvedDocMap = {};
  final Map<String, Map<String, dynamic>> _userDocMap = {};

  final GlobalKey<MapScreenState> _mapScreenKey = GlobalKey<MapScreenState>();

  @override
  void initState() {
    super.initState();
    widget.urlListenable.addListener(_onRouterUrlChanged);
    CloudService.instance.emailVerifiedNotifier.addListener(
      _onEmailVerifiedChanged,
    );
    _subscribeUserMeta();
    unawaited(CloudService.instance.isEmailVerified());
    unawaited(_loadCachedPotholes());
    _subscribePotholes();
  }

  @override
  void didUpdateWidget(covariant _WebUserHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.urlListenable != widget.urlListenable) {
      oldWidget.urlListenable.removeListener(_onRouterUrlChanged);
      widget.urlListenable.addListener(_onRouterUrlChanged);
      _onRouterUrlChanged();
    }
  }

  @override
  void dispose() {
    CloudService.instance.emailVerifiedNotifier.removeListener(
      _onEmailVerifiedChanged,
    );
    widget.urlListenable.removeListener(_onRouterUrlChanged);
    _potholesSub?.cancel();
    _myPotholesSub?.cancel();
    _userMetaSub?.cancel();
    super.dispose();
  }

  void _onEmailVerifiedChanged() {
    if (!mounted) return;
    final verified = CloudService.instance.emailVerifiedNotifier.value;
    if (verified != _isEmailVerified) {
      setState(() => _isEmailVerified = verified);
    }
  }

  void _onRouterUrlChanged() {
    if (!mounted) return;
    final next = widget.urlListenable.value;
    if (next.route != _activeRoute ||
        next.selectedReportId != _selectedReportId) {
      setState(() {
        _activeRoute = next.route;
        _selectedReportId = next.selectedReportId;
      });
    }
  }

  void _subscribeUserMeta() {
    final user = CloudService.instance.currentUser;
    if (user == null) return;
    final isGoogle = CloudService.instance.isGoogleAuthUser(user);
    _isEmailVerified =
        isGoogle ||
        user.emailVerified ||
        CloudService.instance.emailVerifiedNotifier.value;
    _displayName =
        (user.displayName != null && user.displayName!.trim().isNotEmpty)
        ? user.displayName!.trim()
        : (user.email?.split('@').first ?? 'Road Surveyor');

    _userMetaSub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((doc) {
          if (!mounted) return;
          final data = doc.data() ?? const <String, dynamic>{};
          final first = (data['firstName'] as String? ?? '').trim();
          final last = (data['lastName'] as String? ?? '').trim();
          final combined = '$first $last'.trim();
          final fallbackName =
              (data['displayName'] as String? ?? user.displayName ?? '').trim();
          final resolved = combined.isNotEmpty
              ? combined
              : (fallbackName.isNotEmpty
                    ? fallbackName
                    : (user.email?.split('@').first ?? 'Road Surveyor'));
          final rawRole = (data['role'] as String? ?? 'user').toLowerCase();
          setState(() {
            _displayName = resolved;
            _roleLabel = rawRole == 'admin' || rawRole == 'super_admin'
                ? 'GIS Administrator'
                : 'Road Surveyor';
            final refreshedUser = CloudService.instance.currentUser;
            _isEmailVerified =
                isGoogle ||
                (refreshedUser?.emailVerified ?? user.emailVerified) ||
                CloudService.instance.emailVerifiedNotifier.value;
          });
        });
  }

  Future<void> _loadCachedPotholes() async {
    final snapshot = await RoadReportCache.loadApprovedReports();
    if (!mounted || snapshot == null || _potholes.isNotEmpty) return;
    final restored = snapshot.records
        .where((r) => !r.isResolved)
        .map(
          (r) => PotholeMarker(
            docId: r.docId,
            canonicalDefectId: r.canonicalDefectId,
            location: r.location,
            imagePath: '',
            timestamp: DateTime.fromMillisecondsSinceEpoch(r.updatedAtMs),
            status: r.status,
            isResolved: r.isResolved,
            potholeCount: r.potholeCount,
            primaryDpwhCode: r.primaryDpwhCode,
            primaryDefect: r.primaryDefect,
            barangay: r.barangay,
            city: r.city,
            province: r.province,
            formattedAddress: r.formattedAddress,
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
    if (restored.isEmpty || !mounted) return;
    setState(() {
      _potholes = restored;
      _reportsLastUpdatedAt = snapshot.savedAt;
      _isUsingCachedData = true;
    });
  }

  void _rebuildWebPotholeMarkers({bool fromLiveStream = false}) {
    final currentUser = CloudService.instance.currentUser;
    final merged = <String, Map<String, dynamic>>{}
      ..addAll(_approvedDocMap)
      ..addAll(_userDocMap);
    final cloudPotholes = <PotholeMarker>[];
    final cacheRecords = <CachedReportRecord>[];
    int ownActiveCount = 0;

    for (final entry in merged.entries) {
      final docId = entry.key;
      final data = entry.value;
      try {
        final latNum = data['latitude'];
        final lngNum = data['longitude'];
        if (latNum == null || lngNum == null) continue;
        final lat = (latNum is num)
            ? latNum.toDouble()
            : double.tryParse(latNum.toString());
        final lng = (lngNum is num)
            ? lngNum.toDouble()
            : double.tryParse(lngNum.toString());
        if (lat == null || lng == null) continue;

        final imageUrl = data['imageUrl'] as String? ?? '';
        final status = (data['status'] as String? ?? 'pending')
            .toLowerCase()
            .trim();
        final bool isResolved =
            data['resolved'] == true ||
            data['isResolved'] == true ||
            status == 'resolved' ||
            status == 'fixed' ||
            status == 'closed';
        final bool isAccessible =
            data['isAccessible'] != false && data['accessible'] != false;
        final overallSeverity = (data['overallSeverity'] as String? ?? 'medium')
            .toLowerCase()
            .trim();
        final potholeCount = (data['potholeCount'] as num?)?.toInt() ?? 1;
        final reporterEmail = (data['reporterEmail'] as String? ?? '').trim();
        final reporterUid = (data['reporterUid'] as String? ?? '').trim();

        DateTime timestamp = DateTime.now();
        final rawTimestamp = data['timestamp'];
        if (rawTimestamp is Timestamp) {
          timestamp = rawTimestamp.toDate();
        } else if (rawTimestamp is int) {
          timestamp = DateTime.fromMillisecondsSinceEpoch(rawTimestamp);
        }

        final lastEditedAt = (data['lastEditedAt'] as Timestamp?)?.toDate();
        final moderatedAt = (data['moderatedAt'] as Timestamp?)?.toDate();

        final primaryDpwhCode = data['primaryDpwhCode'] as String? ?? 'CODE 01';
        final primaryDefect = DpwhStandards.reportDefectName(data);
        final defectClass =
            DpwhStandards.classForReport(data) ??
            DpwhStandards.classifyByCode(primaryDpwhCode);
        final responseTime =
            data['responseTime'] as String? ?? defectClass.responseTime;
        final correctiveMeasure =
            data['correctiveMeasure'] as String? ??
            defectClass.correctiveMeasure;
        final detections = DpwhStandards.parseDetectionsWithFallback(data);
        final double? roadBearingDeg =
            (data['roadBearingDeg'] as num?)?.toDouble() ??
            (data['headingDeg'] as num?)?.toDouble() ??
            (data['bearingDeg'] as num?)?.toDouble();
        final bool roadMatched = data['roadMatched'] == true;
        final canonicalDefectId =
            (data['canonicalDefectId'] ??
                    data['clusterId'] ??
                    data['parentReportId'] ??
                    data['physicalPotholeId'])
                ?.toString()
                .trim();
        final roadName = (data['roadName'] ?? data['streetName'])
            ?.toString()
            .trim();

        final bool isMine =
            currentUser != null &&
            ((reporterUid.isNotEmpty && reporterUid == currentUser.uid) ||
                (reporterEmail.isNotEmpty &&
                    currentUser.email != null &&
                    reporterEmail.toLowerCase() ==
                        currentUser.email!.toLowerCase().trim()));

        if (isMine && status != 'deleted') {
          ownActiveCount++;
        }

        if (status == 'deleted' ||
            status == 'rejected' ||
            isResolved ||
            !isAccessible) {
          continue;
        }
        if (status != 'approved' && !isMine) continue;

        final marker = PotholeMarker(
          docId: docId,
          canonicalDefectId: canonicalDefectId,
          location: LatLng(lat, lng),
          imagePath: imageUrl,
          timestamp: timestamp,
          status: status,
          isResolved: isResolved,
          isAccessible: isAccessible,
          overallSeverity: overallSeverity,
          potholeCount: potholeCount,
          reporterEmail: reporterEmail,
          reporterUid: reporterUid,
          primaryDpwhCode: primaryDpwhCode,
          primaryDefect: primaryDefect,
          responseTime: responseTime,
          correctiveMeasure: correctiveMeasure,
          barangay: (data['barangay'] as String? ?? '').trim(),
          city: (data['city'] as String? ?? '').trim(),
          province: (data['province'] as String? ?? '').trim(),
          formattedAddress: (data['formattedAddress'] as String? ?? '').trim(),
          note: (data['note'] as String? ?? '').trim(),
          rejectionReason: (data['rejectionReason'] as String? ?? '').trim(),
          lastEditedAt: lastEditedAt,
          moderatedAt: moderatedAt,
          roadName: roadName,
          detections: detections,
          roadBearingDeg: roadBearingDeg,
          roadMatched: roadMatched,
        );
        cloudPotholes.add(marker);

        if (status == 'approved' && !isResolved) {
          cacheRecords.add(
            CachedReportRecord(
              docId: docId,
              canonicalDefectId: canonicalDefectId,
              latitude: lat,
              longitude: lng,
              primaryDefect: primaryDefect,
              primaryDpwhCode: primaryDpwhCode,
              status: status,
              isResolved: isResolved,
              potholeCount: potholeCount,
              defectClasses: DpwhStandards.extractCachedDefectClasses(
                detections,
                primaryDefect,
              ),
              barangay: marker.barangay,
              city: marker.city,
              province: marker.province,
              formattedAddress: marker.formattedAddress,
              roadName: roadName,
              roadBearingDeg: roadBearingDeg,
              roadMatched: roadMatched,
              updatedAtMs: (moderatedAt ?? lastEditedAt ?? timestamp)
                  .millisecondsSinceEpoch,
            ),
          );
        }
      } catch (docErr) {
        debugPrint('Skipping malformed pothole doc $docId: $docErr');
      }
    }

    if (fromLiveStream) {
      unawaited(RoadReportCache.saveApprovedReports(cacheRecords));
    }

    if (mounted) {
      setState(() {
        _potholes = cloudPotholes;
        _myReportsCount = ownActiveCount;
        _isCloudLoading = false;
        _cloudError = null;
        if (fromLiveStream) {
          _reportsLastUpdatedAt = DateTime.now();
          _isUsingCachedData = false;
        }
      });
    }
  }

  void _subscribePotholes() {
    _potholesSub?.cancel();
    _myPotholesSub?.cancel();
    if (mounted) {
      setState(() {
        _isCloudLoading = true;
        _cloudError = null;
      });
    }
    try {
      // Only stream approved reports + signed-in user's own submissions instead
      // of blindly downloading rejected/deleted/other-user pending records.
      _potholesSub = CloudService.instance.streamApprovedPotholes().listen(
        (snapshot) {
          _approvedDocMap.clear();
          for (final doc in snapshot.docs) {
            final data = doc.data() as Map<String, dynamic>?;
            if (data != null) {
              _approvedDocMap[doc.id] = data;
            }
          }
          _rebuildWebPotholeMarkers(fromLiveStream: true);
        },
        onError: (e) {
          debugPrint('Stream error in _WebUserHome: $e');
          if (mounted) {
            setState(() {
              _isCloudLoading = false;
              if (_potholes.isNotEmpty) {
                _isUsingCachedData = true;
              }
              _cloudError =
                  'Could not sync road reports from cloud. Check your connection and retry.';
            });
          }
        },
      );

      final uid = CloudService.instance.currentUser?.uid;
      if (uid != null && uid.isNotEmpty) {
        _myPotholesSub = CloudService.instance
            .streamUserPotholes(uid)
            .listen(
              (snapshot) {
                _userDocMap.clear();
                for (final doc in snapshot.docs) {
                  final data = doc.data() as Map<String, dynamic>?;
                  if (data != null) {
                    _userDocMap[doc.id] = data;
                  }
                }
                _rebuildWebPotholeMarkers(fromLiveStream: false);
              },
              onError: (e) {
                debugPrint('User reports stream error: $e');
              },
            );
      }
    } catch (e) {
      debugPrint('Error subscribing potholes: $e');
      if (mounted) {
        setState(() {
          _isCloudLoading = false;
          if (_potholes.isNotEmpty) {
            _isUsingCachedData = true;
          }
          _cloudError =
              'Could not initialize road report stream. Check your connection and retry.';
        });
      }
    }
  }

  Future<bool> _confirmDiscardUnsavedProfile() async {
    if (!_hasUnsavedProfileChanges ||
        _activeRoute != WebShellRoute.account ||
        !mounted) {
      return true;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: const Text(
          'You have unsaved edits in your Personal Details form. Leave without saving?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _hasUnsavedProfileChanges = false);
      return true;
    }
    return false;
  }

  Future<void> _navigateToRoute(WebShellRoute route, {String? reportId}) async {
    if (route == _activeRoute && reportId == _selectedReportId) return;
    final canLeave = await _confirmDiscardUnsavedProfile();
    if (!canLeave || !mounted) return;
    final cur = widget.urlListenable.value;
    final nextReportId = route != WebShellRoute.map
        ? null
        : (reportId ?? (route == _activeRoute ? _selectedReportId : null));
    setState(() {
      _activeRoute = route;
      _selectedReportId = nextReportId;
    });
    widget.onPushUrlState(
      WebUrlState(
        route: route,
        selectedReportId: nextReportId,
        lat: route == WebShellRoute.map ? cur.lat : null,
        lng: route == WebShellRoute.map ? cur.lng : null,
        zoom: route == WebShellRoute.map ? cur.zoom : null,
      ),
    );
  }

  void _syncMapViewport(LatLng center, double zoom) {
    if (!mounted || _activeRoute != WebShellRoute.map) return;
    final cur = widget.urlListenable.value;
    if (cur.route != WebShellRoute.map) return;
    widget.onReplaceUrlState(
      context,
      WebUrlState(
        route: WebShellRoute.map,
        selectedReportId: cur.selectedReportId,
        lat: center.latitude,
        lng: center.longitude,
        zoom: zoom,
      ),
    );
  }

  Future<void> _addMarkerFromMap(LatLng location) async {
    final docRef = await CloudService.instance.addPotholeToCloud(
      location: location,
      imageUrl: '',
      overallSeverity: 'medium',
      potholeCount: 1,
    );
    final newMarker = PotholeMarker(
      docId: docRef.id,
      location: location,
      imagePath: '',
      timestamp: DateTime.now(),
      status: 'pending',
      reporterEmail: CloudService.instance.currentUser?.email,
      reporterUid: CloudService.instance.currentUser?.uid,
    );
    if (mounted) {
      setState(() {
        _potholes.add(newMarker);
      });
    }
  }

  void _openHelpDialog() {
    showDialog<void>(context: context, builder: (_) => const WebHelpDialog());
  }

  void _openSettingsDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => WebSettingsDialog(
        onSettingsChanged: () {
          if (mounted) setState(() {});
        },
        onPlacePinOnMap: () => unawaited(_navigateToRoute(WebShellRoute.map)),
      ),
    );
  }

  Future<void> _handleSignOut() async {
    final canLeave = await _confirmDiscardUnsavedProfile();
    if (!canLeave) return;
    await CloudService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final uid = CloudService.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WebAppShellHeader(
            activeRoute: _activeRoute,
            myReportsCount: _myReportsCount,
            displayName: _displayName,
            roleLabel: _roleLabel,
            isVerified: _isEmailVerified,
            isLiveConnected: _cloudError == null,
            onSelectRoute: (route) => unawaited(_navigateToRoute(route)),
            onOpenHelp: _openHelpDialog,
            onOpenSettings: _openSettingsDialog,
            onToggleTheme: () => AppSettings.instance.toggleTheme(!isDark),
            onSignOut: () => unawaited(_handleSignOut()),
          ),
          Expanded(
            child: IndexedStack(
              index: _activeRoute == WebShellRoute.map ? 0 : 1,
              children: [
                MapScreen(
                  key: _mapScreenKey,
                  detectedPotholes: _potholes,
                  onDeleteDetectedPothole: (pothole) async {
                    if (pothole.docId != null && pothole.docId!.isNotEmpty) {
                      await CloudService.instance.userSoftDeletePothole(
                        pothole.docId!,
                      );
                    }
                  },
                  onAddDetectedPothole: _addMarkerFromMap,
                  onOpenProfile: () =>
                      unawaited(_navigateToRoute(WebShellRoute.account)),
                  isMapActive: _activeRoute == WebShellRoute.map,
                  showEmbeddedNavSwitcher: false,
                  currentUid: uid,
                  isAdminUser: false,
                  isCloudLoading: _isCloudLoading,
                  cloudError: _cloudError,
                  onRetryCloud: _subscribePotholes,
                  reportsLastUpdatedAt: _reportsLastUpdatedAt,
                  isUsingCachedData: _isUsingCachedData,
                  initialReportId: _selectedReportId,
                  onSelectedReportChanged: (docId) {
                    if (!mounted || _activeRoute != WebShellRoute.map) return;
                    final cur = widget.urlListenable.value;
                    setState(() => _selectedReportId = docId);
                    widget.onPushUrlState(
                      WebUrlState(
                        route: WebShellRoute.map,
                        selectedReportId: docId,
                        lat: cur.lat,
                        lng: cur.lng,
                        zoom: cur.zoom,
                      ),
                    );
                  },
                  onSyncMapViewport: _syncMapViewport,
                ),
                ProfileScreen(
                  embeddedInShell: true,
                  activeRoute: _activeRoute == WebShellRoute.account
                      ? WebShellRoute.account
                      : WebShellRoute.reports,
                  onNavigateRoute: (route) =>
                      unawaited(_navigateToRoute(route)),
                  onUnsavedChangesChanged: (dirty) {
                    if (mounted && dirty != _hasUnsavedProfileChanges) {
                      setState(() => _hasUnsavedProfileChanges = dirty);
                    }
                  },
                  onOpenHelp: _openHelpDialog,
                  onOpenSettings: _openSettingsDialog,
                  onSwitchToMap: () =>
                      unawaited(_navigateToRoute(WebShellRoute.map)),
                  onLocateOnMap: (location, docId, data) async {
                    await _navigateToRoute(WebShellRoute.map, reportId: docId);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _mapScreenKey.currentState?.locatePothole(
                        location,
                        docId,
                        data,
                      );
                    });
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
