import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class PotholeNotifier {
  PotholeNotifier._();

  static final PotholeNotifier instance = PotholeNotifier._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  DateTime? _lastShownAt;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  Future<void> showPotholeAlert(String distanceText) async {
    final AppLifecycleState? state =
        WidgetsBinding.instance.lifecycleState;
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    final DateTime now = DateTime.now();
    if (_lastShownAt != null &&
        now.difference(_lastShownAt!) < const Duration(seconds: 15)) {
      return;
    }
    try {
      await _ensureInitialized();
      await _plugin.show(
        1,
        'Pothole Warning',
        '$distanceText ahead - slow down',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'pothole_alerts',
            'Pothole Alerts',
            channelDescription: 'Background pothole proximity warnings',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),        ),
      );
      _lastShownAt = now;
    } catch (_) {}
  }
}
