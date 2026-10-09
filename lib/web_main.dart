/// Web-only entry point.
/// This file is completely free of dart:io so Flutter Web does not crash.
library;

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';
import 'firebase_options.dart';
import 'cloud_service.dart';
import 'auth_screen.dart';
import 'admin_dashboard_screen.dart';
import 'web_profile_screen.dart';
import 'web_map_screen.dart';
import 'app_settings.dart';
import 'web_design.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Catch any Flutter framework errors and display them
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e, stack) {
    debugPrint('Firebase initialization error: $e\n$stack');
  }
  runApp(const WebApp());
}

class WebApp extends StatelessWidget {
  const WebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'RoadSense — GIS Platform',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          // The web UI has its own design system (lib/web_design.dart) so it can
          // evolve without touching AppDesign, which the mobile app compiles
          // against. See CLAUDE.md section 1.
          theme: WebDesign.buildTheme(isDark: false),
          darkTheme: WebDesign.buildTheme(isDark: true),
          builder: (context, child) {
            ErrorWidget.builder = (FlutterErrorDetails details) =>
                _FatalErrorScreen(details: details);
            return child ?? const SizedBox.shrink();
          },
          home: StreamBuilder(
            stream: CloudService.instance.authStateChanges,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _SplashLoader();
              }
              final user = snapshot.data;
              if (user == null) {
                return AuthScreen(onAuthSuccess: () {});
              }
              return _RoleRouter(uid: user.uid);
            },
          ),
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
            Container(
              padding: const EdgeInsets.all(WebDesign.space4),
              decoration: BoxDecoration(
                color: WebDesign.brand(isDark),
                borderRadius: BorderRadius.circular(WebDesign.radiusLg),
              ),
              child: Icon(
                Icons.add_road_rounded,
                color: isDark ? const Color(0xFF06283D) : Colors.white,
                size: WebDesign.iconXl,
              ),
            ),
            const SizedBox(height: WebDesign.space5),
            Text(
              'RoadSense',
              style: text.headlineSmall?.copyWith(letterSpacing: -0.2),
            ),
            const SizedBox(height: WebDesign.space1),
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
  const _RoleRouter({required this.uid});

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
        return const _WebUserHome();
      },
    );
  }
}

/// Web Application for User / Surveyor Accounts with Dedicated Page Navigation
class _WebUserHome extends StatefulWidget {
  const _WebUserHome();

  @override
  State<_WebUserHome> createState() => _WebUserHomeState();
}

class _WebUserHomeState extends State<_WebUserHome> {
  int _selectedTab = 0;
  List<PotholeMarker> _potholes = [];
  final GlobalKey<MapScreenState> _mapScreenKey = GlobalKey<MapScreenState>();

  @override
  void initState() {
    super.initState();
    try {
      CloudService.instance.streamAllPotholes().listen((snapshot) {
        final currentUser = CloudService.instance.currentUser;
        final cloudPotholes = <PotholeMarker>[];
        for (final doc in snapshot.docs) {
          try {
            final data = doc.data() as Map<String, dynamic>?;
            if (data == null) continue;
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
            final status =
                (data['status'] as String? ?? 'pending').toLowerCase().trim();
            final overallSeverity =
                (data['overallSeverity'] as String? ?? 'medium')
                    .toLowerCase()
                    .trim();
            final potholeCount = (data['potholeCount'] as num?)?.toInt() ?? 1;
            final reporterEmail =
                (data['reporterEmail'] as String? ?? '').trim();
            final reporterUid = (data['reporterUid'] as String? ?? '').trim();

            DateTime timestamp = DateTime.now();
            final rawTimestamp = data['timestamp'];
            if (rawTimestamp is Timestamp) {
              timestamp = rawTimestamp.toDate();
            } else if (rawTimestamp is int) {
              timestamp = DateTime.fromMillisecondsSinceEpoch(rawTimestamp);
            }

            // Exclude deleted and rejected reports
            if (status == 'deleted' || status == 'rejected') continue;

            // Include if approved live
            if (status == 'approved') {
              cloudPotholes.add(PotholeMarker(
                docId: doc.id,
                location: LatLng(lat, lng),
                imagePath: imageUrl,
                timestamp: timestamp,
                status: status,
                overallSeverity: overallSeverity,
                potholeCount: potholeCount,
                reporterEmail: reporterEmail,
                reporterUid: reporterUid,
              ));
              continue;
            }

            // Include if pending report owned by current user
            if (currentUser != null) {
              final isMyUid =
                  reporterUid.isNotEmpty && reporterUid == currentUser.uid;
              final isMyEmail = reporterEmail.isNotEmpty &&
                  currentUser.email != null &&
                  reporterEmail.toLowerCase() ==
                      currentUser.email!.toLowerCase().trim();
              if (isMyUid || isMyEmail) {
                cloudPotholes.add(PotholeMarker(
                  docId: doc.id,
                  location: LatLng(lat, lng),
                  imagePath: imageUrl,
                  timestamp: timestamp,
                  status: status,
                  overallSeverity: overallSeverity,
                  potholeCount: potholeCount,
                  reporterEmail: reporterEmail,
                  reporterUid: reporterUid,
                ));
              }
            }
          } catch (docErr) {
            debugPrint('Skipping malformed pothole doc ${doc.id}: $docErr');
          }
        }
        if (mounted) setState(() => _potholes = cloudPotholes);
      }, onError: (e) {
        debugPrint('Stream error in _WebUserHome: $e');
      });
    } catch (e) {
      debugPrint('Error loading potholes: $e');
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
      debugPrint('Cloud write note (local fallback used): $e');
    }
    final newMarker = PotholeMarker(
      docId: docId,
      location: location,
      imagePath: '',
      timestamp: DateTime.now(),
      status: 'approved',
      reporterEmail:
          CloudService.instance.currentUser?.email ?? 'web_dev@roadsense.local',
    );
    if (mounted) {
      setState(() {
        _potholes.add(newMarker);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: IndexedStack(
        index: _selectedTab,
        children: [
          MapScreen(
            key: _mapScreenKey,
            detectedPotholes: _potholes,
            onDeleteDetectedPothole: (_) async {},
            onAddDetectedPothole: _addMarkerFromMap,
            onOpenProfile: () => setState(() => _selectedTab = 1),
            isMapActive: _selectedTab == 0,
          ),
          ProfileScreen(
            onSwitchToMap: () => setState(() => _selectedTab = 0),
            onLocateOnMap: (location, docId, data) {
              setState(() => _selectedTab = 0);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _mapScreenKey.currentState?.locatePothole(location, docId, data);
              });
            },
          ),
        ],
      ),
    );
  }
}
