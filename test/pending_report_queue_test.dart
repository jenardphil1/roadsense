import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:my_flutter_app/functions_client.dart';
import 'package:my_flutter_app/pending_report_queue.dart';
import 'package:my_flutter_app/upload_error.dart';
import 'package:my_flutter_app/user_reports_model.dart';

void main() {
  test('concurrent retries publish a queued report once', () async {
    final dir = await Directory.systemTemp.createTemp('roadsense-concurrent-');
    addTearDown(() => dir.delete(recursive: true));
    final image = File('${dir.path}/image.jpg');
    await image.writeAsBytes([1, 2, 3]);
    final queue = PendingReportQueue(Directory('${dir.path}/outbox'));
    await queue.enqueue('owner', image.path, {});
    var calls = 0;
    Future<void> send(Map<String, dynamic> _) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final counts = await Future.wait([
      queue.flush('owner', send),
      queue.flush('owner', send),
    ]);
    expect(calls, 1);
    expect(counts.reduce((a, b) => a + b), 1);
  });

  test(
    'failed upload survives restart, respects ownership, and retries once',
    () async {
      final dir = await Directory.systemTemp.createTemp('roadsense-queue-');
      addTearDown(() => dir.delete(recursive: true));
      final image = File('${dir.path}/source.png');
      await image.writeAsBytes([137, 80, 78, 71]);
      final folder = Directory('${dir.path}/outbox');
      var queue = PendingReportQueue(folder);
      final id = await queue.enqueue('owner', image.path, {'latitude': 14.85});
      await image.delete();
      expect(
        await queue.flush(
          'owner',
          (_) async => throw const SocketException('offline'),
        ),
        0,
      );
      queue = PendingReportQueue(folder);
      expect(await queue.contains(id), isTrue);
      expect(
        await queue.flush('other-user', (_) async => fail('wrong account')),
        0,
      );
      var calls = 0;
      Future<void> send(Map<String, dynamic> item) async {
        calls++;
        expect(item['id'], id);
        expect(await File(item['imagePath'] as String).readAsBytes(), [
          137,
          80,
          78,
          71,
        ]);
      }

      expect(await queue.flush('owner', send), 1);
      expect(await queue.contains(id), isFalse);
      expect(await queue.flush('owner', send), 0);
      expect(calls, 1);
    },
  );

  test(
    'recovers legacy queued records without syncState and preserves failed error state across restarts',
    () async {
      final dir = await Directory.systemTemp.createTemp('roadsense-legacy-');
      addTearDown(() => dir.delete(recursive: true));
      final folder = Directory('${dir.path}/outbox');
      await folder.create(recursive: true);

      const legacyId = 'legacy-report-0001';
      await File('${folder.path}/$legacyId.image').writeAsBytes([1, 2, 3, 4]);
      await File('${folder.path}/$legacyId.json').writeAsString(
        jsonEncode({
          'id': legacyId,
          'uid': 'user-1',
          // Simulate an old path from an OS container relocation; fallback resolves $legacyId.image.
          'imagePath': '${dir.path}/nonexistent-old-container/$legacyId.image',
          'report': {'latitude': 14.85, 'longitude': 120.81, 'primaryDefect': 'Pothole'},
        }),
      );

      final queue = PendingReportQueue(folder);
      final initial = await queue.listForUser('user-1');
      expect(initial.length, 1);
      expect(initial.first.syncState, PendingSyncState.waiting);
      expect(initial.first.hasLocalImage, isTrue);

      await queue.flush('user-1', (_) async {
        throw const FirebaseCallableException(
          code: 'failed-precondition',
          reason: 'upload-not-configured',
          message: 'Report image upload storage is not configured.',
        );
      });

      final reloaded = PendingReportQueue(folder);
      final failedList = await reloaded.listForUser('user-1');
      expect(failedList.length, 1);
      expect(failedList.first.syncState, PendingSyncState.failed);
      expect(
        failedList.first.errorCategory,
        ReportUploadErrorCategory.missingConfiguration,
      );
      expect(failedList.first.retryCount, 1);
    },
  );

  test(
    'checkpoints uploadedImageUrl when image succeeds and skips re-upload on Firestore retry',
    () async {
      final dir = await Directory.systemTemp.createTemp('roadsense-partial-');
      addTearDown(() => dir.delete(recursive: true));
      final imgFile = File('${dir.path}/photo.jpg');
      await imgFile.writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0]);

      final folder = Directory('${dir.path}/outbox');
      var queue = PendingReportQueue(folder);
      final id = await queue.enqueue('user-1', imgFile.path, {
        'latitude': 14.85,
        'longitude': 120.81,
      });

      var uploadCalls = 0;
      var saveCalls = 0;

      // Attempt 1: Azure upload succeeds, Firestore create fails offline.
      final firstCount = await queue.flush('user-1', (item) async {
        await syncQueuedReportPayload(
          queue: queue,
          item: item,
          uploadImage: (bytes, {required String reportId}) async {
            uploadCalls++;
            expect(reportId, id);
            return 'https://potholestorage2026.blob.core.windows.net/photos/reports/user-1/$id.jpg';
          },
          saveReport: (reportId, report, imageUrl) async {
            saveCalls++;
            throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'unavailable',
              message: 'Offline during Firestore write',
            );
          },
        );
      });

      expect(firstCount, 0);
      expect(uploadCalls, 1);
      expect(saveCalls, 1);
      expect(await queue.contains(id), isTrue);

      // Re-instantiate queue (restart) -> uploadedImageUrl & connectivity failure persisted.
      queue = PendingReportQueue(folder);
      final persisted = await queue.getById(id, expectedUid: 'user-1');
      expect(persisted, isNotNull);
      expect(
        persisted!.uploadedImageUrl,
        'https://potholestorage2026.blob.core.windows.net/photos/reports/user-1/$id.jpg',
      );
      expect(persisted.errorCategory, ReportUploadErrorCategory.connectivity);

      // Attempt 2: Retry succeeds without re-uploading image bytes.
      final secondCount = await queue.flush('user-1', (item) async {
        await syncQueuedReportPayload(
          queue: queue,
          item: item,
          uploadImage: (bytes, {required String reportId}) async {
            uploadCalls++;
            return fail('Image should not be re-uploaded once uploadedImageUrl is checkpointed');
          },
          saveReport: (reportId, report, imageUrl) async {
            saveCalls++;
            expect(
              imageUrl,
              'https://potholestorage2026.blob.core.windows.net/photos/reports/user-1/$id.jpg',
            );
          },
        );
      });

      expect(secondCount, 1);
      expect(uploadCalls, 1);
      expect(saveCalls, 2);
      expect(await queue.contains(id), isFalse);
    },
  );

  test(
    'syncQueuedReportPayload classifies missing local image and preserves error without deleting metadata',
    () async {
      final dir = await Directory.systemTemp.createTemp('roadsense-missing-img-');
      addTearDown(() => dir.delete(recursive: true));
      final imgFile = File('${dir.path}/temp.jpg');
      await imgFile.writeAsBytes([1, 2, 3]);
      final folder = Directory('${dir.path}/outbox');
      final queue = PendingReportQueue(folder);
      final id = await queue.enqueue('user-1', imgFile.path, {});
      // Delete queued copy to simulate OS cache eviction / missing local file.
      await File('${folder.path}/$id.image').delete();

      await queue.flush('user-1', (item) async {
        await syncQueuedReportPayload(
          queue: queue,
          item: item,
          uploadImage: (_, {required String reportId}) async => fail('unexpected upload'),
          saveReport: (_, _, _) async => fail('unexpected firestore save'),
        );
      });

      final record = await queue.getById(id, expectedUid: 'user-1');
      expect(record, isNotNull);
      expect(record!.syncState, PendingSyncState.failed);
      expect(record.errorCategory, ReportUploadErrorCategory.missingImage);
    },
  );

  test(
    'classifyUploadError distinguishes all failure categories and strips credentials/signed URLs',
    () {
      expect(
        classifyUploadError(const SocketException('down')).category,
        ReportUploadErrorCategory.connectivity,
      );
      expect(
        classifyUploadError(TimeoutException('timeout')).category,
        ReportUploadErrorCategory.connectivity,
      );
      expect(
        classifyUploadError(
          http.ClientException(
            'Failed',
            Uri.parse(
              'https://acct.blob.core.windows.net/photos/r.jpg?sv=2022-11-02&sig=SUPERSECRET',
            ),
          ),
        ).message,
        isNot(contains('SUPERSECRET')),
      );
      expect(
        classifyUploadError(
          const FirebaseCallableException(
            code: 'not-found',
            reason: 'not-deployed',
            message: '404',
            httpStatus: 404,
          ),
        ).category,
        ReportUploadErrorCategory.missingConfiguration,
      );
      expect(
        classifyUploadError(
          const FirebaseCallableException(
            code: 'unauthenticated',
            reason: 'unauthenticated',
            message: 'Bearer eyJhbGciOi',
          ),
        ).category,
        ReportUploadErrorCategory.authentication,
      );
      expect(
        classifyUploadError(
          const FirebaseCallableException(
            code: 'failed-precondition',
            reason: 'email-not-verified',
            message: 'Verify email first',
          ),
        ).category,
        ReportUploadErrorCategory.permission,
      );
      expect(
        classifyUploadError(
          const FirebaseCallableException(
            code: 'internal',
            reason: 'internal',
            message:
                'AccountKey=TOPSECRETKEY==;sig=ABC failed at https://foo.bar/blob?sig=XYZ',
          ),
        ),
        isA<ReportUploadException>()
            .having((e) => e.category, 'category', ReportUploadErrorCategory.server)
            .having((e) => e.message, 'redacts key', isNot(contains('TOPSECRETKEY')))
            .having((e) => e.message, 'redacts sig', isNot(contains('XYZ'))),
      );
    },
  );

  test(
    'mergeUserReports deduplicates by stable ID, isolates accounts, and separates queue from Pending review',
    () {
      final now = DateTime(2026, 11, 16, 10).millisecondsSinceEpoch;
      final localRecords = [
        PendingReportRecord(
          id: 'dup-id',
          uid: 'user-a',
          imagePath: '/tmp/dup.jpg',
          report: {'primaryDefect': 'Pothole', 'latitude': 14.8, 'longitude': 120.8},
          syncState: PendingSyncState.waiting,
          createdAtMs: now,
          updatedAtMs: now,
        ),
        PendingReportRecord(
          id: 'local-only-id',
          uid: 'user-a',
          imagePath: '/tmp/local.jpg',
          report: {'primaryDefect': 'Pothole', 'latitude': 14.8, 'longitude': 120.8},
          syncState: PendingSyncState.failed,
          errorCategory: ReportUploadErrorCategory.connectivity,
          errorMessage: 'Offline',
          createdAtMs: now + 1000,
          updatedAtMs: now + 1000,
        ),
        PendingReportRecord(
          id: 'other-user-id',
          uid: 'user-b',
          imagePath: '/tmp/other.jpg',
          report: {'primaryDefect': 'Pothole'},
          syncState: PendingSyncState.waiting,
          createdAtMs: now,
          updatedAtMs: now,
        ),
      ];
      final cloudRecords = [
        CloudReportRecord(
          id: 'dup-id',
          data: {
            'reporterUid': 'user-a',
            'status': 'pending',
            'primaryDefect': 'Pothole',
            'timestamp': DateTime.fromMillisecondsSinceEpoch(now + 500),
          },
        ),
        CloudReportRecord(
          id: 'approved-id',
          data: {
            'reporterUid': 'user-a',
            'status': 'approved',
            'primaryDefect': 'Pothole',
            'timestamp': DateTime.fromMillisecondsSinceEpoch(now - 1000),
          },
        ),
        CloudReportRecord(
          id: 'foreign-cloud-id',
          data: {
            'reporterUid': 'user-b',
            'status': 'pending',
            'primaryDefect': 'Pothole',
            'timestamp': DateTime.fromMillisecondsSinceEpoch(now),
          },
        ),
      ];

      final merged = mergeUserReports(
        uid: 'user-a',
        localRecords: localRecords,
        cloudRecords: cloudRecords,
      );

      expect(merged.activeItems.map((i) => i.id).toList(), [
        'local-only-id',
        'dup-id',
        'approved-id',
      ]);
      // Duplicate resolved to cloud (isLocal == false), single row kept.
      expect(merged.activeItems[1].isCloud, isTrue);
      expect(merged.localQueuedCount, 1);
      expect(merged.pendingReviewCount, 1); // local item does not inflate cloud pending count
      expect(merged.approvedCount, 1);
      expect(merged.totalActiveCount, 3);
    },
  );
}
