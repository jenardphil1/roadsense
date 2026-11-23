import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:latlong2/latlong.dart';

import 'approval_priority.dart';
import 'barangay_forecast_panel.dart' show barangayKey;
import 'dpwh_standards.dart';

/// Workflow statuses supported by Firestore rules for road-defect reports.
enum AdminReportStatus {
  pending('pending', 'Pending review'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Rejected'),
  deleted('deleted', 'Trash / Archived');

  final String wireValue;
  final String label;
  const AdminReportStatus(this.wireValue, this.label);

  static AdminReportStatus fromRaw(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'approved':
        return AdminReportStatus.approved;
      case 'rejected':
        return AdminReportStatus.rejected;
      case 'deleted':
        return AdminReportStatus.deleted;
      case 'pending':
      default:
        return AdminReportStatus.pending;
    }
  }
}

/// Physical damage-magnitude severity stored on a report, explicitly separating
/// missing/unknown values from assessed severity levels.
enum AdminSeverity {
  high('high', 'High', 3),
  medium('medium', 'Medium', 2),
  low('low', 'Low', 1),
  notAssessed('not_assessed', 'Not assessed', 0);

  final String wireValue;
  final String label;
  final int rankDesc;

  const AdminSeverity(this.wireValue, this.label, this.rankDesc);

  static AdminSeverity fromRaw(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'high':
        return AdminSeverity.high;
      case 'medium':
        return AdminSeverity.medium;
      case 'low':
        return AdminSeverity.low;
      default:
        return AdminSeverity.notAssessed;
    }
  }
}

enum AdminReportSort {
  priority('Approval priority (Pending urgency)'),
  newest('Newest first'),
  oldest('Oldest first'),
  severityDesc('Severity: High to Low'),
  severityAsc('Severity: Low to High'),
  confidenceDesc('AI confidence: High to Low'),
  proximity('Closest to my location');

  final String label;
  const AdminReportSort(this.label);
}

enum AdminDatePreset {
  all('All dates'),
  last7d('Last 7 days'),
  last30d('Last 30 days'),
  last90d('Last 90 days');

  final String label;
  const AdminDatePreset(this.label);
}

/// Filter & sort state for the Admin Review Queue & synchronized map overlays.
class AdminReportFilter {
  /// Empty set means all non-deleted active reports (pending + approved + rejected).
  final Set<AdminReportStatus> statuses;
  final Set<AdminSeverity> severities;

  /// Defect class names matching [DpwhDefectClass.name], plus `'legacy'` for unclassified.
  final Set<String> defectClasses;
  final String? barangayFilterKey;
  final String? barangayDisplayLabel;
  final String searchQuery;
  final AdminDatePreset datePreset;
  final bool onlySlaBreached;
  final AdminReportSort sort;

  const AdminReportFilter({
    this.statuses = const {AdminReportStatus.pending},
    this.severities = const {},
    this.defectClasses = const {},
    this.barangayFilterKey,
    this.barangayDisplayLabel,
    this.searchQuery = '',
    this.datePreset = AdminDatePreset.all,
    this.onlySlaBreached = false,
    this.sort = AdminReportSort.priority,
  });

  int get activeFacetCount {
    int count = 0;
    count += severities.length;
    count += defectClasses.length;
    if (barangayFilterKey != null && barangayFilterKey!.isNotEmpty) count++;
    if (datePreset != AdminDatePreset.all) count++;
    if (onlySlaBreached) count++;
    if (searchQuery.trim().isNotEmpty) count++;
    return count;
  }

  bool get hasActiveFilters => activeFacetCount > 0;

  AdminReportFilter copyWith({
    Set<AdminReportStatus>? statuses,
    Set<AdminSeverity>? severities,
    Set<String>? defectClasses,
    String? barangayFilterKey,
    String? barangayDisplayLabel,
    bool clearBarangay = false,
    String? searchQuery,
    AdminDatePreset? datePreset,
    bool? onlySlaBreached,
    AdminReportSort? sort,
  }) {
    return AdminReportFilter(
      statuses: statuses ?? this.statuses,
      severities: severities ?? this.severities,
      defectClasses: defectClasses ?? this.defectClasses,
      barangayFilterKey: clearBarangay
          ? null
          : (barangayFilterKey ?? this.barangayFilterKey),
      barangayDisplayLabel: clearBarangay
          ? null
          : (barangayDisplayLabel ?? this.barangayDisplayLabel),
      searchQuery: searchQuery ?? this.searchQuery,
      datePreset: datePreset ?? this.datePreset,
      onlySlaBreached: onlySlaBreached ?? this.onlySlaBreached,
      sort: sort ?? this.sort,
    );
  }

  AdminReportFilter clearRefinements() {
    return AdminReportFilter(statuses: statuses, sort: sort);
  }
}

/// Normalized, test-friendly admin projection of a Firestore `potholes/{id}` document.
/// Keeps reported status, physical severity, AI confidence, DPWH statutory SLA,
/// and Approval Priority strictly separated.
class AdminReportRow {
  final String id;
  final String shortId;
  final LatLng? location;
  final String imageUrl;
  final DateTime? timestamp;
  final AdminReportStatus status;
  final AdminSeverity severity;
  final int potholeCount;
  final DpwhDefectClass? defectClass;
  final String defectLabel;
  final String dpwhCode;
  final String responseTime;
  final String correctiveMeasure;

  /// Maximum AI detection confidence in `[0.0, 1.0]`, or `null` if no detections were stored.
  final double? maxConfidence;
  final List<Map<String, dynamic>> detections;
  final String reporterUid;
  final String reporterName;
  final String reporterEmail;
  final String reporterPhotoUrl;
  final String address;
  final String barangay;
  final String city;
  final String province;
  final String formattedAddress;
  final String note;
  final String rejectionReason;
  final DateTime? moderatedAt;
  final String moderatedBy;
  final String previousStatus;
  final DateTime? deletedAt;
  final String deletedBy;
  final bool autoApproved;
  final Map<String, dynamic> rawData;

  const AdminReportRow({
    required this.id,
    required this.shortId,
    required this.location,
    required this.imageUrl,
    required this.timestamp,
    required this.status,
    required this.severity,
    required this.potholeCount,
    required this.defectClass,
    required this.defectLabel,
    required this.dpwhCode,
    required this.responseTime,
    required this.correctiveMeasure,
    required this.maxConfidence,
    required this.detections,
    required this.reporterUid,
    required this.reporterName,
    required this.reporterEmail,
    required this.reporterPhotoUrl,
    required this.address,
    required this.barangay,
    required this.city,
    required this.province,
    required this.formattedAddress,
    required this.note,
    required this.rejectionReason,
    required this.moderatedAt,
    required this.moderatedBy,
    required this.previousStatus,
    required this.deletedAt,
    required this.deletedBy,
    required this.autoApproved,
    required this.rawData,
  });

  bool get hasValidCoordinates =>
      location != null &&
      location!.latitude.isFinite &&
      location!.longitude.isFinite &&
      location!.latitude >= -90 &&
      location!.latitude <= 90 &&
      location!.longitude >= -180 &&
      location!.longitude <= 180;

  bool get hasPhoto =>
      imageUrl.startsWith('https://') || imageUrl.startsWith('http://');

  String get canonicalBarangayKey => barangayKey(barangay);

  String get displayLocation {
    final parts = <String>[
      if (barangay.isNotEmpty && barangay != 'Unassigned Barangay') barangay,
      if (city.isNotEmpty) city,
    ];
    if (parts.isNotEmpty) return parts.join(', ');
    if (formattedAddress.isNotEmpty) return formattedAddress;
    if (address.isNotEmpty) return address;
    if (hasValidCoordinates) {
      return '${location!.latitude.toStringAsFixed(5)}, ${location!.longitude.toStringAsFixed(5)}';
    }
    return 'Coordinates unavailable';
  }

  static DateTime? parseTimestamp(dynamic raw) {
    if (raw == null) return null;
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw.trim());
    }
    return null;
  }

  static double? extractMaxConfidence(List<Map<String, dynamic>> detections) {
    double? best;
    for (final det in detections) {
      final rawConf = det['confidence'];
      if (rawConf is num) {
        final v = rawConf.toDouble();
        if (v.isFinite) {
          final normalized = v > 1.0
              ? (v / 100.0).clamp(0.0, 1.0)
              : v.clamp(0.0, 1.0);
          if (best == null || normalized > best) {
            best = normalized;
          }
        }
      }
    }
    return best;
  }

  factory AdminReportRow.fromMap(String id, Map<String, dynamic> data) {
    final lat = (data['latitude'] as num?)?.toDouble();
    final lng = (data['longitude'] as num?)?.toDouble();
    final hasCoords =
        lat != null &&
        lng != null &&
        lat.isFinite &&
        lng.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lng >= -180 &&
        lng <= 180;
    final cls = DpwhStandards.classForReport(data);
    final rawCode = (data['primaryDpwhCode'] as String? ?? '').trim();
    final resolvedCode = rawCode.isNotEmpty
        ? rawCode
        : (cls?.code ?? 'UNCLASSIFIED');
    final fallbackInfo = rawCode.isNotEmpty
        ? DpwhStandards.getByCode(rawCode)
        : null;
    final detections =
        (data['detections'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];

    final image =
        ((data['imageUrl'] as String?) ?? (data['photoUrl'] as String?) ?? '')
            .trim();

    return AdminReportRow(
      id: id,
      shortId: id.length > 6
          ? id.substring(0, 6).toUpperCase()
          : id.toUpperCase(),
      location: hasCoords ? LatLng(lat, lng) : null,
      imageUrl: image,
      timestamp: parseTimestamp(data['timestamp']),
      status: AdminReportStatus.fromRaw(data['status'] as String?),
      severity: AdminSeverity.fromRaw(data['overallSeverity'] as String?),
      potholeCount: ((data['potholeCount'] as num?)?.toInt() ?? 1).clamp(
        1,
        999,
      ),
      defectClass: cls,
      defectLabel: DpwhStandards.reportDefectName(data),
      dpwhCode: resolvedCode,
      responseTime: (data['responseTime'] as String?)?.trim().isNotEmpty == true
          ? (data['responseTime'] as String).trim()
          : (cls?.responseTime ??
                fallbackInfo?.responseTime ??
                'Not specified'),
      correctiveMeasure:
          (data['correctiveMeasure'] as String?)?.trim().isNotEmpty == true
          ? (data['correctiveMeasure'] as String).trim()
          : (cls?.correctiveMeasure ??
                fallbackInfo?.correctiveMeasure ??
                'Assess on inspection'),
      maxConfidence: extractMaxConfidence(detections),
      detections: detections,
      reporterUid: (data['reporterUid'] as String? ?? '').trim(),
      reporterName: (data['reporterName'] as String? ?? '').trim().isNotEmpty
          ? (data['reporterName'] as String).trim()
          : 'Surveyor',
      reporterEmail: (data['reporterEmail'] as String? ?? '').trim(),
      reporterPhotoUrl: (data['reporterPhotoUrl'] as String? ?? '').trim(),
      address: (data['address'] as String? ?? '').trim(),
      barangay: (data['barangay'] as String? ?? '').trim(),
      city: (data['city'] as String? ?? '').trim(),
      province: (data['province'] as String? ?? '').trim(),
      formattedAddress: (data['formattedAddress'] as String? ?? '').trim(),
      note: (data['note'] as String? ?? '').trim(),
      rejectionReason: (data['rejectionReason'] as String? ?? '').trim(),
      moderatedAt: parseTimestamp(data['moderatedAt']),
      moderatedBy: (data['moderatedBy'] as String? ?? '').trim(),
      previousStatus: (data['previousStatus'] as String? ?? 'pending').trim(),
      deletedAt: parseTimestamp(data['deletedAt']),
      deletedBy: (data['deletedBy'] as String? ?? '').trim(),
      autoApproved: data['autoApproved'] == true,
      rawData: data,
    );
  }
}

/// Filters and deterministically sorts normalized admin report rows.
List<AdminReportRow> filterAndSortAdminRows(
  List<AdminReportRow> rows, {
  required AdminReportFilter filter,
  Map<String, ReportPriority> priorities = const {},
  LatLng? adminPosition,
  DateTime? now,
}) {
  final clockNow = now ?? DateTime.now();
  final q = filter.searchQuery.trim().toLowerCase().replaceAll(
    RegExp(r'\s+'),
    ' ',
  );

  final DateTime? cutoff = switch (filter.datePreset) {
    AdminDatePreset.all => null,
    AdminDatePreset.last7d => clockNow.subtract(const Duration(days: 7)),
    AdminDatePreset.last30d => clockNow.subtract(const Duration(days: 30)),
    AdminDatePreset.last90d => clockNow.subtract(const Duration(days: 90)),
  };

  final filtered = rows.where((row) {
    if (row.status == AdminReportStatus.deleted) return false;
    if (filter.statuses.isNotEmpty && !filter.statuses.contains(row.status)) {
      return false;
    }
    if (filter.severities.isNotEmpty &&
        !filter.severities.contains(row.severity)) {
      return false;
    }
    if (filter.defectClasses.isNotEmpty) {
      final cls = row.defectClass;
      final isSupported = cls != null && DpwhStandards.allClasses.contains(cls);
      final matchesLegacy =
          filter.defectClasses.contains('legacy') && !isSupported;
      final matchesClass =
          cls != null && filter.defectClasses.contains(cls.name);
      if (!matchesLegacy && !matchesClass) return false;
    }
    if (filter.barangayFilterKey != null &&
        filter.barangayFilterKey!.isNotEmpty) {
      if (row.canonicalBarangayKey != filter.barangayFilterKey) {
        return false;
      }
    }
    if (cutoff != null) {
      if (row.timestamp == null || row.timestamp!.isBefore(cutoff)) {
        return false;
      }
    }
    if (filter.onlySlaBreached) {
      final p = priorities[row.id];
      if (p == null || !p.isSlaBreached) return false;
    }
    if (q.isNotEmpty) {
      final haystack = <String>[
        row.id,
        row.shortId,
        row.reporterName,
        row.reporterEmail,
        row.address,
        row.formattedAddress,
        row.barangay,
        row.city,
        row.province,
        row.dpwhCode,
        row.defectLabel,
        row.status.label,
        row.severity.label,
        row.note,
        if (row.location != null)
          '${row.location!.latitude.toStringAsFixed(5)}, ${row.location!.longitude.toStringAsFixed(5)}',
      ].join(' ').toLowerCase();
      if (!haystack.contains(q)) return false;
    }
    return true;
  }).toList();

  filtered.sort((a, b) {
    final cmp = _compareAdminRows(
      a,
      b,
      filter.sort,
      priorities: priorities,
      adminPosition: adminPosition,
    );
    if (cmp != 0) return cmp;
    return a.id.compareTo(b.id);
  });

  return filtered;
}

int _compareAdminRows(
  AdminReportRow a,
  AdminReportRow b,
  AdminReportSort sort, {
  required Map<String, ReportPriority> priorities,
  LatLng? adminPosition,
}) {
  final aTime = a.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0);
  final bTime = b.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0);

  switch (sort) {
    case AdminReportSort.priority:
      final aScore = priorities[a.id]?.score ?? 0.0;
      final bScore = priorities[b.id]?.score ?? 0.0;
      final cmp = bScore.compareTo(aScore);
      return cmp != 0 ? cmp : aTime.compareTo(bTime);

    case AdminReportSort.newest:
      return bTime.compareTo(aTime);

    case AdminReportSort.oldest:
      return aTime.compareTo(bTime);

    case AdminReportSort.severityDesc:
      // Always place unassessed items after assessed Low so missing data is never promoted.
      final cmp = b.severity.rankDesc.compareTo(a.severity.rankDesc);
      return cmp != 0 ? cmp : bTime.compareTo(aTime);

    case AdminReportSort.severityAsc:
      // Low (1) < Medium (2) < High (3); Not assessed (0) always stays at the end (rank 99).
      final aRank = a.severity == AdminSeverity.notAssessed
          ? 99
          : a.severity.rankDesc;
      final bRank = b.severity == AdminSeverity.notAssessed
          ? 99
          : b.severity.rankDesc;
      final cmp = aRank.compareTo(bRank);
      return cmp != 0 ? cmp : bTime.compareTo(aTime);

    case AdminReportSort.confidenceDesc:
      // Null/unavailable confidence always sorts after valid scores.
      final aConf = a.maxConfidence ?? -1.0;
      final bConf = b.maxConfidence ?? -1.0;
      final cmp = bConf.compareTo(aConf);
      return cmp != 0 ? cmp : bTime.compareTo(aTime);

    case AdminReportSort.proximity:
      if (adminPosition != null) {
        final aDist = a.hasValidCoordinates
            ? _haversineMeters(adminPosition, a.location!)
            : double.infinity;
        final bDist = b.hasValidCoordinates
            ? _haversineMeters(adminPosition, b.location!)
            : double.infinity;
        final cmp = aDist.compareTo(bDist);
        return cmp != 0 ? cmp : bTime.compareTo(aTime);
      }
      return bTime.compareTo(aTime);
  }
}

double _haversineMeters(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = (b.latitude - a.latitude) * math.pi / 180.0;
  final dLng = (b.longitude - a.longitude) * math.pi / 180.0;
  final la1 = a.latitude * math.pi / 180.0;
  final la2 = b.latitude * math.pi / 180.0;
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(h), math.sqrt(math.max(0.0, 1.0 - h)));
}

class AdminPageSlice<T> {
  final List<T> items;
  final int pageIndex;
  final int pageSize;
  final int totalItems;
  final int totalPages;

  const AdminPageSlice({
    required this.items,
    required this.pageIndex,
    required this.pageSize,
    required this.totalItems,
    required this.totalPages,
  });

  int get startOrdinal => totalItems == 0 ? 0 : (pageIndex * pageSize) + 1;
  int get endOrdinal => math.min((pageIndex + 1) * pageSize, totalItems);
}

AdminPageSlice<T> paginateAdminItems<T>(
  List<T> items, {
  required int requestedPage,
  required int pageSize,
}) {
  final safeSize = pageSize < 1 ? 25 : pageSize;
  final total = items.length;
  final totalPages = math.max(1, (total / safeSize).ceil());
  final clampedPage = requestedPage.clamp(0, totalPages - 1);
  final start = clampedPage * safeSize;
  final end = math.min(start + safeSize, total);
  return AdminPageSlice<T>(
    items: start < total ? items.sublist(start, end) : <T>[],
    pageIndex: clampedPage,
    pageSize: safeSize,
    totalItems: total,
    totalPages: totalPages,
  );
}

/// Spreadsheet formula-injection safe CSV serializer and scoped report exporter.
class AdminCsvExporter {
  AdminCsvExporter._();

  static final RegExp _formulaLead = RegExp(r'^[\t\r\n ]*[=+\-@]');

  /// Neutralizes spreadsheet formula triggers (`=`, `+`, `-`, `@`, tab, CR) in
  /// string values while preserving numeric scalars such as negative GPS coords.
  static String formatCell(Object? value) {
    if (value == null) return '""';
    if (value is num) {
      if (!value.isFinite) return '""';
      return '"$value"';
    }
    if (value is bool) return '"$value"';

    var text = value.toString();
    if (_formulaLead.hasMatch(text)) {
      text = "'$text";
    } else if (text.isNotEmpty &&
        (text.startsWith('\t') || text.startsWith('\r'))) {
      text = "'$text";
    }
    final escaped = text.replaceAll('"', '""');
    return '"$escaped"';
  }

  static String encodeRows(List<List<Object?>> rows) {
    return rows.map((row) => row.map(formatCell).join(',')).join('\r\n');
  }

  static String buildReportsCsv(
    List<AdminReportRow> rows, {
    required bool includeReporterEmail,
    Map<String, ReportPriority> priorities = const {},
  }) {
    final data = <List<Object?>>[
      [
        'Report ID',
        'Status',
        'Defect Category',
        'Defect Code',
        'Max AI Confidence (%)',
        'Approval Priority Score',
        'Approval Priority Band',
        'Priority Flag',
        'Review Priority',
        'Corrective Measure',
        'Defect Count',
        'Barangay',
        'City / Municipality',
        'Province',
        'Address / Location',
        'Latitude',
        'Longitude',
        'Submitted Timestamp (ISO)',
        'Reporter Name',
        if (includeReporterEmail) 'Reporter Email',
        'Moderator Note / Rejection Reason',
      ],
    ];

    for (final r in rows) {
      final p = priorities[r.id];
      data.add([
        r.id,
        r.status.label,
        r.defectLabel,
        r.dpwhCode,
        r.maxConfidence != null
            ? (r.maxConfidence! * 100).toStringAsFixed(1)
            : 'Unavailable',
        p != null ? p.score.toStringAsFixed(1) : '',
        p?.bandLabel ?? '',
        p?.isSlaBreached ?? false,
        r.responseTime,
        r.correctiveMeasure,
        r.potholeCount,
        r.barangay,
        r.city,
        r.province,
        r.address.isNotEmpty ? r.address : r.formattedAddress,
        r.location?.latitude ?? '',
        r.location?.longitude ?? '',
        r.timestamp?.toUtc().toIso8601String() ?? '',
        r.reporterName,
        if (includeReporterEmail) r.reporterEmail,
        r.rejectionReason,
      ]);
    }

    return encodeRows(data);
  }
}
