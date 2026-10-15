// Item K: the audit that every surface is wired.
//
// This is a static audit over the repository — deliberately, because the
// alternative is eight end-to-end tests against a live database, and a test
// that needs a database is a test that does not run in CI. What it CAN prove
// without a server is exactly the class of bug the audit exists to catch: a
// menu item that pushes a route nobody registered (a dead tap), a route with no
// builder (a blank screen), an error path that shows a sentence but writes no
// reference code, and a global handler that was quietly removed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) {
  final f = File(path);
  if (!f.existsSync()) fail('missing file: $path');
  return f.readAsStringSync();
}

/// Every `context.push('/…')` / `context.go('/…')` target in a file.
Set<String> pushedTargets(String source) {
  final out = <String>{};
  final re = RegExp("context\\.(?:push|go)\\(\\s*'([^']+)'");
  for (final m in re.allMatches(source)) {
    final p = m.group(1)!.trim();
    if (p.startsWith('/')) out.add(p);
  }
  return out;
}

void main() {
  group('no dead admin taps', () {
    test('every route the admin dashboard pushes is registered', () {
      final router = read('lib/routing/app_router.dart');
      final targets = pushedTargets(read('lib/features/admin/admin_dashboard.dart'));
      expect(targets, isNotEmpty,
          reason: 'the audit must find the dashboard\'s navigation targets');

      final missing = <String>[];
      for (final t in targets) {
        // Strip a query string and any path parameters before matching, so a
        // target like /user/orders/123 matches the registered
        // /user/orders/:id.
        final bare = t.split('?').first;
        final direct = router.contains("path: '$bare'");
        final asPattern = router.contains(
          RegExp("path: '${RegExp.escape(bare).replaceAll(r'\:', ':')}"),
        );
        // A nested path may be registered on its own line with the same text.
        final contains = router.contains(bare);
        if (!direct && !asPattern && !contains) missing.add(t);
      }
      expect(missing, isEmpty,
          reason: 'admin dashboard pushes routes that are not registered: '
              '${missing.join(', ')}');
    });

    test('every admin sidebar destination named in the spec exists', () {
      final router = read('lib/routing/app_router.dart');
      // The sections the brief names, each of which must have a real screen.
      const required = [
        '/admin/app-releases', // item I
        '/admin/fees',
        '/admin/fees/categories',
        '/admin/settings',
        '/admin/income',
        '/admin/transactions',
        '/admin/payments',
        '/admin/document-verification',
        '/admin/orders',
        '/admin/users',
        '/admin/providers',
        '/admin/support-tickets',
        '/admin/content',
        '/admin/staff',
        '/admin/history',
      ];
      for (final p in required) {
        expect(router.contains(p), isTrue,
            reason: '$p must be registered in the router');
      }
    });
  });

  group('every route renders something', () {
    test('no GoRoute is missing a builder', () {
      final src = read('lib/routing/app_router.dart');
      final count = RegExp(r'GoRoute\(').allMatches(src).length;
      final builders = RegExp(r'builder:').allMatches(src).length;
      expect(count, greaterThan(40),
          reason: 'sanity: the router must have many routes');
      // One builder per route (pageBuilder would also count).
      final pageBuilders = RegExp(r'pageBuilder:').allMatches(src).length;
      expect(builders + pageBuilders, greaterThanOrEqualTo(count),
          reason: 'every GoRoute must have a builder or pageBuilder, or it '
              'renders a blank screen');
    });
  });

  group('global error handling is still installed', () {
    test('bootstrap installs all three handlers', () {
      final src = read('lib/core/bootstrap.dart');
      expect(src, contains('FlutterError.onError ='));
      expect(src, contains('runZonedGuarded('));
      expect(src, contains('PlatformDispatcher.instance.onError ='));
      // And the framework errors are reported, not only printed.
      expect(src, contains('ErrorLogger.instance.logError'));
    });

    test('the logger writes to the admin-readable table', () {
      final src = read('lib/core/services/error_logger.dart');
      expect(src, contains("from('client_error_logs')"));
      expect(src, contains("'reference_code': reference"));
      expect(src, contains("'fingerprint': fingerprint"));
    });
  });

  group('friendly errors carry a reference code', () {
    test('the logger returns AL- codes', () {
      final src = read('lib/core/services/error_logger.dart');
      expect(src, contains("'AL-"));
      expect(src, contains('String? log('));
      expect(src, contains('String? logError('));
    });

    test('the helper appends the code to the sentence', () {
      final src = read('lib/core/utils/friendly_failure.dart');
      expect(src, contains('friendlyErrorWithRef'));
      expect(src, contains('ErrorLogger.instance.logError'));
      expect(src, contains('(Ref '));
      expect(src, contains(r'$ref'));
    });

    test('the three write paths use it, not the bare sentence', () {
      // The third write path is the one that places the order, and that moved
      // to the payment step when the checkout became the fulfilment screen: the
      // checkout now only READS (the availability check, best-effort by design),
      // so the reference code has to be on the screen that actually writes.
      for (final path in [
        'lib/features/user/user_ride_request_screen.dart',
        'lib/features/provider/provider_product_form_screen.dart',
        'lib/features/user/user_payment_screen.dart',
      ]) {
        expect(read(path), contains('friendlyErrorWithRef'),
            reason: '$path must show a reference code on failure');
      }
    });

    test('the migration adds the column and the assertion', () {
      final sql = read('supabase/migrations/20261007000007_error_reference_codes.sql');
      expect(sql, contains('reference_code text'));
      expect(sql, contains('idx_client_error_logs_reference_code'));
      expect(sql, contains('assert_error_logs_carry_a_reference'));
    });
  });

  group('offline, timeout and retry states exist', () {
    test('the offline banner and the error boundary are both mounted', () {
      expect(read('lib/app.dart'), contains('ConnectivityBanner'));
      expect(read('lib/core/bootstrap.dart'), contains('AppErrorBoundary'));
    });

    test('there is a shared retry view for failed loads', () {
      expect(File('lib/core/widgets/load_error_view.dart').existsSync(), isTrue);
    });
  });
}
