// The payment step is its own screen, and the appeal doors lead somewhere.
//
// Two quiet failures this guards against:
//
//  1. The split half-done. The checkout still placing the order (or still
//     rendering the accounts and the upload), so a buyer has two places to pay
//     and only one of them is the journey the flow describes. Read from the
//     sources rather than asserted in a comment.
//
//  2. An appeal door that opens the form with a tag the form ignores. The
//     appeal screen only accepts `?about=` values that are keys of its own
//     label map — anything else is silently dropped and the case lands as
//     "Something else", which is exactly the queue nobody can filter. So every
//     `about=` used anywhere in lib/ is checked against that map.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) {
  final f = File(path);
  if (!f.existsSync()) fail('missing source file: $path');
  return f.readAsStringSync();
}

/// Source with comment-only lines removed, so a doc comment that mentions a
/// pattern is not mistaken for the pattern.
String readCode(String path) {
  return read(path).split('\n').where((line) {
    final t = line.trimLeft();
    return !(t.startsWith('//') ||
        t.startsWith('/*') ||
        t.startsWith('*') ||
        t.startsWith('*/'));
  }).join('\n');
}

void main() {
  test('the checkout hands off and does not place the order itself', () {
    final checkout = readCode('lib/features/user/user_checkout_screen.dart');
    expect(checkout.contains("'/user/payment'"), isTrue,
        reason: 'checkout must open the payment step');
    expect(checkout.contains('_continueToPayment'), isTrue,
        reason: 'checkout must have the hand-off action');
    expect(checkout.contains('order-create'), isFalse,
        reason: 'only the payment screen may create the order; a second call '
            'site is a second place an order can be placed from');
    expect(checkout.contains('PLACE ORDER'), isFalse,
        reason: 'the place-order button belongs to the payment step now');
    expect(checkout.contains('AdminPaymentDetailsCard'), isFalse,
        reason: 'the platform account belongs to the payment step, not the '
            'fulfillment screen');
    // ...but the availability backstop must still be here.
    expect(checkout.contains('/user/availability'), isTrue,
        reason: 'the checkout is the availability gate backstop for deep links');
  });

  test('the payment step owns the money, and defers when it must', () {
    final pay = readCode('lib/features/user/user_payment_screen.dart');
    expect(pay.contains('AdminPaymentDetailsCard'), isTrue,
        reason: 'the account the administrator configured must be on this '
            'screen');
    expect(pay.contains('Amount you paid'), isTrue,
        reason: 'the price-writing section is the point of this screen');
    expect(pay.contains('Payment Reference'), isTrue,
        reason: 'the reference field, where the buyer writes the transaction '
            'number, must be here');
    expect(pay.contains('_pickScreenshot'), isTrue,
        reason: 'the image upload option must be here');
    expect(pay.contains('order-create'), isTrue,
        reason: 'this screen is what places the order');
    expect(pay.contains('AvailabilityNotice'), isTrue,
        reason: 'a gated listing must show the notice instead of asking for '
            'money before the provider has confirmed');
    expect(pay.contains('paymentDeferred'), isTrue,
        reason: 'the draft must be able to say the payment comes later');
    // The written amount is a record. If it ever becomes the price, a buyer
    // could pay one birr for anything.
    expect(pay.contains('Amount written by buyer'), isTrue,
        reason: 'the written amount must reach the order note');
    expect(RegExp(r'payableTotal\s*=\s*_amountCtrl').hasMatch(pay), isFalse,
        reason: 'the amount WRITTEN by the buyer must never become the order '
            'total — the server prices the order');
  });

  test('the route exists', () {
    final router = readCode('lib/routing/app_router.dart');
    expect(router.contains("'/user/payment'"), isTrue,
        reason: 'CONTINUE TO PAYMENT pushes /user/payment');
    expect(router.contains('UserPaymentScreen'), isTrue,
        reason: 'the route must build the payment screen');
  });

  test('every appeal door uses a tag the appeal form actually accepts', () {
    final appeal = readCode('lib/features/appeal/appeal_screen.dart');
    // The keys of `_aboutLabels` are the only accepted values.
    final mapMatch = RegExp(r'_aboutLabels = \{(.*?)\};', dotAll: true)
        .firstMatch(appeal);
    expect(mapMatch, isNotNull,
        reason: 'could not read _aboutLabels from appeal_screen.dart');
    final keys = RegExp(r"'([a-z_]+)':").allMatches(mapMatch!.group(1)!)
        .map((m) => m.group(1)!)
        .toSet();
    expect(keys, contains('dispute'),
        reason: 'the payment and order doors tag cases as a dispute');

    // Matches both spellings a door may use: the bare `'/appeal?about=x'` and
    // the one that carries the transaction `'/appeal?about=x&order=…'`.
    final doors = <String>[];
    for (final entity in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final text = readCode(entity.path);
      for (final m in RegExp(r"'/appeal\?about=([a-z_]+)").allMatches(text)) {
        doors.add('${entity.path} -> ${m.group(1)}');
      }
    }
    expect(doors, isNotEmpty,
        reason: 'no screen links to the appeal form any more');
    for (final door in doors) {
      final tag = door.split('->').last.trim();
      expect(keys, contains(tag),
          reason: '$door uses an `about` value the appeal form ignores, so the '
              'case would land as "Something else" and be unfilterable');
    }
  });

  test('a door that knows the transaction hands it over', () {
    final appeal = readCode('lib/features/appeal/appeal_screen.dart');
    expect(appeal.contains("qp['order']"), isTrue,
        reason: 'the appeal form ignores ?order=, so the transaction the '
            'buyer filed about is never recorded and the reviewer has to ask');
    expect(appeal.contains('order \${_orderRef!}'), isTrue,
        reason: 'the order is read but not written into the description — '
            'the only field the admin queue renders');
    expect(readCode('lib/features/user/user_order_detail_screen.dart')
        .contains('&order='), isTrue,
        reason: 'the order screen files a dispute without naming the order');
    expect(readCode('lib/features/user/user_payment_screen.dart')
        .contains('&order='), isTrue,
        reason: 'the payment step files a dispute about a placed order without '
            'naming it');
  });

  test('the admin queue the door leads to exists', () {
    final router = readCode('lib/routing/app_router.dart');
    expect(router.contains("'/admin/appeals'"), isTrue,
        reason: 'a filed appeal needs its admin queue');
    expect(readCode('lib/features/user/user_order_detail_screen.dart')
        .contains('_appealCard'), isTrue,
        reason: 'an order with a problem must be able to reach that queue');
  });

  test('the version bump reached both files the release reads', () {
    final m = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
            multiLine: true)
        .firstMatch(read('pubspec.yaml'));
    expect(m, isNotNull, reason: 'pubspec.yaml must have version: x.y.z+N');
    final build = read('lib/core/app_build.dart');
    expect(build.contains("kAppVersionName = '${m!.group(1)}'"), isTrue,
        reason: 'kAppVersionName must match pubspec.yaml');
    expect(build.contains('kAppBuildNumber = ${m.group(2)}'), isTrue,
        reason: 'kAppBuildNumber must match pubspec.yaml — this is the number '
            'sent as x-client-build and the versionCode Play reads');
  });
}
