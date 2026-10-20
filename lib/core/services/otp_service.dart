import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// What the server did with an OTP request.
///
/// Three outcomes, not two, and the third is the one that used to hang the
/// registration flow:
///
///   * `delivered` — a code was emailed; the code screen is the next step.
///   * `skipped`   — the server has the OTP gate switched OFF
///     (`signup_otp_required` is false), so it deliberately sent nothing.
///     `send-otp` already says so in its own words (`skipped:
///     "email_verification_disabled"`), but this class used to collapse that
///     answer into "success" and the screen then asked the user for a six-digit
///     code that was never sent and could never arrive. The signup screen now
///     reads the difference and completes the step.
///   * neither, plus an error — a real refusal, surfaced as
///     [OtpUnavailableException] so the screen can say what happened instead of
///     blaming the user's connection.
class OtpSendResult {
  /// A code was handed to the mail provider.
  final bool delivered;

  /// The server does not require email verification, so no code exists.
  final bool skipped;

  /// The server's own reason for [skipped], for the console only.
  final String? reason;

  const OtpSendResult({
    this.delivered = false,
    this.skipped = false,
    this.reason,
  });

  /// True when there is a code in an inbox waiting to be typed.
  bool get codeSent => delivered && !skipped;
}

/// Email OTP verification (signup gate, Task 7).
///
/// Server flow (nothing is trusted client-side):
///   1. sendOtp()   -> POST /functions/v1/send-otp. The Edge Function
///      generates the code, stores only its SHA-256 hash (10-min expiry,
///      5 attempts, 60 s resend window), and sends it to the mailbox.
///   2. verifyOtp() -> rpc verify_email_otp(email, code). Consumes the code.
///   3. signUp()    -> the handle_new_user trigger refuses to create the
///      account unless a verified OTP exists for the email.
///
/// ## Why every call here is bounded
///
/// This runs inside the registration submit handler, on a screen that shows a
/// full-screen "Creating account…" scrim. A call with no deadline is not an
/// error, so nothing catches it: the scrim stays, the button stays disabled,
/// and the only way out is to kill the app. That is the shape of the reported
/// "registration hangs and never completes". A deadline turns it into a
/// sentence the user can act on.
class OtpService {
  OtpService._();
  static final OtpService instance = OtpService._();

  SupabaseClient get _client => Supabase.instance.client;

  /// How long the OTP endpoint gets before the screen reports a problem.
  static const Duration _sendTimeout = Duration(seconds: 20);

  /// How long the signup screen waits for the gate lookup before assuming ON.
  static const Duration _gateLookupTimeout = Duration(seconds: 8);

  /// Whether a new account must verify an email OTP before it can be created.
  ///
  /// The server is the only authority here: `handle_new_user()` refuses an
  /// unverified signup with EMAIL_OTP_REQUIRED, and it reads the same
  /// `signup_otp_required` setting this returns. A client that guessed wrong
  /// in either direction breaks registration — skipping the code screen
  /// while the server refuses every account, or demanding a code whose email
  /// cannot be delivered.
  ///
  /// A lookup failure (including a timeout, which is why the call is bounded)
  /// returns TRUE, i.e. fail closed: the screen asks for the code rather than
  /// silently skipping a gate the server may still enforce.
  static Future<bool> isRequiredAtSignup() async {
    try {
      return await Supabase.instance.client
              .rpc('signup_otp_required')
              .timeout(_gateLookupTimeout) ==
          true;
    } catch (_) {
      return true;
    }
  }

  /// Requests a code for [email].
  ///
  /// Returns after the server confirms what it did; see [OtpSendResult].
  /// Throws [OtpCooldownException] when the 60-second resend window is open and
  /// [OtpUnavailableException] when the endpoint refused or did not answer.
  Future<OtpSendResult> sendOtp(String email, {String? captchaId}) async {
    final FunctionResponse res;
    try {
      res = await _client.functions
          .invoke(
            'send-otp',
            body: {
              'email': email.trim().toLowerCase(),
              'captcha_id': captchaId,
            },
          )
          .timeout(_sendTimeout);
    } on TimeoutException {
      throw const OtpUnavailableException(
        'The verification service did not answer. Please try again — the '
        'details you entered are kept.',
      );
    } on FunctionException catch (e) {
      // 401/403 is the gateway refusing the CALL, not the user's network: this
      // endpoint must be reachable by a signed-out signup (that is the whole
      // point of verifying an address before the account exists). Naming it
      // is what stops "check your connection" from hiding a deployment
      // defect for months.
      if (e.status == 401 || e.status == 403) {
        throw const OtpUnavailableException(
          'Email verification is not reachable from signup right now. Please '
          'contact support — registration cannot be completed until this is '
          'fixed.',
        );
      }
      final details = e.details;
      final code = details is Map ? details['error']?.toString() : null;
      throw OtpUnavailableException(
        _sentenceFor(code ?? ''),
      );
    }
    final data = res.data as Map<String, dynamic>?;

    if (data == null) {
      throw const OtpUnavailableException(
        'The verification service did not answer. Check your connection and '
        'try again.',
      );
    }

    if (data['retry_after_seconds'] != null) {
      throw OtpCooldownException((data['retry_after_seconds'] as num).toInt());
    }
    if (data['error'] != null) {
      throw OtpUnavailableException(
        _sentenceFor(data['error'].toString()),
      );
    }

    return OtpSendResult(
      delivered: data['delivered'] == true,
      skipped: data['skipped'] != null,
      reason: data['skipped']?.toString(),
    );
  }

  /// Verifies [code] for [email]. Throws on wrong/expired/exhausted codes.
  Future<void> verifyOtp(String email, String code) async {
    final res = await _client
        .rpc(
          'verify_email_otp',
          params: {
            'p_email': email.trim().toLowerCase(),
            'p_code': code.trim(),
          },
        )
        .timeout(_sendTimeout);
    final data = Map<String, dynamic>.from(res as Map<dynamic, dynamic>);
    if (data['ok'] != true) {
      throw OtpVerifyException(data['error'] as String? ?? 'UNKNOWN');
    }
  }

  /// The server's error codes, said in a way a person can act on.
  ///
  /// The sentences deliberately do NOT read "check your connection" for
  /// everything. When the endpoint is unreachable because it was deployed
  /// behind JWT verification that an anonymous signup can never satisfy, the
  /// user's connection is fine — telling them to check it sends them round a
  /// loop that cannot fix anything, which is how this defect stayed invisible.
  static String _sentenceFor(String code) {
    switch (code) {
      case 'captcha_required':
      case 'captcha_failed':
        return 'The security check was not accepted. Solve a new one and try '
            'again.';
      case 'email_provider_not_configured':
        return 'Email verification is not available at the moment. Please try '
            'again shortly.';
      case 'email_delivery_failed':
        return 'We could not send the code. Please try again in a moment.';
      case 'security_check_unavailable':
        return 'Verification is temporarily unavailable. Please try again '
            'shortly.';
      case 'otp_request_failed':
        return 'We could not create a verification code. Please try again.';
      default:
        return 'Verification is temporarily unavailable. Please try again '
            'shortly.';
    }
  }
}

/// 60-second resend window still open.
class OtpCooldownException implements Exception {
  final int retryAfterSeconds;
  OtpCooldownException(this.retryAfterSeconds);

  @override
  String toString() => 'OtpCooldownException($retryAfterSeconds)';
}

/// Verification failure: WRONG_CODE / NO_ACTIVE_CODE / TOO_MANY_ATTEMPTS.
class OtpVerifyException implements Exception {
  final String code;
  OtpVerifyException(this.code);

  @override
  String toString() => code;
}

/// The OTP endpoint refused, is not deployed, or is not reachable by an
/// anonymous caller. Carries the sentence to show, because only this layer
/// knows what the server said.
class OtpUnavailableException implements Exception {
  final String message;
  const OtpUnavailableException(this.message);

  @override
  String toString() => message;
}
