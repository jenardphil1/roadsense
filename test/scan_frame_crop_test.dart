import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/scan_frame_crop.dart';

Future<Uint8List> _createSolidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(
    recorder,
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF334155),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  test('computeVisibleScanCropRect returns full image when aspect matches', () {
    final rect = computeVisibleScanCropRect(
      imageWidth: 720,
      imageHeight: 1280,
      viewWidth: 360,
      viewHeight: 640,
      previewAspectRatio: 720 / 1280,
    );
    expect(rect, const ui.Rect.fromLTWH(0, 0, 720, 1280));
  });

  test(
    'computeVisibleScanCropRect crops tall 9:16 photo to wider viewfinder symmetrically',
    () {
      final rect = computeVisibleScanCropRect(
        imageWidth: 720,
        imageHeight: 1280,
        viewWidth: 393,
        viewHeight: 652,
      );
      expect(rect.left, 0);
      expect(rect.width, 720);
      final expectedH = (720 / (393 / 652)).roundToDouble();
      expect(rect.height, closeTo(expectedH, 1.0));
      expect(rect.top, closeTo((1280 - rect.height) / 2.0, 1.0));
    },
  );

  test(
    'computeVisibleScanCropRect applies two-step sensor preview + viewport crop',
    () {
      // 3:4 sensor image (3000x4000) with 9:16 previewAspectRatio (0.5625) in 393x652 viewport.
      final rect = computeVisibleScanCropRect(
        imageWidth: 3000,
        imageHeight: 4000,
        viewWidth: 393,
        viewHeight: 652,
        previewAspectRatio: 0.5625,
      );
      // Step 1 center-crops width to 4000 * 0.5625 = 2250, left = 375.
      // Step 2 center-crops height to 2250 / (393 / 652) ~= 3733, top ~= 134.
      expect(rect.left, closeTo(375, 1.0));
      expect(rect.width, closeTo(2250, 1.0));
      expect(rect.width / rect.height, closeTo(393 / 652, 0.002));
      expect(rect.top, greaterThan(100));
    },
  );

  test(
    'remapDetectionsToCropRect translates visible boxes and drops off-screen boxes',
    () {
      const cropRect = ui.Rect.fromLTWH(100, 200, 500, 800);
      final detections = [
        // Inside crop: maps relative to (100, 200) and scales 500x800 -> 250x400 (0.5x)
        {
          'tag': 'Pothole',
          'classId': 0,
          'trackId': 7,
          'box': [200.0, 400.0, 400.0, 600.0, 0.88],
        },
        // Completely outside top margin of cropRect -> dropped
        {
          'tag': 'Longitudinal Crack',
          'classId': 1,
          'trackId': 8,
          'box': [150.0, 10.0, 250.0, 120.0, 0.72],
        },
        // Tiny sliver (<15% visible) on edge -> dropped
        {
          'tag': 'Transverse Crack',
          'classId': 4,
          'trackId': 9,
          'box': [120.0, 0.0, 220.0, 220.0, 0.65],
        },
      ];

      final remapped = remapDetectionsToCropRect(
        detections,
        cropRect: cropRect,
        sourceWidth: 720,
        sourceHeight: 1280,
        outputWidth: 250,
        outputHeight: 400,
      );

      expect(remapped, hasLength(1));
      expect(remapped.single['tag'], 'Pothole');
      expect(remapped.single['classId'], 0);
      expect(remapped.single['trackId'], 7);
      final box = remapped.single['box'] as List;
      expect(box[0], closeTo(50.0, 1e-6));
      expect(box[1], closeTo(100.0, 1e-6));
      expect(box[2], closeTo(150.0, 1e-6));
      expect(box[3], closeTo(200.0, 1e-6));
      expect(box[4], closeTo(0.88, 1e-6));
    },
  );

  test(
    'cropImageBytesToVisibleScan outputs cropped PNG matching viewport aspect',
    () async {
      final png = await _createSolidPng(720, 1280);
      final cropped = await cropImageBytesToVisibleScan(
        png,
        viewSize: const ui.Size(393, 652),
      );

      expect(cropped.sourceWidth, 720);
      expect(cropped.sourceHeight, 1280);
      expect(cropped.width, 720);
      expect(cropped.height, lessThan(1280));
      expect(cropped.width / cropped.height, closeTo(393 / 652, 0.005));

      final codec = await ui.instantiateImageCodec(cropped.bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, cropped.width);
      expect(frame.image.height, cropped.height);
      frame.image.dispose();
      codec.dispose();
    },
  );
}
