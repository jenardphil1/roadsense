import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/app_settings.dart';
import 'package:my_flutter_app/cloud_service.dart';
import 'package:my_flutter_app/dpwh_standards.dart';
import 'package:my_flutter_app/road_report_cache.dart';
import 'package:my_flutter_app/route_pothole_advisor.dart';
import 'package:my_flutter_app/sta_maria_sample_potholes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StaMariaSamplePotholeSpecs', () {
    test('contains 22 unique sample markers within Santa Maria bounds', () {
      expect(staMariaSamplePotholeSpecs.length, 22);

      const canonicalClasses = {
        'Pothole',
        'Alligator crack',
        'Longitudinal crack',
        'Transverse crack',
      };

      final ids = <String>{};
      for (final spec in staMariaSamplePotholeSpecs) {
        expect(isSampleStaMariaMarkerId(spec.docId), isTrue);
        expect(ids.add(spec.docId), isTrue);
        expect(spec.location.latitude, inInclusiveRange(14.78, 14.90));
        expect(spec.location.longitude, inInclusiveRange(120.92, 121.05));
        expect(canonicalClasses.contains(spec.primaryDefect), isTrue);
        expect(spec.barangay, isNotEmpty);
        expect(spec.formattedAddress, contains('Santa Maria'));
      }
      expect(isSampleStaMariaMarkerId('firestore_doc_123'), isFalse);
      expect(isSampleStaMariaMarkerId(null), isFalse);
    });
  });

  group('RoutePotholeAdvisor', () {
    test(
      'counts route hazards and recommends alternate route with fewer potholes',
      () {
        // Synthetic Poblacion -> Pulong Buhangin corridor (6 hazards on Route 1 vs 1 on Route 2)
        const route1 = <LatLng>[
          LatLng(14.8200, 120.9550),
          LatLng(14.8250, 120.9600),
          LatLng(14.8350, 120.9700),
          LatLng(14.8450, 120.9800),
          LatLng(14.8550, 120.9900),
          LatLng(14.8630, 121.0020),
        ];
        const route2Bypass = <LatLng>[
          LatLng(14.8200, 120.9550),
          LatLng(14.8200, 120.9720),
          LatLng(14.8350, 120.9920),
          LatLng(14.8550, 121.0030),
          LatLng(14.8630, 121.0020),
        ];

        final hazards = <LatLng>[
          // 6 hazards along Route 1
          const LatLng(14.8230, 120.9580),
          const LatLng(14.8280, 120.9630),
          const LatLng(14.8330, 120.9680),
          const LatLng(14.8380, 120.9730),
          const LatLng(14.8430, 120.9780),
          const LatLng(14.8500, 120.9850),
          // 1 hazard along Route 2 bypass
          const LatLng(14.8450, 120.9975),
        ];

        final counts = RoutePotholeAdvisor.countHazardsPerRoute(
          routes: const [route1, route2Bypass],
          hazards: hazards,
          toleranceMeters: 30.0,
        );
        expect(counts, [6, 1]);

        final suggestion = RoutePotholeAdvisor.buildSwitchSuggestion(
          currentRouteIndex: 0,
          hazardCounts: counts,
          distancesMeters: const [5200, 6100],
          durationsSeconds: const [600, 720],
        );
        expect(suggestion, isNotNull);
        expect(suggestion!.recommendedRouteIndex, 1);
        expect(suggestion.currentHazards, 6);
        expect(suggestion.recommendedHazards, 1);
        expect(suggestion.hazardsAvoided, 5);
        expect(suggestion.extraMinutes, 2);

        // Once user switches to Route 2 (index 1), no suggestion is emitted because Route 2 is cleanest.
        final afterSwitch = RoutePotholeAdvisor.buildSwitchSuggestion(
          currentRouteIndex: 1,
          hazardCounts: counts,
          distancesMeters: const [5200, 6100],
          durationsSeconds: const [600, 720],
        );
        expect(afterSwitch, isNull);
      },
    );

    test(
      'breaks ties among alternate routes with equal low hazards by shortest ETA',
      () {
        final suggestion = RoutePotholeAdvisor.buildSwitchSuggestion(
          currentRouteIndex: 0,
          hazardCounts: const [4, 1, 1],
          distancesMeters: const [4000, 5500, 4600],
          durationsSeconds: const [480, 660, 540],
        );
        expect(suggestion, isNotNull);
        expect(suggestion!.recommendedRouteIndex, 2);
        expect(suggestion.hazardsAvoided, 3);
      },
    );

    test(
      'computes smooth meter countdown along route down to 0 m and roaming fallback',
      () {
        const start = LatLng(14.8200, 120.9575);
        // Roughly ~1 km straight north along same longitude
        const mid = LatLng(14.8245, 120.9575);
        const end = LatLng(14.8290, 120.9575);
        const quarterWay = LatLng(14.82225, 120.9575);
        final route = [start, end];

        final hazardInputs = [
          RouteHazardInput(
            location: mid,
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            barangay: 'Guyong',
          ),
          // Non-pothole defect must stay excluded from pothole alerts.
          RouteHazardInput(
            location: quarterWay,
            defectName: 'Alligator Crack',
            dpwhCode: 'CODE 04',
            barangay: 'Guyong',
          ),
        ];

        final atStart = RoutePotholeAdvisor.findUpcomingHazard(
          userPos: start,
          hazards: hazardInputs,
          activeRoute: route,
          routeToleranceMeters: 20.0,
        );
        expect(atStart, isNotNull);
        expect(atStart!.isOnActiveRoute, isTrue);
        expect(atStart.defectName, 'Pothole');
        expect(atStart.barangay, 'Guyong');
        expect(atStart.distanceMeters, inInclusiveRange(450, 540));

        // Moving halfway toward mid drops countdown proportionally
        final atQuarter = RoutePotholeAdvisor.findUpcomingHazard(
          userPos: quarterWay,
          hazards: hazardInputs,
          activeRoute: route,
        );
        expect(atQuarter, isNotNull);
        expect(atQuarter!.distanceMeters, inInclusiveRange(220, 280));

        // Right on top of the hazard -> 0 m
        final atHazard = RoutePotholeAdvisor.findUpcomingHazard(
          userPos: mid,
          hazards: hazardInputs,
          activeRoute: route,
        );
        expect(atHazard, isNotNull);
        expect(atHazard!.roundedMeters, 0);

        // Well past the hazard (>3m behind) -> cleared ahead
        const pastHazard = LatLng(14.8260, 120.9575);
        final afterHazard = RoutePotholeAdvisor.findUpcomingHazard(
          userPos: pastHazard,
          hazards: hazardInputs,
          activeRoute: route,
        );
        expect(afterHazard, isNull);

        // Free-roaming within 600 m finds nearby hazard; > 600 m returns null
        final roamingNear = RoutePotholeAdvisor.findUpcomingHazard(
          userPos: quarterWay,
          hazards: hazardInputs,
          roamingRadiusMeters: 600.0,
        );
        expect(roamingNear, isNotNull);
        expect(roamingNear!.isOnActiveRoute, isFalse);

        final roamingFar = RoutePotholeAdvisor.findUpcomingHazard(
          userPos: const LatLng(14.8000, 120.9400),
          hazards: hazardInputs,
          roamingRadiusMeters: 600.0,
        );
        expect(roamingFar, isNull);
      },
    );

    test(
      'builds perpendicular bypass waypoints and filters duplicate/long detours',
      () {
        const a = LatLng(14.8200, 120.9575);
        const b = LatLng(14.8350, 120.9575); // ~1.67 km
        const midHazard = LatLng(14.8275, 120.9575);

        final waypoints = RoutePotholeAdvisor.buildAvoidanceWaypoints(
          primaryRoute: const [a, midHazard, b],
          hazards: const [midHazard],
          lateralOffsetMeters: 420.0,
        );
        expect(waypoints.length, 2);

        // Identical corridor should be rejected as non-distinct
        expect(
          RoutePotholeAdvisor.isDistinctAlternateRoute(
            const [a, midHazard, b],
            const [
              [a, midHazard, b],
            ],
          ),
          isFalse,
        );

        // Reasonable shifted corridor (~400m east) is accepted
        const shiftedEast = LatLng(14.8275, 120.9615);
        expect(
          RoutePotholeAdvisor.isDistinctAlternateRoute(
            const [a, shiftedEast, b],
            const [
              [a, midHazard, b],
            ],
          ),
          isTrue,
        );
      },
    );
  });

  group('AppSettings Sta. Maria sample markers', () {
    test(
      'legacy sample preference starts disabled and supports old test callers',
      () {
        SharedPreferences.setMockInitialValues({});
        AppSettings.instance.toggleSampleStaMariaPotholes(false);
        expect(AppSettings.instance.sampleStaMariaPotholesEnabled, isFalse);
        expect(
          AppSettings.instance.sampleStaMariaPotholesNotifier.value,
          isFalse,
        );

        AppSettings.instance.toggleSampleStaMariaPotholes(true);
        expect(AppSettings.instance.sampleStaMariaPotholesEnabled, isTrue);
        expect(
          AppSettings.instance.sampleStaMariaPotholesNotifier.value,
          isTrue,
        );
      },
    );
  });

  group('RouteCorridorConfig, Deduplication, Eligibility & Separation', () {
    const route = <LatLng>[
      LatLng(14.8200, 120.9575),
      LatLng(14.8290, 120.9575), // ~1 km north
    ];

    test(
      'deduplicates repeated canonical reports without merging nearby distinct potholes',
      () {
        final hazards = [
          // Two submissions for the SAME canonical pothole
          const RouteHazardInput(
            location: LatLng(14.8230, 120.9575),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'r-dup-1',
            canonicalDefectId: 'canon-p1',
          ),
          const RouteHazardInput(
            location: LatLng(14.82301, 120.95751),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'r-dup-2',
            canonicalDefectId: 'canon-p1',
          ),
          // Two genuinely separate nearby potholes (~3.3m apart)
          const RouteHazardInput(
            location: LatLng(14.8250, 120.9575),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'r-sep-a',
            canonicalDefectId: 'canon-p2',
          ),
          const RouteHazardInput(
            location: LatLng(14.82503, 120.9575),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'r-sep-b',
            canonicalDefectId: 'canon-p3',
          ),
        ];

        final built = PrecomputedRouteIndex.build(
          route: route,
          hazards: hazards,
          routeDistanceMeters: 1000,
          durationSeconds: 120,
        );
        expect(built.summary.distinctPotholeCount, 3);
        expect(built.summary.potholeEncounters.length, 3);
      },
    );

    test(
      'excludes pending, rejected, deleted, resolved, inaccessible reports and separates other defects',
      () {
        final hazards = [
          const RouteHazardInput(
            location: LatLng(14.8220, 120.9575),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'ok-1',
            status: 'approved',
          ),
          const RouteHazardInput(
            location: LatLng(14.8230, 120.9575),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'pending-1',
            status: 'pending',
          ),
          const RouteHazardInput(
            location: LatLng(14.8235, 120.9575),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'rejected-1',
            status: 'rejected',
          ),
          const RouteHazardInput(
            location: LatLng(14.8240, 120.9575),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'deleted-1',
            status: 'deleted',
          ),
          const RouteHazardInput(
            location: LatLng(14.8245, 120.9575),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'resolved-1',
            status: 'approved',
            isResolved: true,
          ),
          const RouteHazardInput(
            location: LatLng(14.8250, 120.9575),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'inaccessible-1',
            status: 'approved',
            isAccessible: false,
          ),
          const RouteHazardInput(
            location: LatLng(14.8255, 120.9575),
            defectName: 'Alligator crack',
            dpwhCode: 'CODE 04',
            reportId: 'crack-1',
            status: 'approved',
          ),
          const RouteHazardInput(
            location: LatLng(14.8260, 120.9575),
            defectName: 'Edge break',
            dpwhCode: 'CODE 01',
            reportId: 'edge-1',
            status: 'approved',
          ),
          // Outside 18m corridor (~65m east, still inside map bbox)
          const RouteHazardInput(
            location: LatLng(14.8265, 120.9581),
            defectName: 'Pothole',
            dpwhCode: 'CODE 01',
            reportId: 'parallel-road-1',
            status: 'approved',
          ),
        ];

        final built = PrecomputedRouteIndex.build(
          route: route,
          hazards: hazards,
          routeDistanceMeters: 5200,
          durationSeconds: 840,
        );
        expect(built.summary.distinctPotholeCount, 1);
        expect(built.summary.otherDefectCounts['Alligator crack'], 1);
        expect(built.summary.otherDefectCounts['Edge break'], 1);
        expect(built.summary.totalOtherDefectsCount, 2);
        expect(built.summary.isApproximate, isTrue);
        expect(
          built.summary.formattedSummaryLine(formattedEta: '14 min'),
          '5.2 km · 14 min · 1 reported pothole (approx.)',
        );
      },
    );

    test(
      'filters incompatible road names / opposite carriageways and scales corridor with GPS accuracy',
      () {
        expect(
          RouteCorridorConfig.effectiveCorridorMeters(
            baseCorridorMeters: 18.0,
            gpsAccuracyMeters: 5.0,
          ),
          18.0,
        );
        expect(
          RouteCorridorConfig.effectiveCorridorMeters(
            baseCorridorMeters: 18.0,
            gpsAccuracyMeters: 30.0,
          ),
          inInclusiveRange(22.0, RouteCorridorConfig.maxCorridorMeters),
        );

        final spans = [
          const RouteStepRoadSpan(
            roadName: 'Santa Maria Bypass Road',
            location: LatLng(14.8200, 120.9575),
          ),
        ];
        final hazards = [
          // Same road, aligned northbound heading
          const RouteHazardInput(
            location: LatLng(14.8230, 120.9575),
            defectName: 'Pothole',
            reportId: 'matched-nb',
            roadName: 'Sta. Maria Bypass Rd',
            roadMatched: true,
            roadBearingDeg: 2.0,
          ),
          // Parallel service road with different name -> excluded
          const RouteHazardInput(
            location: LatLng(14.8240, 120.95755),
            defectName: 'Pothole',
            reportId: 'service-rd',
            roadName: 'Service Road West',
            roadMatched: true,
            roadBearingDeg: 0.0,
          ),
          // Opposite carriageway (southbound 180 deg) on northbound route -> excluded
          const RouteHazardInput(
            location: LatLng(14.8250, 120.95752),
            defectName: 'Pothole',
            reportId: 'opp-lane',
            roadName: 'Santa Maria Bypass Road',
            roadMatched: true,
            roadBearingDeg: 180.0,
          ),
        ];

        final built = PrecomputedRouteIndex.build(
          route: route,
          hazards: hazards,
          steps: spans,
          assumeVerifiedRoadNetwork: true,
        );
        expect(built.summary.distinctPotholeCount, 1);
        expect(
          built.summary.potholeEncounters.single.hazard.reportId,
          'matched-nb',
        );
        expect(built.summary.isApproximate, isFalse);

        // Zero potholes summary text
        final clear = PrecomputedRouteIndex.build(
          route: route,
          hazards: const [],
          routeDistanceMeters: 5200,
          durationSeconds: 840,
        );
        expect(clear.summary.distinctPotholeCount, 0);
        expect(clear.summary.shortPotholePhrase, '0 reported potholes');
        expect(
          clear.summary.potholePhrase,
          'No reported potholes along this route',
        );
      },
    );
  });

  group('RoutePotholeAdvisor.evaluateAlternatives & Detour Caps', () {
    const start = LatLng(14.8200, 120.9575);
    const end = LatLng(14.8500, 120.9575);
    const routeFast = [start, LatLng(14.8350, 120.9575), end];
    const routeFewer = [start, LatLng(14.8350, 120.9640), end];
    const routeAlt = [start, LatLng(14.8350, 120.9510), end];
    const routeExcessiveDetour = [start, LatLng(14.8350, 120.9800), end];

    test(
      'presents up to 3 options with Fastest, Fewer reported potholes, Alternative and tradeoff text',
      () {
        final hazards = [
          for (int i = 0; i < 6; i++)
            RouteHazardInput(
              location: LatLng(14.8250 + i * 0.002, 120.9575),
              defectName: 'Pothole',
              reportId: 'fast-$i',
            ),
          const RouteHazardInput(
            location: LatLng(14.8275, 120.96075),
            defectName: 'Pothole',
            reportId: 'fewer-0',
          ),
          const RouteHazardInput(
            location: LatLng(14.8350, 120.9640),
            defectName: 'Pothole',
            reportId: 'fewer-1',
          ),
          const RouteHazardInput(
            location: LatLng(14.8350, 120.9510),
            defectName: 'Pothole',
            reportId: 'alt-0',
          ),
        ];

        final res = RoutePotholeAdvisor.evaluateAlternatives(
          routes: const [routeFast, routeFewer, routeAlt],
          distancesMeters: const [5200, 5900, 7400],
          durationsSeconds: const [840, 1020, 1680],
          hazards: hazards,
          viaSummaries: const ['MacArthur Hwy', 'Bypass Rd', 'Outer Loop'],
          detourConfig: const RouteDetourConfig(
            maxExtraDurationRatio: 0.35,
            minAllowedExtraSeconds: 300,
            maxExtraDistanceRatio: 0.45,
          ),
        );

        expect(res.options.length, 3);
        expect(res.fastestOption?.roleLabel, 'Fastest');
        expect(res.fastestOption?.summary.distinctPotholeCount, 6);
        expect(res.preferredSaferOption?.routeIndex, 1);
        expect(res.preferredSaferOption?.roleLabel, 'Fewer reported potholes');
        expect(res.preferredSaferOption?.summary.distinctPotholeCount, 2);
        expect(res.preferredSaferOption?.withinDetourAllowance, isTrue);
        expect(
          res.preferredSaferOption?.tradeoffExplanation,
          '4 fewer reported potholes · approximately 3 minutes longer',
        );
        expect(res.hasFewerPotholesOption, isTrue);
        expect(res.options.last.roleLabel, 'Alternative');
      },
    );

    test(
      'rejects excessive detours from preferredSaferOption and reports no fewer option clearly',
      () {
        final hazards = [
          const RouteHazardInput(
            location: LatLng(14.8350, 120.9575),
            defectName: 'Pothole',
            reportId: 'f-1',
          ),
        ];
        final resExcessive = RoutePotholeAdvisor.evaluateAlternatives(
          routes: const [routeFast, routeExcessiveDetour],
          distancesMeters: const [5200, 12000],
          durationsSeconds: const [600, 1800],
          hazards: hazards,
          detourConfig: const RouteDetourConfig(
            maxExtraDurationRatio: 0.25,
            minAllowedExtraSeconds: 180,
            maxExtraDistanceRatio: 0.30,
          ),
        );
        expect(resExcessive.preferredSaferOption, isNull);
        expect(resExcessive.options[1].withinDetourAllowance, isFalse);

        // Same pothole count on both routes -> explicit status message
        final tiedRes = RoutePotholeAdvisor.evaluateAlternatives(
          routes: const [routeFast, routeFewer],
          distancesMeters: const [5200, 5800],
          durationsSeconds: const [840, 960],
          hazards: const [],
        );
        expect(tiedRes.hasFewerPotholesOption, isFalse);
        expect(
          tiedRes.statusMessage,
          'No route with fewer reported potholes was found.',
        );

        // Single-route provider limitation
        final singleRes = RoutePotholeAdvisor.evaluateAlternatives(
          routes: const [routeFast],
          distancesMeters: const [5200],
          durationsSeconds: const [840],
          hazards: hazards,
        );
        expect(singleRes.providerReturnedAlternatives, isFalse);
        expect(singleRes.hasFewerPotholesOption, isFalse);
      },
    );
  });

  group('NavigationHazardTracker & Adaptive Voice Alerts', () {
    test(
      'handles loop routes with multi-pass encounters, hysteresis, status transitions & alert dedupe',
      () {
        // Out-and-back loop (~1 km north to 14.8290 then back south to 14.8200)
        const p0 = LatLng(14.8200, 120.9575);
        const pTop = LatLng(14.8290, 120.9575);
        const loopRoute = [p0, pTop, p0];
        const potholeMid = LatLng(
          14.8245,
          120.9575,
        ); // ~500m up and ~1500m on return
        const potholeNearTop = LatLng(14.8280, 120.9575);

        final built = PrecomputedRouteIndex.build(
          route: loopRoute,
          hazards: const [
            RouteHazardInput(
              location: potholeMid,
              defectName: 'Pothole',
              reportId: 'loop-mid',
            ),
            RouteHazardInput(
              location: potholeNearTop,
              defectName: 'Pothole',
              reportId: 'loop-top',
            ),
          ],
        );
        // Distinct physical potholes = 2, while loop produces 3+ ordered encounters!
        expect(built.summary.distinctPotholeCount, 2);
        expect(built.summary.potholeEncounters.length, greaterThanOrEqualTo(3));

        final tracker = NavigationHazardTracker(built);

        // 1. Waiting for location
        final waitState = tracker.update(position: null);
        expect(waitState.status, NavigationHazardStatus.waitingForLocation);
        expect(waitState.totalRoutePotholeCount, 2);

        // 2. Approaching first pothole (~350m ahead) with good GPS & 15 m/s speed
        const approach1 = LatLng(14.82135, 120.9575);
        final s1 = tracker.update(
          position: approach1,
          gpsAccuracyMeters: 42.0, // low accuracy threshold > 35m
          speedMps: 15.0,
          headingDeg: 0.0,
          timestamp: DateTime(2026, 11, 15, 10, 0, 0),
          now: DateTime(2026, 11, 15, 10, 0, 0),
        );
        expect(s1.status, NavigationHazardStatus.hazardAhead);
        expect(s1.isLowAccuracy, isTrue);
        expect(s1.alertTriggerToSpeak, isNotNull);
        expect(
          RoutePotholeAdvisor.formatDistanceAhead(s1.distanceToNextMeters!),
          contains('m ahead'),
        );
        expect(
          RoutePotholeAdvisor.formatVoiceAlertAnnouncement(
            s1.alertTriggerDistanceMeters!,
          ),
          contains('Reported pothole ahead'),
        );

        // Repeat update same spot -> voice alert deduplicated (must not repeat)
        final s1Repeat = tracker.update(
          position: approach1,
          gpsAccuracyMeters: 8.0,
          speedMps: 15.0,
          headingDeg: 0.0,
          timestamp: DateTime(2026, 11, 15, 10, 0, 2),
          now: DateTime(2026, 11, 15, 10, 0, 2),
        );
        expect(s1Repeat.alertTriggerToSpeak, isNull);
        expect(s1Repeat.isLowAccuracy, isFalse);

        // 3. Pass potholeMid well past threshold (~35m north of mid) + GPS jitter slightly backward
        const justPastMid = LatLng(14.8249, 120.9575);
        final sPast = tracker.update(
          position: justPastMid,
          headingDeg: 0.0,
          timestamp: DateTime(2026, 11, 15, 10, 0, 25),
          now: DateTime(2026, 11, 15, 10, 0, 25),
        );
        expect(sPast.nextEncounter?.hazard.reportId, 'loop-top');

        // Small 2m backward GPS jitter should NOT re-activate passed encounter!
        const jitterBack = LatLng(14.82488, 120.9575);
        final sJitter = tracker.update(
          position: jitterBack,
          headingDeg: 0.0,
          timestamp: DateTime(2026, 11, 15, 10, 0, 27),
          now: DateTime(2026, 11, 15, 10, 0, 27),
        );
        expect(sJitter.nextEncounter?.hazard.reportId, 'loop-top');

        // 4. Off-route check (~150m east)
        final sOff = tracker.update(
          position: const LatLng(14.8250, 120.9592),
          timestamp: DateTime(2026, 11, 15, 10, 0, 35),
          now: DateTime(2026, 11, 15, 10, 0, 35),
        );
        expect(sOff.status, NavigationHazardStatus.offRoute);
      },
    );

    test(
      'scales voice trigger distance smoothly with speed and GPS accuracy',
      () {
        final slowTrigger = RoutePotholeAdvisor.computeAlertTriggerMeters(
          baseTriggerMeters: 250,
          speedMps: 4.0,
          gpsAccuracyMeters: 5.0,
        );
        final fastTrigger = RoutePotholeAdvisor.computeAlertTriggerMeters(
          baseTriggerMeters: 250,
          speedMps: 18.0,
          gpsAccuracyMeters: 25.0,
        );
        expect(fastTrigger, greaterThan(slowTrigger));
        expect(RoutePotholeAdvisor.formatDistanceAhead(1250), '1.3 km ahead');
        expect(RoutePotholeAdvisor.formatDistanceAhead(347), '347 m ahead');
      },
    );
  });

  group('Regression fixes (segments, >400 corridor pages, mixed defects, loops)', () {
    test(
      'matches potholes between widely spaced vertices, on sharp bends, endpoints, and beyond 80-vertex steps',
      () {
        // 1. Widely spaced straight route (2 vertices ~1.2 km apart) + pothole near midpoint (~600 m from vertices)
        final wideRoute = const [
          LatLng(14.8200, 120.9550),
          LatLng(14.8308, 120.9550),
        ];
        final wideBuilt = PrecomputedRouteIndex.build(
          route: wideRoute,
          hazards: [
            RouteHazardInput(
              location: const LatLng(
                14.8254,
                120.95505,
              ), // ~5 m east of midpoint
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              reportId: 'mid-seg',
            ),
            RouteHazardInput(
              location: const LatLng(
                14.8308,
                120.95508,
              ), // near destination endpoint
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              reportId: 'end-pt',
            ),
          ],
          config: const RouteCorridorConfig(corridorMeters: 18),
        );
        expect(wideBuilt.summary.distinctPotholeCount, 2);

        // 2. Sharp 90-degree bend: pothole 12 m off outer corner included, 32 m off branch excluded
        final bendRoute = const [
          LatLng(14.8200, 120.9550),
          LatLng(14.8230, 120.9550),
          LatLng(14.8230, 120.9590),
        ];
        final bendBuilt = PrecomputedRouteIndex.build(
          route: bendRoute,
          hazards: [
            RouteHazardInput(
              location: const LatLng(14.82308, 120.95492), // ~12 m NW of corner
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              reportId: 'bend-near',
            ),
            RouteHazardInput(
              location: const LatLng(
                14.82330,
                120.9550,
              ), // ~33 m north past turn
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              reportId: 'bend-far',
            ),
          ],
          config: const RouteCorridorConfig(corridorMeters: 18),
        );
        expect(bendBuilt.summary.distinctPotholeCount, 1);
        expect(
          bendBuilt.summary.potholeEncounters.single.hazard.reportId,
          'bend-near',
        );

        // 3. Long step with >80 vertices before second step: road name span must stay accurate past vertex 80
        final longRoute = List<LatLng>.generate(
          120,
          (i) => LatLng(14.8200 + i * 0.0001, 120.9550),
        )..add(const LatLng(14.8320, 120.9570));
        final steps = const [
          RouteStepRoadSpan(
            roadName: 'MacArthur Highway',
            location: LatLng(14.8200, 120.9550),
          ),
          RouteStepRoadSpan(
            roadName: 'Rizal Street',
            location: LatLng(14.8319, 120.9550),
          ),
        ];
        final longStepBuilt = PrecomputedRouteIndex.build(
          route: longRoute,
          steps: steps,
          hazards: [
            RouteHazardInput(
              location: longRoute[105], // past vertex 80
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              roadName: 'MacArthur Highway',
              reportId: 'past-80',
            ),
          ],
          config: const RouteCorridorConfig(corridorMeters: 18),
        );
        expect(longStepBuilt.summary.distinctPotholeCount, 1);
      },
    );

    test(
      'keeps GPS offsets inside corridor while rejecting parallel service/flyover roads, opposite carriageways, and over-snapped rawLocations',
      () {
        final route = const [
          LatLng(14.8200, 120.9550),
          LatLng(14.8260, 120.9550),
        ];
        final steps = const [
          RouteStepRoadSpan(
            roadName: 'MacArthur Highway Northbound',
            location: LatLng(14.8200, 120.9550),
          ),
        ];
        final built = PrecomputedRouteIndex.build(
          route: route,
          steps: steps,
          config: const RouteCorridorConfig(corridorMeters: 18),
          hazards: [
            // GPS offset 12 m east on the same named highway -> included
            RouteHazardInput(
              location: const LatLng(14.8220, 120.95511),
              rawLocation: const LatLng(14.8220, 120.95511),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              roadName: 'MacArthur Hwy Northbound',
              roadBearingDeg: 4,
              reportId: 'gps-offset-ok',
            ),
            // Service road 14 m away -> rejected despite prefix overlap
            RouteHazardInput(
              location: const LatLng(14.8230, 120.95513),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              roadName: 'MacArthur Hwy Service Rd',
              reportId: 'service-rd',
            ),
            // Flyover variant -> rejected
            RouteHazardInput(
              location: const LatLng(14.8235, 120.95508),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              roadName: 'MacArthur Hwy Northbound Flyover',
              reportId: 'flyover',
            ),
            // Opposite carriageway -> rejected
            RouteHazardInput(
              location: const LatLng(14.8240, 120.95492),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              roadName: 'MacArthur Hwy Southbound',
              roadBearingDeg: 180,
              reportId: 'opposite-sb',
            ),
            // Location snapped onto route, but rawLocation 30 m off on parallel road -> rejected
            RouteHazardInput(
              location: const LatLng(14.8245, 120.9550),
              rawLocation: const LatLng(14.8245, 120.95528),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              reportId: 'over-snapped-parallel',
            ),
          ],
        );
        expect(built.summary.distinctPotholeCount, 1);
        expect(
          built.summary.potholeEncounters.single.hazard.reportId,
          'gps-offset-ok',
        );
      },
    );

    test(
      'distinguishes nearby separate potholes from duplicate canonical reports and handles mixed defects without summing cracks',
      () {
        final route = const [
          LatLng(14.8200, 120.9550),
          LatLng(14.8260, 120.9550),
        ];
        final built = PrecomputedRouteIndex.build(
          route: route,
          config: const RouteCorridorConfig(corridorMeters: 18),
          hazards: [
            // Two separate potholes only ~6 m apart, distinct report IDs & no shared canonical ID
            RouteHazardInput(
              location: const LatLng(14.82100, 120.9550),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              potholeCount: 1,
              reportId: 'sep-a',
            ),
            RouteHazardInput(
              location: const LatLng(14.82105, 120.9550),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              potholeCount: 1,
              reportId: 'sep-b',
            ),
            // Duplicate reports sharing canonicalDefectId -> count once
            RouteHazardInput(
              location: const LatLng(14.82200, 120.9550),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              potholeCount: 1,
              detectedDefects: const ['Pothole', 'Transverse crack'],
              canonicalDefectId: 'canon-dup',
              reportId: 'dup-1',
            ),
            RouteHazardInput(
              location: const LatLng(14.82204, 120.95502),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              potholeCount: 2,
              detectedDefects: const ['Pothole', 'Transverse crack'],
              canonicalDefectId: 'canon-dup',
              reportId: 'dup-2',
            ),
            // Mixed-class report where primary is Alligator crack, potholeCount=3, includes 1 Pothole + 2 cracks
            RouteHazardInput(
              location: const LatLng(14.82350, 120.9550),
              defectName: 'Alligator crack',
              dpwhCode: 'CODE 04',
              potholeCount: 3,
              detectedDefects: const [
                'Alligator crack',
                'Pothole',
                'Longitudinal crack',
              ],
              reportId: 'mixed-crack-primary',
            ),
            // Pure crack report must NOT be counted as a pothole
            RouteHazardInput(
              location: const LatLng(14.82450, 120.9550),
              defectName: 'Transverse crack',
              dpwhCode: 'CODE 03',
              potholeCount: 4,
              detectedDefects: const ['Transverse crack'],
              reportId: 'pure-crack',
            ),
          ],
        );

        // sep-a (1) + sep-b (1) + canon-dup (1) + mixed-crack-primary (1) = 4 distinct pothole sites
        expect(built.summary.distinctPotholeCount, 4);
        expect(built.summary.reportedPotholeDetectionCount, 4);
        expect(built.summary.otherDefectCounts['Alligator crack'], 1);
        expect(built.summary.otherDefectCounts['Transverse crack'], 2);
        expect(built.summary.otherDefectCounts['Longitudinal crack'], 1);
      },
    );

    test(
      'paginates more than 400 candidate corridor reports without truncating later approved reports',
      () async {
        // 950 total raw candidates across 3 pages of 400:
        // page 0: 400 invalid/out-of-lon/unapproved/inaccessible candidates
        // page 1: 397 invalid + 3 valid approved corridor reports
        // page 2: 148 invalid + 2 valid approved corridor reports
        final pages = <List<Map<String, dynamic>>>[
          List<Map<String, dynamic>>.generate(400, (i) {
            if (i % 5 == 0) {
              return {
                'page': 0,
                'id': 'p0-outlon-$i',
                'status': 'approved',
                'isResolved': false,
                'latitude': 14.821,
                'longitude': 121.200, // outside [120.94, 120.99]
              };
            }
            if (i % 5 == 1) {
              return {
                'page': 0,
                'id': 'p0-pending-$i',
                'status': 'pending',
                'isResolved': false,
                'latitude': 14.821,
                'longitude': 120.960,
              };
            }
            if (i % 5 == 2) {
              return {
                'page': 0,
                'id': 'p0-resolved-$i',
                'status': 'approved',
                'isResolved': true,
                'latitude': 14.821,
                'longitude': 120.960,
              };
            }
            if (i % 5 == 3) {
              return {
                'page': 0,
                'id': 'p0-inaccessible-$i',
                'status': 'approved',
                'isResolved': false,
                'isAccessible': false,
                'latitude': 14.821,
                'longitude': 120.960,
              };
            }
            return {
              'page': 0,
              'id': 'p0-deleted-$i',
              'status': 'deleted',
              'latitude': 14.821,
              'longitude': 120.960,
            };
          }),
          [
            ...List<Map<String, dynamic>>.generate(
              397,
              (i) => {
                'page': 1,
                'id': 'p1-outlon-$i',
                'status': 'approved',
                'latitude': 14.825,
                'longitude': 120.900, // out of lon
              },
            ),
            for (int k = 1; k <= 3; k++)
              {
                'page': 1,
                'id': 'approved-page2-$k',
                'status': 'approved',
                'isResolved': false,
                'isAccessible': true,
                'latitude': 14.825 + k * 0.0001,
                'longitude': 120.960,
              },
          ],
          [
            ...List<Map<String, dynamic>>.generate(
              148,
              (i) => {
                'page': 2,
                'id': 'p2-fixed-$i',
                'status': 'fixed',
                'latitude': 14.830,
                'longitude': 120.960,
              },
            ),
            {
              'page': 2,
              'id': 'approved-page3-1',
              'status': 'approved',
              'isResolved': false,
              'latitude': 14.831,
              'longitude': 120.961,
            },
            {
              'page': 2,
              'id': 'approved-page3-2',
              'status': 'approved',
              'isResolved': false,
              'latitude': 14.832,
              'longitude': 120.962,
            },
          ],
        ];

        int fetchedPages = 0;
        final results =
            await CloudService.paginateCorridorPages<Map<String, dynamic>>(
              pageSize: 400,
              fetchPage: (afterCursor) async {
                final int pageIdx = afterCursor == null
                    ? 0
                    : ((afterCursor['page'] as int) + 1);
                fetchedPages++;
                if (pageIdx >= pages.length) return const [];
                return pages[pageIdx];
              },
              dataOf: (doc) => doc,
              minLon: 120.94,
              maxLon: 120.99,
            );

        expect(fetchedPages, 3);
        expect(
          results.map((d) => d['id']).toList(),
          equals([
            'approved-page2-1',
            'approved-page2-2',
            'approved-page2-3',
            'approved-page3-1',
            'approved-page3-2',
          ]),
        );
      },
    );

    test(
      'keeps remainingPotholeCount consistent with totalRoutePotholeCount across multi-pass loops, new hazards, and resolved hazards',
      () {
        final loopRoute = const [
          LatLng(14.8200, 120.9550),
          LatLng(14.8250, 120.9550),
          LatLng(14.8250, 120.9570),
          LatLng(14.8200, 120.9570),
          LatLng(14.8200, 120.9550),
          LatLng(
            14.8250,
            120.9550,
          ), // second northbound pass over the same point
        ];
        final singleCanonHazard = RouteHazardInput(
          location: const LatLng(14.8225, 120.9550),
          defectName: 'Pothole',
          dpwhCode: 'CODE 01',
          canonicalDefectId: 'loop-canon-1',
          reportId: 'r-loop',
        );

        final initialIndex = PrecomputedRouteIndex.build(
          route: loopRoute,
          hazards: [singleCanonHazard],
          config: const RouteCorridorConfig(corridorMeters: 18),
        );
        expect(initialIndex.summary.distinctPotholeCount, 1);
        expect(initialIndex.summary.potholeEncounters.length, 2);

        final tracker = NavigationHazardTracker(initialIndex);

        // Start: 1 distinct pothole total, 1 remaining distinct pothole, 2 remaining encounters
        final s0 = tracker.update(
          position: const LatLng(14.8205, 120.9550),
          timestamp: DateTime(2026, 11, 16, 8, 0, 0),
          now: DateTime(2026, 11, 16, 8, 0, 0),
        );
        expect(s0.totalRoutePotholeCount, 1);
        expect(s0.remainingPotholeCount, 1);
        expect(s0.remainingEncounterCount, 2);
        expect(s0.totalRouteEncounterCount, 2);

        // Pass the first northbound encounter -> southbound leg has 1 distinct remaining & 1 encounter
        tracker.update(
          position: const LatLng(14.8235, 120.9550),
          timestamp: DateTime(2026, 11, 16, 8, 0, 10),
          now: DateTime(2026, 11, 16, 8, 0, 10),
        );
        final sMid = tracker.update(
          position: const LatLng(14.8250, 120.9565),
          timestamp: DateTime(2026, 11, 16, 8, 0, 20),
          now: DateTime(2026, 11, 16, 8, 0, 20),
        );
        expect(
          sMid.remainingPotholeCount,
          lessThanOrEqualTo(sMid.totalRoutePotholeCount),
        );
        expect(sMid.remainingPotholeCount, 1);
        expect(sMid.remainingEncounterCount, 1);

        // Now resolve the hazard mid-route and verify replaceRouteIndex preserves chain lock & drops total to 0
        final resolvedIndex = PrecomputedRouteIndex.build(
          route: loopRoute,
          hazards: [
            RouteHazardInput(
              location: const LatLng(14.8225, 120.9550),
              defectName: 'Pothole',
              dpwhCode: 'CODE 01',
              canonicalDefectId: 'loop-canon-1',
              reportId: 'r-loop',
              isResolved: true,
            ),
          ],
          config: const RouteCorridorConfig(corridorMeters: 18),
        );
        tracker.replaceRouteIndex(
          resolvedIndex,
          keepAlerts: true,
          preserveProgress: true,
        );
        final sAfterResolve = tracker.update(
          position: const LatLng(14.8240, 120.9570),
          timestamp: DateTime(2026, 11, 16, 8, 0, 25),
          now: DateTime(2026, 11, 16, 8, 0, 25),
        );
        expect(sAfterResolve.totalRoutePotholeCount, 0);
        expect(sAfterResolve.remainingPotholeCount, 0);
        expect(sAfterResolve.remainingEncounterCount, 0);
      },
    );
  });

  group('Mixed-defect parsing and cache round-trip', () {
    test(
      'parses defectClasses fallback and preserves multi-defect pothole matching across cache JSON',
      () {
        final rawData = <String, dynamic>{
          'primaryDefect': 'Longitudinal crack',
          'defectClasses': ['Longitudinal crack', 'Pothole'],
        };

        final parsedDetections = DpwhStandards.parseDetectionsWithFallback(
          rawData,
        );
        expect(parsedDetections, isNotNull);

        final extracted = DpwhStandards.extractDetectionClassNames(
          parsedDetections,
        );
        expect(extracted, equals(['Longitudinal crack', 'Pothole']));

        final cachedClasses = DpwhStandards.extractCachedDefectClasses(
          parsedDetections,
          'Longitudinal crack',
        );
        final record = CachedReportRecord(
          docId: 'mixed-doc-1',
          canonicalDefectId: 'canon-mixed-1',
          latitude: 14.8225,
          longitude: 120.9550,
          primaryDefect: 'Longitudinal crack',
          primaryDpwhCode: 'CODE 04',
          status: 'approved',
          isResolved: false,
          potholeCount: 1,
          defectClasses: cachedClasses,
          barangay: 'San Gabriel',
          city: 'Santa Maria',
          province: 'Bulacan',
          formattedAddress: 'San Gabriel, Santa Maria, Bulacan',
          roadName: 'J. P. Rizal Street',
          roadBearingDeg: 45.0,
          roadMatched: true,
          updatedAtMs: 1731740000000,
        );

        final restored = CachedReportRecord.fromJson(record.toJson());
        expect(restored, isNotNull);
        expect(
          restored!.defectClasses,
          equals(['Longitudinal crack', 'Pothole']),
        );
        expect(restored.roadBearingDeg, 45.0);
        expect(restored.roadMatched, isTrue);

        final input = RouteHazardInput(
          reportId: restored.docId,
          canonicalDefectId: restored.canonicalDefectId,
          location: LatLng(restored.latitude, restored.longitude),
          status: restored.status,
          isResolved: restored.isResolved,
          defectName: restored.primaryDefect,
          dpwhCode: restored.primaryDpwhCode,
          potholeCount: restored.potholeCount,
          detectedDefects: restored.defectClasses,
          roadBearingDeg: restored.roadBearingDeg,
          roadMatched: restored.roadMatched,
        );
        expect(input.isPotholeClass, isFalse);
        expect(input.containsPotholeClass, isTrue);
        expect(input.resolvedPotholeDetectionCount, 1);
      },
    );
  });
}
