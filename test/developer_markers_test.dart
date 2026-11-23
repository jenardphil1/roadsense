import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_flutter_app/developer_markers.dart';
import 'package:my_flutter_app/dpwh_standards.dart';
import 'package:my_flutter_app/road_hazard_marker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'local markers persist all four classes, edit in place, and delete',
    () async {
      final store = DeveloperMarkers();
      addTearDown(store.dispose);
      for (final cls in DpwhStandards.allClasses) {
        await store.save(
          DeveloperMarker(
            '${DeveloperMarkers.prefix}${cls.classId}',
            const LatLng(14.82, 120.96),
            cls.name,
          ),
        );
      }
      final reloaded = DeveloperMarkers();
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(
        reloaded.items.map((m) => m.defect).toSet(),
        DpwhStandards.allClasses.map((c) => c.name).toSet(),
      );
      final id = reloaded.items.first.id;
      await reloaded.save(
        DeveloperMarker(
          id,
          const LatLng(14.83, 120.97),
          DpwhStandards.allClasses.last.name,
        ),
      );
      expect(reloaded.items.length, 4);
      expect(
        reloaded.items.firstWhere((m) => m.id == id).location,
        const LatLng(14.83, 120.97),
      );
      await reloaded.remove(id);
      final afterDelete = DeveloperMarkers();
      addTearDown(afterDelete.dispose);
      await afterDelete.load();
      expect(afterDelete.items.length, 3);
      expect(afterDelete.items.any((m) => m.id == id), isFalse);
    },
  );

  test(
    'invalid and foreign entries never become local development markers',
    () async {
      SharedPreferences.setMockInitialValues({
        'roadsense_developer_markers_v1': [
          '{broken',
          jsonEncode({
            'id': 'real-report',
            'lat': 14,
            'lng': 120,
            'defect': 'Pothole',
          }),
          jsonEncode({
            'id': '${DeveloperMarkers.prefix}bad',
            'lat': 91,
            'lng': 120,
            'defect': 'Pothole',
          }),
          jsonEncode({
            'id': '${DeveloperMarkers.prefix}good',
            'lat': 14.82,
            'lng': 120.96,
            'defect': 'Pothole',
          }),
        ],
      });
      final store = DeveloperMarkers();
      addTearDown(store.dispose);
      await store.load();
      expect(store.items.map((m) => m.id), ['${DeveloperMarkers.prefix}good']);
      await expectLater(
        store.save(
          const DeveloperMarker('real-report', LatLng(14, 120), 'Pothole'),
        ),
        throwsArgumentError,
      );
      await expectLater(
        store.save(
          DeveloperMarker(
            '${DeveloperMarkers.prefix}invalid',
            LatLng(double.nan, 120),
            'Pothole',
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test('zoom sizing is bounded and increases smoothly', () {
    expect(RoadHazardMarker.sizeForZoom(3), 14);
    expect(RoadHazardMarker.sizeForZoom(22), 30);
    expect(
      RoadHazardMarker.sizeForZoom(13.5),
      greaterThan(RoadHazardMarker.sizeForZoom(13)),
    );
    expect(
      RoadHazardMarker.sizeForZoom(13.5),
      lessThan(RoadHazardMarker.sizeForZoom(14)),
    );
  });

  testWidgets(
    'editor exposes four classes and saves the chosen class locally',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDeveloperMarkerEditor(
                  context,
                  location: const LatLng(14.82, 120.96),
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      expect(find.text('Developer custom markers'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('developer-defect-null')));
      await tester.pumpAndSettle();
      for (final cls in DpwhStandards.allClasses) {
        expect(find.text(cls.name), findsWidgets);
      }
      await tester.tap(find.text('Transverse crack').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save local marker'));
      await tester.pumpAndSettle();
      expect(find.text('Developer custom markers'), findsNothing);
      expect(DeveloperMarkers.instance.items.single.defect, 'Transverse crack');
      await DeveloperMarkers.instance.remove(
        DeveloperMarkers.instance.items.single.id,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editor Choose location on map picks coordinates and reopens preserving defect class',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const picked = LatLng(14.845123, 120.971234);
      LatLng? receivedInitial;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDeveloperMarkerEditor(
                  context,
                  location: const LatLng(14.82, 120.96),
                  onPickLocationOnMap: (initial) async {
                    receivedInitial = initial;
                    return picked;
                  },
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      expect(find.text('Developer custom markers'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('developer-defect-null')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alligator crack').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Choose location on map'));
      await tester.pumpAndSettle();

      expect(receivedInitial, const LatLng(14.82, 120.96));
      expect(find.text('Developer custom markers'), findsOneWidget);
      expect(find.text('Alligator crack'), findsOneWidget);
      expect(find.text('14.845123'), findsOneWidget);
      expect(find.text('120.971234'), findsOneWidget);

      await tester.tap(find.text('Save local marker'));
      await tester.pumpAndSettle();
      expect(DeveloperMarkers.instance.items.single.defect, 'Alligator crack');
      expect(
        DeveloperMarkers.instance.items.single.location.latitude,
        closeTo(picked.latitude, 1e-6),
      );
      expect(
        DeveloperMarkers.instance.items.single.location.longitude,
        closeTo(picked.longitude, 1e-6),
      );
      await DeveloperMarkers.instance.remove(
        DeveloperMarkers.instance.items.single.id,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
