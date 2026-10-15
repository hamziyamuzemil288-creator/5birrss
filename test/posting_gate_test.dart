// The posting gate, tested where it decides.
//
// The gate is the checklist a provider meets before posting: document
// verification and the admin-configured wallet minimum. It was THREE steps
// while item 6 was in force — an active payment account, without which the
// server refused the listing and hid the ones already published — but
// 20261015000010 removed that rule: the platform collects the payment, so a
// provider has no account number to publish and nothing to add. The gate must
// not keep a third row that no screen in the app can turn green.
//
// What breaks silently in a gate like this is the DISPLAY logic — a step that
// reads "Done" when the server did not say so, an "under review" state that
// swallows the other step, a progress line that counts the wrong things, or a
// new server code (WALLET_BELOW_MINIMUM, migration 20261006000003) that falls
// through to a generic sentence instead of the wallet step's remedy. Every test
// below is one of those shapes, driven through the real pure factory
// (`PostingGateState.from`) rather than a copy of it.

import 'package:birr5/core/services/posting_gate.dart';
import 'package:birr5/core/services/provider_doc_gate.dart';
import 'package:birr5/core/services/provider_readiness.dart';
import 'package:birr5/core/utils/friendly_error.dart';
import 'package:flutter_test/flutter_test.dart';

PostingGateState _state({
  bool checked = true,
  List<String> blockers = const [],
  DocReviewState docState = DocReviewState.verified,
  double balance = 500,
  double requiredAmount = 0,
  bool verificationRequired = true,
  String? rejectionReason,
}) =>
    PostingGateState.from(
      checked: checked,
      blockers: blockers,
      docState: docState,
      balance: balance,
      requiredAmount: requiredAmount,
      verificationRequired: verificationRequired,
      rejectionReason: rejectionReason,
    );

void main() {
  group('readiness is the server answer, and only the server answer', () {
    test('checked with no blockers is ready', () {
      expect(_state().ready, isTrue);
    });

    // 20261015000010: the account rule is gone, so the gate must not carry a
    // step for it. The two assertions are the pair that matters — no route to
    // the accounts screen, and no third step counted — because either one
    // alone would leave a provider staring at a row they can never complete.
    test('there is no payment-account step any more', () {
      final s = _state();
      expect(PostingGateState.totalSteps, 2);
      expect(s.progressLabel, '2 of 2 done');
      // The wallet step is the only one that can be outstanding on its own —
      // the third, account-shaped state no longer exists to be reported.
      expect(s.onlyWalletLeft, isFalse);
      expect(_state(blockers: const ['WALLET_BELOW_MINIMUM'], balance: 0)
          .onlyWalletLeft, isTrue);
      // And nothing in the state points at the accounts screen.
      expect(s.wallet.route ?? '', isNot('/provider/payment-methods'));
      expect(PostingGateState.unknown.wallet.route ?? '',
          isNot('/provider/payment-methods'));
    });

    // A provider whose blockers could not be read must never see a green
    // checklist: "could not ask" is a different answer from "nothing is
    // outstanding", and the first one must not open the form.
    test('unchecked is NOT ready, even with an empty blocker list', () {
      expect(_state(checked: false).ready, isFalse);
    });

    test('the unknown constant never reads as ready, and shows why', () {
      // What the dialog renders when every read failed: unknown steps, not
      // done ones, and no way to press Continue.
      final s = PostingGateState.unknown;
      expect(s.ready, isFalse);
      expect(s.documents.state, PostingStepState.unknown);
      expect(s.wallet.state, PostingStepState.unknown);
      expect(s.progressLabel, '0 of 2 done');
    });

    test('any blocker means not ready', () {
      expect(_state(blockers: ['ACCOUNT_NOT_APPROVED']).ready, isFalse);
    });
  });

  group('progress counts what the server counts', () {
    test('one step done reads "1 of 2 done"', () {
      // Documents verified (done), the wallet short (not done): exactly one
      // counted step, and the gate is not ready.
      final s = _state(
        blockers: const ['WALLET_BELOW_MINIMUM'],
        balance: 40,
        requiredAmount: 100,
      );
      expect(s.doneCount, 1);
      expect(s.progressLabel, '1 of 2 done');
      expect(s.ready, isFalse);
    });

    test('both steps done read "2 of 2 done" and are ready', () {
      final s = _state(balance: 500, requiredAmount: 100);
      expect(s.doneCount, 2);
      expect(s.progressLabel, '2 of 2 done');
      expect(s.ready, isTrue);
    });

    test('under review is NOT done, and never swallows the wallet step', () {
      // The spec's edge case: documents sitting with an administrator must
      // not hide the wallet step — the provider can still recharge while
      // they wait, and the progress line must not count the review as done.
      final s = _state(
        docState: DocReviewState.pending,
        blockers: const ['DOCUMENTS_UNVERIFIED', 'WALLET_BELOW_MINIMUM'],
        balance: 0,
        requiredAmount: 100,
      );
      expect(s.documents.state, PostingStepState.underReview);
      expect(s.documents.actionLabel, isNull);
      expect(s.wallet.state, PostingStepState.todo);
      expect(s.wallet.route, '/wallet/recharge');
      expect(s.progressLabel, '0 of 2 done');
    });
  });

  group('the wallet step speaks in the admin number', () {
    test('shortfall names the minimum and offers the recharge screen', () {
      final s = _state(
        blockers: const ['WALLET_BELOW_MINIMUM'],
        balance: 40,
        requiredAmount: 100,
      );
      expect(s.wallet.state, PostingStepState.todo);
      expect(s.wallet.detail, contains('60 ETB short'));
      expect(s.wallet.detail, contains('100 ETB minimum'));
      expect(s.wallet.route, '/wallet/recharge');
    });

    test('a funded wallet reads as done with the number on file', () {
      final s = _state(
        blockers: const [],
        balance: 120,
        requiredAmount: 100,
      );
      expect(s.wallet.state, PostingStepState.done);
      expect(s.wallet.detail, contains('120 ETB'));
    });

    test('WALLET_BELOW_MINIMUM folds into the wallet step, not extra blockers',
        () {
      final s = _state(
        blockers: const ['DOCUMENTS_UNVERIFIED', 'WALLET_BELOW_MINIMUM'],
        docState: DocReviewState.none,
        balance: 0,
        requiredAmount: 50,
      );
      expect(s.extraBlockers, isEmpty);
      expect(s.wallet.state, PostingStepState.todo);
    });

    test('unrelated blockers still surface as extra rows', () {
      final s = _state(
        blockers: const ['ACCOUNT_NOT_APPROVED', 'ACTIVATION_FEE_UNPAID'],
        docState: DocReviewState.verified,
      );
      expect(s.extraBlockers,
          containsAll(['ACCOUNT_NOT_APPROVED', 'ACTIVATION_FEE_UNPAID']));
    });

    // The server no longer raises this code, so nothing in the app may still
    // tell a provider to go and add an account number (Part 13).
    test('the readiness banner has no payment-account remedy', () {
      final remedy = ProviderReadiness.remedyFor('NO_PAYMENT_ACCOUNT');
      expect(remedy.route, isNot('/provider/payment-methods'));
      expect(remedy.action, isNot('Add a payment account'));
    });
  });

  group('document states say what a provider can do', () {
    test('rejected carries the administrator reason and a re-upload action',
        () {
      final s = _state(
        docState: DocReviewState.rejected,
        blockers: const ['DOCUMENTS_UNVERIFIED'],
        rejectionReason: 'Photo of the ID was blurry.',
      );
      expect(s.documents.state, PostingStepState.rejected);
      expect(s.documents.detail, contains('Photo of the ID was blurry.'));
      expect(s.documents.actionLabel, 'Upload a new ID');
      expect(s.documents.opensSheet, isTrue);
    });

    test('verification switched off makes the step done, not todo', () {
      final s = _state(
        docState: DocReviewState.none,
        verificationRequired: false,
        blockers: const [],
      );
      expect(s.documents.state, PostingStepState.done);
      expect(s.ready, isTrue);
    });
  });

  group('the new server codes arrive as sentences', () {
    test('WALLET_BELOW_MINIMUM in a refusal names the minimum', () {
      final text = friendlyError(
        'PROVIDER_NOT_FULFILMENT_READY: DOCUMENTS_UNVERIFIED,'
        'WALLET_BELOW_MINIMUM',
      );
      expect(text, contains('minimum balance'));
      expect(text, isNot(contains('WALLET_BELOW_MINIMUM')));
    });

    test('POSTING_FEE_INSUFFICIENT says nothing was charged or created', () {
      final text = friendlyError('POSTING_FEE_INSUFFICIENT: 25');
      expect(text, contains('nothing was charged'));
      expect(text, isNot(contains('POSTING_FEE_INSUFFICIENT')));
    });

    test('WALLET_BELOW_MINIMUM has a readiness remedy pointing at recharge',
        () {
      final remedy = ProviderReadiness.remedyFor('WALLET_BELOW_MINIMUM');
      expect(remedy.route, '/wallet/recharge');
      expect(remedy.action, 'Top up your wallet');
    });
  });
}
