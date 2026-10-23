import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// The canonical push/inbox deep-link mapping lives with the inbox screen. It is
// a pure function with no widget dependency, and reusing it here (rather than a
// second copy) is what keeps a tapped push and an inbox row landing on the same
// screen — the one thing that must never diverge.
import '../../features/user/user_notifications_screen.dart';
import '../config/env.dart';

/// Background entry point. A NOTIFICATION-payload push (everything this app
/// sends) is displayed by the OS without any Dart code, in both the background
/// and the killed state — so this handler deliberately does nothing with the
/// message. It exists so a future data-only push has a defined entry point, and
/// because `FirebaseMessaging.onBackgroundMessage` requires a top-level
/// function. It must not touch plugins or UI: it runs in a short-lived
/// background isolate with no Flutter bindings.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

/// The one Android channel every Aliob push is posted to. Created once on the
/// client; the sender edge function references the same id so a push is never
/// dropped into an unnamed default channel (which users can silence
/// independently and which looks unfinished).
const AndroidNotificationChannel kAliobNotificationChannel =
    AndroidNotificationChannel(
  'aliob_updates',
  'Aliob updates',
  description: 'Orders, rides, payments and account updates.',
  importance: Importance.high,
);

/// Client half of push notifications: Firebase Cloud Messaging transport only.
///
/// ## What this is, and is not
///
/// There is NO Firestore and NO Cloud Function here. Firebase is used purely
/// as the delivery pipe. Every notification this app produces is already
/// written to the `notifications` table by the server (see
/// `20261015000001_every_notification_also_leaves_as_a_push.sql`); the server
/// then fans a push out over FCM via an Edge Function. This class is only the
/// device side of that pipe:
///
///   * obtain and PERSIST the device token into `fcm_tokens` (which the sender
///     reads), refresh it when FCM rotates it, and remove it on sign-out;
///   * ask for the Android 13+ notification permission;
///   * create the shared notification channel;
///   * display a foreground push (background/killed pushes are shown by the OS)
///     and turn a tap — foreground, background, or cold-start — into the same
///     deep link the in-app inbox uses.
///
/// ## Build-safety
///
/// Firebase is initialized with EXPLICIT `FirebaseOptions` from `--dart-define`
/// (`Env.firebaseConfigured`), never from a google-services.json. If those
/// values are absent, `initialize()` returns early and push stays off — the app
/// builds and runs exactly as before. This is why the project carries no
/// google-services Gradle plugin: a build before the Firebase config exists
/// must still succeed.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// The last token this device registered, kept so sign-out can delete the
  /// matching `fcm_tokens` row without a second round trip to fetch it.
  String? _token;

  /// Set once by the app shell (the only place that owns the [GoRouter]) so a
  /// tapped push can navigate. Injected rather than reached for globally, so
  /// this service stays testable and free of a router singleton.
  GoRouter? _router;

  /// A deep link that arrived before the router existed (a push that cold-started
  /// the app). Held until [attachRouter] drains it.
  String? _pendingPath;

  /// Wire the router in and immediately service any deep link that was waiting
  /// for it. Called from the app shell on build; idempotent.
  void attachRouter(GoRouter router) {
    _router = router;
    final pending = _pendingPath;
    if (pending != null) {
      _pendingPath = null;
      _navigate(pending);
    }
  }

  /// Bring up Firebase, the channel, the permission prompt and the handlers.
  /// Safe to call more than once; a no-op when Firebase is not configured.
  /// Never throws: push is an enhancement, and a failure here must not stop the
  /// app from starting.
  Future<void> initialize() async {
    if (_initialized) return;
    if (!Env.firebaseConfigured) {
      debugPrint(
          'NotificationService: Firebase not configured via --dart-define; push stays off.');
      return;
    }

    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: Env.firebaseApiKey,
          appId: Env.firebaseAppId,
          messagingSenderId: Env.firebaseMessagingSenderId,
          projectId: Env.firebaseProjectId,
        ),
      );
    } catch (e) {
      debugPrint('NotificationService: Firebase.initializeApp failed: $e');
      return;
    }

    // Register the background entry point now that Firebase exists.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Channel + foreground-tap routing. A local-notifications failure only
    // means we cannot DRAW a foreground push ourselves; the OS still shows
    // background/killed pushes and taps still deep-link.
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      );
      await _local.initialize(
        settings,
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload == null) return;
          try {
            _openFromData(
                Map<String, dynamic>.from(jsonDecode(payload) as Map));
          } catch (_) {}
        },
      );
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(kAliobNotificationChannel);
    } catch (e) {
      debugPrint('NotificationService: local-notification setup failed: $e');
    }

    _initialized = true;

    // Android 13+ runtime permission (and iOS prompt). Best-effort: a decline
    // leaves in-app notifications working, push simply does not appear.
    try {
      await FirebaseMessaging.instance.requestPermission();
    } catch (e) {
      debugPrint('NotificationService: requestPermission failed: $e');
    }

    // FOREGROUND: the OS does not draw these, so show them ourselves on the
    // shared channel, carrying the data payload for the tap deep link.
    FirebaseMessaging.onMessage.listen((message) async {
      final notification = message.notification;
      if (notification == null) return;
      try {
        await _local.show(
          message.hashCode,
          notification.title ?? 'Aliob',
          notification.body ?? '',
          // Not `const`: reading `.id`/`.name` off the const channel is not a
          // constant expression, and re-spelling the strings here would let
          // the channel this push is posted to drift from the one the client
          // creates. The channel const stays the single source of truth.
          NotificationDetails(
            android: AndroidNotificationDetails(
              kAliobNotificationChannel.id,
              kAliobNotificationChannel.name,
              channelDescription: kAliobNotificationChannel.description,
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
            ),
            iOS: DarwinNotificationDetails(),
          ),
          payload: jsonEncode(message.data),
        );
      } catch (e) {
        debugPrint('NotificationService: foreground show failed: $e');
      }
    });

    // BACKGROUND tap (app alive in the tray, user opens it from the push).
    FirebaseMessaging.onMessageOpenedApp
        .listen((message) => _openFromData(_asDataMap(message.data)));

    // FCM rotated this device's token — keep the stored one current so pushes
    // keep arriving and the stale row can be reaped by the sender.
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      _token = token;
      unawaited(_upsertToken(token));
    });

    // COLD-START tap (app was killed; the push launched it). The router may not
    // exist yet, so _openFromData parks the path until attachRouter drains it.
    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _openFromData(_asDataMap(initial.data));
    } catch (_) {}

    // If a user is already signed in when the app starts, register at once.
    if (Supabase.instance.client.auth.currentUser != null) {
      unawaited(registerToken());
    }
  }

  /// Fetch this device's FCM token, persist it into `fcm_tokens` (the table the
  /// sender reads), and join the broadcast topic. Called after sign-in. Best
  /// effort and idempotent — an upsert keyed on (user_id, token).
  Future<void> registerToken() async {
    if (!_initialized) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      _token = token;
      await _upsertToken(token);
      // Broadcast topic: lets an admin announcement target every device in one
      // send. Best-effort — a topic failure must not block sign-in.
      await FirebaseMessaging.instance.subscribeToTopic('all_users');
    } catch (e) {
      debugPrint('NotificationService: registerToken failed: $e');
    }
  }

  /// Sign-out / dead-session cleanup: delete this device's `fcm_tokens` row (so
  /// the sender stops addressing it), drop the local FCM token, and leave the
  /// topic. Must run while the user is STILL signed in to remove the server row;
  /// when the session is already gone it still clears the local token. Best
  /// effort — the sender reaps a token FCM reports as unregistered regardless.
  Future<void> removeToken() async {
    if (!_initialized) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    final token = _token;
    try {
      if (uid != null && token != null) {
        await Supabase.instance.client
            .from('fcm_tokens')
            .delete()
            .eq('user_id', uid)
            .eq('token', token);
      }
      await FirebaseMessaging.instance.unsubscribeFromTopic('all_users');
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('NotificationService: removeToken failed: $e');
    }
    _token = null;
  }

  // ── internals ────────────────────────────────────────────────────────────

  Future<void> _upsertToken(String token) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    await Supabase.instance.client.from('fcm_tokens').upsert(
      {
        'user_id': uid,
        'token': token,
        'device_type':
            defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
        'is_active': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'user_id,token',
    );
  }

  Map<String, dynamic> _asDataMap(Map<String, dynamic> data) => data;

  /// Resolve a push payload to a route using the SAME mapper the inbox uses,
  /// then navigate — now if the router is up, else park it until it is.
  void _openFromData(Map<String, dynamic> data) {
    final path = notificationTargetPath({'data': data});
    if (path == null) return;
    if (_router != null) {
      _navigate(path);
    } else {
      _pendingPath = path;
    }
  }

  void _navigate(String path) {
    try {
      _router?.push(path);
    } catch (e) {
      debugPrint('NotificationService: deep-link navigation failed: $e');
    }
  }
}
