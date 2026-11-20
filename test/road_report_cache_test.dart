import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/road_report_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RoadReportCache', () {
    test('saves and restores approved report snapshots preserving canonical IDs and flags', () async {
      final records = [
        CachedReportRecord(
          docId: 'doc-approved-1',
          canonicalDefectId: 'canon-01',
          latitude: 14.8197,
          longitude: 120.9575,
          primaryDefect: 'Pothole',
          primaryDpwhCode: 'CODE 01',
          status: 'approved',
          isResolved: false,
          potholeCount: 2,
          barangay: 'Poblacion',
          city: 'Santa Maria',
          province: 'Bulacan',
          formattedAddress: 'Poblacion, Santa Maria, Bulacan',
          roadName: 'J.P. Rizal St',
          updatedAtMs: DateTime.utc(2026, 11, 15, 10, 0).millisecondsSinceEpoch,
        ),
        CachedReportRecord(
          docId: 'doc-crack-1',
          canonicalDefectId: null,
          latitude: 14.8240,
          longitude: 120.9610,
          primaryDefect: 'Alligator crack',
          primaryDpwhCode: 'CODE 04',
          status: 'approved',
          isResolved: false,
          potholeCount: 1,
          barangay: 'Guyong',
          updatedAtMs: DateTime.utc(2026, 11, 15, 9, 30).millisecondsSinceEpoch,
        ),
      ];

      await RoadReportCache.saveApprovedReports(records);
      final loaded = await RoadReportCache.loadApprovedReports();

      expect(loaded, isNotNull);
      expect(loaded!.records.length, 2);
      expect(loaded.records.first.docId, 'doc-approved-1');
      expect(loaded.records.first.canonicalDefectId, 'canon-01');
      expect(loaded.records.first.roadName, 'J.P. Rizal St');
      expect(loaded.records.first.isResolved, isFalse);
      expect(loaded.records.last.primaryDefect, 'Alligator crack');
    });

    test('round-trips defectClasses, roadBearingDeg, and roadMatched fields', () async {
      final records = [
        CachedReportRecord(
          docId: 'doc-mixed-1',
          latitude: 14.821,
          longitude: 120.958,
          primaryDefect: 'Alligator crack',
          primaryDpwhCode: 'CODE 04',
          status: 'approved',
          isResolved: false,
          potholeCount: 2,
          updatedAtMs: DateTime.utc(2026, 11, 16, 1, 0).millisecondsSinceEpoch,
          defectClasses: const ['Alligator crack', 'Pothole'],
          roadBearingDeg: 14.5,
          roadMatched: true,
        ),
      ];
      await RoadReportCache.saveApprovedReports(records);
      final loaded = await RoadReportCache.loadApprovedReports();
      expect(loaded, isNotNull);
      expect(loaded!.records.single.defectClasses, ['Alligator crack', 'Pothole']);
      expect(loaded.records.single.roadBearingDeg, 14.5);
      expect(loaded.records.single.roadMatched, isTrue);
    });

    test('normalizes route cache keys and persists recent offline route geometries', () async {
      final key = RoadReportCache.routeCacheKey(
        origin: const LatLng(14.81972, 120.95754),
        destination: const LatLng(14.84271, 120.97393),
        travelMode: 'car',
      );
      expect(key, 'car_14.8197,120.9575_14.8427,120.9739');

      await RoadReportCache.saveRecentRoute(
        routeKey: key,
        routes: const [
          [LatLng(14.8197, 120.9575), LatLng(14.8427, 120.9739)],
          [LatLng(14.8197, 120.9575), LatLng(14.8300, 120.9680), LatLng(14.8427, 120.9739)],
        ],
        durationsSeconds: const [420.0, 540.0],
        distancesMeters: const [3200.0, 3900.0],
      );

      final cached = await RoadReportCache.loadRecentRoute(key);
      expect(cached, isNotNull);
      expect(cached!.routes.length, 2);
      expect(cached.routes.last.length, 3);
      expect(cached.durations, const [420.0, 540.0]);
      expect(cached.distances, const [3200.0, 3900.0]);
      expect(await RoadReportCache.loadRecentRoute('missing_key'), isNull);
    });

    test('formats data freshness labels for live, relative, and saved offline states', () {
      final now = DateTime.utc(2026, 11, 15, 12, 0);
      expect(
        RoadReportCache.formatDataUpdatedLabel(null),
        contains('Syncing'),
      );
      expect(
        RoadReportCache.formatDataUpdatedLabel(null, isUsingCached: true),
        contains('saved'),
      );
      expect(
        RoadReportCache.formatDataUpdatedLabel(
          now.subtract(const Duration(seconds: 20)),
          now: now,
        ),
        'Report data updated just now',
      );
      expect(
        RoadReportCache.formatDataUpdatedLabel(
          now.subtract(const Duration(minutes: 12)),
          now: now,
        ),
        'Report data updated 12 min ago',
      );
      expect(
        RoadReportCache.formatDataUpdatedLabel(
          now.subtract(const Duration(minutes: 12)),
          isUsingCached: true,
          now: now,
        ),
        contains('saved'),
      );
    });
  });
}
