import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/lgu_forecast.dart';

void main() {
  DateTime week(int weeksAgo, [int dayOffset = 0]) =>
      DateTime(2025, 1, 6 + dayOffset).subtract(Duration(days: weeksAgo * 7));
  // Anchor "now": the week() helper places samples inside the 8-week window.
  final now = DateTime(2025, 1, 6);

  ForecastSample s(
    double lat,
    double lng, {
    DateTime? date,
    String severity = 'medium',
    String city = 'Malolos',
    String barangay = 'Bagna',
  }) =>
      ForecastSample(
        date: date ?? week(0),
        lat: lat,
        lng: lng,
        severity: severity,
        city: city,
        barangay: barangay,
      );

  test('growing trend is rising with a positive 30-day projection', () {
    final samples = <ForecastSample>[];
    for (var w = 0; w < 8; w++) {
      for (var i = 0; i < 1 + w; i++) {
        samples.add(s(14.85, 120.81, date: week(7 - w)));
      }
    }
    final f = LguForecast.compute(samples, now: now).single;
    expect(f.trend, 'rising');
    expect(f.predicted30, greaterThan(8));
    expect(f.risk, anyOf('high', 'medium'));
    expect(f.confidence, 1.0);
  });

  test('declining trend and zero-data exclusion', () {
    final samples = <ForecastSample>[];
    for (var w = 0; w < 8; w++) {
      for (var i = 0; i < 8 - w; i++) {
        samples.add(s(14.85, 120.81, date: week(7 - w)));
      }
    }
    final f = LguForecast.compute(samples, now: now).single;
    expect(f.trend, 'declining');

    expect(LguForecast.compute([s(14.85, 120.81, date: DateTime(2019))],
        now: now), isEmpty);
  });

  test('hotspot grid groups nearby points and returns cell centers', () {
    final zones = LguForecast.hotspots([
      s(14.8505, 120.8105, date: week(1)),
      s(14.8507, 120.8107, date: week(0)),
      s(14.8506, 120.8106,
          date: week(0), severity: 'high', barangay: 'Matimbo'),
    ], now: now);
    expect(zones, hasLength(1));
    expect(zones.single.count, 3);
    expect(zones.single.highCount, 1);
    expect((zones.single.lat - 14.8506).abs(), lessThan(0.002));
  });

  test('normalizeName matches Firestore LGU strings to canonical names', () {
    expect(LguForecast.normalizeName('Brgy. Sta. Clara'), 'santa clara');
    expect(LguForecast.normalizeName('Barangay Cay Pombo'), 'cay pombo');
    expect(LguForecast.normalizeName('Santa Maria, Bulacan'),
        'santa maria bulacan');
  });
}
