import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_flutter_app/cloud_service.dart';
import 'package:my_flutter_app/functions_client.dart';
import 'package:my_flutter_app/pending_report_queue.dart';
import 'package:my_flutter_app/profile_screen.dart';
import 'package:my_flutter_app/upload_error.dart';
import 'package:my_flutter_app/user_reports_model.dart';

// Valid 1x1 transparent PNG so Image.file renders cleanly in widget tests.
final Uint8List _valid1x1Png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

Map<String, dynamic> _sampleReportPayload({String note = 'Deep pothole'}) => {
  'latitude': 14.8527,
  'longitude': 120.8150,
  'overallSeverity': 'high',
  'potholeCount': 2,
  'primaryDpwhCode': 'CODE 01',
  'primaryDefect': 'Pothole',
  'barangay': 'Poblacion',
  'city': 'Santa Maria',
  'province': 'Bulacan',
  'note': note,
  'detections': [
    {'classId': 0, 'className': 'Pothole', 'dpwhCode': 'CODE 01', 'confidence': 0.91},
  ],
};

Widget _wrapScreen(Widget child) {
  return MaterialApp(home: child);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'My Reports displays locally queued reports immediately while stream is offline/waiting and persists across restarts',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('roadsense-widget-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final imgFile = File('${dir.path}/capture.png');
      imgFile.writeAsBytesSync(_valid1x1Png);

      final outboxDir = Directory('${dir.path}/outbox');
      final queue1 = PendingReportQueue(outboxDir);
      final reportId = await queue1.enqueue(
        'user-a',
        imgFile.path,
        _sampleReportPayload(note: 'Offline capture'),
      );

      // Cloud stream emits an error (simulating offline/unavailable Firestore).
      final cloudController =
          StreamController<List<CloudReportRecord>>.broadcast();
      addTearDown(cloudController.close);

      await tester.pumpWidget(
        _wrapScreen(
          ProfileScreen(
            section: ProfileScreenSection.reports,
            currentUidOverride: 'user-a',
            pendingQueue: queue1,
            userReportsStreamOverride: cloudController.stream,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Waiting to upload'), findsOneWidget);
      expect(find.textContaining('severity'), findsNothing);
      expect(find.text('Offline capture'), findsNothing);
      expect(find.text('Poblacion, Santa Maria'), findsOneWidget);
      // Total includes local queued item, while Pending review counts cloud-pending only.
      expect(find.text('Pending review'), findsOneWidget);

      // Emit a Firestore stream error — local queued item must remain visible!
      cloudController.addError(Exception('unavailable'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Waiting to upload'), findsOneWidget);
      expect(
        find.text(
          'Cloud sync unavailable right now. Showing reports saved on this device.',
        ),
        findsOneWidget,
      );

      // Simulate cold restart with a brand new PendingReportQueue instance.
      final queue2 = PendingReportQueue(outboxDir);
      final cloudController2 =
          StreamController<List<CloudReportRecord>>.broadcast();
      addTearDown(cloudController2.close);

      await tester.pumpWidget(
        _wrapScreen(
          ProfileScreen(
            section: ProfileScreenSection.reports,
            currentUidOverride: 'user-a',
            pendingQueue: queue2,
            userReportsStreamOverride: cloudController2.stream,
          ),
        ),
      );
      cloudController2.add(const []);
      await tester.pump();

      expect(find.text('Waiting to upload'), findsOneWidget);
      expect(await queue2.contains(reportId), isTrue);
    },
  );

  testWidgets(
    'My Reports displays sanitized upload failure, supports Retry, deduplicates stable ID, and transitions Waiting -> Pending review -> Approved',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('roadsense-sync-flow-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final imgFile = File('${dir.path}/capture.png');
      imgFile.writeAsBytesSync(_valid1x1Png);

      final outboxDir = Directory('${dir.path}/outbox');
      final queue = PendingReportQueue(outboxDir);
      final reportId = await queue.enqueue(
        'user-a',
        imgFile.path,
        _sampleReportPayload(),
      );

      // Simulate an initial upload failure carrying a credential-bearing URL that MUST be redacted.
      await queue.flush('user-a', (_) async {
        throw ReportUploadException(
          category: ReportUploadErrorCategory.connectivity,
          message:
              'PUT https://potholestorage2026.blob.core.windows.net/photos/reports/user-a/$reportId.png?sig=SECRET123&sv=2022-11-02 timed out',
        );
      });

      final cloudController =
          StreamController<List<CloudReportRecord>>.broadcast();
      addTearDown(cloudController.close);

      var retryCalls = 0;
      Future<void> onRetry({String? targetId}) async {
        retryCalls++;
        await queue.flush('user-a', (item) async {
          expect(item['id'], reportId);
          // Cloud doc arrives with the same stable ID before/as local entry clears.
          cloudController.add([
            CloudReportRecord(
              id: reportId,
              data: {
                ..._sampleReportPayload(),
                'reporterUid': 'user-a',
                'status': 'pending',
                'imageUrl': '',
                'timestamp': DateTime.now(),
              },
            ),
          ]);
        }, targetId: targetId);
      }

      await tester.pumpWidget(
        _wrapScreen(
          ProfileScreen(
            section: ProfileScreenSection.reports,
            currentUidOverride: 'user-a',
            pendingQueue: queue,
            onRetryPendingReports: onRetry,
            userReportsStreamOverride: cloudController.stream,
          ),
        ),
      );
      cloudController.add(const []);
      await tester.pump();

      // Upload failed status pill & redacted message shown (no SECRET123).
      expect(find.text('Upload failed'), findsOneWidget);
      expect(find.textContaining('?[redacted]'), findsWidgets);
      expect(find.textContaining('SECRET123'), findsNothing);

      // Tap Retry on the card / banner.
      final retryButton = find.widgetWithText(OutlinedButton, 'Retry').first;
      await tester.ensureVisible(retryButton);
      await tester.tap(retryButton);
      await tester.pump();
      await tester.pump();

      expect(retryCalls, 1);
      expect(await queue.contains(reportId), isFalse);
      // Local status gone; server Pending review shown once (no duplicate card).
      expect(find.text('Upload failed'), findsNothing);
      expect(find.text('Pending review'), findsNWidgets(2)); // KPI + card pill
      expect(find.text('Poblacion, Santa Maria'), findsOneWidget);

      // Moderator approves report -> updates seamlessly to Approved.
      cloudController.add([
        CloudReportRecord(
          id: reportId,
          data: {
            ..._sampleReportPayload(),
            'reporterUid': 'user-a',
            'status': 'approved',
            'imageUrl': '',
            'timestamp': DateTime.now(),
          },
        ),
      ]);
      await tester.pump();

      expect(find.text('Approved'), findsNWidgets(2)); // KPI + card pill
    },
  );

  testWidgets(
    'My Reports isolates queued and cloud reports per signed-in account',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('roadsense-acct-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final imgFile = File('${dir.path}/capture.png');
      imgFile.writeAsBytesSync(_valid1x1Png);

      final queue = PendingReportQueue(Directory('${dir.path}/outbox'));
      await queue.enqueue(
        'user-a',
        imgFile.path,
        _sampleReportPayload(note: 'User A private report'),
      );

      final cloudController =
          StreamController<List<CloudReportRecord>>.broadcast();
      addTearDown(cloudController.close);

      await tester.pumpWidget(
        _wrapScreen(
          ProfileScreen(
            section: ProfileScreenSection.reports,
            currentUidOverride: 'user-b',
            pendingQueue: queue,
            userReportsStreamOverride: cloudController.stream,
          ),
        ),
      );
      cloudController.add([
        CloudReportRecord(
          id: 'foreign-cloud-doc',
          data: {
            ..._sampleReportPayload(note: 'Leak from user A'),
            'reporterUid': 'user-a',
            'status': 'pending',
            'timestamp': DateTime.now(),
          },
        ),
      ]);
      await tester.pump();

      expect(find.text('No Submitted Reports Yet'), findsOneWidget);
      expect(find.text('Waiting to upload'), findsNothing);
      expect(find.text('Poblacion, Santa Maria'), findsNothing);
    },
  );

  test(
    'uploadReportImageWithSignedUrl uses short-lived backend URL and returns unsigned publicUrl',
    () async {
      late Map<String, String> putHeaders;
      late Uri putUri;
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/issueReportUploadUrl')) {
          expect(request.headers['Authorization'], 'Bearer test-id-token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final data = body['data'] as Map<String, dynamic>;
          expect(data['reportId'], 'rep_12345678');
          expect(data['contentType'], 'image/png');
          return http.Response(
            jsonEncode({
              'result': {
                'uploadUrl':
                    'https://testacct.blob.core.windows.net/photos/reports/user-a/rep_12345678.png?sv=2022-11-02&sp=cw&sr=b&sig=secretSig',
                'publicUrl':
                    'https://testacct.blob.core.windows.net/photos/reports/user-a/rep_12345678.png',
                'requiredHeaders': {
                  'x-ms-blob-type': 'BlockBlob',
                  'x-ms-version': '2022-11-02',
                  'Content-Type': 'image/png',
                },
              },
            }),
            200,
          );
        }
        putUri = request.url;
        putHeaders = request.headers;
        return http.Response('', 201);
      });

      final fnClient = FirebaseFunctionsClient(
        httpClient: mockClient,
        idTokenProvider: () async => 'test-id-token',
      );
      final url = await uploadReportImageWithSignedUrl(
        bytes: _valid1x1Png,
        reportId: 'rep_12345678',
        functionsClient: fnClient,
        httpClient: mockClient,
      );

      expect(
        url,
        'https://testacct.blob.core.windows.net/photos/reports/user-a/rep_12345678.png',
      );
      expect(putUri.queryParameters['sp'], 'cw');
      expect(putHeaders['x-ms-blob-type'], 'BlockBlob');
      expect(putHeaders['Content-Type'], 'image/png');
    },
  );
}
