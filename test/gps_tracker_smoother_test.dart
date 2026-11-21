import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:my_flutter_app/gps_tracker_smoother.dart';

void main() {
  group('GpsTrackerSmoother', () {
    final baseTime = DateTime(2026, 11, 20, 14, 0, 0);

    LatLng moveNorth(LatLng origin, double meters) =>
        LatLng(origin.latitude + meters / 111320.0, origin.longitude);

    LatLng moveEast(LatLng origin, double meters) =>
        LatLng(origin.latitude, origin.longitude + meters / 107580.0);

    test(
      'high-speed travel glides smoothly between 1 Hz fixes without lunging or jumping backward',
      () {
        final smoother = GpsTrackerSmoother();
        const origin = LatLng(14.8500, 120.9500);
        const speedMps = 20.0; // 72 km/h

        // Initial lock
        final r0 = smoother.ingestFix(
          GpsFixSample(
            position: origin,
            timestamp: baseTime,
            accuracyMeters: 6.0,
            speedMps: speedMps,
            headingDeg: 0.0,
          ),
        );
        expect(r0.accepted, isTrue);
        expect(r0.shouldSnapImmediately, isTrue);

        // Simulate 3 seconds of 1 Hz GPS fixes with 60 FPS rendering in between.
        double lastLat = origin.latitude;
        double maxStepMeters = 0.0;

        for (int sec = 1; sec <= 3; sec++) {
          // 59 intermediate 60 FPS frames between fixes
          for (int f = 1; f < 60; f++) {
            final now = baseTime.add(
              Duration(milliseconds: (sec - 1) * 1000 + (f * 1000 ~/ 60)),
            );
            final frame = smoother.advanceFrame(now: now, dtSeconds: 1.0 / 60.0);
            expect(frame.position, isNotNull);
            // Must move monotonically forward (north) without snapping backward
            expect(frame.position!.latitude, greaterThanOrEqualTo(lastLat - 1e-7));
            final step = GpsTrackerSmoother.distanceMeters(
              LatLng(lastLat, origin.longitude),
              frame.position!,
            );
            if (step > maxStepMeters) maxStepMeters = step;
            lastLat = frame.position!.latitude;
          }

          // Next 1 Hz GPS fix arrives
          final nextPos = moveNorth(origin, speedMps * sec);
          final res = smoother.ingestFix(
            GpsFixSample(
              position: nextPos,
              timestamp: baseTime.add(Duration(seconds: sec)),
              accuracyMeters: 6.0,
              speedMps: speedMps,
              headingDeg: 0.0,
            ),
          );
          expect(res.accepted, isTrue);
        }

        // At 20 m/s @ 60 FPS, ideal step is ~0.33m/frame; smooth glide never jumps > 1.5m/frame.
        expect(maxStepMeters, lessThan(1.5));
        // After 3 seconds at 20 m/s, puck should be close to 60m north (no heavy lag).
        final totalMoved = GpsTrackerSmoother.distanceMeters(
          origin,
          smoother.displayPosition!,
        );
        expect(totalMoved, greaterThan(48.0));
        expect(totalMoved, lessThan(68.0));
      },
    );

    test('rejects single-fix teleport spike and poor-accuracy network bounce', () {
      final smoother = GpsTrackerSmoother();
      const origin = LatLng(14.8500, 120.9500);

      smoother.ingestFix(
        GpsFixSample(
          position: origin,
          timestamp: baseTime,
          accuracyMeters: 6.0,
          speedMps: 15.0,
          headingDeg: 0.0,
        ),
      );

      // 1) Sudden 600m sideways spike 1 second later -> rejected
      final spike = smoother.ingestFix(
        GpsFixSample(
          position: moveEast(origin, 600.0),
          timestamp: baseTime.add(const Duration(seconds: 1)),
          accuracyMeters: 10.0,
          speedMps: 15.0,
        ),
      );
      expect(spike.accepted, isFalse);
      expect(
        GpsTrackerSmoother.distanceMeters(origin, smoother.filteredPosition!),
        lessThan(1.0),
      );

      // 2) Poor accuracy 120m cell-tower bounce -> rejected
      final noisy = smoother.ingestFix(
        GpsFixSample(
          position: moveEast(origin, 40.0),
          timestamp: baseTime.add(const Duration(seconds: 2)),
          accuracyMeters: 120.0,
          speedMps: 15.0,
        ),
      );
      expect(noisy.accepted, isFalse);

      // 3) Valid next fix resumes cleanly
      final valid = smoother.ingestFix(
        GpsFixSample(
          position: moveNorth(origin, 30.0),
          timestamp: baseTime.add(const Duration(seconds: 2)),
          accuracyMeters: 5.0,
          speedMps: 15.0,
          headingDeg: 0.0,
        ),
      );
      expect(valid.accepted, isTrue);
    });

    test('accepts genuine tunnel-exit re-lock after two consistent fixes', () {
      final smoother = GpsTrackerSmoother();
      const origin = LatLng(14.8500, 120.9500);
      final exitPos = moveNorth(origin, 500.0);

      smoother.ingestFix(
        GpsFixSample(
          position: origin,
          timestamp: baseTime,
          accuracyMeters: 8.0,
          speedMps: 15.0,
        ),
      );

      // First fix after tunnel exit looks like a spike -> held for confirmation
      final first = smoother.ingestFix(
        GpsFixSample(
          position: exitPos,
          timestamp: baseTime.add(const Duration(seconds: 1)),
          accuracyMeters: 8.0,
          speedMps: 15.0,
        ),
      );
      expect(first.accepted, isFalse);

      // Second consistent fix near exit -> accepted and snapped cleanly
      final second = smoother.ingestFix(
        GpsFixSample(
          position: moveNorth(exitPos, 15.0),
          timestamp: baseTime.add(const Duration(seconds: 2)),
          accuracyMeters: 8.0,
          speedMps: 15.0,
        ),
      );
      expect(second.accepted, isTrue);
      expect(second.shouldSnapImmediately, isTrue);
      expect(
        GpsTrackerSmoother.distanceMeters(
          moveNorth(exitPos, 15.0),
          smoother.displayPosition!,
        ),
        lessThan(1.0),
      );
    });

    test('stationary deadband suppresses GPS drift jitter and settles ticker', () {
      final smoother = GpsTrackerSmoother();
      const origin = LatLng(14.8500, 120.9500);

      smoother.ingestFix(
        GpsFixSample(
          position: origin,
          timestamp: baseTime,
          accuracyMeters: 8.0,
          speedMps: 0.0,
        ),
      );

      // 2-meter jitter while stopped should not move filtered position
      final jitter = smoother.ingestFix(
        GpsFixSample(
          position: moveEast(origin, 2.0),
          timestamp: baseTime.add(const Duration(seconds: 1)),
          accuracyMeters: 8.0,
          speedMps: 0.2,
        ),
      );
      expect(jitter.accepted, isTrue);
      expect(
        GpsTrackerSmoother.distanceMeters(origin, smoother.filteredPosition!),
        lessThan(0.01),
      );

      final frame = smoother.advanceFrame(
        now: baseTime.add(const Duration(seconds: 1, milliseconds: 50)),
        dtSeconds: 1.0 / 60.0,
      );
      expect(frame.isSettled, isTrue);
    });

    test(
      'snaps perpendicular GPS jitter to active route and curves dead-reckoning around bends',
      () {
        final smoother = GpsTrackerSmoother();
        const p0 = LatLng(14.8500, 120.9500);
        final p1 = moveNorth(p0, 40.0); // bend at 40m north
        final p2 = moveEast(p1, 100.0); // turns east
        final route = [p0, p1, p2];

        // Lock near start, moving north at 20 m/s
        smoother.ingestFix(
          GpsFixSample(
            position: moveNorth(p0, 10.0),
            timestamp: baseTime,
            accuracyMeters: 6.0,
            speedMps: 20.0,
            headingDeg: 0.0,
          ),
          activeRoute: route,
        );

        // Fix 1s later at 30m north with 8m lateral east jitter -> snapped back to N-S road
        final res = smoother.ingestFix(
          GpsFixSample(
            position: moveEast(moveNorth(p0, 30.0), 8.0),
            timestamp: baseTime.add(const Duration(seconds: 1)),
            accuracyMeters: 6.0,
            speedMps: 20.0,
            headingDeg: 0.0,
          ),
          activeRoute: route,
        );
        expect(res.accepted, isTrue);
        // Snapped to the N-S segment: longitude matches p0 closely
        expect(
          (res.filteredPosition!.longitude - p0.longitude).abs(),
          lessThan(1e-5),
        );

        // Dead-reckon 0.8s ahead (16m past 30m -> 6m around the 90° east bend!).
        for (int i = 1; i <= 50; i++) {
          smoother.advanceFrame(
            now: baseTime.add(Duration(milliseconds: 1000 + i * 16)),
            dtSeconds: 0.016,
          );
        }
        // Puck should have curved east along p1->p2 instead of overshooting north past p1.
        expect(smoother.displayPosition!.latitude, lessThanOrEqualTo(p1.latitude + 1e-5));
        expect(smoother.displayPosition!.longitude, greaterThan(p0.longitude + 1e-5));
      },
    );

    test(
      'fuses steady GPS course at speed and ignores magnetometer interference until stopped',
      () {
        final smoother = GpsTrackerSmoother();
        const origin = LatLng(14.8500, 120.9500);

        smoother.ingestFix(
          GpsFixSample(
            position: origin,
            timestamp: baseTime,
            accuracyMeters: 5.0,
            speedMps: 14.0,
            headingDeg: 355.0,
          ),
        );

        // Wild magnetometer interference at speed should be ignored
        smoother.ingestCompassHeading(
          180.0,
          now: baseTime.add(const Duration(milliseconds: 200)),
        );

        // Next GPS fix crosses 0° north smoothly (355° -> 5°)
        smoother.ingestFix(
          GpsFixSample(
            position: moveNorth(origin, 14.0),
            timestamp: baseTime.add(const Duration(seconds: 1)),
            accuracyMeters: 5.0,
            speedMps: 14.0,
            headingDeg: 5.0,
          ),
        );

        for (int i = 0; i < 30; i++) {
          smoother.advanceFrame(
            now: baseTime.add(Duration(milliseconds: 1000 + i * 16)),
            dtSeconds: 0.016,
          );
        }
        // Should wrap cleanly through 0° toward 5°, never swinging through 180°
        final h = smoother.displayHeadingDeg!;
        expect(h <= 10.0 || h >= 350.0, isTrue);

        // Once stopped, compass regains control
        smoother.ingestFix(
          GpsFixSample(
            position: moveNorth(origin, 14.0),
            timestamp: baseTime.add(const Duration(seconds: 2)),
            accuracyMeters: 5.0,
            speedMps: 0.0,
          ),
        );
        smoother.ingestCompassHeading(
          90.0,
          now: baseTime.add(const Duration(seconds: 2, milliseconds: 100)),
        );
        for (int i = 0; i < 60; i++) {
          smoother.advanceFrame(
            now: baseTime.add(Duration(milliseconds: 2100 + i * 16)),
            dtSeconds: 0.016,
          );
        }
        expect(smoother.displayHeadingDeg!, closeTo(90.0, 2.0));
      },
    );

    test(
      'routeForwardBearingDeg skips short driveway spur and looks ahead along route',
      () {
        const origin = LatLng(14.8500, 120.9500);
        // Short 5m east driveway spur, then straight north for 100m
        final p1 = moveEast(origin, 5.0);
        final p2 = moveNorth(p1, 100.0);
        final route = [origin, p1, p2];

        final bearing = GpsTrackerSmoother.routeForwardBearingDeg(
          route,
          origin,
          lookaheadMeters: 30.0,
          maxDistanceMeters: 120.0,
        );
        expect(bearing, isNotNull);
        // Must point predominantly north (~9.5° east of due north, not 90° east!)
        expect(bearing! < 20.0 || bearing > 340.0, isTrue);

        // Returns null when too far from route
        final farBearing = GpsTrackerSmoother.routeForwardBearingDeg(
          route,
          moveEast(origin, 250.0),
          maxDistanceMeters: 120.0,
        );
        expect(farBearing, isNull);
      },
    );

    test(
      'setHeading overrides stale compass heading and stationary nav ingestFix stays aligned to route',
      () {
        final smoother = GpsTrackerSmoother();
        const origin = LatLng(14.8500, 120.9500);
        final route = [origin, moveNorth(origin, 150.0)];

        // Simulate stale pre-navigation compass pointing south (180°)
        smoother.ingestCompassHeading(180.0, now: baseTime);
        expect(smoother.displayHeadingDeg, closeTo(180.0, 1e-3));

        // Explicitly align to route forward heading (0° north)
        final routeHeading = GpsTrackerSmoother.routeForwardBearingDeg(
          route,
          origin,
          lookaheadMeters: 30.0,
          maxDistanceMeters: 500.0,
        )!;
        smoother.setHeading(routeHeading);
        expect(smoother.displayHeadingDeg, closeTo(0.0, 1.0));

        // Stationary GPS fix in driving mode (~15m off route, within 80m) must
        // keep pointing along the route and never revert to stale 180°.
        final res = smoother.ingestFix(
          GpsFixSample(
            position: moveEast(origin, 15.0),
            timestamp: baseTime.add(const Duration(seconds: 1)),
            accuracyMeters: 8.0,
            speedMps: 0.0,
          ),
          activeRoute: route,
          isNavigating: true,
        );
        expect(res.accepted, isTrue);
        expect(res.fusedHeadingDeg, closeTo(0.0, 1.0));
        expect(smoother.displayHeadingDeg, closeTo(0.0, 1.0));
      },
    );
  });
}
