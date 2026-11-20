import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/live_detection_snapshot.dart';
import 'package:my_flutter_app/model_detections.dart';

void main() {
  final start = DateTime(2026, 11, 13);
  Map<String, dynamic> detection(int id, double score, [double x = 0]) => {
    'classId': id,
    'box': [x, 0.0, x + 100, 100.0, score],
  };
  test('one missed pass holds the matching image, not the missed frame', () {
    final buffer = LiveDetectionBuffer();
    final bytes = Uint8List.fromList([1, 2, 3]);
    final result = detection(3, 0.64);
    buffer.update(bytes, 720, 1280, [result], start);
    bytes[0] = 9;
    (result['box'] as List)[4] = 0.99;
    final held = buffer.update(
      Uint8List.fromList([4]),
      720,
      1280,
      [],
      start.add(const Duration(seconds: 1)),
    )!;
    expect(held.bytes, [1, 2, 3]);
    expect(held.detections.single['box'][4], 0.64);
    expect(buffer.isHeld, isTrue);
    expect(
      buffer.update(
        bytes,
        720,
        1280,
        [],
        start.add(const Duration(seconds: 2)),
      ),
      isNull,
    );
  });
  test('retained detections expire even when no new frame arrives', () {
    final buffer = LiveDetectionBuffer();
    buffer.update(Uint8List(1), 720, 1280, [detection(3, 0.5)], start);
    expect(buffer.current(start.add(const Duration(seconds: 3))), isNull);
    buffer.clear();
    expect(buffer.current(start), isNull);
  });
  test(
    'two passes deduplicate one defect without merging other classes or locations',
    () {
      final results = mergeModelDetections([
        detection(3, 0.4),
        detection(3, 0.7, 2),
        detection(4, 0.6),
        detection(3, 0.5, 200),
      ]);
      expect(results, hasLength(3));
      expect(results.first['box'][4], 0.7);
      expect(results.where((r) => r['classId'] == 4), hasLength(1));
    },
  );
}
