import 'package:flutter/material.dart';

/// Represents one official DPWH Road Distress Classification from the
/// thesis research package and dataset.
class DpwhDefectClass {
  final int classId;
  final String name;
  final String rawLabel;
  final String code; // Standardized as 'CODE 01', 'CODE 02', etc.
  final String severity; // 'high', 'medium', 'low'
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
    required this.severity,
    required this.responseTime,
    required this.correctiveMeasure,
    required this.unit,
    required this.precision,
    required this.recall,
    required this.f1Score,
    required this.map50,
    required this.map50_95,
  });

  Color get color => DpwhStandards.getCodeColor(code);
  String get unitOfMeasurement => unit;
  String get severityLevel =>
      severity.isNotEmpty ? (severity[0].toUpperCase() + severity.substring(1)) : 'Medium';

  Map<String, dynamic> toMap() => {
    'classId': classId,
    'className': name,
    'rawLabel': rawLabel,
    'dpwhCode': code,
    'severity': severity,
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
/// derived directly from the YOLOv8s Thesis Results.
class DpwhStandards {
  DpwhStandards._();

  // Model Specs & Speed Benchmark from thesis_speed_benchmark.txt
  static const String modelName = 'YOLOv8s (DPWH Road Defect Detector)';
  static const String inputResolution = '640 x 640';
  static const double avgLatencyMs = 17.25;
  static const double latencyStdMs = 0.33;
  static const double throughputFps = 57.99;
  static const bool isRealtimeCapable = true;

  // Global Evaluation Metrics from thesis_test_metrics.csv
  static const double overallPrecision = 0.7652;
  static const double overallRecall = 0.6600;
  static const double overallF1Score = 0.7071;
  static const double overallMap50 = 0.7111;
  static const double overallMap50_95 = 0.4112;

  // The 5 Canonical DPWH Defect Classes
  static const DpwhDefectClass pothole = DpwhDefectClass(
    classId: 0,
    name: 'Pothole',
    rawLabel: 'Pothole (DPWH Code 01)',
    code: 'CODE 01',
    severity: 'high',
    responseTime: '3 Days',
    correctiveMeasure:
        'Bituminous premix (hot) or penetration patching; add base material if needed.',
    unit: 'sq.m.',
    precision: 0.9232,
    recall: 0.8151,
    f1Score: 0.8658,
    map50: 0.8763,
    map50_95: 0.5953,
  );

  static const DpwhDefectClass alligatorCrack = DpwhDefectClass(
    classId: 1,
    name: 'Alligator crack',
    rawLabel: 'Alligator crack (DPWH Code 02)',
    code: 'CODE 02',
    severity: 'high',
    responseTime: '3 Days',
    correctiveMeasure:
        'Bituminous premix (hot) or penetration patching of affected area.',
    unit: 'sq.m.',
    precision: 0.8442,
    recall: 0.7500,
    f1Score: 0.7943,
    map50: 0.7999,
    map50_95: 0.4930,
  );

  static const DpwhDefectClass depression = DpwhDefectClass(
    classId: 2,
    name: 'Depression',
    rawLabel: 'Depression (DPWH Code 05)',
    code: 'CODE 05',
    severity: 'medium',
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

  static const DpwhDefectClass longitudinalCrack = DpwhDefectClass(
    classId: 3,
    name: 'Longitudinal crack',
    rawLabel: 'Longitudinal crack (DPWH Code 12)',
    code: 'CODE 12',
    severity: 'low',
    responseTime: 'Routine maintenance / sealing',
    correctiveMeasure:
        'Crack sealing with hot or cold applied elastomeric sealant.',
    unit: 'l.m.',
    precision: 0.7094,
    recall: 0.5893,
    f1Score: 0.6438,
    map50: 0.6578,
    map50_95: 0.3340,
  );

  static const DpwhDefectClass transverseCrack = DpwhDefectClass(
    classId: 4,
    name: 'Transverse crack',
    rawLabel: 'Transverse crack (DPWH Code 12)',
    code: 'CODE 12',
    severity: 'low',
    responseTime: 'Routine maintenance / sealing',
    correctiveMeasure:
        'Crack sealing with hot or cold applied elastomeric sealant.',
    unit: 'l.m.',
    precision: 0.7991,
    recall: 0.7647,
    f1Score: 0.7815,
    map50: 0.7954,
    map50_95: 0.4777,
  );

  static const List<DpwhDefectClass> allClasses = [
    pothole,
    alligatorCrack,
    depression,
    longitudinalCrack,
    transverseCrack,
  ];

  /// Classifies any detection string (tag, raw label, name, code) to its canonical DPWH standard.
  static DpwhDefectClass classify(String? raw) {
    if (raw == null || raw.trim().isEmpty) return pothole;
    final lower = raw.trim().toLowerCase();

    // Check specific class keywords
    if (lower.contains('alligator') || lower.contains('crocodile')) {
      return alligatorCrack;
    }
    if (lower.contains('depression') || lower.contains('rut')) {
      return depression;
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
    if (lower.contains('code 05')) {
      return depression;
    }
    if (lower.contains('code 12')) {
      return lower.contains('transverse') ? transverseCrack : longitudinalCrack;
    }
    if (lower.contains('code 01') || lower.contains('pothole')) {
      return pothole;
    }

    // Default to pothole if unspecified
    return pothole;
  }

  /// Classifies by DPWH Code string ('CODE 01', 'CODE 02', 'CODE 05', 'CODE 12')
  static DpwhDefectClass classifyByCode(String? code) {
    if (code == null) return pothole;
    final normalized = code.trim().toUpperCase();
    if (normalized.contains('02')) return alligatorCrack;
    if (normalized.contains('05')) return depression;
    if (normalized.contains('12')) return longitudinalCrack;
    return pothole;
  }

  /// Evaluates detection severity ('high', 'medium', 'low') using class SLA and box dimensions
  static String evaluateSeverity(Map<String, dynamic> det) {
    final String tag = (det['tag'] as String? ?? '').trim();
    final cls = classify(tag);

    // If bounding box is large or confidence is extremely high, upgrade severity
    if (det.containsKey('box')) {
      final box = det['box'] as List<dynamic>?;
      if (box != null && box.length >= 4) {
        final left = (box[0] as num).toDouble();
        final top = (box[1] as num).toDouble();
        final right = (box[2] as num).toDouble();
        final bottom = (box[3] as num).toDouble();
        final double area = (right - left).abs() * (bottom - top).abs();
        final double conf = box.length > 4 ? (box[4] as num).toDouble() : 0.5;

        // Severe hazard override
        if (cls.code == 'CODE 01' || cls.code == 'CODE 02') {
          return 'high';
        }
        if (area > 50000 || conf >= 0.85) {
          return cls.severity == 'low' ? 'medium' : 'high';
        }
      }
    }
    return cls.severity;
  }

  /// Color palette for severity levels
  static Color getSeverityColor(String severity) {
    switch (severity.toLowerCase().trim()) {
      case 'high':
        return const Color(0xFFEF4444); // Red
      case 'medium':
        return const Color(0xFFF97316); // Orange
      case 'low':
      default:
        return const Color(0xFFEAB308); // Amber/Yellow
    }
  }

  /// Distinct official color palette for DPWH Code Badges
  static Color getCodeColor(String code) {
    final c = code.trim().toUpperCase();
    if (c.contains('01')) return const Color(0xFFEF4444); // Red - Urgent Pothole
    if (c.contains('02')) return const Color(0xFFEA580C); // Dark Orange - Alligator
    if (c.contains('05')) return const Color(0xFFF59E0B); // Amber - Depression
    if (c.contains('12')) return const Color(0xFF2563EB); // Blue - Cracks Sealant
    return const Color(0xFF6366F1); // Indigo default
  }

  /// DPWH Code short title
  static String getCodeTitle(String code) {
    final c = code.trim().toUpperCase();
    if (c.contains('01')) return 'Pothole (Urgent 3-Day)';
    if (c.contains('02')) return 'Alligator Crack (High 3-Day)';
    if (c.contains('05')) return 'Depression (30-Day)';
    if (c.contains('12')) return 'Crack (Routine Sealant)';
    return 'Road Surface Hazard';
  }

  /// List of all 5 DPWH defect classes
  static List<DpwhDefectClass> get standards => allClasses;

  /// Looks up DPWH specification by code ('CODE 01', 'CODE 02', 'CODE 05', 'CODE 12')
  static DpwhDefectClass? getByCode(String? code) {
    if (code == null) return null;
    return classifyByCode(code);
  }

  /// Classifies by defect name
  static DpwhDefectClass classifyByName(String? name) => classify(name);

  /// Gets the standard DPWH code for a severity level
  static String getDefaultCodeForSeverity(String? severity) {
    switch (severity?.toLowerCase().trim()) {
      case 'high':
        return 'CODE 01';
      case 'medium':
        return 'CODE 05';
      case 'low':
        return 'CODE 12';
      default:
        return 'CODE 01';
    }
  }

  /// Gets the DPWH code corresponding to a detection tag/label
  static String getCodeForLabel(String? label) => classify(label).code;

  /// Returns the badge color for a given DPWH code
  static Color getColorForCode(String? code) => getCodeColor(code ?? '');
}
