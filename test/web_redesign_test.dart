import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:my_flutter_app/barangay_forecast_panel.dart'
    show barangayKey, santaMariaBarangays;
import 'package:my_flutter_app/settings_dialog.dart';
import 'package:my_flutter_app/web_components.dart';
import 'package:my_flutter_app/web_design.dart';
import 'package:my_flutter_app/web_map_side_panel.dart';
import 'package:my_flutter_app/web_report_query.dart';

List<WebReportItem> _sampleReports() {
  final now = DateTime.utc(2026, 11, 14, 12, 0);
  return [
    WebReportItem(
      docId: 'rep-001-alpha',
      location: const LatLng(14.8192, 120.9565),
      imageUrl: '',
      timestamp: now.subtract(const Duration(hours: 2)),
      status: 'approved',
      severity: 'high',
      potholeCount: 3,
      primaryDefect: 'Pothole',
      primaryDpwhCode: 'CODE 01',
      responseTime: '24-48 hours',
      correctiveMeasure: 'Full depth patching',
      barangay: 'Poblacion',
      city: 'Santa Maria',
      province: 'Bulacan',
      note: 'Deep crater near crossing',
      reporterUid: 'user-a',
      detections: const [
        {'class': 'Pothole', 'confidence': 0.91},
      ],
    ),
    WebReportItem(
      docId: 'rep-002-bravo',
      location: const LatLng(14.8280, 120.9640),
      imageUrl: '',
      timestamp: now.subtract(const Duration(days: 3)),
      status: 'pending',
      severity: 'medium',
      potholeCount: 2,
      primaryDefect: 'Alligator crack',
      primaryDpwhCode: 'CODE 02',
      responseTime: '7 days',
      correctiveMeasure: 'Bituminous surface treatment',
      barangay: 'Guyong',
      city: 'Santa Maria',
      province: 'Bulacan',
      note: 'Fatigue mesh along shoulder',
      reporterUid: 'user-owner',
      detections: const [
        {'class': 'Alligator crack', 'confidence': 0.78},
      ],
    ),
    WebReportItem(
      docId: 'rep-003-charlie',
      location: const LatLng(14.8410, 120.9850),
      imageUrl: '',
      timestamp: now.subtract(const Duration(days: 12)),
      status: 'rejected',
      severity: 'low',
      potholeCount: 1,
      primaryDefect: 'Longitudinal crack',
      primaryDpwhCode: 'CODE 12',
      responseTime: 'Routine',
      correctiveMeasure: 'Crack sealing',
      barangay: 'Santa Cruz',
      city: 'Santa Maria',
      province: 'Bulacan',
      note: 'Shadow artifact on seam',
      rejectionReason:
          'Image shows road casting shadow rather than structural separation.',
      reporterUid: 'user-owner',
      detections: const [
        {'class': 'Longitudinal crack', 'confidence': 0.62},
      ],
    ),
    WebReportItem(
      docId: 'rep-004-delta',
      location: const LatLng(14.8050, 120.9710),
      imageUrl: '',
      timestamp: now.subtract(const Duration(days: 45)),
      status: 'approved',
      severity: 'high',
      potholeCount: 4,
      primaryDefect: 'Transverse crack',
      primaryDpwhCode: 'CODE 12',
      responseTime: '48 hours',
      correctiveMeasure: 'Joint sealing & slab repair',
      barangay: 'Cay Pombo',
      city: 'Santa Maria',
      province: 'Bulacan',
      note: 'Expansion joint separation',
      reporterUid: 'user-b',
      detections: const [
        {'class': 'Transverse crack', 'confidence': 0.86},
      ],
    ),
  ];
}

void main() {
  group('WebReportQueryEngine & WebUrlState unit tests', () {
    test('normalizes Barangay, Sta., Sto., punctuation, and whitespace', () {
      expect(
        WebReportQueryEngine.normalizeSearchText('  Brgy. Sta. Maria '),
        'santa maria',
      );
      expect(
        WebReportQueryEngine.normalizeSearchText('Barangay Sto. Tomas (#123)'),
        'santo tomas 123',
      );
    });

    test('Santa Maria barangay catalog covers all 24 barangays honestly', () {
      expect(santaMariaBarangayCatalog.length, 24);
      expect(
        santaMariaBarangayCatalog.map((e) => barangayKey(e.name)).toSet(),
        santaMariaBarangays.map(barangayKey).toSet(),
      );

      final withoutCoords = santaMariaBarangayCatalog
          .where((e) => !e.hasCoordinates)
          .map((e) => e.name)
          .toSet();
      expect(withoutCoords, {
        'Bulac',
        'Mag-asawang Sapa',
        'Mahabang Parang',
        'Pulong Buhangin',
        'San Gabriel',
        'San Jose Patag',
        'San Vicente',
        'Santa Clara',
        'Santa Cruz',
        'Santo Tomas',
      });

      final withCoords = santaMariaBarangayCatalog
          .where((e) => e.hasCoordinates)
          .length;
      expect(withCoords, 14);
    });

    test(
      'supports filtering all 4 active DPWH classes, statuses, severities, and dates',
      () {
        final dataset = _sampleReports();
        final now = DateTime.utc(2026, 11, 14, 12, 0);

        for (final defectKey in const [
          'Pothole',
          'Alligator crack',
          'Longitudinal crack',
          'Transverse crack',
        ]) {
          final res = WebReportQueryEngine.execute(
            dataset: dataset,
            filter: WebReportFilter(defectClasses: {defectKey}),
            now: now,
          );
          expect(
            res.items,
            hasLength(1),
            reason: 'Expected 1 report for $defectKey',
          );
        }

        final pendingGuyong = WebReportQueryEngine.execute(
          dataset: dataset,
          filter: WebReportFilter(
            statuses: const {'pending'},
            barangayKeys: {barangayKey('Brgy. Guyong')},
          ),
          now: now,
        );
        expect(pendingGuyong.items.map((e) => e.docId), ['rep-002-bravo']);

        final last7d = WebReportQueryEngine.execute(
          dataset: dataset,
          filter: const WebReportFilter(datePreset: WebDateRangePreset.last7d),
          now: now,
        );
        expect(last7d.items.map((e) => e.docId).toList(), [
          'rep-001-alpha',
          'rep-002-bravo',
        ]);

        final boundsOnly = WebReportQueryEngine.execute(
          dataset: dataset,
          filter: const WebReportFilter(onlyInMapBounds: true),
          mapBounds: const GeoBoundsBox(
            north: 14.83,
            south: 14.81,
            east: 120.97,
            west: 120.95,
          ),
          now: now,
        );
        expect(boundsOnly.items.map((e) => e.docId).toList(), [
          'rep-001-alpha',
          'rep-002-bravo',
        ]);
      },
    );

    test(
      'flags Nearest sort without reference location instead of faking distance',
      () {
        final dataset = _sampleReports();
        final noLoc = WebReportQueryEngine.execute(
          dataset: dataset,
          filter: const WebReportFilter(sort: WebReportSort.nearest),
        );
        expect(noLoc.nearestRequestedWithoutLocation, isTrue);

        final withLoc = WebReportQueryEngine.execute(
          dataset: dataset,
          filter: const WebReportFilter(sort: WebReportSort.nearest),
          referencePoint: const LatLng(14.8050, 120.9710),
        );
        expect(withLoc.nearestRequestedWithoutLocation, isFalse);
        expect(withLoc.items.first.docId, 'rep-004-delta');
      },
    );

    test(
      'searchSuggestions matches doc ID, barangay abbreviation, defect & DPWH code',
      () {
        final dataset = _sampleReports();

        final byId = WebReportQueryEngine.searchSuggestions(
          dataset: dataset,
          query: 'rep-002',
        );
        expect(byId.first.item.docId, 'rep-002-bravo');

        final byBrgy = WebReportQueryEngine.searchSuggestions(
          dataset: dataset,
          query: 'Sta. Cruz',
        );
        expect(byBrgy.first.item.docId, 'rep-003-charlie');

        final byCode = WebReportQueryEngine.searchSuggestions(
          dataset: dataset,
          query: 'CODE 02',
        );
        expect(byCode.first.item.docId, 'rep-002-bravo');
      },
    );

    test('WebUrlState parses and serializes hashes without PII', () {
      const state = WebUrlState(
        route: WebShellRoute.map,
        selectedReportId: 'rep-001',
        lat: 14.81920,
        lng: 120.95650,
        zoom: 16.5,
      );
      final hash = state.toHash();
      expect(hash, '#/map?report=rep-001&lat=14.81920&lng=120.95650&z=16.5');

      final parsed = WebUrlState.parseHash(hash);
      expect(parsed.route, WebShellRoute.map);
      expect(parsed.selectedReportId, 'rep-001');
      expect(parsed.lat, closeTo(14.8192, 0.0001));
      expect(parsed.lng, closeTo(120.9565, 0.0001));
      expect(parsed.zoom, closeTo(16.5, 0.05));

      expect(WebUrlState.parseHash('#/reports').route, WebShellRoute.reports);
      expect(WebUrlState.parseHash('#/account').route, WebShellRoute.account);
    });
  });

  group('Responsive web UI & accessibility widget tests', () {
    Future<void> pumpSized(
      WidgetTester tester,
      Size size,
      Widget child, {
      Brightness brightness = Brightness.light,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: WebDesign.buildTheme(isDark: brightness == Brightness.dark),
          home: Scaffold(body: child),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'WebAppShellHeader renders without overflow at 1440px, 1024px, 768px, 390px',
      (tester) async {
        WebShellRoute selected = WebShellRoute.map;
        for (final viewport in const [
          Size(1440, 900),
          Size(1024, 768),
          Size(768, 1024),
          Size(390, 844),
        ]) {
          await pumpSized(
            tester,
            viewport,
            WebAppShellHeader(
              activeRoute: selected,
              myReportsCount: 4,
              displayName: 'Maria Santos',
              roleLabel: 'Surveyor',
              isVerified: true,
              isLiveConnected: true,
              onSelectRoute: (r) => selected = r,
              onOpenHelp: () {},
              onOpenSettings: () {},
              onToggleTheme: () {},
              onSignOut: () {},
            ),
          );
          if (viewport.width >= 520) {
            expect(find.bySemanticsLabel('RoadSense AI logo'), findsWidgets);
          } else {
            expect(find.text('Map'), findsOneWidget);
            expect(find.text('Reports'), findsOneWidget);
          }
          expect(
            tester.takeException(),
            isNull,
            reason: 'Overflow at $viewport',
          );
        }
      },
    );

    testWidgets(
      'WebMapWorkspacePanel renders search, filters, error retry, and empty state cleanly',
      (tester) async {
        var retried = false;
        final ctrl = TextEditingController();
        final focus = FocusNode();
        addTearDown(ctrl.dispose);
        addTearDown(focus.dispose);

        // Desktop 1440px with error banner and filtered empty result
        await pumpSized(
          tester,
          const Size(1440, 900),
          SizedBox(
            width: 400,
            height: 820,
            child: WebMapWorkspacePanel(
              searchController: ctrl,
              searchFocusNode: focus,
              searchQuery: '',
              isSearchingPlaces: false,
              isSearchHistoryOpen: false,
              unifiedSuggestions: const [],
              highlightedSuggestionIndex: -1,
              searchHistory: const [],
              searchedPlace: null,
              nearbyPlaceHazardCount: 0,
              onClearSearchedPlace: () {},
              onDirectionsToPlace: (_) {},
              filter: const WebReportFilter(statuses: {'approved'}),
              onFilterChanged: (_) {},
              isFilterDrawerOpen: true,
              onToggleFilterDrawer: () {},
              onOpenBarangayPicker: () {},
              queryResult: const WebReportQueryResult(
                items: [],
                totalDatasetCount: 4,
              ),
              visibleResultLimit: 25,
              onLoadMoreResults: () {},
              selectedReport: null,
              onSelectReport: (_) {},
              onBackToResults: () {},
              currentUid: 'user-owner',
              isAdminUser: false,
              hasUserLocation: false,
              isCloudLoading: false,
              cloudError: 'Realtime cloud connection failed.',
              onRetryCloud: () => retried = true,
              onOpenRoutePlanner: () {},
              routePlannerContent: const SizedBox.shrink(),
              isRoutePlanningMode: false,
              onSearchChanged: (_) {},
              onSubmitSearch: () {},
              onClearSearch: () {},
              onSelectSuggestion: (_) {},
              onSelectHistoryItem: (_) {},
              onRemoveHistoryItem: (_) {},
              onClearHistory: () {},
              onMoveSuggestionHighlight: (_) {},
              onCenterReportOnMap: (_) {},
              onViewFullPhoto: (_) {},
            ),
          ),
        );

        expect(find.text('Retry'), findsOneWidget);
        await tester.tap(find.text('Retry'));
        await tester.pump();
        expect(retried, isTrue);

        expect(find.text('Reset filters'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'WebReportDetailPanel enforces owner-pending rules & AI confidence disclaimer',
      (tester) async {
        final reports = _sampleReports();
        final pendingOwned = reports[1]; // pending & owned by user-owner
        final approvedOther = reports[0]; // approved & owned by user-a
        final rejectedOwned = reports[2]; // rejected & owned by user-owner

        await pumpSized(
          tester,
          const Size(1440, 900),
          SizedBox(
            width: 400,
            height: 820,
            child: WebReportDetailPanel(
              report: pendingOwned,
              currentUid: 'user-owner',
              isAdminUser: false,
              onBack: () {},
              onCenterOnMap: () {},
              onViewFullPhoto: () {},
              onEditReport: () {},
              onDeleteReport: () {},
            ),
          ),
        );
        expect(find.text('Directions here'), findsNothing);
        expect(find.text('Center map'), findsOneWidget);
        expect(
          find.text(
            'Confidence reflects how certain the detector is about the defect class.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Submitted by you'), findsOneWidget);
        expect(find.text('Notes'), findsNothing);
        expect(find.byType(WebSeverityBadge), findsNothing);
        expect(find.text('Edit'), findsOneWidget);
        expect(find.text('Move to Trash'), findsOneWidget);

        // Approved reports cannot be edited or trashed by owner
        await pumpSized(
          tester,
          const Size(1440, 900),
          SizedBox(
            width: 400,
            height: 820,
            child: WebReportDetailPanel(
              report: approvedOther,
              currentUid: 'user-owner',
              isAdminUser: false,
              onBack: () {},
              onCenterOnMap: () {},
              onViewFullPhoto: () {},
              onEditReport: () {},
              onDeleteReport: () {},
            ),
          ),
        );
        expect(
          find.textContaining('Verified community surveyor'),
          findsOneWidget,
        );
        expect(find.text('Edit'), findsNothing);
        expect(find.text('Move to Trash'), findsNothing);

        // Rejected owned report shows rejection reason and hides Edit/Move to Trash
        await pumpSized(
          tester,
          const Size(390, 844),
          SizedBox(
            width: 390,
            height: 760,
            child: WebReportDetailPanel(
              report: rejectedOwned,
              currentUid: 'user-owner',
              isAdminUser: false,
              onBack: () {},
              onCenterOnMap: () {},
              onViewFullPhoto: () {},
              onEditReport: () {},
              onDeleteReport: () {},
            ),
          ),
        );
        expect(find.textContaining('casting shadow'), findsOneWidget);
        expect(find.text('Edit'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'SantaMariaBarangayPickerDialog filters & selects from 24 barangays at 390px',
      (tester) async {
        await pumpSized(
          tester,
          const Size(390, 844),
          const SantaMariaBarangayPickerDialog(initialSelection: {}),
        );
        expect(find.text('Barangay Bulac'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Guyong');
        await tester.pumpAndSettle();
        expect(find.text('Barangay Guyong'), findsOneWidget);
        await tester.tap(find.text('Barangay Guyong'));
        await tester.pumpAndSettle();
        expect(find.text('Apply (1)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'WebSettingsDialog, WebHelpDialog, and WebMapLegendCard fit mobile & desktop viewports',
      (tester) async {
        for (final viewport in const [Size(1440, 900), Size(390, 844)]) {
          await pumpSized(tester, viewport, const WebSettingsDialog());
          expect(tester.takeException(), isNull);

          await pumpSized(tester, viewport, const WebHelpDialog());
          expect(tester.takeException(), isNull);

          await pumpSized(tester, viewport, const WebMapLegendCard());
          expect(tester.takeException(), isNull);
        }
      },
    );
  });
}
