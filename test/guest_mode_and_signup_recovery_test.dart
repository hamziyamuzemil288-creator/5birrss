// Guest mode, and the registration step that used to never finish.
//
// Two things are pinned here, both of them decisions that are easy to undo by
// accident and impossible to see in a screenshot:
//
//   1. The guest gate fires on TRANSACTIONS, not on browsing. A build that
//      widens `guestBlockedTransaction` locks a visitor out of the marketplace
//      it just let them into; one that narrows it lets a guest reach checkout
//      with no account and read an RLS refusal instead of a registration form.
//      The routing itself is not unit-testable without a router and a server,
//      so the RULE is tested directly and the wiring is checked below.
//   2. The signup handler releases its full-screen "Creating account…" scrim
//      in a `finally`, and the OTP endpoint is deployed so a signed-out signup
//      can actually reach it. Both are the root cause of "registration hangs
//      after submitting, never completes account creation": the scrim had no
//      other exit, and the endpoint answered 401 before its body ran.
import 'dart:io';

import 'package:birr5/core/services/guest_session.dart';
import 'package:birr5/core/services/otp_service.dart';
import 'package:flutter_test/flutter_test.dart';

String read(String path) {
  final f = File(path);
  if (!f.existsSync()) fail('missing file: $path');
  return f.readAsStringSync();
}

void main() {
  group('guest mode gates transactions, not browsing', () {
    test('every transaction route is blocked', () {
      for (final route in const [
        '/user/availability',
        '/user/checkout',
        '/user/payment',
        '/user/order-waiting',
        '/user/ride-request',
        '/user/orders/abc123',
      ]) {
        expect(guestBlockedTransaction(route), isTrue,
            reason: '$route creates a transaction and needs an account');
      }
    });

    test('browsing stays open', () {
      for (final route in const [
        '/user',
        '/user/search',
        '/user/product/p1',
        '/user/provider/pr1',
        '/user/category/c1',
        '/user/category-group/transport',
        '/map',
        '/terms',
        '/login',
        '/signup/user',
      ]) {
        expect(guestBlockedTransaction(route), isFalse,
            reason: '$route is browsing and must not be gated');
        expect(guestBlockedAccount(route), isFalse,
            reason: '$route is browsing and must not be gated');
      }
    });

    test('workspaces and account surfaces are closed to a guest', () {
      for (final route in const [
        '/admin',
        '/staff/dashboard',
        '/provider/orders',
        '/vehicle/vehicles',
        '/profile',
        '/wallet',
        '/user/cart',
        '/user/favorites',
        '/user/ride-history',
      ]) {
        expect(guestBlockedAccount(route), isTrue,
            reason: '$route needs an account or a workspace');
      }
    });

    test('the transaction check wins over the account check', () {
      // `/user/orders/x` is both, and the useful answer for somebody holding
      // an order link is the registration form, not the sign-in screen.
      expect(guestBlockedTransaction('/user/orders/x'), isTrue);
    });

    test('the interception always opens the STANDARD user signup', () {
      final src = read('lib/core/services/guest_session.dart');
      expect(src.contains("context.push('/signup/user')"), isTrue,
          reason: 'a guest must be sent to user registration, never to the '
              'provider or staff-assisted paths');
      expect(src.contains("'/signup/service'"), isFalse);
      expect(src.contains("'/signup/vehicle'"), isFalse);
    });
  });

  group('registration cannot hang on a scrim or an unreachable endpoint', () {
    test('the signup scrim is released in a finally', () {
      final src = read('lib/features/auth/signup_screen.dart');
      expect(RegExp(r'\}\s*finally\s*\{[^}]*_isLoading\s*=\s*false').hasMatch(src),
          isTrue,
          reason: 'the "Creating account…" overlay must never outlive the '
              'attempt; only the catch block used to clear it');
    });

    test('the account call and the terms write are bounded', () {
      final auth = read('lib/core/providers/auth_provider.dart');
      expect(auth.contains(').timeout(const Duration(seconds: 20))'), isTrue,
          reason: 'auth.signUp() had no deadline, so a stall was not an error '
              'and nothing dismissed the scrim');
      final signup = read('lib/features/auth/signup_screen.dart');
      expect(
          signup.contains(
              ".rpc('accept_terms', params: {'p_version': kTermsVersion})"),
          isTrue);
      expect(signup.contains('const Duration(seconds: 5)'), isTrue,
          reason: 'accept_terms sits between a created account and the app');
    });

    test('a skipped OTP send completes the step instead of asking for a code',
        () {
      final screen = read('lib/features/auth/otp_verification_screen.dart');
      expect(screen.contains('result.skipped'), isTrue,
          reason: 'send-otp answers skipped when the gate is off; asking for a '
              'six-digit code that was never sent is a dead end');
      expect(screen.contains('context.pop(true)'), isTrue);
    });

    test('the OTP result distinguishes delivered from skipped', () {
      expect(const OtpSendResult(delivered: true).codeSent, isTrue);
      expect(const OtpSendResult(skipped: true).codeSent, isFalse);
      expect(const OtpSendResult().codeSent, isFalse);
    });

    test('send-otp is deployed so a signed-out signup can reach it', () {
      final workflow = read('.github/workflows/deploy-supabase.yml');
      final m = RegExp(r'functions\s+deploy\s+send-otp\b([^\n]*)')
          .firstMatch(workflow);
      expect(m, isNotNull, reason: 'send-otp must stay in the deploy workflow');
      expect(m!.group(1), contains('--no-verify-jwt'),
          reason: 'the caller has no session yet; without the flag the gateway '
              'answers 401 before the function body and no code is ever sent');
    });
  });
}
