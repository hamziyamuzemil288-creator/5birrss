import 'package:flutter/foundation.dart' show kDebugMode, debugPrint, debugPrintStack;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_service.dart';

/// The one auth event that means a person has just signed in.
///
/// `initialSession` is a cold-start restore, `tokenRefreshed` is the same
/// session getting a new access token, and `signedOut` is the opposite. None of
/// them is a sign-in. Keeping the answer here (rather than an `== signedIn`
/// buried in the auth listener) is what the tests can pin down.
bool isWelcomeBackSignInEvent(AuthChangeEvent event) =>
    event == AuthChangeEvent.signedIn;

enum WelcomeBackStatus {
  /// The server wrote the inbox row and, when a token existed, queued the push.
  sent,

  /// This exact session already produced a welcome. A retry is a no-op.
  alreadySent,

  /// A real sign-in inside the five-minute gap. Deliberately quiet.
  throttled,

  /// The account has push switched off. The inbox row was still written.
  pushDisabled,

  /// A guest, a brand-new account, or a session without an id. Not an error.
  skipped,

  /// The device token is still being registered. Try again shortly.
  retry,

  /// The call failed. The sign-in itself still succeeded.
  failed,
}

/// Turn the server's status string into a client disposition.
///
/// The server is the source of truth; this function only decides whether to
/// stop or retry. Unknown strings fail closed (no retry loop), because an
/// unrecognised answer is not evidence that waiting will help.
WelcomeBackStatus welcomeBackStatusFor(String status) {
  switch (status.trim().toLowerCase()) {
    case 'sent':
      return WelcomeBackStatus.sent;
    case 'already_sent':
      return WelcomeBackStatus.alreadySent;
    case 'throttled':
      return WelcomeBackStatus.throttled;
    case 'push_disabled':
      return WelcomeBackStatus.pushDisabled;
    case 'guest':
    case 'new_account':
    case 'no_session':
    case 'no_profile':
    case 'signed_out':
      return WelcomeBackStatus.skipped;
    case 'waiting_for_token':
      return WelcomeBackStatus.retry;
    default:
      return WelcomeBackStatus.failed;
  }
}

class WelcomeBackOutcome {
  const WelcomeBackOutcome({
    required this.status,
    this.trayExpected = false,
    this.serverStatus = '',
  });

  final WelcomeBackStatus status;
  final bool trayExpected;
  final String serverStatus;

  bool get isSuccessful =>
      status == WelcomeBackStatus.sent ||
      status == WelcomeBackStatus.alreadySent ||
      status == WelcomeBackStatus.throttled ||
      status == WelcomeBackStatus.pushDisabled ||
      status == WelcomeBackStatus.skipped;
}

typedef WelcomeBackRpc = Future<Map<String, dynamic>> Function(
  bool allowInboxOnly,
);
typedef WelcomeBackTokenPreparer = Future<bool> Function();
typedef WelcomeBackDelay = Future<void> Function(Duration duration);

/// Delivers the "Welcome back" notification once, after an explicit sign-in.
///
/// ## Why the client calls this instead of inserting a notification
///
/// A client cannot write `notifications` (the injection guard refuses it), and
/// a client that could address any user would be a notification gun. The Edge
/// Function it calls takes no recipient: the service-role SQL half receives
/// the id from the verified JWT, never from the request body, and deduplicates
/// on that JWT's `session_id`.
///
/// ## What the retry is for
///
/// Firebase registration is asynchronous and can finish a second or two after
/// the session exists. The server refuses to write a welcome it cannot push
/// (unless the final inbox-only fallback is explicitly allowed), so a short
/// retry converts that ordinary race into a delivered tray notification. If the
/// token never arrives — permission denied, Firebase unconfigured, a device
/// with no Play Services — the last attempt still puts the message in the
/// inbox with `p_allow_inbox_only`, rather than dropping it entirely.
class WelcomeBackService {
  WelcomeBackService({
    WelcomeBackRpc? rpc,
    WelcomeBackTokenPreparer? prepareToken,
    WelcomeBackDelay? delay,
  })  : _rpc = rpc ?? _callRpc,
        _prepareToken = prepareToken ??
            (() => NotificationService.instance.prepareForSignIn()),
        _delay = delay ?? _wait;

  static final WelcomeBackService instance = WelcomeBackService();

  final WelcomeBackRpc _rpc;
  final WelcomeBackTokenPreparer _prepareToken;
  final WelcomeBackDelay _delay;

  static Future<void> _wait(Duration duration) => Future<void>.delayed(duration);

  static Future<Map<String, dynamic>> _callRpc(bool allowInboxOnly) async {
    // The Edge Function verifies the caller's own JWT and runs the service-role
    // SQL path, so the notification is immediate. Calling the client-callable
    // wrapper instead would queue it for the once-a-minute outbox drain.
    final response = await Supabase.instance.client.functions.invoke(
      'signin-welcome',
      body: {'allow_inbox_only': allowInboxOnly},
    );
    final data = response.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return const <String, dynamic>{'ok': false, 'status': 'failed'};
  }

  /// Call only from an explicit `AuthChangeEvent.signedIn` branch.
  ///
  /// The caller may fire-and-forget this; it never throws. [tokenAttempts] is
  /// the number of normal (token-required) attempts before the inbox-only
  /// fallback, so the default costs at most ~8 seconds of background work.
  Future<WelcomeBackOutcome> deliverAfterSignIn({
    int tokenAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
  }) async {
    for (var attempt = 0; attempt < tokenAttempts; attempt++) {
      try {
        await _prepareToken();
      } catch (e, st) {
        _log('token preparation', e, st);
      }

      try {
        final outcome = _outcome(await _rpc(false));
        if (outcome.status != WelcomeBackStatus.retry) return outcome;
      } catch (e, st) {
        _log('signin-welcome', e, st);
      }

      if (attempt < tokenAttempts - 1) {
        await _delay(retryDelay);
      }
    }

    // The token never became ready (or every attempt failed). One inbox-only
    // call is better than silence, and the server records it so a later retry
    // in the same session cannot duplicate it.
    try {
      return _outcome(await _rpc(true));
    } catch (e, st) {
      _log('signin-welcome (inbox only)', e, st);
      return const WelcomeBackOutcome(status: WelcomeBackStatus.failed);
    }
  }

  WelcomeBackOutcome _outcome(Map<String, dynamic> response) {
    final status = '${response['status'] ?? ''}';
    return WelcomeBackOutcome(
      status: welcomeBackStatusFor(status),
      trayExpected: response['tray_expected'] == true,
      serverStatus: status,
    );
  }

  void _log(String where, Object error, StackTrace stack) {
    if (!kDebugMode) return;
    debugPrint('welcome back skipped [$where]: $error');
    debugPrintStack(stackTrace: stack);
  }
}
