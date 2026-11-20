import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/dpwh_standards.dart';

/// Deterministic severity tests for DpwhStandards.evaluateSeverity.
/// Frame area = 640x640 = 409,600 px² in all cases; boxes in frame px.
void main() {
  const double frameArea = 640.0 * 640.0;

  Map<String, dynamic> det(String tag, List<double> box,
          {double conf = 0.7}) =>
      {'tag': tag, 'box': [...box, conf]};

  group('evaluateSeverity', () {
    test('large pothole (≥10% of frame) → high', () {
      // 220x220 = 48,400 px² ≈ 11.8% of frame
      expect(
        DpwhStandards.evaluateSeverity(
            det('Pothole', [100, 100, 320, 320]), frameArea),
        'high',
      );
    });

    test('typical pothole (≥2.5%) → medium', () {
      // 120x120 = 14,400 px² ≈ 3.5%
      expect(
        DpwhStandards.evaluateSeverity(
            det('Pothole', [200, 200, 320, 320]), frameArea),
        'medium',
      );
    });

    test('line crack (tiny) → low', () {
      // 80x30 = 2,400 px² ≈ 0.6%
      expect(
        DpwhStandards.evaluateSeverity(
            det('Longitudinal crack', [300, 300, 380, 330]), frameArea),
        'low',
      );
    });

    test('alligator crack patch → high (structural class)', () {
      // 150x150 = 22,500 px² ≈ 5.5%
      expect(
        DpwhStandards.evaluateSeverity(
            det('Alligator crack', [200, 200, 350, 350]), frameArea),
        'high',
      );
    });

    test('tiny alligator patch → medium (class floor)', () {
      // 40x40 = 1,600 px² ≈ 0.4%
      expect(
        DpwhStandards.evaluateSeverity(
            det('Alligator crack', [300, 300, 340, 340]), frameArea),
        'medium',
      );
    });

    test('large transverse crack → medium', () {
      // 400x80 = 32,000 px² ≈ 7.8%
      expect(
        DpwhStandards.evaluateSeverity(
            det('Transverse crack', [120, 280, 520, 360]), frameArea),
        'medium',
      );
    });

    test('confidence never changes the rating', () {
      final low = det('Pothole', [200, 200, 320, 320], conf: 0.20);
      final high = det('Pothole', [200, 200, 320, 320], conf: 0.95);
      expect(DpwhStandards.evaluateSeverity(low, frameArea),
          DpwhStandards.evaluateSeverity(high, frameArea));
    });

    test('unknown frame area: urgent-code classes medium, cracks low', () {
      final pothole = det('Pothole', [200, 200, 320, 320]);
      final crack = det('Longitudinal crack', [300, 300, 380, 330]);
      expect(DpwhStandards.evaluateSeverity(pothole, 0), 'medium');
      expect(DpwhStandards.evaluateSeverity(crack, -1), 'low');
    });

    test('empty/malformed detection → type-only rating (pothole floor)', () {
      // No tag → classify defaults to pothole; no box → minimum size score.
      expect(DpwhStandards.evaluateSeverity({}, frameArea), 'medium');
      expect(
        DpwhStandards.evaluateSeverity({'tag': 'Pothole'}, frameArea),
        'medium',
      );
      expect(
        DpwhStandards.evaluateSeverity({'tag': 'Longitudinal crack'}, frameArea),
        'low',
      );
    });
  });

  group('getOverallSeverity rule (max severity wins)', () {
    test('overall = highest across detections, empty → medium', () {
      String overall(List<Map<String, dynamic>> dets, double area) {
        if (dets.isEmpty) return 'medium';
        bool hasHigh = false, hasMed = false;
        for (final d in dets) {
          final sev = DpwhStandards.evaluateSeverity(d, area);
          if (sev == 'high') hasHigh = true;
          if (sev == 'medium') hasMed = true;
        }
        return hasHigh ? 'high' : (hasMed ? 'medium' : 'low');
      }

      final crack = det('Longitudinal crack', [300, 300, 380, 330]);
      final pothole = det('Pothole', [200, 200, 320, 320]);
      expect(overall([], frameArea), 'medium');
      expect(overall([crack], frameArea), 'low');
      expect(overall([crack, pothole], frameArea), 'medium');
      expect(overall([crack, det('Pothole', [100, 100, 320, 320])], frameArea),
          'high');
    });
  });
}
