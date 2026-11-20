import 'dart:math' as math;
import 'dpwh_standards.dart';

/// Deduplicate matching detections from two passes over the same photograph.
List<Map<String, dynamic>> mergeModelDetections(
  List<Map<String, dynamic>> detections,
) {
  final sorted = List<Map<String, dynamic>>.of(detections)
    ..sort((a, b) => (b['box'][4] as num).compareTo(a['box'][4] as num));
  final kept = <Map<String, dynamic>>[];
  for (final candidate in sorted) {
    final a = candidate['box'] as List;
    final duplicate = kept.any((other) {
      if (candidate['classId'] != other['classId']) return false;
      final b = other['box'] as List;
      final intersection =
          math.max(
            0,
            math.min(a[2] as num, b[2] as num) -
                math.max(a[0] as num, b[0] as num),
          ) *
          math.max(
            0,
            math.min(a[3] as num, b[3] as num) -
                math.max(a[1] as num, b[1] as num),
          );
      final union =
          (a[2] - a[0]) * (a[3] - a[1]) +
          (b[2] - b[0]) * (b[3] - b[1]) -
          intersection;
      return union > 0 && intersection / union > 0.45;
    });
    if (!duplicate) kept.add(candidate);
  }
  return kept;
}

/// Map detections from a square, letterboxed model image to the original photo.
List<Map<String, dynamic>> restoreLetterboxedDetections(
  List<Map<String, dynamic>> raw,
  int width,
  int height,
) {
  final size = DpwhStandards.inputSize.toDouble();
  final scale = size / (width > height ? width : height);
  final dx = (size - width * scale) / 2;
  final dy = (size - height * scale) / 2;
  return raw.map((d) {
    final box = d['box'];
    if (box is! List || box.length < 5) return d;
    return <String, dynamic>{
      ...d,
      'box': [
        ((box[0] as num) - dx) / scale,
        ((box[1] as num) - dy) / scale,
        ((box[2] as num) - dx) / scale,
        ((box[3] as num) - dy) / scale,
        box[4],
      ],
    };
  }).toList();
}

/// Preserve the model's classes and probabilities; reject unsupported outputs.
List<Map<String, dynamic>> filterModelDetections(
  List<Map<String, dynamic>> raw, {
  double confidenceThreshold = DpwhStandards.defaultConfidenceThreshold,
  int imageWidth = DpwhStandards.inputSize,
  int imageHeight = DpwhStandards.inputSize,
}) {
  final accepted = <Map<String, dynamic>>[];
  for (final detection in raw) {
    final cls = DpwhStandards.activeClassForDetection(detection);
    final box = detection['box'];
    if (cls == null ||
        box is! List ||
        box.length < 5 ||
        box.take(5).any((v) => v is! num || !v.isFinite)) {
      continue;
    }
    final confidence = (box[4] as num).toDouble();
    if (confidence < confidenceThreshold || confidence > 1) continue;
    final left = (box[0] as num).toDouble().clamp(0.0, imageWidth.toDouble());
    final top = (box[1] as num).toDouble().clamp(0.0, imageHeight.toDouble());
    final right = (box[2] as num).toDouble().clamp(0.0, imageWidth.toDouble());
    final bottom = (box[3] as num).toDouble().clamp(
      0.0,
      imageHeight.toDouble(),
    );
    if (right <= left || bottom <= top) continue;
    accepted.add({
      ...detection,
      'tag': cls.rawLabel,
      'classId': cls.classId,
      'box': [left, top, right, bottom, confidence],
    });
  }
  return accepted;
}
