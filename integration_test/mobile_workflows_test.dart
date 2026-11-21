import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vision/flutter_vision.dart';
import 'package:geolocator/geolocator.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_flutter_app/firebase_setup.dart';
import 'package:my_flutter_app/main.dart' as app;
import 'package:my_flutter_app/onboarding_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android camera, model inference, GPS, and signed-in mobile screen',
    (tester) async {
      await tester.runAsync(() async {
        await initializeFirebase();
        const email = String.fromEnvironment('QA_USER_EMAIL');
        const password = String.fromEnvironment('QA_USER_PASSWORD');
        expect(email, isNotEmpty, reason: 'Pass local QA account flags.');
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
        debugPrint('QA: native Firebase sign-in passed');
        await markOnboardingCompleted();

        final cameras = await availableCameras();
        expect(cameras, isNotEmpty);
        final camera = CameraController(
          cameras.first,
          ResolutionPreset.medium,
          enableAudio: false,
        );
        await camera.initialize();
        final picture = await camera.takePicture();
        await camera.dispose();
        final bytes = await File(picture.path).readAsBytes();
        expect(bytes, isNotEmpty);
        debugPrint('QA: native camera capture passed');
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final width = frame.image.width, height = frame.image.height;
        frame.image.dispose();
        codec.dispose();
        final vision = FlutterVision();
        await vision.loadYoloModel(
          labels: 'assets/dpwh_thesis_package6/labels.txt',
          modelPath: 'assets/dpwh_thesis_package6/best_float32.tflite',
          modelVersion: 'yolov8',
          quantization: false,
          numThreads: 2,
          useGpu: false,
        );
        final detections = await vision.yoloOnImage(
          bytesList: bytes,
          imageHeight: height,
          imageWidth: width,
          iouThreshold: 0.4,
          confThreshold: 0.2,
          classThreshold: 0.2,
        );
        expect(detections, isA<List>());
        await vision.closeYoloModel();
        debugPrint('QA: native model load and inference passed');

        expect(await Geolocator.isLocationServiceEnabled(), isTrue);
        final position = await Geolocator.getCurrentPosition(
          locationSettings: AndroidSettings(
            forceLocationManager: true,
            timeLimit: const Duration(seconds: 30),
          ),
        );
        expect(position.latitude, closeTo(14.85, 0.01));
        expect(position.longitude, closeTo(120.81, 0.01));
        debugPrint('QA: simulated Android GPS position passed');
      });
      await tester.pumpWidget(const app.MyApp());
      for (
        var i = 0;
        i < 30 && find.byType(app.MyHomePage).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(app.MyHomePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await FirebaseAuth.instance.signOut();
    },
  );
}
