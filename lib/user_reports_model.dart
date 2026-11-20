import 'package:cloud_firestore/cloud_firestore.dart';
import 'dpwh_standards.dart';
import 'pending_report_queue.dart';

/// Minimal cloud report representation decoupleable from Firestore snapshots in tests.
class CloudReportRecord {
  final String id;
  final Map<String, dynamic> data;

  const CloudReportRecord({required this.id, required this.data});

  factory CloudReportRecord.fromSnapshot(QueryDocumentSnapshot doc) {
    final raw = doc.data();
    return CloudReportRecord(
      id: doc.id,
      data: raw is Map<String, dynamic>
          ? raw
          : Map<String, dynamic>.from(raw as Map),
    );
  }
}

/// Unified entry in My Reports representing either a local queued report or a
/// synced cloud report (deduplicated by stable report ID).
class UserReportListItem {
  final String id;
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final PendingReportRecord? localRecord;

  const UserReportListItem({
    required this.id,
    required this.data,
    required this.createdAt,
    this.localRecord,
  });

  bool get isLocal => localRecord != null;
  bool get isCloud => localRecord == null;

  String get status => isLocal
      ? localRecord!.syncState.name
      : ((data['status'] as String?) ?? 'pending').toLowerCase();
}

/// Summary and partitioned lists for My Reports.
class MergedUserReports {
  final List<UserReportListItem> activeItems;
  final List<UserReportListItem> trashedItems;
  final int approvedCount;
  final int pendingReviewCount;
  final int localQueuedCount;
  final int localFailedCount;
  final int localUploadingCount;

  const MergedUserReports({
    required this.activeItems,
    required this.trashedItems,
    required this.approvedCount,
    required this.pendingReviewCount,
    required this.localQueuedCount,
    required this.localFailedCount,
    required this.localUploadingCount,
  });

  int get totalActiveCount => activeItems.length;
}

DateTime parseReportTimestamp(dynamic rawTimestamp, {int? fallbackMs}) {
  if (rawTimestamp is Timestamp) {
    return rawTimestamp.toDate();
  }
  if (rawTimestamp is DateTime) {
    return rawTimestamp;
  }
  if (rawTimestamp is int) {
    return DateTime.fromMillisecondsSinceEpoch(rawTimestamp);
  }
  if (fallbackMs != null && fallbackMs > 0) {
    return DateTime.fromMillisecondsSinceEpoch(fallbackMs);
  }
  return DateTime.now();
}

/// Merges local outbox submissions and cloud Firestore documents by stable ID,
/// enforcing strict per-account isolation and separating local sync states from
/// server moderation states.
MergedUserReports mergeUserReports({
  required String uid,
  required List<PendingReportRecord> localRecords,
  required List<CloudReportRecord> cloudRecords,
}) {
  final activeCloud = <UserReportListItem>[];
  final trashedCloud = <UserReportListItem>[];
  final cloudIds = <String>{};

  var approvedCount = 0;
  var pendingReviewCount = 0;

  for (final doc in cloudRecords) {
    final reporterUid = (doc.data['reporterUid'] as String?)?.trim();
    if (reporterUid != null && reporterUid.isNotEmpty && reporterUid != uid) {
      continue;
    }
    cloudIds.add(doc.id);
    final status = (doc.data['status'] as String? ?? 'pending').toLowerCase();
    final item = UserReportListItem(
      id: doc.id,
      data: doc.data,
      createdAt: parseReportTimestamp(doc.data['timestamp']),
    );
    if (status == 'deleted') {
      trashedCloud.add(item);
    } else {
      activeCloud.add(item);
      if (status == 'approved') approvedCount++;
      if (status == 'pending') pendingReviewCount++;
    }
  }

  final localActive = <UserReportListItem>[];
  var localQueuedCount = 0;
  var localFailedCount = 0;
  var localUploadingCount = 0;

  for (final rec in localRecords) {
    if (rec.uid != uid) continue;
    // Cloud document with the same stable ID wins to prevent duplicates while
    // local outbox cleanup completes.
    if (cloudIds.contains(rec.id)) continue;

    localQueuedCount++;
    if (rec.syncState == PendingSyncState.failed) localFailedCount++;
    if (rec.syncState == PendingSyncState.uploading) localUploadingCount++;

    localActive.add(
      UserReportListItem(
        id: rec.id,
        data: {
          ...rec.report,
          'status': rec.syncState.name,
          if (rec.uploadedImageUrl != null) 'imageUrl': rec.uploadedImageUrl,
        },
        createdAt: rec.createdAt,
        localRecord: rec,
      ),
    );
  }

  final activeItems = [...localActive, ...activeCloud]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  trashedCloud.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  return MergedUserReports(
    activeItems: activeItems,
    trashedItems: trashedCloud,
    approvedCount: approvedCount,
    pendingReviewCount: pendingReviewCount,
    localQueuedCount: localQueuedCount,
    localFailedCount: localFailedCount,
    localUploadingCount: localUploadingCount,
  );
}

List<UserReportListItem> filterActiveUserReports(
  List<UserReportListItem> items, {
  required String statusFilter,
  String? defectFilter,
  required String query,
}) {
  final q = query.trim().toLowerCase();
  return items.where((item) {
    final data = item.data;
    final status = item.status;

    if (statusFilter == 'local') {
      if (!item.isLocal) return false;
    } else if (statusFilter != 'all') {
      if (item.isLocal || status != statusFilter) return false;
    }

    final defectName = DpwhStandards.reportDefectName(data);
    if (defectFilter != null && defectName != defectFilter) {
      return false;
    }

    if (q.isNotEmpty) {
      final haystack = [
        defectName,
        if (item.isLocal) item.localRecord!.syncState.label else status,
        item.localRecord?.errorMessage ?? '',
        data['formattedAddress'] ?? '',
        data['barangay'] ?? '',
        data['city'] ?? '',
        data['note'] ?? '',
      ].join(' ').toLowerCase();
      if (!haystack.contains(q)) return false;
    }
    return true;
  }).toList();
}
