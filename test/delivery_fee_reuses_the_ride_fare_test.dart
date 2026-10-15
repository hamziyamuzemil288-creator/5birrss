// Part 10: the delivery fee REUSES the ride fare — proven from the repository,
// not asserted in a comment.
//
// What this guards against is the quiet failure the repo has already been
// bitten by twice: a second copy of a pricing rule. If the delivery fee ever
// stops calling `calculate_fare_estimate_at` and starts carrying its own
// base + per-km arithmetic, the delivery quoted at checkout and the delivery
// the order is priced with drift apart the first time an admin edits a rate —
// and nothing crashes, so nothing notices.
//
// So it reads the deployed bodies (the LAST definition in deploy order, which
// is what a full deploy leaves live), the column definition PostgreSQL will
// use for `products.display_price`, the Dart resolver, the checkout screen and
// the Edge Function, and fails when any of them has stopped talking to the
// shared reader.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<File> migrationFiles() {
  final dir = Directory('supabase/migrations');
  if (!dir.existsSync()) {
    fail('supabase/migrations not found — run this test from the package root');
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// The body of the LATEST definition of `public.<name>` across all migrations.
String latestFunctionBody(String name) {
  final pattern = RegExp(
    r'create\s+or\s+replace\s+function\s+public\.' + name + r'\b',
    caseSensitive: false,
  );
  String? found;
  for (final f in migrationFiles()) {
    final text = f.readAsStringSync();
    for (final m in pattern.allMatches(text)) {
      final end = text.indexOf(r'$$;', m.start);
      if (end == -1) continue;
      found = text.substring(m.start, end);
    }
  }
  if (found == null) {
    fail('no definition of public.$name in any migration');
  }
  return found;
}

String read(String path) {
  final f = File(path);
  if (!f.existsSync()) fail('missing source file: $path');
  return f.readAsStringSync();
}

/// The same source with comment-only lines removed, so a docstring that NAMES a
/// forbidden pattern (fee_resolver.dart's own header explains why it must not
/// divide by 100) is not mistaken for the pattern in code.
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
  test('the delivery fee is the ride fare, not a second formula', () {
    final delivery = latestFunctionBody('calculate_delivery_fee_at');
    expect(
      delivery.contains('calculate_fare_estimate_at'),
      isTrue,
      reason: 'calculate_delivery_fee_at must price through '
          'calculate_fare_estimate_at — the reader create_ride_request charges '
          'a ride with. Carrying its own base + per_km arithmetic here is the '
          'duplication this test exists to catch.',
    );
    expect(
      delivery.contains('platform_display_markup'),
      isTrue,
      reason: 'the delivery fee must apply the platform markup the product '
          'price is generated from, not a copy of it',
    );
  });

  test('the buyer is quoted from the same function the order is priced with',
      () {
    final quote = latestFunctionBody('quote_delivery_fee');
    expect(
      quote.contains('calculate_fare_estimate_at'),
      isTrue,
      reason: 'quote_delivery_fee must price through the shared fare reader, '
          'or the checkout shows one number and the order charges another',
    );
    expect(
      quote.contains('platform_display_markup'),
      isTrue,
      reason: 'the quote must include the same markup the charge does',
    );
    // And it must NOT invent a fee when it cannot measure one.
    expect(
      quote.contains('PROVIDER_HAS_NO_LOCATION'),
      isTrue,
      reason: 'a provider with no published point must be reported as '
          'unpriceable, not priced from the city',
    );
  });

  test('the ride context still charges through the same reader', () {
    expect(
      latestFunctionBody('create_ride_request')
          .contains('calculate_fare_estimate_at'),
      isTrue,
      reason: 'create_ride_request must still price through '
          'calculate_fare_estimate_at, or "reuses the ride fare" would be true '
          'of a fare no ride uses any more',
    );
  });

  test('the platform markup exists once and the product price points at it',
      () {
    final markup = latestFunctionBody('platform_display_markup');
    expect(markup.contains('+ 5 +'), isTrue,
        reason: 'the flat platform charge is gone from the markup rule');
    expect(markup.contains('* 0.019'), isTrue,
        reason: 'the 1.9% platform margin is gone from the markup rule');

    final all = migrationFiles()
        .map((f) => f.readAsStringSync())
        .join('\n');
    expect(
      all.contains('GENERATED ALWAYS AS (public.platform_display_markup(price))'),
      isTrue,
      reason: 'products.display_price must be generated FROM '
          'platform_display_markup, so the product price and the delivery fee '
          'cannot drift apart',
    );
  });

  test('the app quotes the delivery fee through FeeResolver, never itself', () {
    final resolver = read('lib/core/services/fee_resolver.dart');
    expect(resolver.contains("rpc('quote_delivery_fee'"), isTrue,
        reason: 'FeeResolver must call the delivery quote over RPC');
    expect(resolver.contains("'order-create (delivery fee)': 'quote_delivery_fee'"),
        isTrue,
        reason: 'the charge path -> reader map must name the delivery quote as '
            'the resolver the order-create charge uses');
    // The same rule the fee-preview test applies to every other fee: the
    // resolver never does the arithmetic. Comments are stripped first, because
    // the file's own header explains this rule by quoting the forbidden shape.
    final resolverCode = readCode('lib/core/services/fee_resolver.dart');
    for (final needle in <String>['* 0.019', '+ 5 +', '/ 100', '* 0.01']) {
      expect(resolverCode.contains(needle), isFalse,
          reason: 'FeeResolver must not compute the delivery fee itself '
              '("$needle") — the server resolves it and the app reads it back');
    }

    final checkout = read('lib/features/user/user_checkout_screen.dart');
    expect(checkout.contains('FeeResolver.instance.deliveryFee'), isTrue,
        reason: 'checkout must quote the delivery fee through FeeResolver');
    expect(checkout.contains('quote_delivery_fee'), isFalse,
        reason: 'checkout must not call the delivery RPC itself — FeeResolver '
            'is the single door');
    // The change-your-mind controls have to exist on the screen.
    expect(checkout.contains('_chooseVehicleType'), isTrue,
        reason: 'the buyer must be able to change the delivery vehicle and '
            'have the fee recalculate');
    expect(checkout.contains('_chooseDeliveryPoint'), isTrue,
        reason: 'the buyer must be able to move the delivery point on the map');
    expect(checkout.contains('WhereToPicker.open'), isTrue,
        reason: 'the delivery point must be chosen on the existing map page, '
            'not a second map');
    expect(checkout.contains('_payableTotal'), isTrue,
        reason: 'the total must be the product price plus the delivery fee');
  });

  test('the order is priced by the server with the same quote', () {
    final fn = read('supabase/functions/order-create/index.ts');
    expect(fn.contains('"quote_delivery_fee"'), isTrue,
        reason: 'order-create must price the delivery with the SAME RPC the '
            'checkout quoted with; a fee sent by the client would be a second '
            'pricing rule the client could lie about');
    expect(fn.contains('delivery_lat') && fn.contains('delivery_lng'), isTrue,
        reason: 'order-create must receive the buyer point it prices to');
  });

  test('a pending availability request is visible from Orders', () {
    final orders = read('lib/features/user/user_orders_screen.dart');
    expect(orders.contains('PendingAvailabilitySection'), isTrue,
        reason: 'Orders must show the live availability requests, so a buyer '
            'can check progress without the waiting screen open');
    final section = read('lib/features/user/pending_availability_section.dart');
    expect(section.contains("from('availability_requests')"), isTrue,
        reason: 'the section must read the request ROW — that row is the '
            'source of truth, which is what makes the request survive a '
            'minimise or a navigation');
    expect(section.contains('ResilientSubscription'), isTrue,
        reason: 'the status must update live, not only on a manual refresh');
  });
}
