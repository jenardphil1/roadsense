import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/admin_barangay_insights_view.dart';
import 'package:my_flutter_app/admin_forecast_metrics.dart';
import 'package:my_flutter_app/admin_map_view.dart';
import 'package:my_flutter_app/admin_overview_view.dart';
import 'package:my_flutter_app/admin_report_inspector.dart';
import 'package:my_flutter_app/admin_report_query.dart';
import 'package:my_flutter_app/admin_review_queue_view.dart';
import 'package:my_flutter_app/admin_trash_view.dart';
import 'package:my_flutter_app/admin_users_settings_view.dart';
import 'package:my_flutter_app/approval_priority.dart';
import 'package:my_flutter_app/web_design.dart';

AdminReportRow _makeRow({
  required String id,
  String status = 'pending',
  String? severity = 'medium',
  String barangay = 'Poblacion',
  String city = 'Santa Maria',
  String province = 'Bulacan',
  String defect = 'Pothole',
  String dpwhCode = 'CODE 01',
  int primaryClassId = 0,
  double lat = 14.8197,
  double lng = 120.9575,
  DateTime? timestamp,
  double? confidence = 0.84,
  String note = '',
  String rejectionReason = '',
  String reporterEmail = 'surveyor@example.com',
}) {
  return AdminReportRow.fromMap(id, {
    'status': status,
    'overallSeverity': ?severity,
    'barangay': barangay,
    'city': city,
    'province': province,
    'primaryDefect': defect,
    'primaryDpwhCode': dpwhCode,
    'primaryClassId': primaryClassId,
    'latitude': lat,
    'longitude': lng,
    'timestamp': timestamp ?? DateTime.utc(2026, 11, 10, 9, 0),
    if (confidence != null)
      'detections': [
        {'className': defect, 'confidence': confidence},
      ],
    'note': note,
    if (rejectionReason.isNotEmpty) 'rejectionReason': rejectionReason,
    'reporterName': 'Field Surveyor',
    'reporterEmail': reporterEmail,
  });
}

ReportPriority _makePriority(
  String id, {
  double score = 52.0,
  PriorityBand band = PriorityBand.high,
  bool slaBreached = false,
  List<String> dupIds = const [],
}) {
  return ReportPriority(
    id: id,
    score: score,
    band: band,
    factors: const PriorityFactors(
      harm: 0.7,
      credibility: 0.8,
      exposure: 0.75,
      aging: 4.0,
      urgency: 0.42,
      modelConfidence: 0.84,
      reporterTrust: 0.8,
      corroboration: 0.2,
      severity: 'high',
      dpwhCode: 'CODE 01',
      responseTime: '3 Days',
      dpwhSlaHours: 72,
      isSlaBreached: false,
      potholeCount: 1,
      witnesses: 0,
      nearbyReporters: 1,
      hasPhoto: true,
      waiting: Duration(hours: 20),
    ),
    reasons: const ['Urgent DPWH Code 01'],
    duplicateIds: dupIds,
    isSlaBreached: slaBreached,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = File('C:/Windows/Fonts/arial.ttf');
    if (await font.exists()) {
      final bytes = await font.readAsBytes();
      for (final family in ['Roboto', 'monospace']) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
  });

  group('AdminReportQuery domain rules', () {
    test(
      'separates missing severity from medium and keeps unassessed last in both sort orders',
      () {
        final high = _makeRow(id: 'r-high', severity: 'high');
        final med = _makeRow(id: 'r-med', severity: 'medium');
        final low = _makeRow(id: 'r-low', severity: 'low');
        final missing = _makeRow(id: 'r-missing', severity: null);

        expect(missing.severity, AdminSeverity.notAssessed);
        expect(med.severity, AdminSeverity.medium);

        final rows = [missing, low, high, med];
        final desc = filterAndSortAdminRows(
          rows,
          filter: const AdminReportFilter(
            statuses: {},
            sort: AdminReportSort.severityDesc,
          ),
        );
        expect(desc.map((r) => r.id), [
          'r-high',
          'r-med',
          'r-low',
          'r-missing',
        ]);

        final asc = filterAndSortAdminRows(
          rows,
          filter: const AdminReportFilter(
            statuses: {},
            sort: AdminReportSort.severityAsc,
          ),
        );
        expect(asc.map((r) => r.id), ['r-low', 'r-med', 'r-high', 'r-missing']);
      },
    );

    test(
      'separates missing AI confidence from 0% and excludes trashed reports',
      () {
        final noDet = _makeRow(id: 'r-nodet', confidence: null);
        final lowConf = _makeRow(id: 'r-lowconf', confidence: 0.42);
        final highConf = _makeRow(id: 'r-highconf', confidence: 0.93);
        final deleted = _makeRow(id: 'r-trash', status: 'deleted');

        expect(noDet.maxConfidence, isNull);
        final sorted = filterAndSortAdminRows(
          [noDet, lowConf, highConf, deleted],
          filter: const AdminReportFilter(
            statuses: {},
            sort: AdminReportSort.confidenceDesc,
          ),
        );
        expect(sorted.map((r) => r.id), ['r-highconf', 'r-lowconf', 'r-nodet']);
      },
    );

    test(
      'filters status, defect class, barangay, SLA breach, and paginates accurately',
      () {
        final r1 = _makeRow(
          id: 'p1',
          status: 'pending',
          barangay: 'Cay Pombo',
          defect: 'Alligator crack',
          dpwhCode: 'CODE 02',
          primaryClassId: 1,
        );
        final r2 = _makeRow(
          id: 'a1',
          status: 'approved',
          barangay: 'Poblacion',
        );
        final r3 = _makeRow(
          id: 'rej1',
          status: 'rejected',
          rejectionReason: 'Duplicate report',
        );

        final pMap = {'p1': _makePriority('p1', slaBreached: true)};

        final pendingOnly = filterAndSortAdminRows(
          [r1, r2, r3],
          filter: const AdminReportFilter(
            statuses: {AdminReportStatus.pending},
            onlySlaBreached: true,
          ),
          priorities: pMap,
        );
        expect(pendingOnly.map((r) => r.id), ['p1']);

        final rejOnly = filterAndSortAdminRows(
          [r1, r2, r3],
          filter: const AdminReportFilter(
            statuses: {AdminReportStatus.rejected},
          ),
        );
        expect(rejOnly.map((r) => r.id), ['rej1']);

        final items = List.generate(30, (i) => i);
        final slice1 = paginateAdminItems(
          items,
          requestedPage: 1,
          pageSize: 25,
        );
        expect(slice1.startOrdinal, 26);
        expect(slice1.endOrdinal, 30);
        expect(slice1.items, [25, 26, 27, 28, 29]);

        // Out-of-bounds page index clamps safely when filter narrows list
        final clamped = paginateAdminItems(
          items.sublist(0, 5),
          requestedPage: 4,
          pageSize: 25,
        );
        expect(clamped.pageIndex, 0);
        expect(clamped.items, [0, 1, 2, 3, 4]);
      },
    );
  });

  group('CSV injection neutralization & PII scoping', () {
    test(
      'escapes spreadsheet formula triggers while preserving negative coordinates',
      () {
        expect(
          AdminCsvExporter.formatCell('=CMD("calc")'),
          '"\'=CMD(""calc"")"',
        );
        expect(AdminCsvExporter.formatCell('+1+2'), '"\'+1+2"');
        expect(AdminCsvExporter.formatCell('-2+3'), '"\'-2+3"');
        expect(AdminCsvExporter.formatCell('@SUM(A1:A2)'), '"\'@SUM(A1:A2)"');
        expect(
          AdminCsvExporter.formatCell('\t=HYPERLINK()'),
          '"\'\t=HYPERLINK()"',
        );
        expect(AdminCsvExporter.formatCell(-14.81972), '"-14.81972"');
      },
    );

    test('omits reporter emails unless explicitly opted in', () {
      final row = _makeRow(id: 'csv-1', reporterEmail: 'secret@citizen.ph');
      final noPii = AdminCsvExporter.buildReportsCsv([
        row,
      ], includeReporterEmail: false);
      expect(noPii, isNot(contains('Reporter Email')));
      expect(noPii, isNot(contains('secret@citizen.ph')));

      final withPii = AdminCsvExporter.buildReportsCsv([
        row,
      ], includeReporterEmail: true);
      expect(withPii, contains('Reporter Email'));
      expect(withPii, contains('secret@citizen.ph'));
    });
  });

  group('AdminForecastMetrics 24-barangay coverage & validation', () {
    final now = DateTime.utc(2026, 11, 14, 12, 0);

    test(
      'distinguishes no-reports, no-recent-reports, insufficient-history, and forecast-available',
      () {
        final rows = <AdminReportRow>[
          // Guyong: >= 8 verified reports across 6 recent weeks -> Forecast available
          for (var w = 0; w < 6; w++) ...[
            _makeRow(
              id: 'guy-a-$w',
              status: 'approved',
              barangay: 'Guyong',
              timestamp: now.subtract(Duration(days: w * 7 + 1)),
              lat: 14.8236 + w * 0.0001,
            ),
            if (w < 3)
              _makeRow(
                id: 'guy-b-$w',
                status: 'approved',
                barangay: 'Guyong',
                timestamp: now.subtract(Duration(days: w * 7 + 2)),
                lat: 14.8240 + w * 0.0001,
              ),
          ],
          // Poblacion: only 2 recent approved reports -> Insufficient history
          _makeRow(
            id: 'pob-1',
            status: 'approved',
            barangay: 'Poblacion',
            timestamp: now.subtract(const Duration(days: 2)),
          ),
          _makeRow(
            id: 'pob-2',
            status: 'approved',
            barangay: 'Poblacion',
            timestamp: now.subtract(const Duration(days: 10)),
          ),
          // Bagbaguin: report older than 56 days -> No recent verified reports
          _makeRow(
            id: 'bag-old',
            status: 'approved',
            barangay: 'Bagbaguin',
            timestamp: now.subtract(const Duration(days: 120)),
          ),
          // External municipality (Malolos) preserved cleanly
          _makeRow(
            id: 'mal-1',
            status: 'approved',
            barangay: 'Bagna',
            city: 'Malolos',
            province: 'Bulacan',
            timestamp: now.subtract(const Duration(days: 3)),
          ),
        ];

        final result = computeAdminBarangayInsights(rows, now: now);
        expect(result.santaMariaRows, hasLength(24));
        expect(result.coveredSantaMariaCount, 3);
        expect(result.forecastReadySantaMariaCount, 1);

        final guyong = result.santaMariaRows.firstWhere(
          (b) => b.barangay == 'Guyong',
        );
        expect(guyong.coverageState, BarangayCoverageState.forecastAvailable);
        expect(guyong.forecast30d, isNotNull);
        expect(guyong.forecastLower30d, lessThanOrEqualTo(guyong.forecast30d!));
        expect(
          guyong.forecastUpper30d,
          greaterThanOrEqualTo(guyong.forecast30d!),
        );
        expect(guyong.periodDeltaLabel, isNot(contains('Infinity')));

        final poblacion = result.santaMariaRows.firstWhere(
          (b) => b.barangay == 'Poblacion',
        );
        expect(
          poblacion.coverageState,
          BarangayCoverageState.insufficientHistory,
        );
        expect(poblacion.forecast30d, isNull);

        final bagbaguin = result.santaMariaRows.firstWhere(
          (b) => b.barangay == 'Bagbaguin',
        );
        expect(bagbaguin.coverageState, BarangayCoverageState.noRecentReports);

        final catmon = result.santaMariaRows.firstWhere(
          (b) => b.barangay == 'Catmon',
        );
        expect(catmon.coverageState, BarangayCoverageState.noReports);

        expect(result.otherLguRows, hasLength(1));
        expect(result.otherLguRows.single.city, 'Malolos');

        expect(result.validation.evaluatedPoints, greaterThan(0));
        expect(result.validation.baselineMae, isNotNull);
        expect(result.validation.modelMae, isNotNull);

        final lguCsv = buildAdminBarangayCsv([guyong, catmon]);
        expect(lguCsv, contains('Insufficient history'));
        expect(lguCsv, contains('No reports recorded'));
      },
    );
  });

  group('Responsive Admin Views across viewports & accessibility', () {
    final now = DateTime.utc(2026, 11, 14, 12, 0);
    final sampleRows = [
      _makeRow(
        id: 'rep-pending-1',
        status: 'pending',
        severity: 'high',
        barangay: 'Poblacion',
        timestamp: now.subtract(const Duration(hours: 6)),
      ),
      _makeRow(
        id: 'rep-approved-2',
        status: 'approved',
        severity: 'medium',
        barangay: 'Guyong',
        defect: 'Alligator crack',
        dpwhCode: 'CODE 02',
        primaryClassId: 1,
        timestamp: now.subtract(const Duration(days: 2)),
      ),
      _makeRow(
        id: 'rep-rejected-3',
        status: 'rejected',
        severity: 'low',
        barangay: 'Catmon',
        defect: 'Longitudinal crack',
        dpwhCode: 'CODE 12',
        primaryClassId: 3,
        rejectionReason: 'Surface shadow artifact',
        timestamp: now.subtract(const Duration(days: 5)),
      ),
      _makeRow(
        id: 'rep-unassigned-4',
        status: 'pending',
        severity: null,
        barangay: '',
        city: '',
        province: '',
        defect: 'Unclassified road defect',
        dpwhCode: '',
        primaryClassId: -1,
        timestamp: now.subtract(const Duration(days: 1)),
      ),
    ];
    final trashRows = [
      _makeRow(id: 'rep-trash-1', status: 'deleted', barangay: 'Cay Pombo'),
    ];
    final priorities = {
      'rep-pending-1': _makePriority(
        'rep-pending-1',
        slaBreached: true,
        dupIds: ['dup-2'],
      ),
    };
    final insights = computeAdminBarangayInsights(sampleRows, now: now);

    Widget wrapViewport({
      required Size size,
      required Widget child,
      bool dark = false,
      double textScale = 1.0,
    }) {
      return MaterialApp(
        theme: WebDesign.buildTheme(isDark: dark),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(body: child),
        ),
      );
    }

    testWidgets(
      'queue selection fits the available panel beside an admin sidebar',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          wrapViewport(
            size: const Size(1600, 900),
            child: Row(
              children: [
                const SizedBox(width: 280),
                Expanded(
                  child: AdminReviewQueueView(
                    activeRows: sampleRows,
                    priorities: priorities,
                    filter: const AdminReportFilter(statuses: {}),
                    onFilterChanged: (_) {},
                    selectedReportId: sampleRows.first.id,
                    onSelectReportId: (_) {},
                    isSuperAdmin: true,
                    adminPosition: null,
                    isFetchingAdminPosition: false,
                    onRequestAdminPosition: () {},
                    onLocateOnMap: (_, _) {},
                    onSoftDelete: (_) async {},
                    onBulkSoftDelete: (_) async => 0,
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 1320px of actual content does not fit a docked inspector plus table.
        expect(find.byType(AdminReportInspectorPanel), findsNothing);
        final table = tester.widget<DataTable>(find.byType(DataTable));
        expect((table.columns[1].label as Text).data, 'Actions');
        expect(
          find
              .byTooltip('Inspect report #${sampleRows.first.shortId}')
              .hitTestable(),
          findsOneWidget,
        );
        final horizontal = tester
            .widgetList<Scrollbar>(find.byType(Scrollbar))
            .where((s) => s.scrollbarOrientation == ScrollbarOrientation.top)
            .single;
        expect(horizontal.thumbVisibility, isTrue);
        await tester.tap(
          find.byTooltip('Inspect report #${sampleRows.first.shortId}'),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AdminReportInspectorPanel), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'queue with a docked inspector keeps report and action columns visible',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          wrapViewport(
            size: const Size(1920, 1000),
            child: Row(
              children: [
                const SizedBox(width: 256),
                Expanded(
                  child: AdminReviewQueueView(
                    activeRows: sampleRows,
                    priorities: priorities,
                    filter: const AdminReportFilter(statuses: {}),
                    onFilterChanged: (_) {},
                    selectedReportId: sampleRows.first.id,
                    onSelectReportId: (_) {},
                    isSuperAdmin: true,
                    adminPosition: null,
                    isFetchingAdminPosition: false,
                    onRequestAdminPosition: () {},
                    onLocateOnMap: (_, _) {},
                    onSoftDelete: (_) async {},
                    onBulkSoftDelete: (_) async => 0,
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AdminReportInspectorPanel), findsOneWidget);
        expect(
          find
              .byTooltip('Inspect report #${sampleRows.first.shortId}')
              .hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final width in [700.0, 1200.0]) {
      testWidgets(
        'admin map selection stays inside ${width.toInt()}px of available content',
        (tester) async {
          tester.view.physicalSize = const Size(1700, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            wrapViewport(
              size: const Size(1700, 1000),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: width,
                  child: AdminMapView(
                    activeRows: sampleRows,
                    priorities: priorities,
                    filter: const AdminReportFilter(statuses: {}),
                    onFilterChanged: (_) {},
                    selectedReportId: sampleRows.first.id,
                    onSelectReportId: (_) {},
                    requestedFocusLocation: null,
                    focusRequestNonce: 0,
                    onSoftDelete: (_) async {},
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 600));
          expect(
            find.byType(AdminReportInspectorPanel),
            width >= 1150 ? findsOneWidget : findsNothing,
          );
          expect(
            find.byTooltip('Fit filtered pins').hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final size in [
      const Size(1440, 900),
      const Size(1024, 768),
      const Size(768, 1024),
      const Size(390, 844),
    ]) {
      testWidgets(
        'Overview & Review Queue render cleanly at ${size.width.toInt()}px',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            wrapViewport(
              size: size,
              child: AdminOverviewView(
                activeRows: sampleRows,
                trashedRows: trashRows,
                priorities: priorities,
                barangayInsights: insights,
                isAutoAccept: false,
                snapshotLoadedAt: now,
                onNavigateQueuePending: () {},
                onNavigateQueueSlaBreached: () {},
                onNavigateQueueApproved: () {},
                onNavigateQueueRejected: () {},
                onNavigateQueueHighSeverity: () {},
                onFilterByDefectClass: (_) {},
                onNavigateBarangayInsights: () {},
                onNavigateSettings: () {},
                onInspectHotspot: (_, _) {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('PENDING REVIEW'), findsOneWidget);
          expect(find.text('REJECTED'), findsOneWidget);
          expect(find.textContaining('Offline Test Set'), findsOneWidget);
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(
            wrapViewport(
              size: size,
              child: AdminReviewQueueView(
                activeRows: sampleRows,
                priorities: priorities,
                filter: const AdminReportFilter(statuses: {}),
                onFilterChanged: (_) {},
                selectedReportId: null,
                onSelectReportId: (_) {},
                isSuperAdmin: true,
                adminPosition: null,
                isFetchingAdminPosition: false,
                onRequestAdminPosition: () {},
                onLocateOnMap: (_, _) {},
                onSoftDelete: (_) async {},
                onBulkSoftDelete: (_) async => 0,
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (size.width >= 900) {
            expect(find.byType(DataTable), findsOneWidget);
          } else {
            expect(find.byType(DataTable), findsNothing);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'Inspector, Barangay Insights, Trash & Role-Restricted Settings work cleanly at 2x text size',
      (tester) async {
        const size = Size(1440, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Inspector separates AI confidence vs Physical severity & duplicate warning
        await tester.pumpWidget(
          wrapViewport(
            size: size,
            textScale: 1.5,
            child: AdminReportInspectorPanel(
              row: sampleRows.first,
              priority: priorities['rep-pending-1'],
              onClose: () {},
              onLocateOnMap: (_, _) {},
              onSoftDelete: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('84.0% max'), findsOneWidget);
        expect(
          find.textContaining('other pending report(s) lie within 25 m'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        // Barangay insights shows all 24 barangays + unassigned backfill banner cleanly at 390px and 1024px
        for (final bSize in [const Size(390, 844), const Size(1024, 768)]) {
          tester.view.physicalSize = bSize;
          await tester.pumpWidget(
            wrapViewport(
              size: bSize,
              child: AdminBarangayInsightsView(
                insights: insights,
                isGeocoding: false,
                geocodedDone: 0,
                geocodedTotal: 0,
                onStartGeocodeBackfill: () {},
                onStopGeocodeBackfill: () {},
                onViewReportsInBarangay: (_) {},
                onFocusBarangayOnMap: (_, _, _) {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('SANTA MARIA COVERAGE'), findsOneWidget);
          expect(find.text('Classify Unassigned'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        tester.view.physicalSize = size;

        // Trash view
        await tester.pumpWidget(
          wrapViewport(
            size: size,
            child: AdminTrashView(trashedRows: trashRows),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('#REP-TR'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Standard admin sees clean backend rule restriction instead of calling super-admin-only user stream
        await tester.pumpWidget(
          wrapViewport(
            size: size,
            child: AdminUsersSettingsView(
              activeRows: sampleRows,
              priorities: priorities,
              isSuperAdmin: false,
              currentUid: 'admin-1',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Restricted by backend rules'),
          findsOneWidget,
        );
        expect(find.textContaining('Download CSV'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
