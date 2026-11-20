import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/app_design.dart';
import 'package:my_flutter_app/auth_screen.dart';
import 'package:my_flutter_app/dpwh_standards.dart';
import 'package:my_flutter_app/mobile_components.dart';
import 'package:my_flutter_app/mobile_tour.dart';
import 'package:my_flutter_app/onboarding_screen.dart';
import 'package:my_flutter_app/settings_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final brighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (brighter + 0.05) / (darker + 0.05);
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

  group('Mobile design primitives & 4-class contrast', () {
    test('all 4 DPWH classes have distinct icons and AA-readable colors', () {
      final icons = <IconData>{};
      for (final isDark in [false, true]) {
        final surface = AppDesign.surface(isDark);
        for (final cls in DpwhStandards.allClasses) {
          icons.add(MobileDefectHelper.iconForClass(cls));
          final fg = MobileDefectHelper.foregroundColor(cls, isDark);
          expect(
            _contrastRatio(fg, surface),
            greaterThanOrEqualTo(4.5),
            reason:
                '${cls.name} (${cls.code}) failed 4.5:1 contrast on isDark=$isDark',
          );
        }
      }
      expect(icons.length, DpwhStandards.allClasses.length);
    });

    test('report status metadata satisfies AA contrast and unique labels', () {
      for (final isDark in [false, true]) {
        final surface = AppDesign.surface(isDark);
        final labels = <String>{};
        for (final status in ['pending', 'approved', 'rejected', 'deleted']) {
          final meta = MobileStatusMeta.forReportStatus(status, isDark);
          labels.add(meta.label);
          expect(
            _contrastRatio(meta.color, surface),
            greaterThanOrEqualTo(4.5),
            reason: 'Status "$status" failed 4.5:1 contrast on isDark=$isDark',
          );
        }
        expect(labels.length, 4);
      }
    });

    testWidgets(
      'mobile touch targets, lifecycle banner, state card, and offline banner hold up at 320px and 2.0x text scale',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        int taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppDesign.buildTheme(isDark: false),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 568),
                textScaler: TextScaler.linear(2.0),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      MobileTouchIconButton(
                        icon: Icons.my_location_rounded,
                        tooltip: 'Center location',
                        onPressed: () => taps++,
                      ),
                      const SizedBox(height: 12),
                      const MobileReportLifecycleBanner(activeStage: 1),
                      const SizedBox(height: 12),
                      const MobileOfflineBanner(),
                      const SizedBox(height: 12),
                      MobileStateCard(
                        icon: Icons.videocam_off_rounded,
                        iconColor: AppDesign.warning,
                        title: 'Camera unavailable',
                        message:
                            'Allow camera permission or take a manual photo.',
                        primaryLabel: 'Retry Live Scanner',
                        onPrimaryPressed: () => taps++,
                        secondaryLabel: 'Take Manual Photo',
                        onSecondaryPressed: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final btnSize = tester.getSize(find.byType(MobileTouchIconButton));
        expect(btnSize.width, greaterThanOrEqualTo(48));
        expect(btnSize.height, greaterThanOrEqualTo(48));

        await tester.tap(find.byType(MobileTouchIconButton));
        expect(taps, 1);

        expect(find.text('Detected'), findsOneWidget);
        expect(find.text('Saved'), findsOneWidget);
        expect(find.text('Submitted'), findsOneWidget);
        expect(find.text('Approved'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('MobileTourController & SpotlightTourOverlay', () {
    testWidgets(
      'tracks 5-step progress, does not overlap targets, enforces 48dp controls, and persists completion',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(375, 812));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final controller = MobileTourController();
        addTearDown(controller.dispose);
        await controller.load();

        final kSearch = GlobalKey();
        final kFilter = GlobalKey();
        final kScan = GlobalKey();
        final kReports = GlobalKey();
        final kProfile = GlobalKey();

        await tester.pumpWidget(
          MaterialApp(
            theme: AppDesign.buildTheme(isDark: false),
            home: Stack(
              children: [
                Scaffold(
                  body: SafeArea(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                key: kSearch,
                                height: 48,
                                color: Colors.blueGrey.shade100,
                                child: const Text('Search bar'),
                              ),
                            ),
                            Container(
                              key: kFilter,
                              width: 56,
                              height: 48,
                              color: Colors.amber.shade200,
                              child: const Text('Filter'),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Container(
                              key: kScan,
                              width: 72,
                              height: 48,
                              color: Colors.green,
                              child: const Text('Scan'),
                            ),
                            Container(
                              key: kReports,
                              width: 72,
                              height: 48,
                              color: Colors.orange,
                              child: const Text('Reports'),
                            ),
                            Container(
                              key: kProfile,
                              width: 72,
                              height: 48,
                              color: Colors.purple,
                              child: const Text('Profile'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                SpotlightTourOverlay(controller: controller),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        final steps = [
          TourStepSpec(
            id: 'search',
            targetKey: kSearch,
            title: 'Search nearby road hazards',
            description: 'Search for a place to view nearby road reports.',
          ),
          TourStepSpec(
            id: 'filters',
            targetKey: kFilter,
            title: 'Filters and layers',
            description:
                'Filter by all 4 road defect classes and approval status.',
          ),
          TourStepSpec(
            id: 'scan',
            targetKey: kScan,
            title: 'Scan road defect',
            description: 'Open the camera to scan for road defects.',
          ),
          TourStepSpec(
            id: 'reports',
            targetKey: kReports,
            title: 'Track your reports',
            description:
                'View your submitted reports and their current status.',
          ),
          TourStepSpec(
            id: 'profile',
            targetKey: kProfile,
            title: 'Profile & settings',
            description: 'Replay this tour anytime in Help & app tour.',
          ),
        ];

        final started = controller.startTour(MobileTourId.main, steps);
        expect(started, isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.text('1 of 5'), findsOneWidget);
        expect(find.text('Search nearby road hazards'), findsOneWidget);
        expect(find.text('Back'), findsNothing);

        // Verify Skip & Next touch target heights >= 48dp
        expect(
          tester.getSize(find.widgetWithText(TextButton, 'Skip')).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.widgetWithText(ElevatedButton, 'Next')).height,
          greaterThanOrEqualTo(48),
        );

        // Step 1 tooltip card must not overlap Search bar
        final searchRect = Rect.fromLTWH(
          tester.getTopLeft(find.byKey(kSearch)).dx,
          tester.getTopLeft(find.byKey(kSearch)).dy,
          tester.getSize(find.byKey(kSearch)).width,
          tester.getSize(find.byKey(kSearch)).height,
        );
        final card1Rect = tester.getRect(
          find
              .ancestor(
                of: find.text('Search nearby road hazards'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(card1Rect.overlaps(searchRect), isFalse);

        // Advance to step 2 -> should show "2 of 5" and Back button >= 48dp
        await tester.tap(find.text('Next'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('2 of 5'), findsOneWidget);
        expect(
          tester.getSize(find.widgetWithText(OutlinedButton, 'Back')).height,
          greaterThanOrEqualTo(48),
        );

        // Test Back returns cleanly to step 1
        await tester.tap(find.text('Back'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('1 of 5'), findsOneWidget);

        // Step through to final step (5 of 5) -> Done
        for (int i = 0; i < 4; i++) {
          await tester.tap(find.text('Next'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
        }
        expect(find.text('5 of 5'), findsOneWidget);
        expect(find.text('Done'), findsOneWidget);

        // Non-overlap on bottom target too
        final profileRect = tester.getRect(find.byKey(kProfile));
        final card5Rect = tester.getRect(
          find
              .ancestor(
                of: find.text('Profile & settings'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(card5Rect.overlaps(profileRect), isFalse);

        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();

        expect(controller.isRunning, isFalse);
        expect(controller.isCompleted(MobileTourId.main), isTrue);

        // Reloading from SharedPreferences remembers completion
        final reloaded = MobileTourController();
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(reloaded.isCompleted(MobileTourId.main), isTrue);
        expect(reloaded.startTour(MobileTourId.main, steps), isFalse);

        // Reset enables replay
        await reloaded.resetAllTours();
        expect(reloaded.isCompleted(MobileTourId.main), isFalse);
        expect(reloaded.startTour(MobileTourId.main, steps), isTrue);
      },
    );

    testWidgets(
      'skips unmounted anchors gracefully and auto-scrolls offscreen targets into view',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final controller = MobileTourController();
        addTearDown(controller.dispose);
        await controller.load();

        final kTop = GlobalKey();
        final kUnavailable = GlobalKey(); // Never attached
        final kScrolled = GlobalKey();

        await tester.pumpWidget(
          MaterialApp(
            theme: AppDesign.buildTheme(isDark: true),
            home: Stack(
              children: [
                Scaffold(
                  body: SingleChildScrollView(
                    child: Column(
                      children: [
                        Container(
                          key: kTop,
                          height: 56,
                          width: double.infinity,
                          color: Colors.teal,
                          child: const Text('Top action'),
                        ),
                        const SizedBox(height: 900),
                        Container(
                          key: kScrolled,
                          height: 56,
                          width: double.infinity,
                          color: Colors.indigo,
                          child: const Text('Bottom scrolled action'),
                        ),
                        const SizedBox(height: 60),
                      ],
                    ),
                  ),
                ),
                SpotlightTourOverlay(controller: controller),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        final started = controller.startTour(MobileTourId.review, [
          TourStepSpec(
            id: 'top',
            targetKey: kTop,
            title: 'Top summary',
            description: 'Always visible step.',
          ),
          TourStepSpec(
            id: 'missing',
            targetKey: kUnavailable,
            title: 'Hidden optional control',
            description: 'Should be skipped cleanly.',
          ),
          TourStepSpec(
            id: 'scrolled',
            targetKey: kScrolled,
            title: 'Submit report',
            description: 'Scrolled into view automatically.',
          ),
        ]);
        expect(started, isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // Unavailable control omitted -> 2 steps total
        expect(find.text('1 of 2'), findsOneWidget);
        expect(find.text('Hidden optional control'), findsNothing);

        await tester.tap(find.text('Next'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        expect(find.text('2 of 2'), findsOneWidget);
        expect(find.text('Submit report'), findsOneWidget);

        // Offscreen target was scrolled cleanly into visible viewport
        final targetTopLeft = tester.getTopLeft(find.byKey(kScrolled));
        expect(targetTopLeft.dy, lessThan(640));
        expect(targetTopLeft.dy, greaterThanOrEqualTo(0));

        await tester.tap(find.text('Skip'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'survives landscape, keyboard inset, reduced motion, 2.0x text scale, and cancelWithoutCompleting',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(568, 320));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final controller = MobileTourController();
        addTearDown(controller.dispose);
        await controller.load();

        final kButton = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppDesign.buildTheme(isDark: false),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(568, 320),
                padding: EdgeInsets.only(top: 24, bottom: 20),
                viewInsets: EdgeInsets.only(bottom: 140),
                textScaler: TextScaler.linear(2.0),
                disableAnimations: true,
              ),
              child: Stack(
                children: [
                  Scaffold(
                    body: SafeArea(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          key: kButton,
                          width: 140,
                          height: 48,
                          color: Colors.green,
                          child: const Text('Target'),
                        ),
                      ),
                    ),
                  ),
                  SpotlightTourOverlay(controller: controller),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        controller.startTour(MobileTourId.scanner, [
          TourStepSpec(
            id: 'scan_btn',
            targetKey: kButton,
            title: 'Save scan frame',
            description:
                'Save the detected scan frame for review. Nothing is submitted yet.',
          ),
        ]);
        await tester.pumpAndSettle();

        expect(find.text('1 of 1'), findsOneWidget);
        expect(tester.takeException(), isNull);

        controller.cancelWithoutCompleting();
        await tester.pumpAndSettle();
        expect(controller.isRunning, isFalse);
        expect(controller.isCompleted(MobileTourId.scanner), isFalse);
      },
    );
  });

  testWidgets(
    'skipping a section guide persists without suppressing other sections',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final target = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SizedBox(key: target, width: 100, height: 100)),
        ),
      );
      final controller = MobileTourController();
      addTearDown(controller.dispose);
      await controller.load();
      final steps = [
        TourStepSpec(
          id: 'report_search',
          targetKey: target,
          title: 'Search reports',
          description: 'Find your saved reports.',
        ),
      ];
      expect(controller.startTour(MobileTourId.reports, steps), isTrue);
      await controller.skip();
      final reloaded = MobileTourController();
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.startTour(MobileTourId.reports, steps), isFalse);
      expect(reloaded.startTour(MobileTourId.profile, steps), isTrue);
      await reloaded.finish();
      expect(
        reloaded.startTour(MobileTourId.reports, steps, force: true),
        isTrue,
      );
      reloaded.cancelWithoutCompleting();
      expect(reloaded.isRunning, isFalse);
    },
  );

  group('MobileSettingsSheet tour replay & defect guide', () {
    testWidgets('invokes onReplayTour cleanly at 2.0x text scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(375, 812));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      bool replayed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppDesign.buildTheme(isDark: false),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(375, 812),
              textScaler: TextScaler.linear(2.0),
            ),
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => MobileSettingsSheet(
                          onReplayTour: () => replayed = true,
                        ),
                      );
                    },
                    child: const Text('Open Settings'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Help & app tour'), findsOneWidget);
      await tester.ensureVisible(find.text('Help & app tour'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Help & app tour'));
      await tester.pumpAndSettle();

      expect(replayed, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('RoadSense Web-parity Mobile Redesign checks', () {
    test('AppDesign primary fill and semantic text meet WCAG AA contrast', () {
      expect(AppDesign.brand, const Color(0xFF2563EB));
      expect(
        _contrastRatio(AppDesign.brand, Colors.white),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(AppDesign.textPrimary(false), AppDesign.bg(false)),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(AppDesign.textPrimary(true), AppDesign.bg(true)),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(
          AppDesign.textSecondary(false),
          AppDesign.surface(false),
        ),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(AppDesign.textSecondary(true), AppDesign.surface(true)),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets(
      'RoadSenseLogo and MobileSeverityPill render cleanly in light & dark themes',
      (tester) async {
        for (final isDark in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppDesign.buildTheme(isDark: isDark),
              home: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const RoadSenseLogo(
                        size: 36,
                        showWordmark: true,
                        subtitle: 'AI Road Monitor',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        children: [
                          MobileSeverityPill(severity: 'high', isDark: isDark),
                          MobileSeverityPill(
                            severity: 'medium',
                            isDark: isDark,
                          ),
                          MobileSeverityPill(
                            severity: 'low',
                            isDark: isDark,
                            compact: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.bySemanticsLabel('RoadSense AI logo'), findsWidgets);
          expect(find.text('AI Road Monitor'), findsOneWidget);
          expect(find.text('High severity'), findsOneWidget);
          expect(find.text('Medium severity'), findsOneWidget);
          expect(find.text('Low'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      'OnboardingScreen displays RoadSense header and slide navigation without overflow',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(375, 812));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            theme: AppDesign.buildTheme(isDark: false),
            home: OnboardingScreen(onComplete: () {}),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.bySemanticsLabel('RoadSense AI logo'), findsWidgets);
        expect(find.text('NEXT'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'AuthScreen Register tab displays 6-digit verification code notice without legacy link copy',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            theme: AppDesign.buildTheme(isDark: false),
            home: AuthScreen(onAuthSuccess: () {}),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.bySemanticsLabel('RoadSense AI logo'), findsWidgets);
        await tester.tap(find.text('Register'));
        await tester.pump(const Duration(milliseconds: 450));

        expect(
          find.textContaining('6-digit verification code'),
          findsOneWidget,
        );
        expect(find.textContaining('verification link'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'MobileFloatingNavBar renders Map, Scan, Reports, and Profile uniformly without solid-blue Scan anomaly',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(375, 812));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        int selectedIndex = 0;
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) => MaterialApp(
              theme: AppDesign.buildTheme(isDark: false),
              home: Scaffold(
                bottomNavigationBar: MobileFloatingNavBar(
                  currentIndex: selectedIndex,
                  onTabSelected: (idx) => setState(() => selectedIndex = idx),
                  isDark: false,
                  disableAnimations: true,
                ),
                body: const SizedBox.shrink(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final labels = ['Map', 'Scan', 'Reports', 'Profile'];
        final labelRects = labels
            .map((l) => tester.getRect(find.text(l)))
            .toList(growable: false);
        final tabRects = labels
            .map(
              (l) => tester.getRect(
                find.ancestor(of: find.text(l), matching: find.byType(InkWell)),
              ),
            )
            .toList(growable: false);
        for (int i = 1; i < labelRects.length; i++) {
          expect(
            (labelRects[i].center.dy - labelRects[0].center.dy).abs(),
            lessThan(0.5),
          );
          expect((tabRects[i].width - tabRects[0].width).abs(), lessThan(1.0));
          expect(
            (tabRects[i].height - tabRects[0].height).abs(),
            lessThan(0.5),
          );
        }

        AnimatedContainer pillFor(String label) =>
            tester.widget<AnimatedContainer>(
              find.descendant(
                of: find.ancestor(
                  of: find.text(label),
                  matching: find.byType(InkWell),
                ),
                matching: find.byType(AnimatedContainer),
              ),
            );

        // Inactive Scan tab must use transparent pill background (same as Reports/Profile)
        expect(
          (pillFor('Scan').decoration as BoxDecoration).color,
          Colors.transparent,
        );
        expect(
          (pillFor('Reports').decoration as BoxDecoration).color,
          Colors.transparent,
        );

        await tester.tap(find.text('Scan'));
        await tester.pumpAndSettle();
        expect(selectedIndex, 1);

        expect(
          (pillFor('Scan').decoration as BoxDecoration).color,
          AppDesign.brandWash(false),
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
