import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/live_detection_snapshot.dart';

void main() {
  final start = DateTime(2026, 11, 16);
  DateTime time(int ms) => start.add(Duration(milliseconds: ms));
  Map<String, dynamic> detection(double x, {int cls = 0, double score = .7}) =>
      {
        'classId': cls,
        'box': [x, 100.0, x + 100, 200.0, score],
      };
  LiveDetectionSnapshot? update(
    LiveDetectionBuffer buffer,
    int ms,
    List<Map<String, dynamic>> results,
  ) => buffer.update(
    Uint8List.fromList([ms ~/ 100]),
    720,
    1280,
    results,
    time(ms),
  );

  test('small movement keeps identity and exact new-image coordinates', () {
    final b = LiveDetectionBuffer();
    final first = update(b, 0, [detection(100)])!;
    final next = update(b, 800, [detection(120, score: .3)])!;
    expect(
      next.detections.single['trackId'],
      first.detections.single['trackId'],
    );
    expect(next.detections.single['box'], [120, 100, 220, 200, .3]);
    expect(next.bytes, [8]);
  });

  test(
    'brief confidence miss preserves identity, never moves old boxes to new photo',
    () {
      final b = LiveDetectionBuffer();
      final first = update(b, 0, [detection(100)])!;
      final missed = update(b, 800, [])!;
      expect(missed, same(first));
      expect(missed.bytes, [0]);
      expect(b.activeCount(time(800)), 1);
      final recovered = update(b, 1600, [detection(125)])!;
      expect(
        recovered.detections.single['trackId'],
        first.detections.single['trackId'],
      );
      expect(recovered.bytes, [16]);
    },
  );

  test(
    'class jitter is withheld; sustained three-frame change is accepted honestly',
    () {
      final b = LiveDetectionBuffer();
      final first = update(b, 0, [detection(100)])!;
      expect(update(b, 400, [detection(105, cls: 1)]), same(first));
      final restored = update(b, 800, [detection(110)])!;
      expect(
        restored.detections.single['trackId'],
        first.detections.single['trackId'],
      );
      expect(update(b, 1200, [detection(115, cls: 1)]), same(restored));
      expect(update(b, 1600, [detection(120, cls: 1)]), same(restored));
      final changed = update(b, 2000, [detection(125, cls: 1, score: .4)])!;
      expect(changed.detections.single['classId'], 1);
      expect(changed.detections.single['box'][4], .4);
      expect(
        changed.detections.single['trackId'],
        first.detections.single['trackId'],
      );
      expect(changed.bytes, [20]);
    },
  );

  test('nearby potholes stay distinct when confidence/order changes', () {
    final b = LiveDetectionBuffer();
    final first = update(b, 0, [detection(100), detection(160)])!;
    final next = update(b, 800, [detection(170), detection(110, score: .26)])!;
    expect(
      next.detections.map((d) => d['trackId']),
      first.detections.map((d) => d['trackId']),
    );
    expect(next.detections.map((d) => d['box'][0]), [110, 170]);
    expect(b.activeCount(time(800)), 2);
  });

  test('one missing pothole expires even while another remains detected', () {
    final b = LiveDetectionBuffer();
    final first = update(b, 0, [detection(100), detection(300)])!;
    update(b, 800, [detection(310)]);
    expect(b.activeCount(time(800)), 2);
    final next = update(b, 1600, [detection(320)])!;
    expect(b.activeCount(time(1600)), 1);
    expect(next.detections.single['trackId'], first.detections.last['trackId']);
    expect(next.detections.single['box'][0], 320);
  });

  test(
    'moving away clears after two misses and stalled inference expires by time',
    () {
      final b = LiveDetectionBuffer();
      update(b, 0, [detection(100)]);
      update(b, 800, []);
      expect(update(b, 1600, []), isNull);
      expect(b.activeCount(time(1600)), 0);
      update(b, 2000, [detection(100)]);
      expect(b.untilExpiry(time(2500)), const Duration(milliseconds: 2500));
      b.expire(time(5000));
      expect(b.current(time(5000)), isNull);
      b.expire(time(6000));
      expect(b.activeCount(time(6000)), 0);
      expect(b.untilExpiry(time(6000)), isNull);
    },
  );

  test('capture reference remains paired while another result arrives', () {
    final b = LiveDetectionBuffer();
    final source = detection(100);
    final image = Uint8List.fromList([1, 2]);
    final capture = b.update(image, 720, 1280, [source], time(0))!;
    image[0] = 9;
    (source['box'] as List)[0] = 999.0;
    update(b, 800, [detection(120)]);
    b.clear();
    expect(capture.bytes, [1, 2]);
    expect(capture.detections.single['box'][0], 100);
    expect(capture.detectedAt, time(0));
  });

  test(
    'one slow missed cycle retains identity without extending the old photo',
    () {
      final b = LiveDetectionBuffer();
      final first = update(b, 0, [detection(100)])!;
      b.update(Uint8List(1), 720, 1280, [], time(2400), capturedAt: time(1000));
      b.expire(time(3000));
      expect(b.current(time(3000)), isNull);
      expect(b.activeCount(time(3000)), 1);
      final next = b.update(
        Uint8List.fromList([9]),
        720,
        1280,
        [detection(120)],
        time(3400),
        capturedAt: time(2500),
      )!;
      expect(
        next.detections.single['trackId'],
        first.detections.single['trackId'],
      );
      expect(next.bytes, [9]);
      expect(next.detectedAt, time(2500));
    },
  );

  test(
    'late results and out-of-order photos cannot resurrect stale tracks',
    () {
      final b = LiveDetectionBuffer();
      final first = update(b, 1000, [detection(100)])!;
      expect(
        b.update(
          Uint8List(1),
          720,
          1280,
          [detection(300)],
          time(1500),
          capturedAt: time(500),
        ),
        same(first),
      );
      expect(
        b.update(
          Uint8List(1),
          720,
          1280,
          [detection(100)],
          time(5500),
          capturedAt: time(1500),
        ),
        isNull,
      );
      expect(b.activeCount(time(5500)), 0);
    },
  );

  test('miss interrupts class-change streak; resizing resets associations', () {
    final b = LiveDetectionBuffer();
    final first = update(b, 0, [detection(100)])!;
    update(b, 400, [detection(100, cls: 1)]);
    update(b, 800, []);
    expect(update(b, 1200, [detection(100, cls: 1)]), same(first));
    final resized = b.update(Uint8List(1), 1280, 720, [
      detection(100),
    ], time(1600))!;
    expect(
      resized.detections.single['trackId'],
      isNot(first.detections.single['trackId']),
    );
  });
}
