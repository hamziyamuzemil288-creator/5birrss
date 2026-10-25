// The filters and the sort behind the two admin update screens.
//
// WHY THESE ARE TESTS
// -------------------
// Both screens load one window of rows and decide in Dart what the operator
// sees. That means the failure mode is not a database error — it is a filter
// that quietly drops the row somebody is looking for, or a soft-deleted
// business reappearing under "Approved" and being approved a second time. The
// queries cannot catch that and neither can a screenshot: the row is simply
// not there. So the decision is a pure function with a test.
//
// The values below mirror what the screens actually receive from PostgREST:
// an embedded `profiles` object on a provider row, and an embedded `products`
// / `provider_profiles` pair on an availability row.

import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/features/admin/admin_provider_management_screen.dart';
import 'package:birr5/features/admin/admin_availability_screen.dart';

Map<String, dynamic> provider({
  String id = 'p1',
  String name = 'Bole Electronics',
  String status = 'APPROVED',
  String type = 'SERVICE_PROVIDER',
  String owner = 'Hanna Bekele',
  String phone = '0911223344',
  String created = '2026-10-01T09:00:00Z',
  String? deletedAt,
}) =>
    {
      'id': id,
      'business_name': name,
      'status': status,
      'provider_type': type,
      'created_at': created,
      'deleted_at': deletedAt,
      'profiles': {'full_name': owner, 'phone': phone},
    };

Map<String, dynamic> request({
  String status = 'PENDING',
  String product = 'Samsung A15',
  String business = 'Bole Electronics',
  String created = '2026-10-25T08:00:00Z',
  String? reason,
}) =>
    {
      'id': 'r1',
      'status': status,
      'quantity': 2,
      'reason': reason,
      'created_at': created,
      'products': {'name': product},
      'provider_profiles': {'business_name': business},
    };

void main() {
  group('provider list filters', () {
    final shop = provider();
    final vehicle = provider(
      id: 'p2',
      name: 'Selam Rides',
      type: 'VEHICLE_PROVIDER',
      owner: 'Dawit Tesfaye',
      phone: '0922334455',
      status: 'APPROVED',
    );

    test('status chip only shows its own status', () {
      expect(
          providerMatchesFilters(shop,
              status: 'APPROVED', type: 'ALL', query: ''),
          isTrue);
      expect(
          providerMatchesFilters(shop,
              status: 'PENDING_APPROVAL', type: 'ALL', query: ''),
          isFalse);
    });

    test('a soft-deleted provider does not appear under its old status', () {
      final removed =
          provider(status: 'SUSPENDED', deletedAt: '2026-10-24T10:00:00Z');
      // The status column still says SUSPENDED after the soft delete; showing
      // it under "Suspended" is how it gets reinstated by mistake.
      expect(
          providerMatchesFilters(removed,
              status: 'SUSPENDED', type: 'ALL', query: ''),
          isFalse);
      expect(
          providerMatchesFilters(removed,
              status: 'DELETED', type: 'ALL', query: ''),
          isTrue);
    });

    test('type filter uses the two types the schema has', () {
      expect(
          providerMatchesFilters(vehicle,
              status: 'APPROVED', type: 'VEHICLE_PROVIDER', query: ''),
          isTrue);
      expect(
          providerMatchesFilters(vehicle,
              status: 'APPROVED', type: 'SERVICE_PROVIDER', query: ''),
          isFalse);
    });

    test('search matches business, owner, phone and type', () {
      expect(providerMatchesQuery(shop, 'electronics'), isTrue);
      expect(providerMatchesQuery(shop, 'HANNA'), isTrue);
      expect(providerMatchesQuery(shop, '0911223344'), isTrue);
      expect(providerMatchesQuery(shop, 'service_provider'), isTrue);
      expect(providerMatchesQuery(shop, '  '), isTrue);
      expect(providerMatchesQuery(shop, 'pharmacy'), isFalse);
    });

    test('search composes with the status and type filters', () {
      expect(
          providerMatchesFilters(vehicle,
              status: 'APPROVED', type: 'VEHICLE_PROVIDER', query: 'selam'),
          isTrue);
      expect(
          providerMatchesFilters(vehicle,
              status: 'APPROVED', type: 'VEHICLE_PROVIDER', query: 'bole'),
          isFalse);
    });
  });

  group('provider list sort', () {
    final older = provider(id: 'a', name: 'Zewditu Shop', created: '2026-01-01T00:00:00Z');
    final newer = provider(id: 'b', name: 'Abebe Traders', created: '2026-10-01T00:00:00Z');

    test('newest first is the default', () {
      final out = sortProviders([older, newer], 'NEWEST');
      expect(out.first['id'], 'b');
    });

    test('oldest first reverses it', () {
      final out = sortProviders([older, newer], 'OLDEST');
      expect(out.first['id'], 'a');
    });

    test('name sort is case-insensitive', () {
      final out = sortProviders([older, newer], 'NAME');
      expect(out.first['business_name'], 'Abebe Traders');
    });

    test('sorting does not mutate the caller list', () {
      final input = [older, newer];
      sortProviders(input, 'NAME');
      expect(input.first['id'], 'a');
    });
  });

  group('availability queue filters', () {
    test('search reads the item name and the business name', () {
      final r = request();
      expect(
          availabilityMatchesFilters(r, query: 'samsung', provider: 'ALL', days: 0),
          isTrue);
      expect(
          availabilityMatchesFilters(r, query: 'bole', provider: 'ALL', days: 0),
          isTrue);
      expect(
          availabilityMatchesFilters(r, query: 'nokia', provider: 'ALL', days: 0),
          isFalse);
    });

    test('provider filter is exact, not a substring', () {
      final r = request();
      expect(
          availabilityMatchesFilters(r,
              query: '', provider: 'Bole Electronics', days: 0),
          isTrue);
      expect(
          availabilityMatchesFilters(r, query: '', provider: 'Bole', days: 0),
          isFalse);
    });

    test('date window excludes an older request', () {
      final old = request(created: '2026-01-01T00:00:00Z');
      expect(
          availabilityMatchesFilters(old, query: '', provider: 'ALL', days: 7),
          isFalse);
      expect(
          availabilityMatchesFilters(old, query: '', provider: 'ALL', days: 0),
          isTrue);
    });

    test('an unparseable date is excluded from a window, never assumed recent', () {
      final broken = request(created: 'not-a-date');
      expect(
          availabilityMatchesFilters(broken, query: '', provider: 'ALL', days: 1),
          isFalse);
    });

    test('a reason is searchable', () {
      final r = request(reason: 'Sold out until Friday');
      expect(
          availabilityMatchesFilters(r,
              query: 'friday', provider: 'ALL', days: 0),
          isTrue);
    });
  });
}
