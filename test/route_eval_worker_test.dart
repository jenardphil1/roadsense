import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:my_flutter_app/route_pothole_advisor.dart';

void main() {
  test(
    'evaluateRouteAlternativesWorker matches synchronous evaluation via compute()',
    () async {
      final routeA = <LatLng>[
        const LatLng(14.8190, 120.9560),
        const LatLng(14.8210, 120.9580),
        const LatLng(14.8235, 120.9605),
      ];
      final routeB = <LatLng>[
        const LatLng(14.8190, 120.9560),
        const LatLng(14.8200, 120.9620),
        const LatLng(14.8235, 120.9605),
      ];
      final hazards = <RouteHazardInput>[
        RouteHazardInput(
          location: const LatLng(14.8210, 120.9580),
          defectName: 'Pothole',
          dpwhCode: 'CODE 01',
          barangay: 'Poblacion',
          status: 'approved',
          reportId: 'r-1',
        ),
        RouteHazardInput(
          location: const LatLng(14.8220, 120.9590),
          defectName: 'Alligator Crack',
          dpwhCode: 'CODE 02',
          barangay: 'Poblacion',
          status: 'approved',
          reportId: 'r-2',
        ),
      ];
      final req = RouteAlternativesEvalRequest(
        routes: [routeA, routeB],
        distancesMeters: const [650.0, 820.0],
        durationsSeconds: const [75.0, 92.0],
        hazards: hazards,
        viaSummaries: const ['Main Rd', 'Bypass Rd'],
        stepsByRoute: const [<RouteStepRoadSpan>[], <RouteStepRoadSpan>[]],
        corridorConfig: const RouteCorridorConfig(),
      );

      final direct = RoutePotholeAdvisor.evaluateAlternatives(
        routes: req.routes,
        distancesMeters: req.distancesMeters,
        durationsSeconds: req.durationsSeconds,
        hazards: req.hazards,
        viaSummaries: req.viaSummaries,
        stepsByRoute: req.stepsByRoute,
        corridorConfig: req.corridorConfig,
      );
      final workerResult = await compute(evaluateRouteAlternativesWorker, req);

      expect(workerResult.options.length, direct.options.length);
      for (int i = 0; i < direct.options.length; i++) {
        expect(
          workerResult.options[i].routeIndex,
          direct.options[i].routeIndex,
        );
        expect(
          workerResult.options[i].summary.distinctPotholeCount,
          direct.options[i].summary.distinctPotholeCount,
        );
        expect(
          workerResult.options[i].summary.totalOtherDefectsCount,
          direct.options[i].summary.totalOtherDefectsCount,
        );
      }
    },
  );
}
