import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_flutter_app/app_design.dart';
import 'package:my_flutter_app/app_settings.dart';
import 'package:my_flutter_app/auth_screen.dart';
import 'package:my_flutter_app/onboarding_screen.dart';
import 'package:my_flutter_app/web_design.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/arial.ttf');
    final bytes = await font.readAsBytes();
    for (final family in ['Roboto', 'monospace']) {
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/geolocator'),
          (call) async => 3,
        );
    AppSettings.instance.themeModeNotifier.value = ThemeMode.light;
  });

  test('ordinary muted text and dark web links meet contrast targets', () {
    double contrast(Color a, Color b) {
      final values = [a.computeLuminance(), b.computeLuminance()]..sort();
      return (values.last + 0.05) / (values.first + 0.05);
    }

    expect(
      contrast(AppDesign.textMuted(false), AppDesign.surface(false)),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrast(AppDesign.textMuted(true), AppDesign.surface(true)),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrast(WebDesign.brandOnSurface(true), WebDesign.surface(true)),
      greaterThanOrEqualTo(4.5),
    );
  });

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(1440, 900),
  ]) {
    for (final dark in [false, true]) {
      testWidgets('auth layout $size dark=$dark', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        AppSettings.instance.toggleTheme(dark);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppDesign.buildTheme(isDark: dark),
            home: AuthScreen(onAuthSuccess: () {}),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        expect(find.text('Welcome Back'), findsOneWidget);
        final form = tester.state<FormState>(find.byType(Form));
        expect(form.validate(), isFalse);
        await tester.pump();
        expect(find.text('Enter a valid email address'), findsOneWidget);
        expect(find.text('Please enter a password'), findsOneWidget);
        await tester.ensureVisible(find.text('Register'));
        await tester.tap(find.text('Register'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Create Account'), findsOneWidget);
        expect(form.validate(), isFalse);
        await tester.pump();
        expect(find.text('Required'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final size in [const Size(375, 812), const Size(1440, 900)]) {
    testWidgets('auth at 200 percent text size $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: size.width >= 900
              ? WebDesign.buildTheme(isDark: false)
              : AppDesign.buildTheme(isDark: false),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: AuthScreen(onAuthSuccess: () {}),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [375.0, 600.0]) {
    testWidgets('onboarding layout and completion at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var completed = false;
      expect(await checkHasSeenOnboarding(), isFalse);
      await tester.pumpWidget(
        MaterialApp(home: OnboardingScreen(onComplete: () => completed = true)),
      );
      for (var page = 0; page < 4; page++) {
        await tester.tap(find.text('NEXT'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('GET STARTED'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(completed, isTrue);
      expect(await checkHasSeenOnboarding(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
