// test/session_persistence_test.dart
//
// The session-persistence fix: a restart (or a resume after the app sat
// backgrounded) must RESTORE the login, not drop a valid, refreshable user
// into guest mode or onto the login screen.
//
// The regression this pins: on cold start the stored ACCESS token is very often
// expired while the REFRESH token is still good. A profile read that races
// ahead of gotrue's refresh comes back 401/PGRST301 — auth-shaped — and the
// old code settled that straight to signed-out, logging a perfectly valid
// session out on every restart.
//
// Like session_settlement_test.dart this file is deliberately offline: it
// checks the pure AuthState surface plus SOURCE pins on the wiring a
// classifier cannot see. It constructs no Supabase client and needs no network.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/providers/auth_provider.dart';

void main() {
  group('AuthState exposes a one-time sign-out notice', () {
    test('a fresh unauthenticated state carries no stale notice', () {
      const s = AuthState(isLoading: false);
      expect(s.sessionNotice, isNull);
    });

    test('copyWith can set, keep and clear the notice', () {
      const base = AuthState(isLoading: false);
      final withNotice = base.copyWith(sessionNotice: 'Please sign in again.');
      expect(withNotice.sessionNotice, 'Please sign in again.');
      // Keeping (copyWith with no notice arg) must not wipe an existing one.
      expect(withNotice.copyWith(isLoading: false).sessionNotice,
          'Please sign in again.');
      // Clearing is explicit, mirroring clearError.
      expect(withNotice.copyWith(clearSessionNotice: true).sessionNotice, isNull);
    });
  });

  group('the central tri-state', () {
    test('loading / authenticated / unauthenticated are all first-class', () {
      // "loading" being its own state is the whole point: collapsing it into
      // "unauthenticated" is what defaulted a cold start to guest before the
      // restore check had finished.
      expect(AuthStatus.values, contains(AuthStatus.loading));
      expect(AuthStatus.values, contains(AuthStatus.authenticated));
      expect(AuthStatus.values, contains(AuthStatus.unauthenticated));
    });
  });

  group('source pins — the wiring a classifier cannot see', () {
    late final String source;

    setUpAll(() {
      source = File('lib/core/providers/auth_provider.dart').readAsStringSync();
    });

    test('the cold-start restore event is handled (initialSession)', () {
      expect(source, contains('AuthChangeEvent.initialSession'),
          reason: 'a restart with a stored session emits initialSession, not '
              'signedIn; without this branch the restore leaned entirely on a '
              'racy synchronous currentSession check');
    });

    test('an auth-shaped load failure tries a refresh before settling', () {
      expect(source, contains('_recoverWithRefresh'),
          reason: 'settling straight to signed-out on a 401 is what logged a '
              'refreshable session out on every restart');
    });

    test('the refresh is single-flight', () {
      expect(source, contains('_singleFlightRefresh'),
          reason: 'two concurrent refreshes race on the one-use refresh token '
              'and can sign the user out for real');
    });

    test('a dead session settles WITH a message, not silently', () {
      expect(source, contains('sessionNotice'),
          reason: 'the login screen must be able to say why the user is there');
      expect(source, contains('Your session ended'),
          reason: 'a refresh failure must not silently switch to guest');
    });

    test('resume re-validates the session', () {
      expect(source, contains('AppLifecycleState.resumed'),
          reason: 'a long-backgrounded session is re-checked on foreground');
    });

    test('the original dead-session settlement is preserved', () {
      // Guards against regressing session_settlement_test.dart: a session the
      // server refuses with NO session left to refresh must still be cleared
      // locally so the next launch goes straight to /login.
      expect(source, contains('signOut(scope: SignOutScope.local)'));
      expect(source, contains('currentSession == null'));
    });
  });
}
