// Stub file so flutter_compass compiles on web.
// Web has no compass hardware — this provides no-op types.

class CompassEvent {
  final double? heading;
  CompassEvent({this.heading});
}

class FlutterCompass {
  static Stream<CompassEvent>? get events => null;
}
