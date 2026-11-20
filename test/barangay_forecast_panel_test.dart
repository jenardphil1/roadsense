import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/barangay_forecast_panel.dart';

void main() {
  test('registry covers 24 unique barangays and historical spellings', () {
    expect(santaMariaBarangays.map(barangayKey).toSet(), hasLength(24));
    expect(barangayKey('Brgy. Sta. Cruz'), barangayKey('Santa Cruz'));
    expect(barangayKey('Magasawang Sapa'), barangayKey('Mag-asawang Sapa'));
    expect(barangayKey('Camangayanan'), barangayKey('Camangyanan'));
  });
  testWidgets('empty history remains visible and search/reset works', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: BarangayForecastPanel(reports: [])))));
    expect(find.text('24 barangays shown'), findsOneWidget);
    expect(find.textContaining('0 of 24'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Sta. Cruz');
    await tester.pump();
    expect(find.text('1 barangays shown'), findsOneWidget);
    expect(find.text('Santa Cruz'), findsOneWidget);
    expect(find.textContaining('Insufficient history.'), findsOneWidget);
    await tester.tap(find.text('Reset filters'));
    await tester.pump();
    expect(find.text('24 barangays shown'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
