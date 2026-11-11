// The dashboard grid's contract: real category chips with Other last, a null
// category for "All products", 24-row pages, a page-size+1 end signal, and a
// server read that cannot return a hidden, deleted or provider-less listing.
//
// The grid itself is a widget over a network RPC, so the parts that can be
// proven without a live database are the pure request/order rules and the SQL
// that the deploy will apply. That is deliberate: a test that only rendered a
// fixture grid would pass while the production query still returned 20 rows.
import 'dart:io';

import 'package:birr5/features/user/user_home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> chip(
  String id,
  String name, {
  String? parentId,
  int sortOrder = 0,
  int parentSortOrder = 0,
}) =>
    {
      'category_id': id,
      'name': name,
      'parent_id': parentId,
      'sort_order': sortOrder,
      'parent_sort_order': parentSortOrder,
    };

void main() {
  group('dashboard feed request', () {
    test('All products sends no category and a multiple-of-three page size', () {
      final params = dashboardFeedParams(categoryId: null, offset: 0);
      expect(params['p_category_id'], isNull);
      expect(params['p_limit'], kDashboardFeedPageSize + 1);
      expect(kDashboardFeedPageSize % 3, 0);
      expect(params['p_offset'], 0);
      expect(params['p_city'], isNull);
    });

    test('a category chip sends only that category id', () {
      final params = dashboardFeedParams(
        categoryId: 'electronics',
        offset: 48,
        city: 'Addis Ababa',
      );
      expect(params['p_category_id'], 'electronics');
      expect(params['p_offset'], 48);
      expect(params['p_city'], 'Addis Ababa');
    });

    test('an empty or whitespace city is All cities, not a city named ""', () {
      expect(dashboardFeedParams(categoryId: null, offset: 0)['p_city'], isNull);
      expect(
        dashboardFeedParams(categoryId: null, offset: 0, city: '   ')['p_city'],
        isNull,
      );
    });

    test('paging boundaries include exact multiples and one over', () {
      const size = kDashboardFeedPageSize;
      // The RPC is asked for size + 1. Exactly `size` returned means there is
      // no next page; size + 1 means there is.
      expect(dashboardFeedHasMore(size + 1, size), isTrue);
      expect(dashboardFeedHasMore(size, size), isFalse);
      expect(dashboardFeedHasMore(size - 1, size), isFalse);
      expect(dashboardFeedHasMore(1, size), isFalse);
      expect(dashboardFeedHasMore(0, size), isFalse);
      // Exactly 48 products: page one returns 25 (24 + sentinel), page two
      // starts at 24 and returns 24, so the grid ends without an empty extra
      // request.
      expect(dashboardFeedHasMore(25, size), isTrue);
      expect(dashboardFeedHasMore(24, size), isFalse);
    });
  });

  group('dashboard category chips', () {
    test('Other is last even when the server row sorts it first', () {
      final ordered = orderDashboardCategoryChips([
        chip('other', 'Other services', sortOrder: 0),
        chip('electronics', 'Electronics',
            parentId: 'retail', sortOrder: 3, parentSortOrder: 3),
        chip('beauty', 'Beauty', sortOrder: 5, parentSortOrder: 5),
        chip('construction', 'Construction',
            parentId: 'home', sortOrder: 4, parentSortOrder: 6),
        chip('foods', 'Foods', sortOrder: 2, parentSortOrder: 2),
      ]);
      expect(ordered.map((r) => r['name']), [
        'Foods',
        'Electronics',
        'Beauty',
        'Construction',
        'Other services',
      ]);
    });

    test('rows without an id are dropped, and empty input is safe', () {
      final ordered = orderDashboardCategoryChips([
        {'category_id': '', 'name': 'broken'},
        chip('ok', 'OK'),
      ]);
      expect(ordered, hasLength(1));
      expect(ordered.single['category_id'], 'ok');
      expect(orderDashboardCategoryChips(const []), isEmpty);
    });
  });

  group('the public feed SQL', () {
    final sql = File(
      'supabase/migrations/20261111000001_dashboard_product_feed.sql',
    ).readAsStringSync();

    test('filters hidden, unavailable, suspended, deleted and photo-less rows',
        () {
      expect(sql, contains('p.is_active = true'));
      expect(sql, contains('p.is_available = true'));
      expect(sql, contains("p.listing_status = 'ACTIVE'"));
      expect(sql, contains("pp.status = 'APPROVED'"));
      expect(sql, contains('pp.deleted_at IS NULL'));
      expect(sql, contains('FROM public.product_images pi'));
    });

    test('a failed image still has a card placeholder', () {
      expect(
        File('lib/core/widgets/dashboard_product_card.dart')
            .readAsStringSync(),
        contains('class _ImageFallback'),
      );
    });

    test('a category includes its descendants, and All products is unfiltered',
        () {
      expect(sql, contains('WITH RECURSIVE subtree'));
      expect(sql, contains('child.parent_id = parent.id'));
      expect(sql, contains('p_category_id IS NULL'));
      expect(sql, contains('p.category_id IN (SELECT id FROM subtree)'));
    });

    test('paging is server-side and bounded', () {
      expect(sql, contains('p_limit int DEFAULT 24'));
      expect(sql, contains('p_offset int DEFAULT 0'));
      expect(sql, contains('LIMIT greatest(1, least(coalesce(p_limit, 24), 60))'));
      expect(sql, contains('OFFSET greatest(coalesce(p_offset, 0), 0)'));
    });

    test('a guest can execute the feed, but not by bypassing provider checks',
        () {
      expect(
        sql,
        contains(
            'GRANT EXECUTE ON FUNCTION public.home_product_feed(uuid, int, int, text)'),
      );
      expect(sql, contains('TO anon, authenticated, service_role'));
      expect(sql, contains('SECURITY DEFINER'));
      expect(sql, contains("provider_profiles pp ON pp.id = p.provider_id"));
    });
  });
}
