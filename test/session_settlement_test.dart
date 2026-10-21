// test/session_settlement_test.dart
//
// The cold-start dead-session settlement: a persisted session the server
// refuses must land the user on /login — not on the splash screen's error
// box behind a Retry that can never succeed, and not on the router's endless
// profile-retry loop when the refresh dies mid-read and the reads come back
// as an anonymous caller's empty answers.
//
// Two halves, because the fix has two halves:
//
//   * pure classification tests for sessionIsUnusable — what counts as a
//     refused session and, just as important, what does NOT (offline and
//     grant denials must keep their retry: being unreachable is not being
//     signed out);
//   * source pins on auth_provider.dart for the wiring the classifier cannot
//     see — the local sign-out and the vanished-session guard.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/providers/auth_provider.dart';

void main() {
  group('sessionIsUnusable — a refused session settles to sign-in', () {
    test('an expired JWT with its 401 is the end of the session', () {
      expect(
        sessionIsUnusable(PostgrestExceptionDouble(
          message: 'JWT expired',
          code: 'PGRST301',
          status: 401,
        )),
        isTrue,
        reason: 'the mapper reads status 401 as unauthorized; a token the '
            'gateway refused must clear the session, not retry the read',
      );
    });

    test('PGRST301 without a status still counts', () {
      // The message path files PGRST301 as `forbidden` when the exception
      // carries no status — permission-shaped wording for a fact that is
      // really "this session is over". The predicate reads the code itself.
      expect(
        sessionIsUnusable(PostgrestExceptionDouble(
          message: 'JWT expired',
          code: 'PGRST301',
        )),
        isTrue,
        reason: 'a refused JWT classified as forbidden would keep the user '
            'on the splash error box forever',
      );
    });

    test('a dead refresh token is a dead session', () {
      expect(
        sessionIsUnusable(Exception('refresh token not found')),
        isTrue,
      );
    });

    test('offline keeps its retry', () {
      expect(
        sessionIsUnusable(
            TimeoutException('profiles query timed out after 10 seconds')),
        isFalse,
        reason: 'an offline cold start is a load failure, not a dead '
            'account — signing the user out over a flight-mode launch would '
            'be its own bug',
      );
      expect(
        sessionIsUnusable(Exception('failed host lookup: api.example.com')),
        isFalse,
      );
    });

    test('a grant denial keeps its retry', () {
      // 42501 is for the deploy to fix, not for the user to re-authenticate
      // against — and the guest-grant migration's own assertion reports it.
      expect(
        sessionIsUnusable(PostgrestExceptionDouble(
          message: 'permission denied for table products',
          code: '42501',
        )),
        isFalse,
        reason: 'a missing GRANT must not sign people out',
      );
    });
  });

  group('the wiring the classifier cannot see', () {
    late final String source;

    setUpAll(() {
      source = File('lib/core/providers/auth_provider.dart').readAsStringSync();
    });

    test('a refused session is cleared locally, not left to retry', () {
      expect(
        source,
        contains('signOut(scope: SignOutScope.local)'),
        reason: 'the settlement must drop the stored token WITHOUT a network '
            'call — the server already refused it — so the next launch goes '
            'straight to /login',
      );
    });

    test('the settlement is reachable from the profile-load catch', () {
      expect(
        source,
        contains('sessionIsUnusable(e)'),
        reason: 'without this call the catch still parks a dead session on '
            'the splash error box — the reported cold-start trap',
      );
    });

    test('a session that vanishes mid-read settles instead of looping', () {
      expect(
        source,
        contains('currentSession == null'),
        reason: 'the silent variant: the refresh dies, supabase drops the '
            'token, the reads answer as anon (null profile, no roles), and '
            'the router retries that empty answer forever unless the load '
            'ends the session',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Double. See failure_mapper_test.dart for the same idea: the classifier
// reads runtimeType name and toString() only, so a local double keeps this
// test off the network and off the real package's constructor churn.
// ---------------------------------------------------------------------------

/// Mirrors `postgrest`'s `PostgrestException` rendering:
/// `PostgrestException(message: ..., code: ..., details: null, status: ...)`.
///
/// Named so runtimeType CONTAINS 'PostgrestException' — that is the first
/// thing the classifier reads (same trick as failure_mapper_test.dart).
class PostgrestExceptionDouble implements Exception {
  PostgrestExceptionDouble({
    required this.message,
    required this.code,
    this.status,
  });

  final String message;
  final String code;
  final int? status;

  @override
  String toString() => 'PostgrestException(message: $message, '
      'code: $code, details: null, '
      '${status != null ? 'status: $status' : 'hint: null'})';
}
