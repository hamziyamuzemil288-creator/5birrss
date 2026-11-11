// The sign-in welcome is a server-owned notification with three client rules
// that can be proven without a phone or a live database:
//
//   1. ONLY an explicit signedIn event announces a sign-in. A cold-start
//      restore and a token refresh must not.
//   2. A waiting-for-token answer is retried, and only the final attempt may
//      fall back to the inbox.
//   3. The SQL uses the JWT session id as the idempotency key, a five-minute
//      gap, the push preference and the real pending provider/admin data.
//
// The actual FCM delivery and the phone tray need a device; that separation is
// stated in the final report.
import 'dart:io';

import 'package:birr5/core/services/welcome_back_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent;

void main() {
  group('which auth event is a sign-in', () {
    test('only signedIn is a fresh sign-in', () {
      expect(isWelcomeBackSignInEvent(AuthChangeEvent.signedIn), isTrue);

      for (final event in [
        AuthChangeEvent.initialSession,
        AuthChangeEvent.tokenRefreshed,
        AuthChangeEvent.signedOut,
        AuthChangeEvent.passwordRecovery,
      ]) {
        expect(
          isWelcomeBackSignInEvent(event),
          isFalse,
          reason: '$event must not produce a welcome-back notification',
        );
      }
    });
  });

  group('server status becomes a client disposition', () {
    test('sent, already sent and throttled all stop retrying', () {
      expect(welcomeBackStatusFor('sent'), WelcomeBackStatus.sent);
      expect(welcomeBackStatusFor('already_sent'), WelcomeBackStatus.alreadySent);
      expect(welcomeBackStatusFor('throttled'), WelcomeBackStatus.throttled);
      expect(welcomeBackStatusFor('push_disabled'), WelcomeBackStatus.pushDisabled);
    });

    test('a guest or a brand-new account is skipped, not failed', () {
      for (final status in [
        'guest',
        'new_account',
        'no_session',
        'no_profile',
        'signed_out',
      ]) {
        expect(welcomeBackStatusFor(status), WelcomeBackStatus.skipped);
      }
    });

    test('only waiting_for_token retries; an unknown answer fails closed', () {
      expect(welcomeBackStatusFor('waiting_for_token'), WelcomeBackStatus.retry);
      expect(welcomeBackStatusFor('something_new'), WelcomeBackStatus.failed);
      expect(welcomeBackStatusFor(''), WelcomeBackStatus.failed);
    });
  });

  group('token wait and inbox fallback', () {
    test('a token that becomes ready sends on the next attempt', () async {
      final calls = <bool>[];
      final service = WelcomeBackService(
        prepareToken: () async => false,
        delay: (_) async {},
        rpc: (allowInboxOnly) async {
          calls.add(allowInboxOnly);
          if (calls.length == 1) {
            return const <String, dynamic>{
              'ok': true,
              'status': 'waiting_for_token',
            };
          }
          return const <String, dynamic>{
            'ok': true,
            'status': 'sent',
            'tray_expected': true,
          };
        },
      );

      final outcome = await service.deliverAfterSignIn(tokenAttempts: 3);

      expect(outcome.status, WelcomeBackStatus.sent);
      expect(outcome.trayExpected, isTrue);
      expect(calls, [false, false],
          reason: 'the first attempt waits, the second delivers the push');
    });

    test('a token that never arrives still reaches the inbox once', () async {
      final calls = <bool>[];
      final service = WelcomeBackService(
        prepareToken: () async => false,
        delay: (_) async {},
        rpc: (allowInboxOnly) async {
          calls.add(allowInboxOnly);
          return <String, dynamic>{
            'ok': true,
            'status': allowInboxOnly ? 'sent' : 'waiting_for_token',
            'tray_expected': false,
          };
        },
      );

      final outcome = await service.deliverAfterSignIn(tokenAttempts: 3);

      expect(calls, [false, false, false, true],
          reason: 'three token-required attempts, then one inbox-only call');
      expect(outcome.status, WelcomeBackStatus.sent);
      expect(outcome.trayExpected, isFalse);
    });

    test('an already-sent session does not retry or call the fallback', () async {
      final calls = <bool>[];
      final service = WelcomeBackService(
        prepareToken: () async => true,
        delay: (_) async {},
        rpc: (allowInboxOnly) async {
          calls.add(allowInboxOnly);
          return const <String, dynamic>{
            'ok': true,
            'status': 'already_sent',
          };
        },
      );

      final outcome = await service.deliverAfterSignIn(tokenAttempts: 3);

      expect(outcome.status, WelcomeBackStatus.alreadySent);
      expect(calls, [false]);
    });

    test('a throttled sign-in is quiet and does not retry', () async {
      final calls = <bool>[];
      final service = WelcomeBackService(
        prepareToken: () async => true,
        delay: (_) async {},
        rpc: (allowInboxOnly) async {
          calls.add(allowInboxOnly);
          return const <String, dynamic>{
            'ok': true,
            'status': 'throttled',
          };
        },
      );

      final outcome = await service.deliverAfterSignIn(tokenAttempts: 3);

      expect(outcome.status, WelcomeBackStatus.throttled);
      expect(calls, [false]);
      expect(outcome.isSuccessful, isTrue);
    });
  });

  group('the welcome SQL', () {
    final sql = File(
      'supabase/migrations/20261112000001_signin_welcome_notification.sql',
    ).readAsStringSync();
    final auth = File('lib/core/providers/auth_provider.dart').readAsStringSync();
    final edge = File(
      'supabase/functions/signin-welcome/index.ts',
    ).readAsStringSync();
    final workflow = File(
      '.github/workflows/deploy-supabase.yml',
    ).readAsStringSync();

    test('the notification type and a dedicated log exist', () {
      expect(sql, contains("ADD VALUE IF NOT EXISTS 'WELCOME_BACK'"));
      expect(sql, contains('CREATE TABLE IF NOT EXISTS public.signin_welcome_log'));
      expect(sql, contains('PRIMARY KEY REFERENCES auth.users(id)'));
    });

    test('one session can only produce one welcome', () {
      expect(sql, contains("'signin-welcome:' || v_user::text || ':' || v_session"));
      expect(sql, contains('v_last.session_id = v_session'));
      expect(sql, contains("'status', 'already_sent'"));
      expect(sql, contains('pg_advisory_xact_lock'));
    });

    test('the minimum gap is five minutes', () {
      expect(sql, contains("interval '5 minutes'"));
      expect(sql, contains("'status', 'throttled'"));
    });

    test('the token race and push preference are handled server-side', () {
      expect(sql, contains('waiting_for_token'));
      expect(sql, contains('p_allow_inbox_only'));
      expect(sql, contains('notification_preferences'));
      expect(sql, contains('push_enabled'));
      expect(sql, contains('fcm_tokens'));
      expect(sql, contains("'welcome_back'"));
    });

    test('next-step copy is backed by real pending data', () {
      expect(sql, contains('FROM public.availability_requests'));
      expect(sql, contains("o.status = 'PENDING_PROVIDER'"));
      expect(sql, contains('AWAITING_APPROVAL'));
    });

    test('only the service role can call the user-id-taking function', () {
      expect(sql, contains("FROM public, anon, authenticated"));
      expect(
        sql,
        contains(
          'GRANT EXECUTE ON FUNCTION public.record_signin_welcome_for_user(uuid, text, boolean)',
        ),
      );
      expect(sql, contains('TO service_role'));
    });

    test('the service-role edge function is the only caller with a user id', () {
      expect(edge, contains('admin.auth.getUser(token)'));
      expect(edge, contains('record_signin_welcome_for_user'));
      expect(edge, contains('sessionIdFromToken(token)'));
      expect(edge, contains('session_id'));
      expect(workflow, contains('supabase functions deploy signin-welcome'));
    });

    test('the app calls it from the signedIn branch and nowhere else', () {
      expect(auth, contains('isWelcomeBackSignInEvent(event)'));
      expect(auth, contains('deliverAfterSignIn()'));

      final signedIn = auth.indexOf('isWelcomeBackSignInEvent(event)');
      final signedOut = auth.indexOf('else if (event == AuthChangeEvent.signedOut)');
      expect(signedIn, greaterThanOrEqualTo(0));
      expect(signedOut, greaterThan(signedIn));
      final branch = auth.substring(signedIn, signedOut);
      expect(branch, contains('deliverAfterSignIn()'));
      expect(
        RegExp('deliverAfterSignIn').allMatches(auth).length,
        1,
        reason: 'session restore and token refresh must not call the welcome',
      );
    });
  });
}
