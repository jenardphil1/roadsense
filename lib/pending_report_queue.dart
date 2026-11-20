import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:uuid/uuid.dart';
import 'upload_error.dart';

/// Lifecycle states for a report waiting in the on-device outbox.
enum PendingSyncState {
  waiting,
  uploading,
  failed;

  static PendingSyncState parse(String? raw) {
    switch (raw) {
      case 'failed':
        return PendingSyncState.failed;
      // On cold restart, any non-failed item resumes as waiting rather than
      // staying stuck in an in-flight state.
      case 'waiting':
      case 'uploading':
      default:
        return PendingSyncState.waiting;
    }
  }

  String get label {
    switch (this) {
      case PendingSyncState.waiting:
        return 'Waiting to upload';
      case PendingSyncState.uploading:
        return 'Uploading';
      case PendingSyncState.failed:
        return 'Upload failed';
    }
  }
}

/// Typed snapshot of an on-device queued submission.
class PendingReportRecord {
  final String id;
  final String uid;
  final String imagePath;
  final Map<String, dynamic> report;
  final PendingSyncState syncState;
  final ReportUploadErrorCategory? errorCategory;
  final String? errorMessage;
  final int retryCount;
  final int createdAtMs;
  final int updatedAtMs;
  final String? uploadedImageUrl;

  const PendingReportRecord({
    required this.id,
    required this.uid,
    required this.imagePath,
    required this.report,
    required this.syncState,
    this.errorCategory,
    this.errorMessage,
    this.retryCount = 0,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.uploadedImageUrl,
  });

  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdAtMs);
  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch(updatedAtMs);

  bool get hasLocalImage =>
      imagePath.isNotEmpty && File(imagePath).existsSync();
}

/// Durable, per-account outbox. A failed upload remains available after restart
/// and surfaces live sync status/error metadata for My Reports.
class PendingReportQueue {
  final Directory directory;
  final ValueNotifier<int> changes = ValueNotifier<int>(0);
  final Set<String> _activeUploadIds = <String>{};
  bool _flushing = false;

  PendingReportQueue(this.directory);

  bool get isFlushing => _flushing;
  bool isUploading(String id) => _activeUploadIds.contains(id);

  void _notifyChanged() {
    changes.value = changes.value + 1;
  }

  String _resolveImagePath(String id, String storedPath) {
    if (storedPath.isNotEmpty && File(storedPath).existsSync()) {
      return storedPath;
    }
    final localFallback = '${directory.path}/$id.image';
    if (File(localFallback).existsSync()) {
      return localFallback;
    }
    return storedPath.isNotEmpty ? storedPath : localFallback;
  }

  PendingReportRecord? _parseFileSync(File file, Map<String, dynamic> raw) {
    final id = (raw['id'] as String?)?.trim() ?? '';
    final uid = (raw['uid'] as String?)?.trim() ?? '';
    final rawReport = raw['report'];
    if (id.isEmpty || uid.isEmpty || rawReport is! Map) {
      return null;
    }

    final report = Map<String, dynamic>.from(rawReport);
    final storedImagePath = (raw['imagePath'] as String?) ?? '';
    final imagePath = _resolveImagePath(id, storedImagePath);

    int fallbackCreatedMs;
    try {
      fallbackCreatedMs = file.lastModifiedSync().millisecondsSinceEpoch;
    } catch (_) {
      fallbackCreatedMs = DateTime.now().millisecondsSinceEpoch;
    }

    final createdAtMs =
        (raw['createdAtMs'] as num?)?.toInt() ?? fallbackCreatedMs;
    final updatedAtMs = (raw['updatedAtMs'] as num?)?.toInt() ?? createdAtMs;
    final diskState = PendingSyncState.parse(raw['syncState'] as String?);
    final effectiveState = _activeUploadIds.contains(id)
        ? PendingSyncState.uploading
        : diskState;

    final category = ReportUploadErrorCategory.tryParse(
      raw['errorCategory'] as String?,
    );
    final rawErrMsg = raw['errorMessage'] as String?;
    final errorMessage = rawErrMsg == null || rawErrMsg.trim().isEmpty
        ? null
        : sanitizeUploadErrorMessage(rawErrMsg);

    final rawUploadedUrl = (raw['uploadedImageUrl'] as String?)?.trim();
    final uploadedUri = rawUploadedUrl != null && rawUploadedUrl.isNotEmpty
        ? Uri.tryParse(rawUploadedUrl)
        : null;
    final safeUploadedUrl =
        uploadedUri != null &&
            uploadedUri.scheme == 'https' &&
            !uploadedUri.hasQuery
        ? rawUploadedUrl
        : null;

    return PendingReportRecord(
      id: id,
      uid: uid,
      imagePath: imagePath,
      report: report,
      syncState: effectiveState,
      errorCategory: category,
      errorMessage: errorMessage,
      retryCount: (raw['retryCount'] as num?)?.toInt() ?? 0,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
      uploadedImageUrl: safeUploadedUrl,
    );
  }

  void _writeAtomicJsonSync(File target, Map<String, dynamic> payload) {
    directory.createSync(recursive: true);
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(jsonEncode(payload), flush: true);
    temp.renameSync(target.path);
  }

  Future<String> enqueue(
    String uid,
    String imagePath,
    Map<String, dynamic> report,
  ) async {
    directory.createSync(recursive: true);
    final id = const Uuid().v4();
    final image = File(imagePath).copySync('${directory.path}/$id.image');
    final file = File('${directory.path}/$id.json');
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _writeAtomicJsonSync(file, {
      'id': id,
      'uid': uid,
      'imagePath': image.path,
      'report': report,
      'syncState': PendingSyncState.waiting.name,
      'retryCount': 0,
      'createdAtMs': nowMs,
      'updatedAtMs': nowMs,
    });
    _notifyChanged();
    return id;
  }

  Future<bool> contains(String id) async =>
      File('${directory.path}/$id.json').existsSync();

  PendingReportRecord? getByIdSync(String id, {String? expectedUid}) {
    final file = File('${directory.path}/$id.json');
    if (!file.existsSync()) return null;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return null;
      final parsed = _parseFileSync(file, Map<String, dynamic>.from(raw));
      if (parsed == null) return null;
      if (expectedUid != null && parsed.uid != expectedUid) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  Future<PendingReportRecord?> getById(
    String id, {
    String? expectedUid,
  }) async => getByIdSync(id, expectedUid: expectedUid);

  List<PendingReportRecord> listForUserSync(
    String uid, {
    bool sortNewestFirst = true,
  }) {
    if (uid.trim().isEmpty || !directory.existsSync()) {
      return const [];
    }
    final records = <PendingReportRecord>[];
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = jsonDecode(entity.readAsStringSync());
        if (raw is! Map) continue;
        final parsed = _parseFileSync(entity, Map<String, dynamic>.from(raw));
        if (parsed == null || parsed.uid != uid) continue;
        records.add(parsed);
      } catch (_) {
        // Ignore unreadable metadata without discarding queued files.
      }
    }
    records.sort((a, b) {
      final cmp = sortNewestFirst
          ? b.createdAtMs.compareTo(a.createdAtMs)
          : a.createdAtMs.compareTo(b.createdAtMs);
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });
    return records;
  }

  Future<List<PendingReportRecord>> listForUser(
    String uid, {
    bool sortNewestFirst = true,
  }) async => listForUserSync(uid, sortNewestFirst: sortNewestFirst);

  /// Persists the unsigned public blob URL once image upload succeeds so a later
  /// Firestore failure can retry creation without re-uploading the same bytes.
  Future<void> markUploadedImageUrl(String id, String imageUrl) async {
    final uri = Uri.tryParse(imageUrl.trim());
    if (uri == null || uri.scheme != 'https' || uri.hasQuery) {
      return;
    }
    final file = File('${directory.path}/$id.json');
    if (!file.existsSync()) return;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return;
      final updated = Map<String, dynamic>.from(raw);
      updated['uploadedImageUrl'] = imageUrl.trim();
      updated['updatedAtMs'] = DateTime.now().millisecondsSinceEpoch;
      _writeAtomicJsonSync(file, updated);
      _notifyChanged();
    } catch (_) {}
  }

  Future<int> flush(
    String uid,
    Future<void> Function(Map<String, dynamic>) send, {
    String? targetId,
  }) async {
    if (_flushing) return 0;
    if (uid.trim().isEmpty) return 0;
    _flushing = true;
    var sent = 0;
    try {
      if (!directory.existsSync()) return 0;
      final entities = <File>[];
      for (final entity in directory.listSync()) {
        if (entity is File && entity.path.endsWith('.json')) {
          entities.add(entity);
        }
      }

      for (final entity in entities) {
        Map<String, dynamic> rawItem;
        try {
          final decoded = jsonDecode(entity.readAsStringSync());
          if (decoded is! Map) continue;
          rawItem = Map<String, dynamic>.from(decoded);
        } catch (_) {
          continue;
        }

        final itemUid = (rawItem['uid'] as String?)?.trim() ?? '';
        final id = (rawItem['id'] as String?)?.trim() ?? '';
        if (itemUid != uid || id.isEmpty) continue;
        if (targetId != null && id != targetId) continue;

        final parsedBefore = _parseFileSync(entity, rawItem);
        if (parsedBefore == null) continue;

        final sendPayload = <String, dynamic>{
          ...rawItem,
          'id': id,
          'uid': uid,
          'imagePath': parsedBefore.imagePath,
          'report': Map<String, dynamic>.from(parsedBefore.report),
          if (parsedBefore.uploadedImageUrl != null)
            'uploadedImageUrl': parsedBefore.uploadedImageUrl,
        };

        _activeUploadIds.add(id);
        _notifyChanged();
        try {
          await send(sendPayload);
          // Server acknowledged report creation before removing local files.
          _activeUploadIds.remove(id);
          if (entity.existsSync()) {
            entity.deleteSync();
          }
          final storedImage = File(parsedBefore.imagePath);
          if (storedImage.existsSync()) {
            storedImage.deleteSync();
          }
          final localImage = File('${directory.path}/$id.image');
          if (localImage.path != storedImage.path && localImage.existsSync()) {
            localImage.deleteSync();
          }
          sent++;
          _notifyChanged();
        } catch (err) {
          _activeUploadIds.remove(id);
          final classified = classifyUploadError(err);
          Map<String, dynamic> latest = rawItem;
          try {
            if (entity.existsSync()) {
              final reread = jsonDecode(entity.readAsStringSync());
              if (reread is Map) {
                latest = Map<String, dynamic>.from(reread);
              }
            }
          } catch (_) {}
          latest['syncState'] = PendingSyncState.failed.name;
          latest['errorCategory'] = classified.category.name;
          latest['errorMessage'] = classified.message;
          latest['retryCount'] =
              ((latest['retryCount'] as num?)?.toInt() ?? 0) + 1;
          latest['updatedAtMs'] = DateTime.now().millisecondsSinceEpoch;
          try {
            _writeAtomicJsonSync(entity, latest);
          } catch (_) {}
          _notifyChanged();
        }
      }
    } finally {
      _activeUploadIds.clear();
      _flushing = false;
    }
    return sent;
  }
}

/// Uploads image (unless already uploaded on an earlier partial attempt),
/// checkpoints the resulting HTTPS URL to disk, and commits the Firestore doc.
Future<void> syncQueuedReportPayload({
  required PendingReportQueue queue,
  required Map<String, dynamic> item,
  required Future<String> Function(Uint8List bytes, {required String reportId})
  uploadImage,
  required Future<void> Function(
    String reportId,
    Map<String, dynamic> report,
    String imageUrl,
  )
  saveReport,
}) async {
  final reportId = (item['id'] as String?)?.trim() ?? '';
  if (reportId.isEmpty) {
    throw ReportUploadException(
      category: ReportUploadErrorCategory.server,
      message: 'Queued report metadata is missing its report ID.',
    );
  }
  final report = Map<String, dynamic>.from(item['report'] as Map);
  var imageUrl = (item['uploadedImageUrl'] as String?)?.trim() ?? '';

  if (imageUrl.isEmpty) {
    final imagePath = (item['imagePath'] as String?) ?? '';
    final imageFile = File(imagePath);
    if (!await imageFile.exists()) {
      throw ReportUploadException(
        category: ReportUploadErrorCategory.missingImage,
        message: 'Captured photo file is missing from this device.',
      );
    }
    final bytes = await imageFile.readAsBytes();
    if (bytes.isEmpty) {
      throw ReportUploadException(
        category: ReportUploadErrorCategory.missingImage,
        message: 'Captured photo file is empty and cannot be uploaded.',
      );
    }
    imageUrl = await uploadImage(bytes, reportId: reportId);
    // Persist the uploaded URL immediately so retrying after a Firestore error
    // does not re-upload the image bytes.
    await queue.markUploadedImageUrl(reportId, imageUrl);
  }

  await saveReport(reportId, report, imageUrl);
}
