// The refusal code an ADMIN sees, next to the sentence everyone sees.
//
// Item 2 asked for exactly this: "Show the real error code to admins." The
// content-control and image-moderation surfaces used to swallow it — a
// moderator whose Hide tap came back NO_SUCH_IMAGE was shown a generic
// "Something went wrong", with nothing to tell support. End users must keep
// the plain sentence (a code tells a buyer nothing), so this file pins both
// directions: the code is present on the admin path and absent from the
// user one.
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/utils/friendly_error.dart';

/// The exact shape Supabase's PostgrestException stringifies to.
const _envelope =
    'PostgrestException(message: NO_SUCH_IMAGE, code: P0001, '
    'details: null, hint: null)';

void main() {
  group('errorCodeOf digs the real refusal out of the exception', () {
    test('a PostgrestException envelope yields the app code and the SQLSTATE',
        () {
      final code = errorCodeOf(_envelope);
      expect(code, isNotNull);
      expect(code, contains('NO_SUCH_IMAGE'));
      expect(code, contains('P0001'));
    });

    test('the SQLSTATE in front of a message survives on its own', () {
      expect(errorCodeOf('42703: column "booking_base_fare" does not exist'),
          contains('42703'));
    });

    test('a bare server sentinel yields itself', () {
      expect(errorCodeOf('ADMIN_ONLY'), contains('ADMIN_ONLY'));
      expect(errorCodeOf('A_REASON_IS_REQUIRED'),
          contains('A_REASON_IS_REQUIRED'));
    });

    test('an error with no code yields null, never an invented one', () {
      expect(errorCodeOf('network is unreachable'), isNull);
      expect(errorCodeOf(SocketishFailure()), isNull);
    });
  });

  group('friendlyErrorWithCode is the admin sentence', () {
    test('it keeps the friendly sentence and appends the real code', () {
      final shown =
          friendlyErrorWithCode(_envelope, context: 'Could not hide this');
      expect(shown, contains('['));
      expect(shown, contains('NO_SUCH_IMAGE'));
      // Still a sentence, not a raw dump.
      expect(shown.toLowerCase(), contains('could not hide this'));
    });

    test('with no code it degrades to the plain sentence, no dangling [',
        () {
      final shown = friendlyErrorWithCode('network is unreachable');
      expect(shown, isNot(contains('[')));
      expect(shown, friendlyError('network is unreachable'));
    });
  });

  group('end users never see a code', () {
    test('friendlyError itself carries no bracketed code', () {
      final message = friendlyError(_envelope, context: 'Could not load');
      expect(message, isNot(contains('P0001')));
      expect(message, isNot(contains('NO_SUCH_IMAGE')));
    });
  });

  // Every refusal admin_delete_provider can raise, and none of them may come
  // back as "Something went wrong". That is exactly how the delete looked
  // broken: the server answered STATUS_CANNOT_BE_SELF_MODIFIED (from a guard
  // that had no branch for an administrator, fixed by 20261025000004), the
  // mapper knew none of these sentinels, and the screen showed a shrug — so
  // the report was "the system is there but delete does not work".
  group('provider deletion refusals read as instructions, not as crashes', () {
    const fallback = 'Something went wrong. Please try again.';

    test('open work is counted out of the server\'s own measurement', () {
      final message = friendlyError(
          'PostgrestException(message: PROVIDER_HAS_OPEN_WORK orders=2 '
          'rides=1, code: P0001, details: null, hint: null)',
          context: 'Could not delete this provider');
      expect(message, isNot(contains(fallback)));
      expect(message, contains('2 open orders'));
      expect(message, contains('1 open ride'));
      expect(message.toLowerCase(), contains('nothing was deleted'));
    });

    test('a malformed count still yields a sentence, never the fallback', () {
      final message = friendlyError('PROVIDER_HAS_OPEN_WORK',
          context: 'Could not delete this provider');
      expect(message, isNot(contains(fallback)));
      expect(message, isNotEmpty);
    });

    test('deleting twice says so instead of failing vaguely', () {
      expect(friendlyError('PROVIDER_ALREADY_DELETED'),
          contains('already been removed'));
    });

    test('deleting your own business names the actual rule', () {
      expect(friendlyError('CANNOT_DELETE_SELF'), contains('your own business'));
    });

    test('the status guard points at the administrator account', () {
      final message = friendlyError('STATUS_CANNOT_BE_SELF_MODIFIED');
      expect(message, isNot(contains(fallback)));
      expect(message.toLowerCase(), contains('administrator'));
    });
  });
}

/// A thrown object whose toString() is pure prose — the transport failures.
class SocketishFailure {
  @override
  String toString() => 'Connection closed before full header was received';
}
