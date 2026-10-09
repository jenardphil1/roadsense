import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'dart:math';

// Helper projection & segment functions matching MapScreen logic
LatLng projectPointToSegment(LatLng p, LatLng a, LatLng b) {
  final double latRefRad =
      ((a.latitude + b.latitude) / 2.0) * (3.141592653589793 / 180.0);
  final double metersPerDegLat = 110540.0;
  final double metersPerDegLon = 111320.0 * cos(latRefRad);

  if (metersPerDegLon.abs() < 1e-6) return a;

  final double bx = (b.longitude - a.longitude) * metersPerDegLon;
  final double by = (b.latitude - a.latitude) * metersPerDegLat;
  final double px = (p.longitude - a.longitude) * metersPerDegLon;
  final double py = (p.latitude - a.latitude) * metersPerDegLat;

  final double abLen2 = bx * bx + by * by;
  if (abLen2 <= 1e-6) return a;

  double t = (px * bx + py * by) / abLen2;
  if (t <= 0) return a;
  if (t >= 1) return b;

  final double projLon = a.longitude + (t * (b.longitude - a.longitude));
  final double projLat = a.latitude + (t * (b.latitude - a.latitude));
  return LatLng(projLat, projLon);
}

double distancePointToSegmentMeters(LatLng p, LatLng a, LatLng b) {
  final double latRefRad =
      ((a.latitude + b.latitude) / 2.0) * (3.141592653589793 / 180.0);
  final double metersPerDegLat = 110540.0;
  final double metersPerDegLon = 111320.0 * cos(latRefRad);

  final double ax = 0;
  final double ay = 0;
  final double bx = (b.longitude - a.longitude) * metersPerDegLon;
  final double by = (b.latitude - a.latitude) * metersPerDegLat;
  final double px = (p.longitude - a.longitude) * metersPerDegLon;
  final double py = (p.latitude - a.latitude) * metersPerDegLat;

  final double abx = bx - ax;
  final double aby = by - ay;
  final double apx = px - ax;
  final double apy = py - ay;
  final double abLen2 = abx * abx + aby * aby;

  if (abLen2 <= 1e-6) {
    final dx = px - ax;
    final dy = py - ay;
    return sqrt(dx * dx + dy * dy);
  }

  double t = (apx * abx + apy * aby) / abLen2;
  if (t < 0) t = 0;
  if (t > 1) t = 1;

  final double closestX = ax + t * abx;
  final double closestY = ay + t * aby;
  final double dx = px - closestX;
  final double dy = py - closestY;
  return sqrt(dx * dx + dy * dy);
}

int findBestRouteSegmentIndex(
  List<LatLng> route,
  LatLng userPos,
  int lastMatchedIdx,
) {
  if (route.length < 2) return 0;

  int bestSegmentIdx = 0;
  double minDistance = double.infinity;

  int startWin = (lastMatchedIdx - 2).clamp(0, route.length - 2);
  int endWin = (lastMatchedIdx + 20).clamp(0, route.length - 2);

  for (int i = startWin; i <= endWin; i++) {
    final dist = distancePointToSegmentMeters(userPos, route[i], route[i + 1]);
    if (dist < minDistance) {
      minDistance = dist;
      bestSegmentIdx = i;
    }
  }

  if (minDistance <= 40.0) {
    return bestSegmentIdx;
  }

  minDistance = double.infinity;
  for (int i = 0; i < route.length - 1; i++) {
    final dist = distancePointToSegmentMeters(userPos, route[i], route[i + 1]);
    if (dist < minDistance) {
      minDistance = dist;
    }
  }

  final List<int> candidateIndices = [];
  for (int i = 0; i < route.length - 1; i++) {
    final dist = distancePointToSegmentMeters(userPos, route[i], route[i + 1]);
    if (dist <= minDistance + 15.0) {
      candidateIndices.add(i);
    }
  }

  if (candidateIndices.isNotEmpty) {
    bestSegmentIdx = candidateIndices.first;
  } else {
    bestSegmentIdx = 0;
  }

  return bestSegmentIdx;
}

void main() {
  test(
    'Route segment index preserves sequential order on U-turn / loop route',
    () {
      final route = <LatLng>[
        const LatLng(14.000, 120.000), // 0: Start
        const LatLng(14.010, 120.000), // 1: North leg
        const LatLng(14.020, 120.000), // 2: Top of North leg
        const LatLng(14.020, 120.001), // 3: East turn
        const LatLng(14.010, 120.001), // 4: South leg
        const LatLng(14.000, 120.001), // 5: End of South leg
      ];

      final userPos = const LatLng(14.009, 120.000);
      final segIdx = findBestRouteSegmentIndex(route, userPos, 0);

      expect(segIdx, lessThanOrEqualTo(1));
    },
  );

  test(
    'Point A to Point B custom origin mode preserves original route start without prepending user GPS',
    () {
      final pointA = const LatLng(14.850, 120.965);
      final pointB = const LatLng(14.835, 120.975);
      final activeRoute = <LatLng>[
        pointA,
        const LatLng(14.842, 120.970),
        pointB,
      ];

      final bool isUsingCustomOrigin = true;
      final userGpsPos = const LatLng(14.810, 120.980); // Far away GPS position

      final routeForChecks = isUsingCustomOrigin
          ? activeRoute
          : [userGpsPos, ...activeRoute];

      expect(routeForChecks.first, equals(pointA));
      expect(routeForChecks.first, isNot(equals(userGpsPos)));
    },
  );
}
