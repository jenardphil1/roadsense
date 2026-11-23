import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:my_flutter_app/app_design.dart';
import 'package:my_flutter_app/auth_screen.dart';
import 'package:my_flutter_app/dpwh_standards.dart';
import 'package:my_flutter_app/map_screen.dart';
import 'package:my_flutter_app/mobile_components.dart';
import 'package:my_flutter_app/onboarding_screen.dart';
import 'package:my_flutter_app/profile_screen.dart';
import 'package:my_flutter_app/road_hazard_marker.dart';
import 'package:my_flutter_app/settings_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ViewportProfile {
  final String name;
  final Size size;
  final EdgeInsets viewInsets;

  const _ViewportProfile(
    this.name,
    this.size, {
    this.viewInsets = EdgeInsets.zero,
  });
}

const List<_ViewportProfile> _profiles = [
  _ViewportProfile('small-phone-portrait', Size(360, 640)),
  _ViewportProfile('phone-portrait', Size(390, 844)),
  _ViewportProfile('phone-landscape', Size(744, 336)),
  _ViewportProfile(
    'phone-landscape-keyboard',
    Size(744, 336),
    viewInsets: EdgeInsets.only(bottom: 180),
  ),
  _ViewportProfile('tablet-landscape', Size(1024, 768)),
];

Future<void> _pumpAcrossProfiles(
  WidgetTester tester,
  Widget Function(_ViewportProfile profile) builder, {
  Future<void> Function(_ViewportProfile profile)? afterPump,
}) async {
  for (final profile in _profiles) {
    tester.view.physicalSize = profile.size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = FakeViewPadding(
      bottom: profile.viewInsets.bottom,
      left: profile.viewInsets.left,
      right: profile.viewInsets.right,
      top: profile.viewInsets.top,
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: ThemeMode.dark,
        home: builder(profile),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    final dynamic exc = tester.takeException();
    expect(
      exc,
      isNull,
      reason: 'Exception on ${profile.name}: $exc',
    );
    if (afterPump != null) {
      await afterPump(profile);
      final dynamic afterExc = tester.takeException();
      expect(
        afterExc,
        isNull,
        reason: 'Post-interaction exception on ${profile.name}: $afterExc',
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = File('C:/Windows/Fonts/arial.ttf');
    if (font.existsSync()) {
      final bytes = await font.readAsBytes();
      for (final family in ['Roboto', 'monospace']) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('OnboardingScreen renders cleanly across all 5 screen profiles', (
    tester,
  ) async {
    await _pumpAcrossProfiles(
      tester,
      (_) => OnboardingScreen(onComplete: () {}),
    );
  });

  testWidgets('AuthScreen Sign In & Register render cleanly across all 5 profiles', (
    tester,
  ) async {
    await _pumpAcrossProfiles(
      tester,
      (_) => AuthScreen(onAuthSuccess: () {}),
      afterPump: (_) async {
        final registerBtn = find.text('Register');
        if (registerBtn.evaluate().isNotEmpty) {
          await tester.tap(registerBtn.first);
          await tester.pump(const Duration(milliseconds: 200));
        }
      },
    );
  });

  testWidgets('MobileFloatingNavBar renders cleanly across all 5 profiles', (
    tester,
  ) async {
    await _pumpAcrossProfiles(
      tester,
      (_) => Scaffold(
        extendBody: true,
        body: const SizedBox.expand(),
        bottomNavigationBar: MobileFloatingNavBar(
          currentIndex: 0,
          onTabSelected: (_) {},
          isDark: true,
          disableAnimations: true,
        ),
      ),
    );
  });

  testWidgets('MobileSettingsSheet renders cleanly across all 5 profiles', (
    tester,
  ) async {
    await _pumpAcrossProfiles(
      tester,
      (_) => Scaffold(
        body: MobileSettingsSheet(
          onSettingsChanged: () {},
        ),
      ),
    );
  });

  testWidgets('ProfileScreen Reports view renders cleanly across all 5 profiles', (
    tester,
  ) async {
    await _pumpAcrossProfiles(
      tester,
      (_) => ProfileScreen(
        section: ProfileScreenSection.reports,
        currentUidOverride: 'qa-user-1',
        userReportsStreamOverride: Stream.value(const []),
      ),
    );
  });

  testWidgets('MapScreen idle renders cleanly across all 5 profiles', (
    tester,
  ) async {
    await _pumpAcrossProfiles(
      tester,
      (_) => Scaffold(
        extendBody: true,
        body: MapScreen(
          detectedPotholes: [
            PotholeMarker(
              id: 1,
              docId: 'p1',
              location: const LatLng(14.87, 120.95),
              imagePath: '',
              timestamp: DateTime(2026, 11, 23),
              barangay: 'Mapulang Lupa',
            ),
          ],
          onDeleteDetectedPothole: (_) async {},
          onAddDetectedPothole: (_) async {},
          isMapActive: true,
        ),
        bottomNavigationBar: MobileFloatingNavBar(
          currentIndex: 0,
          onTabSelected: (_) {},
          isDark: true,
          disableAnimations: true,
        ),
      ),
    );
  });

  test('DpwhStandards swaps Longitudinal <-> Transverse for side-of-road perspective', () {
    expect(
      DpwhStandards.remapCrackTagForPerspective(
        'Longitudinal crack (DPWH Code 12)',
        swapLongitudinalTransverse: true,
      ),
      DpwhStandards.transverseCrack.name,
    );
    expect(
      DpwhStandards.remapCrackTagForPerspective(
        'Transverse crack (DPWH Code 12)',
        swapLongitudinalTransverse: true,
      ),
      DpwhStandards.longitudinalCrack.name,
    );
    expect(
      DpwhStandards.remapCrackTagForPerspective(
        'Pothole (DPWH Code 01)',
        swapLongitudinalTransverse: true,
      ),
      'Pothole (DPWH Code 01)',
    );
    expect(
      DpwhStandards.remapCrackTagForPerspective(
        'Alligator crack (DPWH Code 12)',
        swapLongitudinalTransverse: true,
      ),
      'Alligator crack (DPWH Code 12)',
    );
    expect(
      DpwhStandards.remapCrackTagForPerspective(
        'Longitudinal crack',
        swapLongitudinalTransverse: false,
      ),
      'Longitudinal crack',
    );
    final remapped = DpwhStandards.remapDetectionsForPerspective(
      [
        {'tag': 'Transverse crack', 'box': [0, 0, 10, 10, 0.9]},
        {'tag': 'Pothole', 'box': [0, 0, 10, 10, 0.9]},
      ],
      swapLongitudinalTransverse: true,
    );
    expect(remapped[0]['tag'], DpwhStandards.longitudinalCrack.name);
    expect(remapped[1]['tag'], 'Pothole');
  });
}
