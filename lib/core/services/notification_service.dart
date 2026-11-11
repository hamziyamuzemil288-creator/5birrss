import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter/services.dart';
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

/// The Android channels this app owns.
///
/// One channel for everything was the original bug: Android 8+ gives each
/// channel its own importance and sound settings, so putting orders, rides,
/// promotions and security into one channel meant a user could not silence
/// promotions without also silencing a delivery arriving. These ids are also
/// written into the `n8n_events` payload by
/// `20261111000002_notification_delivery_hardening.sql`, and fcm-dispatch
/// posts to the same id, so the server and the client never disagree.
const AndroidNotificationChannel kAliobOrderChannel = AndroidNotificationChannel(
  'aliob_orders',
  'Orders and checkout',
  description: 'Order updates, checkout approval and delivery decisions.',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

const AndroidNotificationChannel kAliobRideChannel = AndroidNotificationChannel(
  'aliob_rides',
  'Rides and delivery',
  description: 'Ride requests, driver assignment and delivery progress.',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

const AndroidNotificationChannel kAliobPaymentChannel =
    AndroidNotificationChannel(
  'aliob_payments',
  'Payments and wallet',
  description: 'Payment verification, wallet credit and subscription charges.',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

const AndroidNotificationChannel kAliobAccountChannel =
    AndroidNotificationChannel(
  'aliob_account',
  'Account and security',
  description: 'Account decisions, security notices and profile changes.',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

const AndroidNotificationChannel kAliobMessageChannel =
    AndroidNotificationChannel(
  'aliob_messages',
  'General updates',
  description: 'Messages from Aliob that are not an order or a payment.',
  importance: Importance.defaultImportance,
  playSound: true,
  enableVibration: true,
);

const AndroidNotificationChannel kAliobPromotionChannel =
    AndroidNotificationChannel(
  'aliob_promotions',
  'Promotions',
  description: 'Offers and announcements. Quiet by default.',
  importance: Importance.low,
  playSound: false,
  enableVibration: false,
);

const List<AndroidNotificationChannel> kAliobNotificationChannels = [
  kAliobOrderChannel,
  kAliobRideChannel,
  kAliobPaymentChannel,
  kAliobAccountChannel,
  kAliobMessageChannel,
  kAliobPromotionChannel,
];

/// The channel a notification belongs to.
///
/// The server writes `android_channel` into the FCM data payload; when Dart is
/// running we still recompute from `type`/`event` so a foreground local
/// notification has the same channel as the background one. The order of the
/// tests matters: `delivery_assigned` is a ride/delivery event even though its
/// notification type is an ORDER type.
String notificationChannelIdFor(
  String? type,
  Map<String, dynamic> data,
) {
  final supplied = '${data['android_channel'] ?? ''}'.trim();
  if (kAliobNotificationChannels.any((c) => c.id == supplied)) return supplied;

  final event = '${data['event'] ?? ''}'.trim().toLowerCase();
  final kind = '${type ?? data['type'] ?? ''}'.trim().toLowerCase();

  if (const {
    'delivery_assigned',
    'driver_assigned',
    'driver_arriving',
    'driver_arrived',
    'delivery_started',
    'delivery_completed',
  }.contains(event)) {
    return kAliobRideChannel.id;
  }
  if (kind.contains('ride') || event.contains('ride')) {
    return kAliobRideChannel.id;
  }
  if (kind.contains('order') ||
      event.startsWith('checkout') ||
      event.contains('delivery')) {
    return kAliobOrderChannel.id;
  }
  if (kind.contains('payment') ||
      kind.contains('wallet') ||
      kind.contains('subscription') ||
      kind.contains('transaction')) {
    return kAliobPaymentChannel.id;
  }
  if (const {
    'security',
    'approval',
    'rejection',
    'correction_required',
    'registration_received',
    'provider_inactive',
    'welcome_back',
  }.contains(kind)) {
    return kAliobAccountChannel.id;
  }
  if (const {'promotion', 'promo', 'marketing', 'app_update'}.contains(event)) {
    return kAliobPromotionChannel.id;
  }
  return kAliobMessageChannel.id;
}

AndroidNotificationChannel notificationChannelFor(
  String? type,
  Map<String, dynamic> data,
) {
  final id = notificationChannelIdFor(type, data);
  return kAliobNotificationChannels.firstWhere(
    (channel) => channel.id == id,
    orElse: () => kAliobMessageChannel,
  );
}

/// Android 13+ permission state, plus whether this build can push at all and
/// whether this device has a registration token.
class NotificationReadiness {
  const NotificationReadiness({
    required this.firebaseConfigured,
    required this.localReady,
    required this.permission,
    required this.notificationsEnabled,
    required this.hasToken,
    this.authorizationStatus,
  });

  final bool firebaseConfigured;
  final bool localReady;
  final bool permission;
  final bool notificationsEnabled;
  final bool hasToken;
  final AuthorizationStatus? authorizationStatus;

  /// Asked but refused, or switched off in system settings.
  bool get denied =>
      authorizationStatus == AuthorizationStatus.denied ||
      (firebaseConfigured && !notificationsEnabled);

  bool get ready =>
      firebaseConfigured && permission && notificationsEnabled && hasToken;
}

/// Client half of push notifications: Firebase Cloud Messaging transport only.
///
/// ## What this is, and is not
///
/// There is NO Firestore and NO Cloud Function here. Firebase is used purely
/// as the delivery pipe. Every notification this app produces is already
/// written to the `notifications` table by the server; the server then fans a
/// push out over FCM via an Edge Function. This class is only the device side
/// of that pipe:
///
///   * obtain and PERSIST the device token into `fcm_tokens` (which the sender
///     reads), refresh it when FCM rotates it, and remove it on sign-out;
///   * create the Android channels and the monochrome small icon;
///   * ask for the Android 13+ permission when the caller has a reason to;
///   * display a foreground push (background/killed pushes are shown by the OS)
///     and turn a tap — foreground, background, or cold-start — into the same
///     deep link the in-app inbox uses.
///
/// ## Build-safety
///
/// Firebase is initialized with EXPLICIT `FirebaseOptions` from `--dart-define`
/// (`Env.firebaseConfigured`), never from a google-services.json. If those
/// values are absent, `initialize()` returns early and push stays off — the app
/// builds and runs exactly as before.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const MethodChannel _settingsChannel =
      MethodChannel('aliob/notifications');

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  bool _localReady = false;
  bool _firebaseReady = false;
  bool get isInitialized => _firebaseReady;

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

  /// Bring up the channels, Firebase and the handlers. Safe to call more than
  /// once; a no-op when Firebase is not configured. Never throws: push is an
  /// enhancement, and a failure here must not stop the app from starting.
  ///
  /// It deliberately does NOT ask for permission. The Android 13 prompt is
  /// requested at the moment the user does something that needs it (first
  /// order, provider/driver sign-in, or the test button), with an explanation
  /// first. A launch-time wall is the pattern users reflexively deny.
  Future<void> initialize() async {
    if (_localReady && _firebaseReady) return;

    await _initializeLocalNotifications();
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

    _firebaseReady = true;

    // Register the background entry point now that Firebase exists. Background
    // and killed notification-payload pushes are drawn by the OS; this handler
    // is the defined entry point for a future data-only message.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // FOREGROUND: the OS does not draw these, so show them ourselves on the
    // channel carried by the payload.
    FirebaseMessaging.onMessage.listen(_showForeground);

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

    // If a user — including an anonymous guest buyer — is already signed in
    // when the app starts, register at once.
    if (Supabase.instance.client.auth.currentSession != null) {
      unawaited(registerToken());
    }
  }

  Future<void> _initializeLocalNotifications() async {
    if (_localReady) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_aliob'),
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
      final android = _local.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final channel in kAliobNotificationChannels) {
        await android?.createNotificationChannel(channel);
      }
      _localReady = true;
    } catch (e) {
      debugPrint('NotificationService: local-notification setup failed: $e');
    }
  }

  /// Ask for permission only when the caller has a reason. Returns true when
  /// notifications are allowed afterwards.
  Future<bool> requestPermission() async {
    if (!_firebaseReady) return false;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('NotificationService: requestPermission failed: $e');
      return false;
    }
  }

  /// What is blocking delivery, if anything, for the settings screen.
  Future<NotificationReadiness> readiness() async {
    if (!_localReady) await _initializeLocalNotifications();

    bool enabled = false;
    try {
      enabled = await _local
              .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin>()
              ?.areNotificationsEnabled() ??
          false;
    } catch (_) {
      enabled = false;
    }

    if (!_firebaseReady) {
      return NotificationReadiness(
        firebaseConfigured: Env.firebaseConfigured,
        localReady: _localReady,
        permission: false,
        notificationsEnabled: enabled,
        hasToken: false,
      );
    }

    AuthorizationStatus? status;
    bool permission = false;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      status = settings.authorizationStatus;
      permission = status == AuthorizationStatus.authorized ||
          status == AuthorizationStatus.provisional;
    } catch (_) {
      permission = false;
    }

    String? token;
    try {
      token = await FirebaseMessaging.instance.getToken();
    } catch (_) {
      token = null;
    }
    _token = token ?? _token;

    return NotificationReadiness(
      firebaseConfigured: true,
      localReady: _localReady,
      permission: permission,
      notificationsEnabled: enabled,
      hasToken: token != null && token.isNotEmpty,
      authorizationStatus: status,
    );
  }

  /// The system notification/app settings screen. Android-only method supplied
  /// by MainActivity, so no extra permission plugin is required.
  Future<void> openSystemSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _settingsChannel.invokeMethod<void>('openNotificationSettings');
    } catch (e) {
      debugPrint('NotificationService: openSystemSettings failed: $e');
    }
  }

  /// One real notification for THIS user: the inbox row and the FCM push are
  /// produced by the same server path as every other notification.
  Future<Map<String, dynamic>> sendTestNotification() async {
    final response = await Supabase.instance.client.functions
        .invoke('notification-test', body: const {});
    final data = response.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {'ok': false, 'active_tokens': 0, 'tray_expected': false};
  }

  /// Fetch this device's FCM token, persist it into `fcm_tokens` (the table the
  /// sender reads), and join the broadcast topic.
  ///
  /// This works for a signed-in account AND for an anonymous guest session:
  /// the row is scoped by `auth.uid()`, and an anonymous buyer has a real
  /// auth.uid(). Called after sign-in, after the guest session opens, and at
  /// startup when a session was restored.
  Future<void> registerToken() async {
    if (!_firebaseReady) return;
    try {
      await _registerCurrentToken();
    } catch (e) {
      debugPrint('NotificationService: registerToken failed: $e');
    }
  }

  /// Make this device addressable before a sign-in welcome is requested.
  ///
  /// The welcome function refuses to consume its once-per-session key when
  /// push is on but the account has no token: writing the inbox row then would
  /// be the exact "in the inbox, never in the tray" failure the notification
  /// brief warns about. This method gives FCM a short, bounded chance to
  /// produce a token first.
  ///
  /// It asks for the Android 13+ permission only when the OS has never been
  /// asked (`notDetermined`). A refusal is remembered by the OS and is never
  /// re-prompted here; the inbox fallback still runs. Safe to call more than
  /// once, and never throws.
  Future<bool> prepareForSignIn() async {
    try {
      await initialize();
      if (!_firebaseReady) return false;

      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      if (settings.authorizationStatus == AuthorizationStatus.notDetermined) {
        await requestPermission();
      }

      for (var attempt = 0; attempt < 3; attempt++) {
        if (await _registerCurrentToken()) return true;
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 500 * (attempt + 1)),
          );
        }
      }
    } catch (e) {
      debugPrint('NotificationService: prepareForSignIn failed: $e');
    }
    return false;
  }

  Future<bool> _registerCurrentToken() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) return false;
    _token = token;
    await _upsertToken(token);
    // Broadcast topic: lets an admin announcement target every device in one
    // send. Best-effort — a topic failure must not block sign-in.
    await FirebaseMessaging.instance.subscribeToTopic('all_users');
    return true;
  }

  /// Sign-out / dead-session cleanup: delete this device's `fcm_tokens` row (so
  /// the sender stops addressing it), drop the local FCM token, and leave the
  /// topic. Must run while the user is STILL signed in to remove the server row;
  /// when the session is already gone it still clears the local token. Best
  /// effort — the sender reaps a token FCM reports as unregistered regardless.
  Future<void> removeToken() async {
    if (!_firebaseReady) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    var token = _token;
    try {
      // A logout can happen before registerToken() ever completed (for
      // example right after a guest opens checkout and backs out), so read the
      // token again rather than leave the row alive because _token was null.
      token ??= await FirebaseMessaging.instance.getToken();
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

  /// The exact row stored for a token. Public and pure so the guest/buyer
  /// invariant can be tested without Firebase or a live database.
  static Map<String, dynamic> tokenRowFor({
    required String userId,
    required String token,
    String deviceType = 'android',
  }) {
    return {
      'user_id': userId,
      'token': token,
      'device_type': deviceType,
      'is_active': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  // ── internals ────────────────────────────────────────────────────────────

  Future<void> _upsertToken(String token) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    await Supabase.instance.client.from('fcm_tokens').upsert(
      tokenRowFor(
        userId: uid,
        token: token,
        deviceType:
            defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      ),
      onConflict: 'user_id,token',
    );
  }

  Future<void> _showForeground(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    final data = _asDataMap(message.data);
    final channel = notificationChannelFor('${data['type'] ?? ''}', data);
    try {
      await _local.show(
        message.messageId?.hashCode ??
            DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
        notification.title ?? 'Aliob',
        notification.body ?? '',
        NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            importance: channel.importance,
            priority: channel.importance == Importance.low
                ? Priority.low
                : Priority.high,
            icon: 'ic_stat_aliob',
            color: const Color(0xFF1B5E20),
            playSound: channel.playSound,
            enableVibration: channel.enableVibration,
            styleInformation: BigTextStyleInformation(
              notification.body ?? '',
            ),
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        payload: jsonEncode(data),
      );
    } catch (e) {
      debugPrint('NotificationService: foreground show failed: $e');
    }
  }

  Map<String, dynamic> _asDataMap(Map<String, dynamic> data) => data;

  /// Resolve a push payload to a route using the SAME mapper the inbox uses,
  /// then navigate — now if the router is up, else park it until it is.
  void _openFromData(Map<String, dynamic> data) {
    final path = notificationTargetPath(
      {'data': data},
      viewerRole: '${data['recipient_role'] ?? 'user'}',
    );
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
