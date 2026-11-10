import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'reminders.dart';

/// Local notifications (flutter_local_notifications) for the reminders. The
/// app does not run in the background: reminders only fire while it is open.
///
/// Every call is best effort: a missing permission or plugin (tests, desktop)
/// only logs, it never breaks the sensor stream.
class AppNotifications implements ReminderNotifier {
  AppNotifications({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;
  bool _asked = false;

  static const _ids = {ReminderKind.move: 10, ReminderKind.wakeUp: 11};
  static const _remindersChannel = AndroidNotificationDetails(
    'pdiot_reminders',
    'Reminders',
    channelDescription: 'Move reminders and the wake-up alarm',
    importance: Importance.high,
    priority: Priority.high,
  );

  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> init() async {
    if (!_supported || _ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // Ask when the user first connects (see [requestPermission]).
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestSoundPermission: false,
            requestBadgePermission: false,
          ),
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  /// Asks once per app start (Android 13+ and iOS show a system prompt the
  /// first time only).
  Future<void> requestPermission() async {
    if (!_ready || _asked) return;
    _asked = true;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true, badge: false);
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
  }

  @override
  Future<void> notify(ReminderKind kind, String title, String body) async {
    if (!_ready) return;
    await _plugin.show(
      id: _ids[kind]!,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: _remindersChannel,
        iOS: DarwinNotificationDetails(presentSound: true),
      ),
    );
  }
}
