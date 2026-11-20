import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/app_design.dart';
import 'package:my_flutter_app/dpwh_standards.dart';
import 'package:my_flutter_app/developer_markers.dart';
import 'package:my_flutter_app/web_design.dart' as marker_design;
import 'package:my_flutter_app/app_settings.dart';
import 'package:my_flutter_app/map_scale_bar.dart';
import 'package:my_flutter_app/map_screen.dart' as mobile_map;
import 'package:my_flutter_app/mobile_components.dart';
import 'package:my_flutter_app/road_report_cache.dart';
import 'package:my_flutter_app/road_hazard_marker.dart';
import 'package:my_flutter_app/route_pothole_advisor.dart';
import 'package:my_flutter_app/web_design.dart';
import 'package:my_flutter_app/web_map_screen.dart' as web_map;
import 'package:my_flutter_app/web_map_side_panel.dart';
import 'package:my_flutter_app/web_report_query.dart';

// Valid 1x1 transparent PNG for FlutterMap tile requests during widget tests.
final Uint8List _kTransparentPng = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

Map<String, dynamic> _mockOsrmPayload() {
  final primaryCoords = _TestHttpOverrides.useLongCorridorRoute
      ? [
          [120.9575, 14.8197],
          [120.9615, 14.8260],
          [120.9660, 14.8340],
          [120.9739, 14.8427],
          [121.0200, 14.9000],
        ]
      : [
          [120.9575, 14.8197],
          [120.9615, 14.8260],
          [120.9660, 14.8340],
          [120.9739, 14.8427],
        ];
  return <String, dynamic>{
    'code': 'Ok',
    'routes': [
      {
        'distance': _TestHttpOverrides.useLongCorridorRoute ? 11200.0 : 2800.0,
        'duration': _TestHttpOverrides.useLongCorridorRoute ? 900.0 : 240.0,
        'geometry': {'type': 'LineString', 'coordinates': primaryCoords},
        'legs': [
          {
            'summary': 'MacArthur Hwy via Poblacion',
            'steps': [
              {
                'distance': 900.0,
                'duration': 80.0,
                'name': 'MacArthur Highway',
                'maneuver': {
                  'type': 'depart',
                  'modifier': 'straight',
                  'location': [120.9575, 14.8197],
                },
              },
              {
                'distance': 1900.0,
                'duration': 160.0,
                'name': 'Caypombo Bypass',
                'maneuver': {
                  'type': 'arrive',
                  'modifier': '',
                  'location': [120.9739, 14.8427],
                },
              },
            ],
          },
        ],
      },
      {
        'distance': 3400.0,
        'duration': 360.0,
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [120.9575, 14.8197],
            [120.9720, 14.8210],
            [120.9760, 14.8320],
            [120.9739, 14.8427],
          ],
        },
        'legs': [
          {
            'summary': 'Sta. Maria Eastern Bypass',
            'steps': [
              {
                'distance': 1600.0,
                'duration': 170.0,
                'name': 'Eastern Bypass Rd',
                'maneuver': {
                  'type': 'turn',
                  'modifier': 'right',
                  'location': [120.9575, 14.8197],
                },
              },
              {
                'distance': 1800.0,
                'duration': 190.0,
                'name': 'Caypombo Access Rd',
                'maneuver': {
                  'type': 'arrive',
                  'modifier': '',
                  'location': [120.9739, 14.8427],
                },
              },
            ],
          },
        ],
      },
    ],
  };
}

class _TestHttpOverrides extends HttpOverrides {
  static bool failOsrmRequests = false;
  static bool useLongCorridorRoute = false;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpRequest(url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest(url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _FakeHttpRequest(url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this.uri);
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _FakeHttpHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  int contentLength = -1;

  @override
  void add(List<int> data) {}
  @override
  void write(Object? object) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<HttpClientResponse> close() async {
    final host = uri.host.toLowerCase();
    if (host.contains('router.project-osrm.org') ||
        host.contains('routing.openstreetmap.de')) {
      if (_TestHttpOverrides.failOsrmRequests) {
        return _FakeHttpResponse(503, utf8.encode('{}'), 'application/json');
      }
      final bytes = utf8.encode(jsonEncode(_mockOsrmPayload()));
      return _FakeHttpResponse(200, bytes, 'application/json');
    }
    if (host.contains('nominatim.openstreetmap.org') &&
        uri.path.contains('reverse')) {
      final bytes = utf8.encode(
        jsonEncode(<String, dynamic>{
          'name': 'Caypombo Highway',
          'display_name': 'Caypombo Highway, Caypombo, Santa Maria, Bulacan',
          'address': <String, dynamic>{
            'road': 'Caypombo Highway',
            'village': 'Caypombo',
            'town': 'Santa Maria',
          },
        }),
      );
      return _FakeHttpResponse(200, bytes, 'application/json');
    }
    if (host.contains('tile.openstreetmap.org') ||
        host.contains('arcgisonline') ||
        host.contains('basemaps') ||
        host.contains('mt1.google')) {
      return _FakeHttpResponse(200, _kTransparentPng, 'image/png');
    }
    return _FakeHttpResponse(200, utf8.encode('{}'), 'application/json');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpResponse(this.statusCode, this._body, this._mime);
  @override
  final int statusCode;
  final List<int> _body;
  final String _mime;

  @override
  int get contentLength => _body.length;
  @override
  HttpHeaders get headers => _FakeResponseHeaders(_mime);
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const <RedirectInfo>[];
  @override
  List<Cookie> get cookies => const <Cookie>[];
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => 'OK';
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_body]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponseHeaders implements HttpHeaders {
  _FakeResponseHeaders(this._mime);
  final String _mime;
  @override
  ContentType? get contentType => ContentType.parse(_mime);
  @override
  void forEach(void Function(String name, List<String> values) action) {
    action(HttpHeaders.contentTypeHeader, <String>[_mime]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> ttsSpoken = [];

  setUpAll(() async {
    HttpOverrides.global = _TestHttpOverrides();
  });

  setUp(() {
    ttsSpoken.clear();
    _TestHttpOverrides.failOsrmRequests = false;
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.sampleStaMariaPotholesNotifier.value = false;
    AppSettings.instance.mobileVoiceAlertsEnabled = true;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async {
        switch (call.method) {
          case 'isLocationServiceEnabled':
            return true;
          case 'checkPermission':
          case 'requestPermission':
            return 3; // whileInUse
          case 'getLastKnownPosition':
          case 'getCurrentPosition':
            return <String, dynamic>{
              'latitude': 14.8197,
              'longitude': 120.9575,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'accuracy': 8.0,
              'altitude': 12.0,
              'heading': 0.0,
              'speed': 8.0,
              'speed_accuracy': 1.0,
            };
          default:
            return null;
        }
      },
    );

    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
      call,
    ) async {
      if (call.method == 'speak') {
        ttsSpoken.add(call.arguments?.toString() ?? '');
      }
      return 1;
    });

    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => ['wifi'],
    );
  });

  List<mobile_map.PotholeMarker> buildMobileMarkers() {
    final now = DateTime.now();
    return [
      // Approved pothole along Route 1 (~700m north of Poblacion along Route 1)
      mobile_map.PotholeMarker(
        docId: 'mob-r1-p1',
        location: const LatLng(14.8260, 120.9615),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Poblacion',
      ),
      mobile_map.PotholeMarker(
        docId: 'mob-r1-p2',
        location: const LatLng(14.8340, 120.9660),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Guyong',
      ),
      // Duplicate canonical report for mob-r1-p2 -> must NOT inflate pothole count
      mobile_map.PotholeMarker(
        docId: 'mob-r1-p2-dup',
        canonicalDefectId: 'mob-r1-p2',
        location: const LatLng(14.83401, 120.96601),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Guyong',
      ),
      // Non-pothole crack on Route 1 -> separated under Other defects
      mobile_map.PotholeMarker(
        docId: 'mob-r1-crack',
        location: const LatLng(14.8295, 120.9635),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Alligator crack',
        primaryDpwhCode: 'CODE 04',
        barangay: 'Guyong',
      ),
      // Resolved pothole -> excluded
      mobile_map.PotholeMarker(
        docId: 'mob-r1-resolved',
        location: const LatLng(14.8230, 120.9595),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        isResolved: true,
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
      ),
    ];
  }

  List<web_map.PotholeMarker> buildWebMarkers() {
    final now = DateTime.now();
    return [
      web_map.PotholeMarker(
        docId: 'web-r1-p1',
        location: const LatLng(14.8260, 120.9615),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Poblacion',
      ),
      web_map.PotholeMarker(
        docId: 'web-r1-p2',
        location: const LatLng(14.8340, 120.9660),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Guyong',
      ),
      web_map.PotholeMarker(
        docId: 'web-r1-crack',
        location: const LatLng(14.8295, 120.9635),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Edge break',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Guyong',
      ),
    ];
  }

  testWidgets(
    'live maps exclude built-in samples and gate local developer markers',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      AppSettings.instance.toggleSampleStaMariaPotholes(true);
      AppSettings.instance.toggleDevMockMode(false);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppSettings.instance.toggleSampleStaMariaPotholes(false);
        AppSettings.instance.toggleDevMockMode(false);
      });
      const id = '${DeveloperMarkers.prefix}regression';
      await DeveloperMarkers.instance.save(
        const DeveloperMarker(id, LatLng(14.829, 120.9635), 'Alligator crack'),
      );
      var cloudWrites = 0;
      for (final web in [false, true]) {
        final screen = web
            ? web_map.MapScreen(
                detectedPotholes: [
                  web_map.PotholeMarker(
                    docId: 'sample_sta_maria_legacy',
                    location: const LatLng(14.829, 120.9635),
                    imagePath: '',
                    timestamp: DateTime(2026),
                  ),
                ],
                onAddDetectedPothole: (_) async {
                  cloudWrites++;
                },
              )
            : mobile_map.MapScreen(
                detectedPotholes: [
                  mobile_map.PotholeMarker(
                    docId: 'sample_sta_maria_legacy',
                    location: const LatLng(14.829, 120.9635),
                    imagePath: '',
                    timestamp: DateTime(2026),
                  ),
                ],
                onAddDetectedPothole: (_) async {
                  cloudWrites++;
                },
              );
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
        await _pumpFrames(tester, count: 6);
        final controller = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        controller.move(const LatLng(14.829, 120.9635), 15);
        await _pumpFrames(tester, count: 4);
        expect(
          find.byKey(const ValueKey('detected_sample_sta_maria_legacy')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('detected_$id')), findsNothing);
        expect(find.byTooltip('Custom markers (local)'), findsNothing);
        AppSettings.instance.toggleDevMockMode(true);
        await _pumpFrames(tester, count: 4);
        expect(find.byKey(const ValueKey('detected_$id')), findsOneWidget);
        expect(
          find.byTooltip('Custom markers (local)').hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Custom markers (local)'));
        await _pumpFrames(tester, count: 6);
        expect(find.text('Developer custom markers'), findsOneWidget);
        final choices = tester.widget<DropdownButton<String>>(
          find.descendant(
            of: find.byKey(const ValueKey('developer-defect-null')),
            matching: find.byType(DropdownButton<String>),
          ),
        );
        expect(choices.items!.length, 4);
        await tester.tap(find.text('Cancel'));
        await _pumpFrames(tester, count: 6);
        AppSettings.instance.toggleDevMockMode(false);
        await _pumpFrames(tester, count: 4);
        expect(find.byKey(const ValueKey('detected_$id')), findsNothing);
        expect(find.byTooltip('Custom markers (local)'), findsNothing);
        expect(cloudWrites, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpFrames(tester, count: 2);
      }
      await DeveloperMarkers.instance.remove(id);
    },
  );

  testWidgets('individual mobile and web pins use each report defect class', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    AppSettings.instance.toggleSampleStaMariaPotholes(false);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      AppSettings.instance.toggleSampleStaMariaPotholes(true);
    });
    final classes = DpwhStandards.allClasses;
    for (final web in [false, true]) {
      final screen = web
          ? web_map.MapScreen(
              detectedPotholes: [
                for (var i = 0; i < classes.length; i++)
                  web_map.PotholeMarker(
                    docId: 'class_$i',
                    location: LatLng(14.826 + i * .002, 120.9635),
                    imagePath: '',
                    timestamp: DateTime(2026),
                    primaryDefect: classes[i].name,
                    primaryDpwhCode: classes[i].code,
                  ),
              ],
            )
          : mobile_map.MapScreen(
              detectedPotholes: [
                for (var i = 0; i < classes.length; i++)
                  mobile_map.PotholeMarker(
                    docId: 'class_$i',
                    location: LatLng(14.826 + i * .002, 120.9635),
                    imagePath: '',
                    timestamp: DateTime(2026),
                    primaryDefect: classes[i].name,
                    primaryDpwhCode: classes[i].code,
                  ),
              ],
            );
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
      await _pumpFrames(tester, count: 6);
      final controller = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!;
      controller.move(const LatLng(14.829, 120.9635), 14);
      await _pumpFrames(tester, count: 4);
      for (var i = 0; i < classes.length; i++) {
        final marker = find.byKey(ValueKey('detected_class_$i'));
        expect(marker, findsOneWidget);
        expect(
          find.descendant(of: marker, matching: find.byType(RoadHazardMarker)),
          findsOneWidget,
        );
        final circles = tester
            .widgetList<Container>(
              find.descendant(of: marker, matching: find.byType(Container)),
            )
            .where(
              (container) =>
                  container.decoration is BoxDecoration &&
                  (container.decoration as BoxDecoration).shape ==
                      BoxShape.circle,
            );
        expect(circles, hasLength(1));
        final decoration = circles.single.decoration as BoxDecoration;
        expect(
          (decoration.border as Border).top.color,
          MobileDefectHelper.foregroundColor(classes[i], false),
        );
        expect(
          find.descendant(
            of: marker,
            matching: find.byIcon(
              marker_design.WebDesign.defectIcon(classes[i]),
            ),
          ),
          findsOneWidget,
        );
      }
      for (final zoom in [14.0, 14.25, 15.0]) {
        controller.move(const LatLng(14.829, 120.9635), zoom);
        await _pumpFrames(tester, count: 4);
        final pin = find.descendant(
          of: find.byKey(const ValueKey('detected_class_0')),
          matching: find.byType(RoadHazardMarker),
        );
        expect(
          tester.getSize(pin).width,
          closeTo(RoadHazardMarker.sizeForZoom(zoom), .01),
          reason: 'Rendered ${web ? "web" : "mobile"} pin follows camera zoom',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpFrames(tester, count: 2);
    }
  });

  for (final dismissal in [
    'close',
    'swipe left',
    'swipe right',
    'close after timeout',
  ]) {
    testWidgets('Mobile pothole warning $dismissal does not rebuild the map', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      mobile_map.PotholeMarker nearbyMarker(double latitude) =>
          mobile_map.PotholeMarker(
            docId: 'nearby-warning',
            location: LatLng(latitude, 120.9575),
            imagePath: '',
            timestamp: DateTime(2026),
            status: 'approved',
            primaryDefect: 'Pothole',
            primaryDpwhCode: 'CODE 01',
          );
      Widget mapWith(mobile_map.PotholeMarker marker) => MaterialApp(
        theme: AppDesign.buildTheme(isDark: false),
        home: Scaffold(body: mobile_map.MapScreen(detectedPotholes: [marker])),
      );
      final marker = nearbyMarker(14.81975); // About 6 m from mocked GPS.
      await tester.pumpWidget(mapWith(marker));
      await _pumpFrames(tester, count: 30);
      expect(find.text('Pothole ahead'), findsOneWidget);

      final mapBefore = tester.widget<FlutterMap>(find.byType(FlutterMap));
      final centerBefore = mapBefore.mapController!.camera.center;
      // A touch must not rebuild the map just to change a desktop mouse cursor.
      final touch = await tester.startGesture(
        tester.getRect(find.byType(FlutterMap)).center + const Offset(-90, 80),
      );
      await tester.pump();
      expect(
        tester.widget<FlutterMap>(find.byType(FlutterMap)),
        same(mapBefore),
      );
      await touch.cancel();
      await tester.pump();
      expect(
        tester.widget<FlutterMap>(find.byType(FlutterMap)),
        same(mapBefore),
      );
      if (dismissal == 'close after timeout') {
        await tester.pump(const Duration(seconds: 9));
        await tester.pump();
        expect(
          tester.widget<FlutterMap>(find.byType(FlutterMap)),
          same(mapBefore),
        );
      }
      if (dismissal.startsWith('swipe')) {
        await tester.drag(
          find.text('Pothole ahead'),
          Offset(dismissal == 'swipe left' ? -180 : 180, 0),
        );
      } else {
        await tester.tap(find.bySemanticsLabel('Dismiss pothole warning'));
      }
      await tester.pump();
      expect(find.text('Pothole ahead'), findsNothing);
      // Identity proves dismissal didn't recreate the tile/marker/route tree.
      expect(
        tester.widget<FlutterMap>(find.byType(FlutterMap)),
        same(mapBefore),
      );

      // Parent rebuilds must not bring this encounter back.
      expect(mapBefore.mapController!.camera.center, centerBefore);
      await tester.pumpWidget(mapWith(marker));
      await _pumpFrames(tester);
      expect(find.text('Pothole ahead'), findsNothing);
      // A different nearby location is still allowed to warn.
      await tester.pumpWidget(mapWith(nearbyMarker(14.8198)));
      await _pumpFrames(tester);
      expect(find.text('Pothole ahead'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
  }

  testWidgets(
    'Mobile MapScreen renders Selected route summary, Compare routes sheet, and upper driving alert with mute toggle',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      AppSettings.instance.toggleSampleStaMariaPotholes(false);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppSettings.instance.mobileVoiceAlertsEnabled = true;
        AppSettings.instance.toggleSampleStaMariaPotholes(true);
      });

      final updatedAt = DateTime.now().subtract(const Duration(minutes: 3));

      await tester.pumpWidget(
        MaterialApp(
          theme: AppDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: mobile_map.MapScreen(
              detectedPotholes: buildMobileMarkers(),
              reportsLastUpdatedAt: updatedAt,
              routeCorridorMeters: RouteCorridorConfig.defaultCorridorMeters,
            ),
          ),
        ),
      );
      await _pumpFrames(tester, count: 6);

      // Open A-to-B Route Planner
      await tester.tap(find.byTooltip('Directions (Point A to B)'));
      await _pumpFrames(tester, count: 5);

      // Ensure horizontally scrollable preset chip is visible before tapping
      final caypomboChip = find.text('Brgy. Caypombo');
      await tester.ensureVisible(caypomboChip);
      await _pumpFrames(tester, count: 2);
      await tester.tap(caypomboChip);
      await _pumpFrames(tester, count: 10);

      // Verify Selected route dock copy, counts, separated defects, and CTAs
      expect(find.text('Selected route'), findsOneWidget);
      expect(find.textContaining('2 reported potholes'), findsWidgets);
      expect(find.textContaining('3 min ago'), findsOneWidget);
      expect(find.textContaining('Other defects along route:'), findsOneWidget);
      expect(find.text('Find fewer potholes'), findsOneWidget);
      expect(find.textContaining('Compare routes'), findsOneWidget);
      expect(find.text('Start driving'), findsOneWidget);

      // Open Compare routes bottom sheet -> verify Fastest & Fewer reported potholes options
      final compareBtn = find.textContaining('Compare routes');
      await tester.ensureVisible(compareBtn);
      await _pumpFrames(tester, count: 2);
      await tester.tap(compareBtn);
      await _pumpFrames(tester, count: 8);

      expect(find.text('Compare routes'), findsWidgets);
      expect(find.text('Fastest'), findsWidgets);
      expect(find.text('Fewer reported potholes'), findsWidgets);
      expect(find.textContaining('2 fewer reported potholes'), findsOneWidget);

      // Select the safer alternative inside Compare routes bottom sheet
      await tester.tap(find.text('Fewer reported potholes').last);
      await _pumpFrames(tester, count: 6);
      expect(
        find.textContaining('No reported potholes along this route'),
        findsOneWidget,
      );

      // Re-open Compare routes to select Fastest (Route 1) so Start driving enters an active pothole route
      await tester.tap(find.textContaining('Compare routes'));
      await _pumpFrames(tester, count: 6);
      await tester.tap(find.text('Fastest').last);
      await _pumpFrames(tester, count: 6);
      expect(find.textContaining('2 reported potholes'), findsWidgets);

      // The marker should follow a viewport gesture even when the map rotates.
      final controller = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!;
      for (final endpoint in ['A', 'B']) {
        final marker = tester
            .widgetList<MarkerLayer>(find.byType(MarkerLayer))
            .expand((layer) => layer.markers)
            .firstWhere(
              (marker) =>
                  marker.key ==
                  ValueKey('endpoint_pin_${endpoint == 'A' ? 1 : 2}'),
            );
        controller.move(marker.point, 15);
        await _pumpFrames(tester, count: 2);
        for (final bearing in [0.0, 90.0, 180.0, 270.0, 45.0]) {
          controller.rotate(bearing);
          await _pumpFrames(tester, count: 2);
          final pin = find.text(endpoint).last;
          final before = tester.getCenter(pin);
          final gesture = await tester.startGesture(before);
          await gesture.moveBy(const Offset(18, 12));
          await _pumpFrames(tester, count: 2);
          final after = tester.getCenter(pin);
          expect((after - before - const Offset(18, 12)).distance, lessThan(6));
          await gesture.up();
          await _pumpFrames(tester, count: 2);
        }
      }

      // Start driving -> one green header carries the next hazard distance.
      await tester.tap(find.text('Start driving'));
      await _pumpFrames(tester, count: 6);

      expect(find.text('Pothole ahead'), findsNothing);
      expect(find.textContaining('Next pothole:'), findsOneWidget);
      expect(find.byTooltip('Mute voice alerts'), findsOneWidget);

      // Tap Mute toggle -> icon flips to unmute & setting flips false
      await tester.tap(find.byTooltip('Mute voice alerts'));
      await _pumpFrames(tester, count: 3);
      expect(AppSettings.instance.mobileVoiceAlertsEnabled, isFalse);
      expect(find.byTooltip('Unmute voice alerts'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Web MapScreen mounts cleanly and WebMapWorkspacePanel route planning renders comparison across desktop & narrow viewports',
    (tester) async {
      final updatedAt = DateTime.now().subtract(const Duration(minutes: 2));
      final markers = buildWebMarkers();

      // 1. Verify Web MapScreen mounts & resizes cleanly at 1440x900 and <900px without throwing.
      // Note: WebMapScreen gates the desktop workspace panel on kIsWeb (false on Dart VM),
      // so full interactive route-planner rendering is verified below via WebMapWorkspacePanel.
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: WebDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: web_map.MapScreen(
              detectedPotholes: markers,
              reportsLastUpdatedAt: updatedAt,
            ),
          ),
        ),
      );
      await _pumpFrames(tester, count: 4);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(390, 844);
      await _pumpFrames(tester, count: 4);
      expect(tester.takeException(), isNull);

      // 2. Evaluate real alternative routes with RoutePotholeAdvisor and render inside WebMapWorkspacePanel
      final advisorReports = markers
          .map(
            (m) => RouteHazardInput(
              reportId: m.docId,
              canonicalDefectId: m.canonicalDefectId,
              location: m.location,
              status: m.status,
              isResolved: m.isResolved,
              defectName: m.primaryDefect,
              dpwhCode: m.primaryDpwhCode,
              barangay: m.barangay,
            ),
          )
          .toList();

      final route1 = const [
        LatLng(14.8197, 120.9575),
        LatLng(14.8260, 120.9615),
        LatLng(14.8340, 120.9660),
        LatLng(14.8427, 120.9739),
      ];
      final route2 = const [
        LatLng(14.8197, 120.9575),
        LatLng(14.8210, 120.9720),
        LatLng(14.8320, 120.9760),
        LatLng(14.8427, 120.9739),
      ];

      final comparison = RoutePotholeAdvisor.evaluateAlternatives(
        routes: [route1, route2],
        distancesMeters: const [2800.0, 3400.0],
        durationsSeconds: const [240.0, 360.0],
        hazards: advisorReports,
      );

      final singleRouteResult = RoutePotholeAdvisor.evaluateAlternatives(
        routes: [route1],
        distancesMeters: const [2800.0],
        durationsSeconds: const [240.0],
        hazards: advisorReports,
      );
      expect(
        singleRouteResult.statusMessage,
        contains('No route with fewer reported potholes was found'),
      );

      final ctrl = TextEditingController();
      final focus = FocusNode();
      addTearDown(ctrl.dispose);
      addTearDown(focus.dispose);

      Widget buildPlannerPanel(
        Size viewport,
        double panelWidth,
        double panelHeight,
      ) {
        var selectedIdx = 0;
        var showPotholesAlongRoute = false;
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final active = comparison.options[selectedIdx];
            final count = active.summary.distinctPotholeCount;
            final kmStr = (active.summary.distanceMeters / 1000.0)
                .toStringAsFixed(1);
            final minStr = (active.summary.durationSeconds / 60.0).round();
            final summaryText = count == 0
                ? 'No reported potholes along this route · $kmStr km · $minStr min'
                : '$kmStr km · $minStr min · $count reported potholes';

            return SizedBox(
              width: panelWidth,
              height: panelHeight,
              child: WebMapWorkspacePanel(
                searchController: ctrl,
                searchFocusNode: focus,
                searchQuery: '',
                isSearchingPlaces: false,
                isSearchHistoryOpen: false,
                unifiedSuggestions: const [],
                highlightedSuggestionIndex: -1,
                searchHistory: const [],
                searchedPlace: null,
                nearbyPlaceHazardCount: 0,
                onClearSearchedPlace: () {},
                onDirectionsToPlace: (_) {},
                filter: const WebReportFilter(statuses: {'approved'}),
                onFilterChanged: (_) {},
                isFilterDrawerOpen: false,
                onToggleFilterDrawer: () {},
                onOpenBarangayPicker: () {},
                queryResult: const WebReportQueryResult(
                  items: [],
                  totalDatasetCount: 3,
                ),
                visibleResultLimit: 25,
                onLoadMoreResults: () {},
                selectedReport: null,
                onSelectReport: (_) {},
                onBackToResults: () {},
                currentUid: null,
                isAdminUser: false,
                hasUserLocation: true,
                isCloudLoading: false,
                cloudError: null,
                onRetryCloud: () {},
                onOpenRoutePlanner: () {},
                isRoutePlanningMode: true,
                routePlannerContent: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Selected route',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(summaryText),
                      Text(RoadReportCache.formatDataUpdatedLabel(updatedAt)),
                      if (active.summary.otherDefectCounts.isNotEmpty)
                        Text(
                          'Other defects along route: ${active.summary.totalOtherDefectsCount} '
                          '(${active.summary.otherDefectsSummary})',
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton(
                            onPressed: comparison.preferredSaferOption != null
                                ? () => setLocalState(
                                    () => selectedIdx = comparison.options
                                        .indexWhere(
                                          (o) =>
                                              o.routeIndex ==
                                              comparison
                                                  .preferredSaferOption!
                                                  .routeIndex,
                                        ),
                                  )
                                : null,
                            child: const Text('Find fewer potholes'),
                          ),
                          FilterChip(
                            label: const Text('Show potholes along route'),
                            selected: showPotholesAlongRoute,
                            onSelected: (v) =>
                                setLocalState(() => showPotholesAlongRoute = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      for (var i = 0; i < comparison.options.length; i++)
                        Material(
                          type: MaterialType.transparency,
                          child: ListTile(
                            dense: true,
                            title: Text(comparison.options[i].roleLabel),
                            subtitle: Text(
                              comparison.options[i].tradeoffExplanation,
                            ),
                            trailing: Text(
                              '${comparison.options[i].summary.distinctPotholeCount}',
                            ),
                            onTap: () => setLocalState(() => selectedIdx = i),
                          ),
                        ),
                      if (showPotholesAlongRoute)
                        for (final enc in active.summary.potholeEncounters)
                          Text(
                            enc.hazard.barangay.isNotEmpty
                                ? enc.hazard.barangay
                                : (enc.hazard.reportId ?? ''),
                          ),
                    ],
                  ),
                ),
                onSearchChanged: (_) {},
                onSubmitSearch: () {},
                onClearSearch: () {},
                onSelectSuggestion: (_) {},
                onSelectHistoryItem: (_) {},
                onRemoveHistoryItem: (_) {},
                onClearHistory: () {},
                onMoveSuggestionHighlight: (_) {},
                onCenterReportOnMap: (_) {},
                onDirectionsToReport: (_) {},
                onViewFullPhoto: (_) {},
              ),
            );
          },
        );
      }

      // Desktop 1440x900 side panel width (400px)
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpWidget(
        MaterialApp(
          theme: WebDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: buildPlannerPanel(const Size(1440, 900), 400, 820),
          ),
        ),
      );
      await _pumpFrames(tester, count: 4);

      expect(find.text('Selected route'), findsOneWidget);
      expect(find.textContaining('2 reported potholes'), findsOneWidget);
      expect(find.textContaining('2 min ago'), findsOneWidget);
      expect(find.textContaining('Other defects along route:'), findsOneWidget);
      expect(find.text('Find fewer potholes'), findsOneWidget);
      expect(find.text('Show potholes along route'), findsOneWidget);
      expect(find.text('Fastest'), findsOneWidget);
      expect(find.text('Fewer reported potholes'), findsOneWidget);

      await tester.tap(find.text('Show potholes along route'));
      await _pumpFrames(tester, count: 3);
      expect(find.text('Poblacion'), findsOneWidget);

      await tester.tap(find.text('Find fewer potholes'));
      await _pumpFrames(tester, count: 3);
      expect(
        find.textContaining('No reported potholes along this route'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Narrow <900px compact bottom drawer viewport (390x844)
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(
        MaterialApp(
          theme: WebDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: buildPlannerPanel(const Size(390, 844), 390, 420),
          ),
        ),
      );
      await _pumpFrames(tester, count: 4);
      expect(find.text('Selected route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mobile MapScreen includes corridorReportFetcher off-viewport reports, updates counts when reports are added/resolved, and preserves active route on reroute failure',
    (tester) async {
      final now = DateTime.now();
      final p1 = mobile_map.PotholeMarker(
        docId: 'mob-r1-p1',
        location: const LatLng(14.8260, 120.9615),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Poblacion',
      );
      final p2Corridor = mobile_map.PotholeMarker(
        docId: 'corridor-p2',
        location: const LatLng(14.8340, 120.9660),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Guyong',
      );
      final p3Between = mobile_map.PotholeMarker(
        docId: 'mob-r1-p3',
        location: const LatLng(
          14.8299,
          120.9637,
        ), // midpoint along (14.8260,120.9615)->(14.8340,120.9660)
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Guyong',
      );

      bool corridorResolved = false;
      Future<List<mobile_map.PotholeMarker>> fetchCorridor({
        required double minLat,
        required double maxLat,
        required double minLon,
        required double maxLon,
      }) async {
        expect(minLat, lessThan(maxLat));
        expect(minLon, lessThan(maxLon));
        if (corridorResolved) return const [];
        return [p2Corridor];
      }

      Widget buildApp(List<mobile_map.PotholeMarker> markers) {
        return MaterialApp(
          theme: AppDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: mobile_map.MapScreen(
              detectedPotholes: markers,
              corridorReportFetcher: fetchCorridor,
              reportsLastUpdatedAt: now,
              routeCorridorMeters: RouteCorridorConfig.defaultCorridorMeters,
            ),
          ),
        );
      }

      // 1. Initial load: 1 widget marker + 1 off-viewport corridor fetcher marker -> 2 reported potholes
      await tester.pumpWidget(buildApp([p1]));
      await _pumpFrames(tester, count: 6);

      await tester.tap(find.byTooltip('Directions (Point A to B)'));
      await _pumpFrames(tester, count: 5);

      final caypomboChip = find.text('Brgy. Caypombo');
      await tester.ensureVisible(caypomboChip);
      await _pumpFrames(tester, count: 2);
      await tester.tap(caypomboChip);
      await _pumpFrames(tester, count: 10);

      expect(find.text('Selected route'), findsOneWidget);
      expect(find.textContaining('2 reported potholes'), findsWidgets);

      // 2. New approved report arrives in widget tree -> count refreshes to 3
      await tester.pumpWidget(buildApp([p1, p3Between]));
      await _pumpFrames(tester, count: 6);
      expect(find.textContaining('3 reported potholes'), findsWidgets);

      // 3. Report p1 and corridor-p2 are marked resolved -> count drops from 3 to 1 (p3Between only)
      corridorResolved = true;
      final p1Resolved = mobile_map.PotholeMarker(
        docId: 'mob-r1-p1',
        location: p1.location,
        imagePath: '',
        timestamp: now.add(const Duration(seconds: 5)),
        status: 'approved',
        isResolved: true,
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Poblacion',
      );
      await tester.pumpWidget(buildApp([p1Resolved, p3Between]));
      await _pumpFrames(tester, count: 6);
      expect(find.textContaining('1 reported pothole'), findsWidgets);

      // 4. Route recalculation failure (switching to Walk while OSRM fails) preserves active route & summary
      _TestHttpOverrides.failOsrmRequests = true;
      final walkTab = find.text('Walk');
      await tester.ensureVisible(walkTab);
      await _pumpFrames(tester, count: 2);
      await tester.tap(walkTab);
      await _pumpFrames(tester, count: 8);

      expect(
        find.textContaining(
          'Unable to calculate route right now. Active route preserved.',
        ),
        findsWidgets,
      );
      expect(find.text('Selected route'), findsOneWidget);
      expect(find.textContaining('1 reported pothole'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'RouteBoundingBox viewport buffer and refresh threshold cover panning and A-to-B camera fits',
    () {
      const initialView = RouteBoundingBox(
        minLat: 14.81,
        maxLat: 14.83,
        minLon: 120.95,
        maxLon: 120.97,
      );
      // Marker within the 0.02 deg viewport buffer stays rendered; far marker is culled.
      expect(
        initialView.containsWithMargin(const LatLng(14.845, 120.960)),
        isTrue,
      );
      expect(
        initialView.containsWithMargin(const LatLng(14.895, 121.015)),
        isFalse,
      );

      // Small pan inside refresh padding (0.012 deg) needs no rebuild.
      const minorPan = RouteBoundingBox(
        minLat: 14.814,
        maxLat: 14.834,
        minLon: 120.954,
        maxLon: 120.974,
      );
      expect(initialView.needsViewportRefresh(minorPan), isFalse);

      // Long Point A-to-B camera fit outside buffer triggers a marker refresh.
      const routeFitView = RouteBoundingBox(
        minLat: 14.81,
        maxLat: 14.90,
        minLon: 120.95,
        maxLon: 121.02,
      );
      expect(initialView.needsViewportRefresh(routeFitView), isTrue);
      expect(
        routeFitView.containsWithMargin(const LatLng(14.895, 121.015)),
        isTrue,
      );
    },
  );

  testWidgets(
    'Web MapScreen keeps pothole markers visible during Point A to B routing even when destination text differs from report barangays',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      AppSettings.instance.toggleSampleStaMariaPotholes(false);
      _TestHttpOverrides.useLongCorridorRoute = true;
      addTearDown(() {
        _TestHttpOverrides.useLongCorridorRoute = false;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppSettings.instance.toggleSampleStaMariaPotholes(true);
      });

      final now = DateTime.now();
      final farNorthMarker = web_map.PotholeMarker(
        docId: 'web-far-p3',
        location: const LatLng(14.8950, 121.0150),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Bulac',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: WebDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: web_map.MapScreen(
              detectedPotholes: [...buildWebMarkers(), farNorthMarker],
              reportsLastUpdatedAt: now,
            ),
          ),
        ),
      );
      await _pumpFrames(tester, count: 6);

      // Nearby markers render on initial load; far north marker (>0.07 deg away) is culled.
      expect(find.byKey(const ValueKey('detected_web-r1-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('detected_web-r1-p2')), findsOneWidget);
      expect(find.byKey(const ValueKey('detected_web-far-p3')), findsNothing);

      // Tap empty map canvas to open tapped-point pill, then tap Directions (Point A -> B).
      final mapCenter = tester.getCenter(find.byType(FlutterMap));
      await tester.tapAt(mapCenter + const Offset(80, -80));
      await _pumpFrames(tester, count: 6);

      final directionsBtn = find.text('Directions');
      expect(directionsBtn, findsOneWidget);
      await tester.tap(directionsBtn);
      await _pumpFrames(tester, count: 12);

      // Previously, _searchController held the destination label/coords and wiped out
      // non-matching report markers, and _fitCameraToRoute left out-of-viewport pins culled.
      expect(find.byKey(const ValueKey('detected_web-r1-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('detected_web-r1-p2')), findsOneWidget);
      expect(find.byKey(const ValueKey('detected_web-far-p3')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mobile MapScreen refreshes viewport-culled pothole markers when Point A to B fits a long route',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      AppSettings.instance.toggleSampleStaMariaPotholes(false);
      _TestHttpOverrides.useLongCorridorRoute = true;
      addTearDown(() {
        _TestHttpOverrides.useLongCorridorRoute = false;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppSettings.instance.toggleSampleStaMariaPotholes(true);
      });

      final now = DateTime.now();
      final farNorthMarker = mobile_map.PotholeMarker(
        docId: 'mob-far-p3',
        location: const LatLng(14.8950, 121.0150),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        primaryDefect: 'Pothole',
        primaryDpwhCode: 'CODE 01',
        barangay: 'Bulac',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: mobile_map.MapScreen(
              detectedPotholes: [...buildMobileMarkers(), farNorthMarker],
              reportsLastUpdatedAt: now,
              routeCorridorMeters: RouteCorridorConfig.defaultCorridorMeters,
            ),
          ),
        ),
      );
      await _pumpFrames(tester, count: 6);

      expect(find.byKey(const ValueKey('detected_mob-r1-p1')), findsOneWidget);
      // mob-r1-p2 and mob-r1-p2-dup are within 10m so they render as a cluster marker.
      final p2ClusterFinder = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.contains('mob-r1-p2'),
      );
      expect(p2ClusterFinder, findsOneWidget);
      expect(find.byKey(const ValueKey('detected_mob-far-p3')), findsNothing);

      await tester.tap(find.byTooltip('Directions (Point A to B)'));
      await _pumpFrames(tester, count: 5);

      final caypomboChip = find.text('Brgy. Caypombo');
      await tester.ensureVisible(caypomboChip);
      await _pumpFrames(tester, count: 2);
      await tester.tap(caypomboChip);
      await _pumpFrames(tester, count: 12);

      expect(find.text('Selected route'), findsOneWidget);
      expect(find.byKey(const ValueKey('detected_mob-r1-p1')), findsOneWidget);
      expect(p2ClusterFinder, findsOneWidget);
      expect(find.byKey(const ValueKey('detected_mob-far-p3')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'web MapScreen counts mixed-defect approved report as pothole and shows ahead banner even without GPS',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppSettings.instance.toggleSampleStaMariaPotholes(true);
      });

      final now = DateTime(2026, 11, 16, 10, 0);
      final mapKey = GlobalKey<web_map.MapScreenState>();
      const routeOrigin = LatLng(14.8190, 120.9550);
      const routeDest = LatLng(14.8280, 120.9550);
      final mixedReport = web_map.PotholeMarker(
        docId: 'web-mixed-1',
        location: const LatLng(14.8225, 120.9550),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        overallSeverity: 'high',
        potholeCount: 1,
        primaryDefect: 'Longitudinal crack',
        primaryDpwhCode: 'CODE 04',
        detections: const [
          {'className': 'Longitudinal crack'},
          {'className': 'Pothole'},
        ],
        barangay: 'San Gabriel',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: WebDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: web_map.MapScreen(
              key: mapKey,
              detectedPotholes: [mixedReport],
              reportsLastUpdatedAt: now,
            ),
          ),
        ),
      );
      await _pumpFrames(tester, count: 6);

      await mapKey.currentState!.debugApplyRoutesForTest(
        routes: const [
          [
            LatLng(14.8190, 120.9550),
            LatLng(14.8235, 120.9550),
            LatLng(14.8280, 120.9550),
          ],
        ],
        durations: const [240.0],
        distances: const [2800.0],
        destination: routeDest,
        customOrigin: routeOrigin,
        originLabel: 'J. P. Rizal Street, Barangay San Gabriel',
        destinationLabel: 'WalterMart',
        showP2pPill: true,
      );
      await _pumpFrames(tester, count: 6);

      final summary = mapKey.currentState!.debugActiveRouteSummary;
      expect(summary, isNotNull);
      expect(summary!.distinctPotholeCount, 1);
      expect(summary.totalOtherDefectsCount, 1);
      expect(mapKey.currentState!.debugP2pHazardCount, 1);
      expect(find.textContaining('Pothole ahead'), findsOneWidget);
      expect(find.text('1 Pothole'), findsOneWidget);
      expect(find.text('All Clear'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'web MapScreen shows other defects badge when 0 potholes and refreshes on didUpdateWidget metadata change',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppSettings.instance.toggleSampleStaMariaPotholes(true);
      });

      final now = DateTime(2026, 11, 16, 10, 0);
      final mapKey = GlobalKey<web_map.MapScreenState>();
      const routeOrigin = LatLng(14.8190, 120.9550);
      const routeDest = LatLng(14.8280, 120.9550);

      final crackOnlyReport = web_map.PotholeMarker(
        docId: 'web-crack-1',
        location: const LatLng(14.8225, 120.9550),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        overallSeverity: 'medium',
        potholeCount: 1,
        primaryDefect: 'Longitudinal crack',
        primaryDpwhCode: 'CODE 04',
        detections: const [
          {'className': 'Longitudinal crack'},
        ],
        barangay: 'Mahabang Parang',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: WebDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: web_map.MapScreen(
              key: mapKey,
              detectedPotholes: [crackOnlyReport],
              reportsLastUpdatedAt: now,
            ),
          ),
        ),
      );
      await _pumpFrames(tester, count: 6);

      await mapKey.currentState!.debugApplyRoutesForTest(
        routes: const [
          [
            LatLng(14.8190, 120.9550),
            LatLng(14.8235, 120.9550),
            LatLng(14.8280, 120.9550),
          ],
        ],
        durations: const [240.0],
        distances: const [2800.0],
        destination: routeDest,
        customOrigin: routeOrigin,
        originLabel: 'J. P. Rizal Street, Barangay San Gabriel',
        destinationLabel: 'WalterMart',
        showP2pPill: true,
      );
      await _pumpFrames(tester, count: 6);

      final summaryBefore = mapKey.currentState!.debugActiveRouteSummary;
      expect(summaryBefore, isNotNull);
      expect(summaryBefore!.distinctPotholeCount, 0);
      expect(summaryBefore.totalOtherDefectsCount, 1);
      expect(
        find.textContaining('Other defects: 1 Longitudinal crack'),
        findsOneWidget,
      );
      expect(find.text('0 Potholes · 1 Defect'), findsOneWidget);
      expect(find.text('All Clear'), findsNothing);

      // Simulate Firestore/metadata update with identical timestamp & coords adding Pothole class
      final updatedWithPothole = web_map.PotholeMarker(
        docId: 'web-crack-1',
        location: const LatLng(14.8225, 120.9550),
        imagePath: '',
        timestamp: now,
        status: 'approved',
        overallSeverity: 'high',
        potholeCount: 1,
        primaryDefect: 'Longitudinal crack',
        primaryDpwhCode: 'CODE 04',
        detections: const [
          {'className': 'Longitudinal crack'},
          {'className': 'Pothole'},
        ],
        barangay: 'Mahabang Parang',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: WebDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: web_map.MapScreen(
              key: mapKey,
              detectedPotholes: [updatedWithPothole],
              reportsLastUpdatedAt: now,
            ),
          ),
        ),
      );
      await _pumpFrames(tester, count: 6);

      final summaryAfter = mapKey.currentState!.debugActiveRouteSummary;
      expect(summaryAfter, isNotNull);
      expect(summaryAfter!.distinctPotholeCount, 1);
      expect(mapKey.currentState!.debugP2pHazardCount, 1);
      expect(find.textContaining('Pothole ahead'), findsOneWidget);
      expect(find.text('1 Pothole'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mobile MapScreen keeps Point A to B button stack and scale bar close above MobileFloatingNavBar under extendBody',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      AppSettings.instance.toggleSampleStaMariaPotholes(false);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        AppSettings.instance.toggleSampleStaMariaPotholes(true);
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppDesign.buildTheme(isDark: false),
          home: Scaffold(
            extendBody: true,
            bottomNavigationBar: MobileFloatingNavBar(
              currentIndex: 0,
              onTabSelected: (_) {},
              isDark: false,
              disableAnimations: true,
            ),
            body: mobile_map.MapScreen(detectedPotholes: buildMobileMarkers()),
          ),
        ),
      );
      await _pumpFrames(tester, count: 6);

      final navRect = tester.getRect(find.byType(MobileFloatingNavBar));
      final locateRect = tester.getRect(find.byTooltip('Center My Location'));
      final pointAToBRect = tester.getRect(
        find.byTooltip('Plan Point A to Point B Route'),
      );
      final scaleBarRect = tester.getRect(find.byType(MapScaleBar));

      // Lowest button sits right above the floating nav bar (no ~100px double-counted gap)
      final double gapAboveNav = navRect.top - locateRect.bottom;
      expect(gapAboveNav, greaterThanOrEqualTo(4.0));
      expect(gapAboveNav, lessThanOrEqualTo(20.0));
      expect(pointAToBRect.bottom, lessThan(locateRect.top));
      expect(pointAToBRect.top, greaterThan(450.0));

      // Scale bar is clearly above the nav bar, not hidden underneath it
      expect(navRect.top - scaleBarRect.bottom, greaterThanOrEqualTo(4.0));
      expect(navRect.top - scaleBarRect.bottom, lessThanOrEqualTo(24.0));
      expect(tester.takeException(), isNull);
    },
  );
}
