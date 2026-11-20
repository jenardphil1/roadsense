import 'package:flutter/material.dart';

/// Represents one official DPWH Road Distress Classification from the
/// thesis research package and dataset.
///
/// NOTE: Categories are strictly type-based; the statutory response time
/// ([responseTime]) depends only on the DPWH code. A separate physical
/// damage-magnitude metric exists in [DpwhStandards.evaluateSeverity] —
/// (defect class + relative size only) — and model confidence (%) and GPS
/// accuracy (±m) must never be combined into it or into any code mapping.
class DpwhDefectClass {
  final int classId; // Original model output slot; IDs are not renumbered.
  final String name;
  final String rawLabel;
  final String code; // 'CODE 01', 'CODE 02', 'CODE 12'
  final Color color; // Okabe-Ito colorblind-safe color
  final String glyphDescription;
  final String responseTime;
  final String correctiveMeasure;
  final String unit;
  final double precision;
  final double recall;
  final double f1Score;
  final double map50;
  final double map50_95;

  const DpwhDefectClass({
    required this.classId,
    required this.name,
    required this.rawLabel,
    required this.code,
    required this.color,
    required this.glyphDescription,
    required this.responseTime,
    required this.correctiveMeasure,
    required this.unit,
    required this.precision,
    required this.recall,
    required this.f1Score,
    required this.map50,
    required this.map50_95,
  });

  String get unitOfMeasurement => unit;

  /// Compatibility fallback during codebase alignment (severity is removed)
  @Deprecated('Use DpwhDefectClass fields directly')
  String get severity => '';
  @Deprecated('Use name directly')
  String get severityLevel => name;

  Map<String, dynamic> toMap() => {
    'classId': classId,
    'className': name,
    'rawLabel': rawLabel,
    'dpwhCode': code,
    'glyph': glyphDescription,
    'responseTime': responseTime,
    'correctiveMeasure': correctiveMeasure,
    'unit': unit,
    'precision': precision,
    'recall': recall,
    'f1Score': f1Score,
    'map50': map50,
    'map50_95': map50_95,
  };
}

/// Official DPWH Road Distress Standards Catalog & Evaluation Metrics
/// derived directly from the YOLOv8m Optimized v2 Thesis Results.
///
/// Four supported classes retain their 5-slot output indices:
///   0 = Pothole (DPWH 01)
///   1 = Alligator crack (DPWH 02)
///   3 = Longitudinal crack (DPWH 12)
///   4 = Transverse crack (DPWH 12)
/// Slot 2 is untrained depression. Older edge-break records are historical only.
class DpwhStandards {
  DpwhStandards._();

  // Model Specs & Speed Benchmark from thesis_speed_benchmark.txt
  static const String modelName = 'YOLOv8m (DPWH Road Defect Detector)';
  static const String modelId = 'dpwh-v2-optimized';
  static const String modelAsset =
      'assets/dpwh_thesis_optimized/best_float32.tflite';
  static const String fallbackModelAsset =
      'assets/dpwh_thesis_optimized/best_float16.tflite';
  static const String labelsAsset = 'assets/dpwh_thesis_optimized/labels.txt';
  static const String inputResolution = '608 x 608';
  static const int inputSize = 608;
  static const double defaultConfidenceThreshold = 0.25;
  static const double avgLatencyMs = 44.43;
  static const double latencyStdMs = 0.81;
  static const double throughputFps = 22.51;
  static const bool isRealtimeCapable = true;

  // Global Evaluation Metrics from thesis_test_metrics.csv (Optimized v2)
  static const double overallPrecision = 0.6991;
  static const double overallRecall = 0.7562;
  static const double overallF1Score = 0.7258;
  static const double overallMap50 = 0.7755;
  static const double overallMap50_95 = 0.4659;

  // Okabe-Ito Colorblind-Safe Palette
  static const Color potholeColor = Color(0xFFD55E00); // Vermillion
  static const Color alligatorColor = Color(0xFF56B4E9); // Sky blue
  static const Color longitudinalColor = Color(0xFF009E73); // Bluish green
  static const Color transverseColor = Color(
    0xFFF0E442,
  ); // Straw yellow (needs dark border on map)
  static const Color edgeBreakColor = Color(0xFFCC79A7); // Reddish purple
  static const Color neutralClusterColor = Color(
    0xFF1E293B,
  ); // Neutral navy (never a class color)

  // 1. Class 0: Bowl-shaped depression / Pothole (DPWH Code 01)
  static const DpwhDefectClass pothole = DpwhDefectClass(
    classId: 0,
    name: 'Pothole',
    rawLabel: 'Bowl-shaped depression / Pothole (DPWH Code 01)',
    code: 'CODE 01',
    color: potholeColor,
    glyphDescription: 'filled irregular blob with jagged inner outline',
    responseTime: '3 Days',
    correctiveMeasure:
        'Bituminous premix (hot) or penetration patching; add base material if needed.',
    unit: 'sq.m.',
    precision: 0.6970,
    recall: 0.8150,
    f1Score: 0.7514,
    map50: 0.8177,
    map50_95: 0.5291,
  );

  // 2. Class 1: Alligator crack (DPWH Code 02)
  static const DpwhDefectClass alligatorCrack = DpwhDefectClass(
    classId: 1,
    name: 'Alligator crack',
    rawLabel: 'Alligator crack (DPWH Code 02)',
    code: 'CODE 02',
    color: alligatorColor,
    glyphDescription: 'closed cell-grid (3x3 mesh) outline',
    responseTime: '3 Days',
    correctiveMeasure:
        'Bituminous premix (hot) or penetration patching of affected area.',
    unit: 'sq.m.',
    precision: 0.7490,
    recall: 0.7351,
    f1Score: 0.7420,
    map50: 0.7945,
    map50_95: 0.5030,
  );

  // 3. Class 2: Depression (DPWH Code 05)
  static const DpwhDefectClass depression = DpwhDefectClass(
    classId: 2,
    name: 'Depression',
    rawLabel: 'Depression (DPWH Code 05)',
    code: 'CODE 05',
    color: Color(0xFFE69F00), // Amber / Ochre
    glyphDescription: 'broad shallow bowl contour outline',
    responseTime: '30 Days',
    correctiveMeasure:
        'Re-blocking / replacement of concrete pavement including base correction.',
    unit: 'sq.m.',
    precision: 0.5503,
    recall: 0.3810,
    f1Score: 0.4502,
    map50: 0.4262,
    map50_95: 0.1563,
  );

  // 4. Class 3: Longitudinal crack (DPWH Code 12)
  static const DpwhDefectClass longitudinalCrack = DpwhDefectClass(
    classId: 3,
    name: 'Longitudinal crack',
    rawLabel: 'Longitudinal crack (DPWH Code 12)',
    code: 'CODE 12',
    color: longitudinalColor,
    glyphDescription: 'vertical dashed line',
    responseTime: 'Routine maintenance / sealing',
    correctiveMeasure:
        'Crack sealing with hot or cold applied elastomeric sealant.',
    unit: 'l.m.',
    precision: 0.6594,
    recall: 0.7268,
    f1Score: 0.6914,
    map50: 0.7529,
    map50_95: 0.4330,
  );

  // 5. Class 4: Transverse crack (DPWH Code 12)
  static const DpwhDefectClass transverseCrack = DpwhDefectClass(
    classId: 4,
    name: 'Transverse crack',
    rawLabel: 'Transverse crack (DPWH Code 12)',
    code: 'CODE 12',
    color: transverseColor,
    glyphDescription: 'horizontal dashed line',
    responseTime: 'Routine maintenance / sealing',
    correctiveMeasure:
        'Crack sealing with hot or cold applied elastomeric sealant.',
    unit: 'l.m.',
    precision: 0.6911,
    recall: 0.7479,
    f1Score: 0.7184,
    map50: 0.7369,
    map50_95: 0.3986,
  );

  // 6. Class 5: Edge break (DPWH Code 01)
  static const DpwhDefectClass edgeBreak = DpwhDefectClass(
    classId: 5,
    name: 'Edge break',
    rawLabel: 'Edge break (DPWH Code 01)',
    code: 'CODE 01',
    color: edgeBreakColor,
    glyphDescription: 'corner tile notch (quarter-circle cut)',
    responseTime: '3 Days',
    correctiveMeasure:
        'Shoulder build-up and edge reconstruction with asphalt premix.',
    unit: 'sq.m.',
    precision: 0.7341,
    recall: 0.6667,
    f1Score: 0.6988,
    map50: 0.7536,
    map50_95: 0.6175,
  );

  /// Classes supported by the current model; excludes untrained/older classes.
  static const List<DpwhDefectClass> allClasses = [
    pothole,
    alligatorCrack,
    longitudinalCrack,
    transverseCrack,
  ];
  static const List<DpwhDefectClass> legacyClasses = [depression, edgeBreak];
  static const List<DpwhDefectClass> modelOutputClasses = [
    pothole,
    alligatorCrack,
    depression,
    longitudinalCrack,
    transverseCrack,
  ];

  static void validateModelLabels(List<String> labels) {
    if (labels.length != modelOutputClasses.length) {
      throw StateError(
        'Model requires all five output labels, including the ignored depression slot.',
      );
    }
    for (var i = 0; i < labels.length; i++) {
      if (labels[i].trim() != modelOutputClasses[i].rawLabel) {
        throw StateError('Model label mismatch at output slot $i.');
      }
    }
  }

  /// Look up defect class by numeric class ID (0..5)
  static DpwhDefectClass? getById(int? id) {
    if (id == null) return null;
    for (final cls in [...allClasses, ...legacyClasses]) {
      if (cls.classId == id) return cls;
    }
    return null;
  }

  /// Classifies any detection string (tag, raw label, name, code) to its canonical DPWH standard.
  static DpwhDefectClass classify(String? raw) {
    return tryClassify(raw) ?? pothole;
  }

  /// Strict lookup for inference and report validation. Unknown labels stay unknown.
  static DpwhDefectClass? tryClassify(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final lower = raw.trim().toLowerCase();

    // Check numeric index or "class X" / "class_X"
    final numMatch = RegExp(r'^(?:class[_\s]*)?(\d+)$').firstMatch(lower);
    if (numMatch != null) {
      final id = int.tryParse(numMatch.group(1)!);
      final fromId = getById(id);
      if (fromId != null) return fromId;
    }

    // Check specific class keywords
    if (lower.contains('alligator') || lower.contains('crocodile')) {
      return alligatorCrack;
    }
    if (lower.contains('edge') || lower.contains('break')) {
      return edgeBreak;
    }
    if (lower.contains('longitudinal')) {
      return longitudinalCrack;
    }
    if (lower.contains('transverse')) {
      return transverseCrack;
    }
    if (lower.contains('code 02')) {
      return alligatorCrack;
    }
    if (lower.contains('code 12')) {
      return lower.contains('transverse') ? transverseCrack : longitudinalCrack;
    }
    if (lower.contains('code 05') ||
        (lower.contains('depression') && !lower.contains('bowl'))) {
      return depression;
    }
    if (lower.contains('code 01') ||
        lower.contains('pothole') ||
        lower.contains('bowl')) {
      return lower.contains('edge') ? edgeBreak : pothole;
    }

    return null;
  }

  static DpwhDefectClass? activeClassForDetection(
    Map<String, dynamic> detection,
  ) {
    final label =
        detection['tag'] ?? detection['className'] ?? detection['rawTag'];
    final cls = label != null
        ? tryClassify(label.toString())
        : getById((detection['classId'] as num?)?.toInt());
    return allClasses.contains(cls) ? cls : null;
  }

  /// Read historical reports without inventing a crack orientation from CODE 12.
  static DpwhDefectClass? classForReport(Map<String, dynamic> report) {
    final label = report['primaryDefect'] as String?;
    final named = tryClassify(label);
    final ambiguousCrack =
        named?.code == 'CODE 12' &&
        !(label ?? '').toLowerCase().contains('longitudinal') &&
        !(label ?? '').toLowerCase().contains('transverse');
    if (named != null && !ambiguousCrack) return named;
    final id = report['primaryClassId'];
    if (id is num) return getById(id.toInt());
    final detections = report['detections'];
    if (detections is List &&
        detections.isNotEmpty &&
        detections.first is Map) {
      final first = Map<String, dynamic>.from(detections.first as Map);
      final cls = tryClassify(
        (first['className'] ?? first['rawTag'] ?? first['tag'])?.toString(),
      );
      if (cls != null) return cls;
    }
    final code = (report['primaryDpwhCode'] as String? ?? '').toUpperCase();
    if (code == 'CODE 01') return pothole;
    if (code == 'CODE 02') return alligatorCrack;
    if (code == 'CODE 05') return depression;
    return null;
  }

  static String reportDefectName(Map<String, dynamic> report) {
    final cls = classForReport(report);
    if (cls != null) return cls.name;
    if (report['primaryDpwhCode'] == 'CODE 12')
      return 'Crack (orientation not recorded)';
    return report['primaryDefect'] as String? ?? 'Unclassified road defect';
  }

  static Map<int, int> countSupportedReports(
    Iterable<Map<String, dynamic>> reports,
  ) {
    final counts = {for (final cls in allClasses) cls.classId: 0};
    for (final report in reports) {
      final cls = classForReport(report);
      if (cls != null && counts.containsKey(cls.classId)) {
        counts[cls.classId] = counts[cls.classId]! + 1;
      }
    }
    return counts;
  }

  static Color getClassColor(String? label) =>
      tryClassify(label)?.color ?? neutralClusterColor;

  /// Classifies by DPWH Code string ('CODE 01', 'CODE 02', 'CODE 05', 'CODE 12')
  static DpwhDefectClass classifyByCode(String? code) {
    if (code == null) return pothole;
    final normalized = code.trim().toUpperCase();
    if (normalized.contains('02')) return alligatorCrack;
    if (normalized.contains('05')) return depression;
    if (normalized.contains('12')) return longitudinalCrack;
    return pothole;
  }

  /// Color palette for classes (Okabe-Ito)
  static Color getColorForClassId(int classId) {
    return getById(classId)?.color ?? neutralClusterColor;
  }

  /// Color palette for DPWH Code Badges
  static Color getCodeColor(String code) {
    final c = code.trim().toUpperCase();
    if (c.contains('01')) return potholeColor;
    if (c.contains('02')) return alligatorColor;
    if (c.contains('05')) return const Color(0xFFE69F00);
    if (c.contains('12')) return longitudinalColor;
    return potholeColor;
  }

  /// DPWH Code short title
  static String getCodeTitle(String code) {
    final c = code.trim().toUpperCase();
    if (c.contains('01')) return 'Pothole (Urgent 3-Day)';
    if (c.contains('02')) return 'Alligator Crack (High 3-Day)';
    if (c.contains('05')) return 'Depression (30-Day Re-blocking)';
    if (c.contains('12')) return 'Crack (Routine Sealant)';
    return 'Road Surface Distress';
  }

  /// The four supported model classes.
  static List<DpwhDefectClass> get standards => allClasses;

  /// Looks up DPWH specification by code
  static DpwhDefectClass? getByCode(String? code) {
    if (code == null) return null;
    return classifyByCode(code);
  }

  /// Classifies by defect name
  static DpwhDefectClass classifyByName(String? name) => classify(name);

  /// Gets the DPWH code corresponding to a detection tag/label
  static String getCodeForLabel(String? label) => classify(label).code;

  /// Returns the badge color for a given DPWH code
  static Color getColorForCode(String? code) => getCodeColor(code ?? '');

  // ---------------------------------------------------------------------------
  // Severity (physical damage magnitude) — separate from statutory urgency
  // ---------------------------------------------------------------------------

  /// Rates one detection's **physical damage magnitude**: 'low' | 'medium' |
  /// 'high'. This is a distinct metric from the statutory DPWH response
  /// urgency ([DpwhDefectClass.responseTime], code-driven) and never uses
  /// model confidence or GPS accuracy. Two factors:
  ///
  ///  1. Defect type weight — structural damage potential of the distress
  ///     class: alligator mesh ≫ pothole ≫ edge break ≫ depression ≫ cracks.
  ///  2. Relative size — the detection box area as a fraction of the analyzed
  ///     frame ([frameArea] in px²), so the rating is scale-invariant across
  ///     cameras and zoom levels.
  ///
  /// total ≥ 3.0 → high · ≥ 1.8 → medium · else low. With an unknown
  /// [frameArea], urgent-code classes (01/02/05) read medium, cracks low.
  static String evaluateSeverity(Map<String, dynamic> det, double frameArea) {
    final dynamic rawTag =
        det['tag'] ?? det['className'] ?? det['classId'] ?? det['dpwhCode'];
    final cls = classify(rawTag == null ? '' : rawTag.toString());

    final double classScore = switch (cls) {
      alligatorCrack => 2.2,
      pothole => 1.6,
      edgeBreak => 1.3,
      depression => 1.0,
      longitudinalCrack => 0.9,
      transverseCrack => 0.8,
      // classify() defaults to pothole, so this arm is unreachable.
      _ => 1.6,
    };

    double sizeScore;
    if (!frameArea.isFinite || frameArea <= 0) {
      sizeScore = cls.code == 'CODE 12' ? 0.2 : 1.2;
    } else {
      final box = det['box'] as List<dynamic>?;
      final w = (box != null && box.length >= 4)
          ? ((box[2] as num).toDouble() - (box[0] as num).toDouble()).abs()
          : 0.0;
      final h = (box != null && box.length >= 4)
          ? ((box[3] as num).toDouble() - (box[1] as num).toDouble()).abs()
          : 0.0;
      final frac = (w * h) / frameArea;
      sizeScore = frac >= 0.10
          ? 1.9
          : frac >= 0.025
          ? 1.2
          : frac >= 0.006
          ? 0.6
          : 0.2;
    }

    final total = classScore + sizeScore;
    return total >= 3.0
        ? 'high'
        : total >= 1.8
        ? 'medium'
        : 'low';
  }

  /// Extracts canonical DPWH defect class names from a report's raw
  /// `detections` entries (supporting heterogeneous schema keys).
  static List<String> extractDetectionClassNames(
    List<Map<String, dynamic>>? detections,
  ) {
    if (detections == null || detections.isEmpty) return const <String>[];
    final names = <String>[];
    for (final det in detections) {
      final raw =
          det['className'] ??
          det['defectClass'] ??
          det['defectType'] ??
          det['rawTag'] ??
          det['tag'] ??
          det['label'] ??
          det['name'];
      if (raw is String && raw.trim().isNotEmpty) {
        names.add(classify(raw).name);
      } else if (det['classId'] is num) {
        final int id = (det['classId'] as num).toInt();
        for (final cls in allClasses) {
          if (cls.classId == id) {
            names.add(cls.name);
            break;
          }
        }
      }
    }
    return names;
  }

  /// Parses Firestore `detections` with fallback to `defectClasses` strings so
  /// mixed-defect reports keep all detected classes regardless of storage form.
  static List<Map<String, dynamic>>? parseDetectionsWithFallback(
    Map<String, dynamic> data,
  ) {
    final rawDetections = data['detections'];
    if (rawDetections is List && rawDetections.isNotEmpty) {
      final parsed = rawDetections
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
      if (parsed.isNotEmpty) return parsed;
    }
    final rawClasses = data['defectClasses'];
    if (rawClasses is List && rawClasses.isNotEmpty) {
      final fallback = <Map<String, dynamic>>[];
      for (final item in rawClasses) {
        if (item is String && item.trim().isNotEmpty) {
          fallback.add(<String, dynamic>{'className': classify(item).name});
        }
      }
      if (fallback.isNotEmpty) return fallback;
    }
    return null;
  }

  /// Returns non-empty canonical defect class names suitable for persisting
  /// into `RoadReportCache`.
  static List<String> extractCachedDefectClasses(
    List<Map<String, dynamic>>? detections,
    String fallbackPrimaryDefect,
  ) {
    final classes = extractDetectionClassNames(detections);
    if (classes.isNotEmpty) return classes;
    return <String>[classify(fallbackPrimaryDefect).name];
  }

  @Deprecated('Use getCodeColor() instead')
  static Color getSeverityColor(String severity) => potholeColor;

  @Deprecated('Use classifyByCode() instead')
  static String getDefaultCodeForSeverity(String? severity) => 'CODE 01';
}
