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

  test('four supported classes retain Package 6 output indices', () {
    expect(DpwhStandards.allClasses.map((c) => c.classId), [0, 1, 3, 4]);
    expect(DpwhStandards.getById(3), DpwhStandards.longitudinalCrack);
    expect(DpwhStandards.getById(4), DpwhStandards.transverseCrack);
    expect(DpwhStandards.allClasses.map((c) => c.name).toSet(), hasLength(4));
    expect(
      DpwhStandards.allClasses.where((c) => c.code == 'CODE 12'),
      hasLength(2),
    );
  });

  test(
    'bundled output labels keep the ignored slot and metadata describes the tensor',
    () {
      final labels = File(DpwhStandards.labelsAsset).readAsLinesSync();
      expect(() => DpwhStandards.validateModelLabels(labels), returnsNormally);
      expect(labels, hasLength(5));
      expect(labels[2], contains('Depression'));
      expect(
        () => DpwhStandards.validateModelLabels([...labels]..removeAt(2)),
        throwsStateError,
      );
      final metadata = jsonDecode(
        File(
          'assets/dpwh_thesis_optimized/dpwh_metadata.json',
        ).readAsStringSync(),
      );
      expect(metadata['supported_class_ids'], [0, 1, 3, 4]);
      expect(metadata['input_size'], [608, 608]);
      expect(metadata['output_shape'], [1, 9, 7581]);
    },
  );

  test(
    'inference excludes untrained, old, unknown and malformed detections',
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
      expect(accepted.map((d) => d['classId']), [0, 1, 3, 4]);
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
    'explicit labels resolve old numeric mismatches and crack orientations stay distinct',
    () {
      expect(
        DpwhStandards.activeClassForDetection({
          'classId': 2,
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
      expect(counts, {0: 1, 1: 1, 3: 1, 4: 1});
      expect(
        DpwhStandards.classForReport({'primaryDefect': 'Depression'}),
        DpwhStandards.depression,
      );
    },
  );
}
