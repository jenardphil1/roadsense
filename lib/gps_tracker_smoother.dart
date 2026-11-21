import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// Raw location sample fed into [GpsTrackerSmoother].
class GpsFixSample {
  final LatLng position;
  final DateTime timestamp;
  final double accuracyMeters;
  final double speedMps;
  final double? headingDeg;
  final bool isMock;

  const GpsFixSample({
    required this.position,
    required this.timestamp,
    this.accuracyMeters = 10.0,
    this.speedMps = 0.0,
    this.headingDeg,
    this.isMock = false,
  });
}

/// Result of processing a single GPS fix.
class GpsFilterResult {
  final bool accepted;
  final LatLng? filteredPosition;
  final double? fusedHeadingDeg;
  final double speedMps;
  final bool shouldSnapImmediately;

  const GpsFilterResult({
    required this.accepted,
    this.filteredPosition,
    this.fusedHeadingDeg,
    this.speedMps = 0.0,
    this.shouldSnapImmediately = false,
  });
}

/// Output of a single 60 FPS frame tick.
class GpsFrameState {
  final LatLng? position;
  final double? headingDeg;
  final bool isSettled;

  const GpsFrameState({
    this.position,
    this.headingDeg,
    this.isSettled = true,
  });
}

class _RouteProjection {
  final LatLng point;
  final double distanceMeters;
  final int segmentIndex;
  final double segmentT;
  final double segmentBearingDeg;

  const _RouteProjection({
    required this.point,
    required this.distanceMeters,
    required this.segmentIndex,
    required this.segmentT,
    required this.segmentBearingDeg,
  });
}

/// Filters noisy GPS fixes, rejects high-speed spikes/glitches, optionally snaps
/// smoothly onto an active navigation route, fuses GPS course with compass
/// heading, and produces continuous 60 FPS puck motion without start-stop jumps.
class GpsTrackerSmoother {
  static const double _metersPerLatDeg = 111320.0;
  static const double _maxPlausibleSpeedMps = 55.0; // ~198 km/h
  static const double _maxDeadReckonSeconds = 1.0;
  static const double _gpsHeadingMinSpeedMps = 2.0; // ~7.2 km/h
  static const double _maxAccuracyMeters = 65.0;

  LatLng? _filteredPos;
  LatLng? _displayPos;
  double? _displayHeadingDeg;
  double? _targetHeadingDeg;

  double _velNorthMps = 0.0;
  double _velEastMps = 0.0;
  double _speedMps = 0.0;
  double _varianceM2 = 100.0;

  DateTime? _lastFixTime;
  double _lastAccuracyM = 10.0;
  int _consecutiveOutliers = 0;
  LatLng? _pendingOutlierPos;

  List<LatLng>? _lastRoute;
  int? _routeSnapIndex;
  bool _snappedToRoute = false;
  int _snappedSegmentIndex = 0;
  double _snappedSegmentT = 0.0;
  bool _movingForwardAlongRoute = true;

  LatLng? get displayPosition => _displayPos;
  LatLng? get filteredPosition => _filteredPos;
  double? get displayHeadingDeg => _displayHeadingDeg;
  double get speedMps => _speedMps;

  static double normalizeAngleDeg(double deg) => ((deg % 360.0) + 360.0) % 360.0;

  static double shortestAngleDeltaDeg(double fromDeg, double toDeg) =>
      ((toDeg - fromDeg + 540.0) % 360.0) - 180.0;

  static double _metersPerLngDeg(double latDeg) =>
      _metersPerLatDeg * math.cos(latDeg * math.pi / 180.0).clamp(0.01, 1.0);

  static double distanceMeters(LatLng a, LatLng b) {
    final avgLat = (a.latitude + b.latitude) * 0.5;
    final dNorth = (b.latitude - a.latitude) * _metersPerLatDeg;
    final dEast = (b.longitude - a.longitude) * _metersPerLngDeg(avgLat);
    return math.sqrt(dNorth * dNorth + dEast * dEast);
  }

  static double bearingDeg(LatLng a, LatLng b) {
    final avgLat = (a.latitude + b.latitude) * 0.5;
    final dNorth = (b.latitude - a.latitude) * _metersPerLatDeg;
    final dEast = (b.longitude - a.longitude) * _metersPerLngDeg(avgLat);
    if (dNorth == 0.0 && dEast == 0.0) return 0.0;
    return normalizeAngleDeg(math.atan2(dEast, dNorth) * 180.0 / math.pi);
  }

  /// Projects [origin] onto [route] and computes the forward road bearing
  /// [lookaheadMeters] ahead along the polyline, avoiding short initial spurs.
  static double? routeForwardBearingDeg(
    List<LatLng> route,
    LatLng origin, {
    double lookaheadMeters = 30.0,
    double maxDistanceMeters = 120.0,
  }) {
    if (route.length < 2) return null;
    final best = _projectRange(route, origin, 0, route.length - 2);
    if (best == null || best.distanceMeters > maxDistanceMeters) return null;
    final ahead = _advanceAlongRoute(
      route,
      best.segmentIndex,
      best.segmentT,
      lookaheadMeters,
    );
    return distanceMeters(best.point, ahead) >= 1.0
        ? bearingDeg(best.point, ahead)
        : best.segmentBearingDeg;
  }

  static LatLng _offsetMeters(LatLng origin, double northMeters, double eastMeters) {
    final dLat = northMeters / _metersPerLatDeg;
    final dLng = eastMeters / _metersPerLngDeg(origin.latitude);
    return LatLng(origin.latitude + dLat, origin.longitude + dLng);
  }

  static LatLng _lerpLatLng(LatLng a, LatLng b, double t) {
    final clamped = t.clamp(0.0, 1.0);
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * clamped,
      a.longitude + (b.longitude - a.longitude) * clamped,
    );
  }

  /// Explicitly sets both target and display heading (e.g., aligning to route on nav start).
  void setHeading(double headingDeg) {
    if (!headingDeg.isFinite) return;
    final normalized = normalizeAngleDeg(headingDeg);
    _targetHeadingDeg = normalized;
    _displayHeadingDeg = normalized;
  }

  /// Resets filter state (for dev mock jumps, simulation start, or explicit snap).
  void reset({LatLng? position, double? headingDeg}) {
    _filteredPos = position;
    _displayPos = position;
    if (headingDeg != null && headingDeg.isFinite) {
      final norm = normalizeAngleDeg(headingDeg);
      _displayHeadingDeg = norm;
      _targetHeadingDeg = norm;
    }
    _velNorthMps = 0.0;
    _velEastMps = 0.0;
    _speedMps = 0.0;
    _varianceM2 = 25.0;
    _lastFixTime = null;
    _lastAccuracyM = 10.0;
    _consecutiveOutliers = 0;
    _pendingOutlierPos = null;
    _lastRoute = null;
    _routeSnapIndex = null;
    _snappedToRoute = false;
  }

  /// Ingests a raw GPS fix and updates the filtered target, velocity, and
  /// heading. Returns whether the fix was accepted or rejected as a glitch.
  GpsFilterResult ingestFix(
    GpsFixSample fix, {
    List<LatLng>? activeRoute,
    double routeSnapMaxMeters = 22.0,
    bool isNavigating = false,
  }) {
    final accuracy = (fix.accuracyMeters.isFinite && fix.accuracyMeters > 0)
        ? fix.accuracyMeters
        : 10.0;
    final hasReportedSpeed = fix.speedMps.isFinite && fix.speedMps >= 0.0;
    final reportedSpeed = hasReportedSpeed ? fix.speedMps : 0.0;
    final validCourse =
        fix.headingDeg != null &&
        fix.headingDeg!.isFinite &&
        fix.headingDeg! >= 0.0 &&
        fix.headingDeg! <= 360.0;

    if (!identical(_lastRoute, activeRoute)) {
      _lastRoute = activeRoute;
      _routeSnapIndex = null;
      _snappedToRoute = false;
    }

    // First lock ever: initialize directly without lag.
    if (_filteredPos == null || _lastFixTime == null) {
      var initialPos = fix.position;
      if (activeRoute != null && activeRoute.length >= 2) {
        final proj = _projectOntoRoute(activeRoute, initialPos);
        if (proj != null && proj.distanceMeters <= routeSnapMaxMeters) {
          initialPos = proj.point;
          _snappedToRoute = true;
          _snappedSegmentIndex = proj.segmentIndex;
          _snappedSegmentT = proj.segmentT;
          _routeSnapIndex = proj.segmentIndex;
        }
      }
      _filteredPos = initialPos;
      _displayPos ??= initialPos;
      _varianceM2 = accuracy * accuracy;
      _lastFixTime = fix.timestamp;
      _lastAccuracyM = accuracy;
      _speedMps = reportedSpeed;
      double? fusedHeading;
      if (validCourse && reportedSpeed >= _gpsHeadingMinSpeedMps) {
        fusedHeading = normalizeAngleDeg(fix.headingDeg!);
        _targetHeadingDeg = fusedHeading;
        _displayHeadingDeg ??= fusedHeading;
        final rad = fusedHeading * math.pi / 180.0;
        _velNorthMps = reportedSpeed * math.cos(rad);
        _velEastMps = reportedSpeed * math.sin(rad);
      } else {
        if (isNavigating && activeRoute != null && activeRoute.length >= 2) {
          final navHeading = routeForwardBearingDeg(
            activeRoute,
            initialPos,
            lookaheadMeters: 28.0,
            maxDistanceMeters: 80.0,
          );
          if (navHeading != null) {
            fusedHeading = navHeading;
            _targetHeadingDeg = navHeading;
            _displayHeadingDeg ??= navHeading;
          }
        }
        _velNorthMps = 0.0;
        _velEastMps = 0.0;
      }
      return GpsFilterResult(
        accepted: true,
        filteredPosition: initialPos,
        fusedHeadingDeg: fusedHeading,
        speedMps: _speedMps,
        shouldSnapImmediately: true,
      );
    }

    final dtSec =
        fix.timestamp.difference(_lastFixTime!).inMicroseconds / 1e6;
    if (dtSec < 0) {
      return GpsFilterResult(
        accepted: false,
        filteredPosition: _filteredPos,
        speedMps: _speedMps,
      );
    }

    // Mock/simulation path: accept directly and compute exact velocity for
    // butter-smooth constant-speed glide.
    if (fix.isMock) {
      final prev = _filteredPos!;
      final safeDt = math.max(dtSec, 0.05);
      final dNorth = (fix.position.latitude - prev.latitude) * _metersPerLatDeg;
      final dEast =
          (fix.position.longitude - prev.longitude) *
          _metersPerLngDeg((prev.latitude + fix.position.latitude) * 0.5);
      final dist = math.sqrt(dNorth * dNorth + dEast * dEast);
      _velNorthMps = (dNorth / safeDt).clamp(-60.0, 60.0);
      _velEastMps = (dEast / safeDt).clamp(-60.0, 60.0);
      _speedMps = reportedSpeed > 0 ? reportedSpeed : (dist / safeDt);
      _filteredPos = fix.position;
      _displayPos ??= fix.position;
      _lastFixTime = fix.timestamp;
      _lastAccuracyM = 5.0;
      _snappedToRoute = false;
      double? fusedHeading;
      if (validCourse) {
        fusedHeading = normalizeAngleDeg(fix.headingDeg!);
      } else if (dist >= 0.5) {
        fusedHeading = bearingDeg(prev, fix.position);
      }
      if (fusedHeading != null) {
        _targetHeadingDeg = fusedHeading;
        _displayHeadingDeg ??= fusedHeading;
      }
      final snapNow = dist > 250.0;
      if (snapNow) {
        _displayPos = fix.position;
      }
      return GpsFilterResult(
        accepted: true,
        filteredPosition: _filteredPos,
        fusedHeadingDeg: fusedHeading,
        speedMps: _speedMps,
        shouldSnapImmediately: snapNow,
      );
    }

    // Reject severely inaccurate cell/Wi-Fi spikes when we already have a recent fix.
    if (accuracy > _maxAccuracyMeters && dtSec < 8.0) {
      return GpsFilterResult(
        accepted: false,
        filteredPosition: _filteredPos,
        speedMps: _speedMps,
      );
    }

    final prevPos = _filteredPos!;
    final distMeters = distanceMeters(prevPos, fix.position);
    final effectiveDt = math.max(dtSec, 0.25);

    // Reject single-fix teleportation spikes (e.g., multipath reflection jump).
    final maxAllowedDist = math.max(
      40.0,
      _maxPlausibleSpeedMps * effectiveDt + accuracy + _lastAccuracyM,
    );
    if (distMeters > maxAllowedDist) {
      final matchesPreviousOutlier =
          _consecutiveOutliers >= 1 &&
          _pendingOutlierPos != null &&
          distanceMeters(_pendingOutlierPos!, fix.position) <=
              math.max(55.0, accuracy * 2.5);
      if (!matchesPreviousOutlier) {
        _consecutiveOutliers++;
        _pendingOutlierPos = fix.position;
        return GpsFilterResult(
          accepted: false,
          filteredPosition: _filteredPos,
          speedMps: _speedMps,
        );
      }
      // Confirmed re-lock at the new location (e.g., tunnel exit).
      _consecutiveOutliers = 0;
      _pendingOutlierPos = null;
      _filteredPos = fix.position;
      _displayPos = fix.position;
      _velNorthMps = 0.0;
      _velEastMps = 0.0;
      _speedMps = reportedSpeed;
      _varianceM2 = accuracy * accuracy;
      _lastFixTime = fix.timestamp;
      _lastAccuracyM = accuracy;
      _routeSnapIndex = null;
      _snappedToRoute = false;
      return GpsFilterResult(
        accepted: true,
        filteredPosition: _filteredPos,
        fusedHeadingDeg: validCourse ? normalizeAngleDeg(fix.headingDeg!) : null,
        speedMps: _speedMps,
        shouldSnapImmediately: true,
      );
    }
    _consecutiveOutliers = 0;
    _pendingOutlierPos = null;

    // Large legitimate jump after a long gap -> snap cleanly instead of sliding across town.
    if (dtSec > 8.0 || distMeters > 250.0) {
      _filteredPos = fix.position;
      _displayPos = fix.position;
      _velNorthMps = 0.0;
      _velEastMps = 0.0;
      _speedMps = reportedSpeed;
      _varianceM2 = accuracy * accuracy;
      _lastFixTime = fix.timestamp;
      _lastAccuracyM = accuracy;
      _routeSnapIndex = null;
      _snappedToRoute = false;
      return GpsFilterResult(
        accepted: true,
        filteredPosition: _filteredPos,
        fusedHeadingDeg:
            (validCourse && reportedSpeed >= _gpsHeadingMinSpeedMps)
                ? normalizeAngleDeg(fix.headingDeg!)
                : null,
        speedMps: _speedMps,
        shouldSnapImmediately: true,
      );
    }

    // Stationary drift deadband: prevent jitter while stopped at a light.
    final stationaryThreshold = math.max(2.5, accuracy * 0.35);
    if (reportedSpeed < 0.8 && distMeters < stationaryThreshold) {
      _velNorthMps *= 0.25;
      _velEastMps *= 0.25;
      if ((_velNorthMps * _velNorthMps + _velEastMps * _velEastMps) < 0.04) {
        _velNorthMps = 0.0;
        _velEastMps = 0.0;
      }
      _speedMps = 0.0;
      _lastFixTime = fix.timestamp;
      _lastAccuracyM = accuracy;
      double? navHeading;
      if (isNavigating && activeRoute != null && activeRoute.length >= 2) {
        navHeading = routeForwardBearingDeg(
          activeRoute,
          _filteredPos!,
          lookaheadMeters: 28.0,
          maxDistanceMeters: 80.0,
        );
        if (navHeading != null) {
          _targetHeadingDeg = navHeading;
          _displayHeadingDeg ??= navHeading;
        }
      }
      return GpsFilterResult(
        accepted: true,
        filteredPosition: _filteredPos,
        fusedHeadingDeg: navHeading,
        speedMps: 0.0,
      );
    }

    // 1) Kalman predict step using prior velocity.
    final predictDt = dtSec.clamp(0.0, 2.0);
    final predictedPos = _offsetMeters(
      prevPos,
      _velNorthMps * predictDt,
      _velEastMps * predictDt,
    );
    final speedHint = math.max(reportedSpeed, _speedMps);
    final processSigma = 2.0 + speedHint * 0.45;
    _varianceM2 += processSigma * processSigma * math.max(dtSec, 0.1);

    // 2) Accuracy-weighted measurement update.
    final measSigma = math.max(accuracy, 4.0);
    final measVar = measSigma * measSigma;
    final kalmanGain = (_varianceM2 / (_varianceM2 + measVar)).clamp(0.24, 0.88);
    var updatedPos = _lerpLatLng(predictedPos, fix.position, kalmanGain);
    _varianceM2 = (1.0 - kalmanGain) * _varianceM2;

    // 3) Smooth velocity vector (fusing finite-difference displacement + GPS speed/course).
    final velDt = math.max(dtSec, 0.2);
    final avgLat = (prevPos.latitude + updatedPos.latitude) * 0.5;
    final dispNorthMps =
        (updatedPos.latitude - prevPos.latitude) * _metersPerLatDeg / velDt;
    final dispEastMps =
        (updatedPos.longitude - prevPos.longitude) *
        _metersPerLngDeg(avgLat) /
        velDt;
    final dispSpeed = math.sqrt(
      dispNorthMps * dispNorthMps + dispEastMps * dispEastMps,
    );

    if (reportedSpeed >= 1.5 && validCourse) {
      final rad = fix.headingDeg! * math.pi / 180.0;
      final gpsNorth = reportedSpeed * math.cos(rad);
      final gpsEast = reportedSpeed * math.sin(rad);
      _velNorthMps = gpsNorth * 0.65 + dispNorthMps * 0.35;
      _velEastMps = gpsEast * 0.65 + dispEastMps * 0.35;
    } else {
      _velNorthMps = dispNorthMps * 0.6 + _velNorthMps * 0.4;
      _velEastMps = dispEastMps * 0.6 + _velEastMps * 0.4;
    }
    final velMag = math.sqrt(
      _velNorthMps * _velNorthMps + _velEastMps * _velEastMps,
    );
    if (velMag > _maxPlausibleSpeedMps) {
      final scale = _maxPlausibleSpeedMps / velMag;
      _velNorthMps *= scale;
      _velEastMps *= scale;
    }
    if (hasReportedSpeed) {
      _speedMps = reportedSpeed < 0.5
          ? reportedSpeed
          : (reportedSpeed * 0.75 + dispSpeed * 0.25);
    } else {
      _speedMps = dispSpeed;
    }

    // 4) Optional route polyline snapping to cancel perpendicular GPS road jitter.
    double? routeBearing;
    _snappedToRoute = false;
    if (activeRoute != null && activeRoute.length >= 2) {
      final proj = _projectOntoRoute(activeRoute, updatedPos);
      if (proj != null && proj.distanceMeters <= routeSnapMaxMeters) {
        const fullSnapMeters = 14.0;
        final double snapBlend;
        if (proj.distanceMeters <= fullSnapMeters) {
          snapBlend = 1.0;
        } else {
          snapBlend =
              1.0 -
              ((proj.distanceMeters - fullSnapMeters) /
                      (routeSnapMaxMeters - fullSnapMeters))
                  .clamp(0.0, 1.0);
        }
        updatedPos = _lerpLatLng(updatedPos, proj.point, snapBlend);
        _routeSnapIndex = proj.segmentIndex;
        _snappedSegmentIndex = proj.segmentIndex;
        _snappedSegmentT = proj.segmentT;
        _snappedToRoute = snapBlend >= 0.5;
        routeBearing = proj.segmentBearingDeg;
      }
    }

    // 5) Heading fusion: prefer steady GPS course at speed over noisy magnetometer.
    double? fusedHeading;
    final double minHeadingSpeed = isNavigating ? 1.0 : _gpsHeadingMinSpeedMps;
    final double? navRouteBearing =
        (isNavigating && activeRoute != null && activeRoute.length >= 2)
        ? (routeForwardBearingDeg(
                activeRoute,
                updatedPos,
                lookaheadMeters: 28.0,
                maxDistanceMeters: 80.0,
              ) ??
              routeBearing)
        : routeBearing;
    if (_speedMps >= minHeadingSpeed) {
      if (validCourse) {
        fusedHeading = normalizeAngleDeg(fix.headingDeg!);
      } else if (distMeters >= 2.5) {
        fusedHeading = bearingDeg(prevPos, updatedPos);
      }
      if (fusedHeading != null &&
          navRouteBearing != null &&
          (_snappedToRoute || isNavigating)) {
        final deltaToRoute = shortestAngleDeltaDeg(
          fusedHeading,
          navRouteBearing,
        );
        _movingForwardAlongRoute = deltaToRoute.abs() <= 90.0;
        if (_movingForwardAlongRoute && deltaToRoute.abs() <= 45.0) {
          fusedHeading = normalizeAngleDeg(fusedHeading + deltaToRoute * 0.45);
        }
      } else if (navRouteBearing != null) {
        _movingForwardAlongRoute = true;
      }
      if (fusedHeading != null) {
        _targetHeadingDeg = fusedHeading;
        _displayHeadingDeg ??= fusedHeading;
      }
    } else if (isNavigating && navRouteBearing != null) {
      // During active navigation while stationary/slow near a route, keep
      // heading locked to the road ahead instead of raw compass jitter.
      fusedHeading = navRouteBearing;
      _targetHeadingDeg = navRouteBearing;
      _displayHeadingDeg ??= navRouteBearing;
    }

    _filteredPos = updatedPos;
    _displayPos ??= updatedPos;
    _lastFixTime = fix.timestamp;
    _lastAccuracyM = accuracy;

    return GpsFilterResult(
      accepted: true,
      filteredPosition: _filteredPos,
      fusedHeadingDeg: fusedHeading,
      speedMps: _speedMps,
    );
  }

  /// Accepts magnetometer compass readings when stationary or walking slowly.
  /// Ignored while moving fast or during active route navigation so phone twists
  /// and magnetic interference cannot make the map rotation jump.
  void ingestCompassHeading(
    double compassDeg, {
    required DateTime now,
    bool isNavigating = false,
  }) {
    if (!compassDeg.isFinite) return;
    if (isNavigating && (_snappedToRoute || _targetHeadingDeg != null)) {
      return;
    }
    final hasFreshFastGps =
        _speedMps >= _gpsHeadingMinSpeedMps &&
        _lastFixTime != null &&
        now.difference(_lastFixTime!).inMilliseconds < 3000;
    if (hasFreshFastGps) return;

    final normalized = normalizeAngleDeg(compassDeg);
    if (_targetHeadingDeg != null &&
        shortestAngleDeltaDeg(_targetHeadingDeg!, normalized).abs() < 4.0) {
      return;
    }
    _targetHeadingDeg = normalized;
    _displayHeadingDeg ??= normalized;
  }

  /// Advances the displayed puck position and heading by one render frame using
  /// bounded constant-velocity (and route-curved) dead-reckoning plus smooth
  /// framerate-independent exponential tracking.
  GpsFrameState advanceFrame({
    required DateTime now,
    required double dtSeconds,
  }) {
    final basePos = _filteredPos;
    if (basePos == null) {
      return GpsFrameState(
        position: _displayPos,
        headingDeg: _displayHeadingDeg,
        isSettled: true,
      );
    }

    final dt = dtSeconds.clamp(0.001, 0.1);
    final currentDisplay = _displayPos ?? basePos;

    // Bounded dead-reckoning between GPS fixes when clearly moving.
    LatLng targetPos = basePos;
    final bool canExtrapolate =
        _speedMps >= 2.5 && _lastFixTime != null;
    if (canExtrapolate) {
      final elapsedSec =
          (now.difference(_lastFixTime!).inMicroseconds / 1e6)
              .clamp(0.0, _maxDeadReckonSeconds);
      if (elapsedSec > 0.0) {
        if (_snappedToRoute &&
            _movingForwardAlongRoute &&
            _lastRoute != null &&
            _lastRoute!.length >= 2) {
          targetPos = _advanceAlongRoute(
            _lastRoute!,
            _snappedSegmentIndex,
            _snappedSegmentT,
            _speedMps * elapsedSec,
          );
        } else {
          targetPos = _offsetMeters(
            basePos,
            _velNorthMps * elapsedSec,
            _velEastMps * elapsedSec,
          );
        }
      }
    }

    final distToTarget = distanceMeters(currentDisplay, targetPos);
    LatLng nextPos;
    if (distToTarget > 250.0 || distToTarget < 0.03) {
      nextPos = targetPos;
    } else {
      // Shorter time constant at higher speeds prevents lagging behind fast travel.
      final tauPos = _speedMps >= 10.0
          ? 0.11
          : (_speedMps >= 3.0 ? 0.15 : 0.22);
      final alphaPos = 1.0 - math.exp(-dt / tauPos);
      nextPos = _lerpLatLng(currentDisplay, targetPos, alphaPos);
    }
    _displayPos = nextPos;

    bool headingSettled = true;
    if (_targetHeadingDeg != null) {
      final curHeading = _displayHeadingDeg ?? _targetHeadingDeg!;
      final delta = shortestAngleDeltaDeg(curHeading, _targetHeadingDeg!);
      if (delta.abs() < 0.25) {
        _displayHeadingDeg = _targetHeadingDeg;
      } else {
        final alphaHeading = 1.0 - math.exp(-dt / 0.12);
        _displayHeadingDeg = normalizeAngleDeg(curHeading + delta * alphaHeading);
        headingSettled = false;
      }
    }

    final isExtrapolationDone =
        !canExtrapolate ||
        (_lastFixTime != null &&
            now.difference(_lastFixTime!).inMilliseconds >=
                (_maxDeadReckonSeconds * 1000).round());
    final posSettled =
        isExtrapolationDone && distanceMeters(nextPos, targetPos) < 0.08;

    return GpsFrameState(
      position: nextPos,
      headingDeg: _displayHeadingDeg,
      isSettled: posSettled && headingSettled,
    );
  }

  _RouteProjection? _projectOntoRoute(List<LatLng> route, LatLng p) {
    if (route.length < 2) return null;
    final lastSeg = route.length - 2;
    _RouteProjection? best;

    // Fast local search around previous matched segment first.
    if (_routeSnapIndex != null && _routeSnapIndex! <= lastSeg) {
      final start = math.max(0, _routeSnapIndex! - 8);
      final end = math.min(lastSeg, _routeSnapIndex! + 24);
      best = _projectRange(route, p, start, end);
      if (best != null && best.distanceMeters <= 35.0) {
        return best;
      }
    }
    return _projectRange(route, p, 0, lastSeg);
  }

  static _RouteProjection? _projectRange(
    List<LatLng> route,
    LatLng p,
    int startIdx,
    int endIdx,
  ) {
    _RouteProjection? best;
    for (int i = startIdx; i <= endIdx; i++) {
      final a = route[i];
      final b = route[i + 1];
      final avgLat = (a.latitude + b.latitude) * 0.5;
      final mLng = _metersPerLngDeg(avgLat);
      final abN = (b.latitude - a.latitude) * _metersPerLatDeg;
      final abE = (b.longitude - a.longitude) * mLng;
      final apN = (p.latitude - a.latitude) * _metersPerLatDeg;
      final apE = (p.longitude - a.longitude) * mLng;
      final abLenSq = abN * abN + abE * abE;
      final double t = abLenSq > 1e-6
          ? ((apN * abN + apE * abE) / abLenSq).clamp(0.0, 1.0)
          : 0.0;
      final projPoint = _lerpLatLng(a, b, t);
      final dN = (p.latitude - projPoint.latitude) * _metersPerLatDeg;
      final dE = (p.longitude - projPoint.longitude) * mLng;
      final dist = math.sqrt(dN * dN + dE * dE);
      if (best == null || dist < best.distanceMeters) {
        best = _RouteProjection(
          point: projPoint,
          distanceMeters: dist,
          segmentIndex: i,
          segmentT: t,
          segmentBearingDeg: abLenSq > 1e-6 ? bearingDeg(a, b) : 0.0,
        );
      }
    }
    return best;
  }

  static LatLng _advanceAlongRoute(
    List<LatLng> route,
    int segIndex,
    double segT,
    double advanceMeters,
  ) {
    if (route.length < 2) return route.first;
    var idx = segIndex.clamp(0, route.length - 2);
    var t = segT.clamp(0.0, 1.0);
    var remaining = advanceMeters;

    while (remaining > 0.0 && idx <= route.length - 2) {
      final a = route[idx];
      final b = route[idx + 1];
      final segLen = distanceMeters(a, b);
      if (segLen < 1e-3) {
        idx++;
        t = 0.0;
        continue;
      }
      final leftOnSeg = segLen * (1.0 - t);
      if (remaining <= leftOnSeg) {
        final nextT = t + remaining / segLen;
        return _lerpLatLng(a, b, nextT);
      }
      remaining -= leftOnSeg;
      idx++;
      t = 0.0;
    }
    return route.last;
  }
}
