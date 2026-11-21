import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/nav_vehicle_3d.dart';

void main() {
  testWidgets('NavVehicle3DWidget renders all 3 3D vehicle profiles cleanly', (
    tester,
  ) async {
    for (final glow in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                for (final type in NavVehicleType.values)
                  NavVehicle3DWidget(
                    type: type,
                    size: 56,
                    showHeadlightGlow: glow,
                  ),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(NavVehicle3DWidget), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('NavCompassNeedleIcon renders cleanly', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Center(child: NavCompassNeedleIcon()),
              Center(child: NavCompassNeedleIcon(angleRadians: 1.0)),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(NavCompassNeedleIcon), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  test('DrivingCameraAngle cycles accurately with and without route', () {
    expect(
      DrivingCameraAngle.chase3D.next(hasRoute: true),
      DrivingCameraAngle.topDown2D,
    );
    expect(
      DrivingCameraAngle.topDown2D.next(hasRoute: true),
      DrivingCameraAngle.northUp2D,
    );
    expect(
      DrivingCameraAngle.northUp2D.next(hasRoute: true),
      DrivingCameraAngle.overview,
    );
    expect(
      DrivingCameraAngle.overview.next(hasRoute: true),
      DrivingCameraAngle.chase3D,
    );

    expect(
      DrivingCameraAngle.northUp2D.next(hasRoute: false),
      DrivingCameraAngle.chase3D,
    );

    expect(DrivingCameraAngle.chase3D.shortBadge, '3D');
    expect(DrivingCameraAngle.topDown2D.shortBadge, '2D');
    expect(DrivingCameraAngle.northUp2D.shortBadge, 'N');
    expect(DrivingCameraAngle.overview.shortBadge, 'ALL');

    expect(DrivingCameraAngle.chase3D.label, '3D Driving View');
    expect(DrivingCameraAngle.topDown2D.label, '2D Overhead View');
    expect(DrivingCameraAngle.northUp2D.label, 'North-Up View');
    expect(DrivingCameraAngle.overview.label, 'Route Overview');

    expect(DrivingCameraAngle.chase3D.isHeadingUp, isTrue);
    expect(DrivingCameraAngle.topDown2D.isHeadingUp, isTrue);
    expect(DrivingCameraAngle.northUp2D.isHeadingUp, isFalse);
    expect(DrivingCameraAngle.overview.isHeadingUp, isFalse);

    expect(DrivingCameraAngle.chase3D.tiltFactor, 1.0);
    expect(DrivingCameraAngle.topDown2D.tiltFactor, 0.0);
    expect(DrivingCameraAngle.northUp2D.tiltFactor, 0.0);
    expect(DrivingCameraAngle.overview.tiltFactor, 0.0);
  });
}
