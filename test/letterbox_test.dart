import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/model_detections.dart';

void main() {
  test('portrait padding is removed without changing probability', () {
    final result = filterModelDetections(restoreLetterboxedDetections([
      {'tag': 'Pothole', 'box': [133.0, 0.0, 475.0, 608.0, 0.69]},
      {'tag': 'Pothole', 'box': [0.0, 0.0, 100.0, 100.0, 0.8]},
    ], 720, 1280), imageWidth: 720, imageHeight: 1280);
    expect(result, hasLength(1));
    expect(result.single['box'], [0.0, 0.0, 720.0, 1280.0, 0.69]);
  });
  test('landscape padding maps to original coordinates', () {
    final result = restoreLetterboxedDetections([
      {'tag': 'Pothole', 'box': [0.0, 133.0, 608.0, 475.0, 0.7]},
    ], 1280, 720);
    final box = result.single['box'] as List;
    for (var i = 0; i < 5; i++) {
      expect(box[i], closeTo([0.0, 0.0, 1280.0, 720.0, 0.7][i], 1e-8));
    }
  });
}
