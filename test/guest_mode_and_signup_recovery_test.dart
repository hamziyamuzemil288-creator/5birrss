// Guest browsing, guest checkout, and the registration step that used to hang.
//
// The marketing rework changed what a "guest" is. It is no longer a wall in
// front of a transaction that must be replaced by a registration form; it is an
// ANONYMOUS Supabase session opened at the first transaction, under which the
// order, the push token and the realtime subscription are scoped. The pins here
// are the ones that are easy to undo by accident:
//
//   1. the first screen is the dashboard, not a login wall;
//   2. a guest may reach checkout, payment, their own order and the delivery
//      map — all of them are scoped by auth.uid(), so the anonymous session is
//      the security boundary, not a route gate;
//   3. workspaces and account surfaces still send a guest to sign-in;
//   4. buyer registration is gone from the router and from the guest helper;
//   5. the signup scrim and the OTP endpoint stay fixed.
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
  group('the dashboard is the first screen for everybody', () {
    test('no session lands on /user, never on a login wall', () {
      final src = read('lib/routing/app_router.dart');
      expect(src.contains("if (loc == '/') return '/user';"), isTrue);
      expect(src.contains("if (loc == '/') return '/login';"), isFalse,
          reason: 'the whole point of the rework is that browsing needs no '
              'account');
    });

    test('workspaces are closed to a guest', () {
      for (final route in const [
        '/admin',
        '/admin/checkout-requests',
        '/admin-login',
        '/staff/dashboard',
        '/provider/orders',
        '/vehicle/vehicles',
        '/ceo',
        '/wallet',
        '/wallet/recharge',
        '/points',
        '/profile',
        '/profile/edit',
        '/appeals',
        '/appeal',
        '/help',
        '/become-partner',
        '/account/deletion',
        '/account/password',
        '/pending-approval',
        '/rejected',
        '/suspended',
        '/complete-profile',
      ]) {
        expect(guestBlockedAccount(route), isTrue,
            reason: '$route needs an account or a workspace');
      }
    });

    test('browsing and the buyer transaction routes stay open', () {
      for (final route in const [
        '/user',
        '/user/search',
        '/user/product/p1',
        '/user/provider/pr1',
        '/user/category/c1',
        '/user/category-group/transport',
        '/user/cart',
        '/user/checkout',
        '/user/payment',
        '/user/orders/abc123',
        '/user/orders/abc123/delivery',
        '/user/checkout/waiting/abc123',
        '/map',
        '/about',
        '/terms',
        '/login',
      ]) {
        expect(guestBlockedAccount(route), isFalse,
            reason: '$route is a buyer surface and must not be walled');
      }
    });

    test('the removed buyer-registration gate is gone', () {
      final guest = read('lib/core/services/guest_session.dart');
      expect(guest.contains('guestBlockedTransaction'), isFalse);
      expect(guest.contains('requestAccountToContinue'), isFalse);
      expect(guest.contains("context.push('/signup/user')"), isFalse);

      final router = read('lib/routing/app_router.dart');
      expect(router.contains('guestBlockedTransaction'), isFalse);
    });

    test('the old buyer signup link answers with the sign-in screen', () {
      final router = read('lib/routing/app_router.dart');
      final m = RegExp(
              r"if \(r != 'vehicle' && r != 'service'\) \{\s*return const LoginScreen\(\);")
          .hasMatch(router);
      expect(m, isTrue,
          reason: 'a buyer does not register; an existing one may still sign in');
    });
  });

  group('guest checkout uses a real anonymous session', () {
    test('the helper signs in anonymously and never opens a form', () {
      final src = read('lib/core/services/guest_session.dart');
      expect(src.contains('signInAnonymously'), isTrue);
      expect(src.contains('signup'), isFalse,
          reason: 'a guest checkout must not route through registration');
    });

    test('GuestMode defaults to browsing without an account', () {
      final mode = GuestMode();
      expect(mode.state, isTrue);
      mode.end();
      expect(mode.state, isFalse);
      mode.start();
      expect(mode.state, isTrue);
    });

    test('the buy button opens the session before writing the cart line', () {
      final src = read('lib/core/widgets/product_buy_button.dart');
      final ensure = src.indexOf('ensureGuestCheckoutSession');
      final add = src.indexOf('addToCart');
      expect(ensure, greaterThanOrEqualTo(0));
      expect(add, greaterThan(ensure),
          reason: 'the cart row is scoped to auth.uid(), so the anonymous '
              'session must exist first');
    });

    test('a guest is never treated as a real signed-in member', () {
      final src = read('lib/core/providers/auth_provider.dart');
      expect(src.contains('user?.isAnonymous'), isTrue);
      final router = read('lib/routing/app_router.dart');
      expect(router.contains('authState.isGuest'), isTrue,
          reason: 'guest tabs and the sign-in doors depend on this');
      expect(
          router.contains('if (next.isAuthenticated && !next.isGuest)'), isTrue,
          reason: 'ending guest mode for an anonymous session would turn the '
              'buyer into a broken member account');
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
