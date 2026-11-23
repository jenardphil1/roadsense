import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/dpwh_standards.dart';
import 'package:my_flutter_app/model_detections.dart';

void main() {
  Map<String, dynamic> detection(Object label, {double confidence = 0.8}) => {
    if (label is int) 'classId': label else 'tag': label,
    'box': [10.0, 20.0, 100.0, 120.0, confidence],
  };

  test('four supported DPWH v3 classes occupy slots 0..3 with no Depression', () {
    expect(DpwhStandards.allClasses.map((c) => c.classId), [0, 1, 2, 3]);
    expect(DpwhStandards.getById(2), DpwhStandards.longitudinalCrack);
    expect(DpwhStandards.getById(3), DpwhStandards.transverseCrack);
    expect(DpwhStandards.getById(4), isNull);
    expect(DpwhStandards.allClasses.map((c) => c.name).toSet(), hasLength(4));
    expect(
      DpwhStandards.allClasses.where((c) => c.code == 'CODE 12'),
      hasLength(2),
    );
    expect(DpwhStandards.overallPrecision, greaterThanOrEqualTo(0.80));
    expect(DpwhStandards.overallRecall, greaterThanOrEqualTo(0.80));
    expect(DpwhStandards.overallF1Score, greaterThanOrEqualTo(0.80));
    expect(DpwhStandards.overallMap50, greaterThanOrEqualTo(0.80));
  });

  test(
    'bundled v3 output labels have strictly 4 classes and metadata matches 640x640 tensor',
    () {
      final labels = File(DpwhStandards.labelsAsset).readAsLinesSync();
      expect(() => DpwhStandards.validateModelLabels(labels), returnsNormally);
      expect(labels, hasLength(4));
      expect(labels.any((l) => l.toLowerCase().contains('depression')), isFalse);
      expect(
        () => DpwhStandards.validateModelLabels([
          ...labels,
          'Depression (DPWH Code 05)',
        ]),
        throwsStateError,
      );
      final metadata = jsonDecode(
        File(
          'assets/dpwh_thesis_optimized/dpwh_metadata.json',
        ).readAsStringSync(),
      );
      expect(metadata['model_id'], 'dpwh-v3-yolov8s');
      expect(metadata['supported_class_ids'], [0, 1, 2, 3]);
      expect(metadata['output_class_count'], 4);
      expect(metadata['input_size'], [640, 640]);
      expect(metadata['output_shape'], [1, 8, 8400]);
    },
  );

  test(
    'inference excludes untrained, legacy, unknown and malformed detections',
    () {
      final accepted = filterModelDetections([
        for (final id in [0, 1, 2, 3, 4, 5, 99]) detection(id),
        detection('Unknown damage'),
        detection('Depression (DPWH Code 05)'),
        {'tag': 'Pothole'},
        {
          'tag': 'Pothole',
          'box': [0, 0, 10, 10, double.nan],
        },
      ]);
      expect(accepted.map((d) => d['classId']), [0, 1, 2, 3]);
    },
  );

  test(
    'inference preserves confidence and never changes edge breaks into potholes',
    () {
      final accepted = filterModelDetections([
        detection('Alligator crack', confidence: 0.15),
        detection('Longitudinal crack', confidence: 0.65),
        detection('Edge break', confidence: 0.99),
      ]);
      expect(accepted, hasLength(1));
      expect(accepted.single['tag'], DpwhStandards.longitudinalCrack.rawLabel);
      expect((accepted.single['box'] as List).last, 0.65);
    },
  );

  test(
    'explicit labels and legacy v2 reports resolve compatibly across versions',
    () {
      expect(
        DpwhStandards.activeClassForDetection({
          'classId': 3,
          'className': 'Longitudinal crack',
        }),
        DpwhStandards.longitudinalCrack,
      );
      expect(
        DpwhStandards.classForReport({
          'primaryDefect': 'Transverse crack',
          'primaryDpwhCode': 'CODE 12',
        }),
        DpwhStandards.transverseCrack,
      );
      expect(
        DpwhStandards.classForReport({
          'modelId': 'dpwh-v2-optimized',
          'primaryClassId': 2,
        }),
        DpwhStandards.depression,
      );
      expect(
        DpwhStandards.classForReport({
          'modelId': 'dpwh-v2-optimized',
          'primaryClassId': 3,
        }),
        DpwhStandards.longitudinalCrack,
      );
      expect(
        DpwhStandards.classForReport({
          'modelId': 'dpwh-v2-optimized',
          'primaryClassId': 4,
        }),
        DpwhStandards.transverseCrack,
      );
      expect(
        DpwhStandards.classForReport({
          'modelId': 'dpwh-v3-yolov8s',
          'primaryClassId': 2,
        }),
        DpwhStandards.longitudinalCrack,
      );
      expect(
        DpwhStandards.classForReport({
          'modelId': 'dpwh-v3-yolov8s',
          'primaryClassId': 3,
        }),
        DpwhStandards.transverseCrack,
      );
      expect(
        DpwhStandards.classForReport({'primaryDpwhCode': 'CODE 12'}),
        isNull,
      );
      expect(
        DpwhStandards.getClassColor('Transverse crack'),
        isNot(DpwhStandards.getClassColor('Longitudinal crack')),
      );
    },
  );

  test(
    'admin counts four classes without turning historical records into current detections',
    () {
      final counts = DpwhStandards.countSupportedReports([
        for (final cls in DpwhStandards.allClasses)
          {'primaryDefect': cls.name, 'primaryDpwhCode': cls.code},
        {'primaryDefect': 'Depression', 'primaryDpwhCode': 'CODE 05'},
        {'primaryDefect': 'Edge break', 'primaryDpwhCode': 'CODE 01'},
        {'primaryDpwhCode': 'CODE 12'},
      ]);
      expect(counts, {0: 1, 1: 1, 2: 1, 3: 1});
      expect(
        DpwhStandards.classForReport({'primaryDefect': 'Depression'}),
        DpwhStandards.depression,
      );
    },
  );
}
