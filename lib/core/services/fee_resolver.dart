import 'package:supabase_flutter/supabase_flutter.dart';

import 'city_service.dart';

/// One resolved fee, with the resolver that produced it.
///
/// The whole point of this class is [source]: a number on a screen is only
/// trustworthy when it was answered by the SAME database function the charge
/// calls. A preview that computes a fee itself — `amount * percent / 100` in
/// Dart — is a second copy of a pricing rule, and the two copies drift the
/// first time an admin edits a fee. So every method here returns a value that
/// came off an RPC, never off local arithmetic, and [source] names the reader
/// so a test (and a support engineer) can verify that.
class FeeQuote {
  const FeeQuote({required this.value, required this.source, this.degraded = false});

  /// The number the server resolved. Null when the reader could not be
  /// reached at all — callers show "unavailable", never a made-up 0.
  final double? value;

  /// The resolver RPC that produced [value].
  final String source;

  /// True when the primary resolver was missing and a documented fallback
  /// answered instead (a deployment that has not run migration 00107).
  final bool degraded;

  bool get hasValue => value != null;
}

/// One delivery fee as the server resolved it, with the distance it priced.
///
/// [ok] is false when the server could not price a delivery at all — the
/// provider has published no point, or the buyer has not chosen one. That is
/// reported as a REASON, never as a zero: a delivery fee invented when the
/// distance is unknown would be a number nobody could justify.
class DeliveryQuote {
  const DeliveryQuote({
    required this.ok,
    required this.reason,
    required this.fee,
    required this.distanceKm,
    this.message,
  });

  final bool ok;
  final String? reason;
  final double? fee;
  final double? distanceKm;
  final String? message;

  bool get hasValue => ok && fee != null;

  static const DeliveryQuote unavailable = DeliveryQuote(
    ok: false,
    reason: 'UNAVAILABLE',
    fee: null,
    distanceKm: null,
  );
}

/// The app's single door to every fee the platform charges.
///
/// ## The contract this class exists to keep
///
/// For each money path there is exactly one resolver, and the charge function
/// and every preview call THE SAME ONE. [chargePathResolvers] states the
/// mapping explicitly, and `test/fee_preview_uses_charge_resolvers_test.dart`
/// reads both this map and the migration SQL to prove it still holds — if a
/// charge path is ever restated to call a different reader, that test fails
/// instead of the app quietly quoting one number and charging another.
///
/// | Charge path                | Resolver                     |
/// |----------------------------|------------------------------|
/// | `create_ride_request`      | `calculate_fare_estimate_at` |
/// | `deduct_transaction_fee`   | `platform_transaction_fee_for` |
/// | `deduct_subscription_fee`  | `fee_subscription`           |
/// | `approve_wallet_recharge`  | `fee_activation`             |
/// | booking creation           | `calculate_booking_fee_at`   |
/// | `create_provider_product`  | `fee_product_listing_fee`    |
///
/// ## Fail-soft, never fail-silent
///
/// Every method catches and returns a [FeeQuote] with a null value rather
/// than throwing into a `build()`. A preview is advisory; the server
/// re-resolves on submit. But a null is reported as "unavailable", so a
/// screen never renders a fabricated zero as if it were the price.
class FeeResolver {
  FeeResolver._();
  static final FeeResolver instance = FeeResolver._();

  SupabaseClient get _client => Supabase.instance.client;

  /// The charge function -> the resolver RPC it must call. Read by the
  /// same-resolver test and printed by the "why this number" tooltip.
  static const Map<String, String> chargePathResolvers = {
    'create_ride_request': 'calculate_fare_estimate_at',
    'deduct_transaction_fee': 'platform_transaction_fee_for',
    'deduct_subscription_fee': 'fee_subscription',
    'approve_wallet_recharge': 'fee_activation',
    'calculate_booking_fee_at': 'calculate_booking_fee_at',
    'create_provider_product': 'fee_product_listing_fee',
    // Part 10: the delivery fee a buyer is quoted at checkout and the fee the
    // `order-create` Edge Function adds to the order total are the same number
    // because both read THIS one function. It prices through
    // calculate_fare_estimate_at — the reader create_ride_request charges a
    // ride with — and applies the markup products.display_price is generated
    // from, so a delivery is the ride fare plus the product markup and not a
    // second formula.
    'order-create (delivery fee)': 'quote_delivery_fee',
  };

  /// The category and city a PROVIDER's fees resolve against, from
  /// `provider_fee_context()` — the exact function `approve_wallet_recharge()`
  /// now reads before withholding the activation fee (20261007000005). So a
  /// provider-side preview and the charge agree on WHICH fee applies, not just
  /// on how it is computed. Returns nulls when the provider is unknown.
  Future<({String? categoryId, String? city})> providerContext(
      String providerId) async {
    try {
      final res = await _client.rpc('provider_fee_context',
          params: {'p_provider_id': providerId});
      if (res is List && res.isNotEmpty) {
        final row = Map<String, dynamic>.from(res.first as Map);
        final categoryId = (row['category_id'] as String?)?.trim();
        final city = (row['city'] as String?)?.trim();
        return (
          categoryId: (categoryId == null || categoryId.isEmpty) ? null : categoryId,
          city: (city == null || city.isEmpty) ? null : city,
        );
      }
    } catch (_) {}
    return (categoryId: null, city: null);
  }

  /// The city a fee resolves against. This is the rider's/provider's OWN city
  /// (`savedCity`), which is what the charge functions read
  /// (`SELECT city FROM profiles WHERE id = p_user_id`) — NOT `activeCity`,
  /// which is the city a user is *browsing* and would drift the quote in the
  /// opposite direction. Null when unknown, which makes the server fall back
  /// to the global rate exactly as an unedited deployment does.
  String? get _city {
    final c = CityService.instance.savedCity?.trim();
    return (c == null || c.isEmpty) ? null : c;
  }

  /// A ride fare for a trip in a vehicle category, from
  /// `calculate_fare_estimate_at` — the resolver `create_ride_request`
  /// charges with. Falls back to the five-argument `calculate_fare_estimate`
  /// only when the city-aware reader does not exist yet (a deployment that has
  /// not run 00107), which is flagged [FeeQuote.degraded] so the UI can say so.
  Future<FeeQuote> rideFare({
    required double pickupLat,
    required double pickupLng,
    required double destLat,
    required double destLng,
    String? vehicleCategoryId,
    double? distanceKm,
  }) async {
    final city = _city;
    try {
      final res = await _client.rpc('calculate_fare_estimate_at', params: {
        'p_pickup_lat': pickupLat,
        'p_pickup_lng': pickupLng,
        'p_dest_lat': destLat,
        'p_dest_lng': destLng,
        if (vehicleCategoryId != null) 'p_vehicle_category_id': vehicleCategoryId,
        if (city != null) 'p_city': city,
      });
      return FeeQuote(
        value: (res as num?)?.toDouble(),
        source: 'calculate_fare_estimate_at',
      );
    } catch (_) {
      try {
        final res = await _client.rpc('calculate_fare_estimate', params: {
          'p_pickup_lat': pickupLat,
          'p_pickup_lng': pickupLng,
          'p_dest_lat': destLat,
          'p_dest_lng': destLng,
          if (vehicleCategoryId != null)
            'p_vehicle_category_id': vehicleCategoryId,
        });
        return FeeQuote(
          value: (res as num?)?.toDouble(),
          source: 'calculate_fare_estimate',
          degraded: true,
        );
      } catch (_) {
        return const FeeQuote(value: null, source: 'calculate_fare_estimate_at');
      }
    }
  }

  /// The delivery fee for a provider -> buyer distance, from
  /// `quote_delivery_fee` — the SAME reader the `order-create` Edge Function
  /// prices the order with, so the number on this screen and the number
  /// charged cannot come from two rules.
  ///
  /// The provider's coordinates are deliberately NOT parameters: they are
  /// private (released to a buyer only after a verified payment), so the
  /// server resolves them. That also means this call is the only way a client
  /// can learn the distance, and it never approximates from the city — an
  /// unpriceable delivery comes back as [DeliveryQuote.ok] false with a
  /// stated reason.
  Future<DeliveryQuote> deliveryFee({
    required String providerId,
    required double deliveryLat,
    required double deliveryLng,
    String? vehicleCategoryId,
    String? city,
  }) async {
    try {
      final res = await _client.rpc('quote_delivery_fee', params: {
        'p_provider_id': providerId,
        'p_delivery_lat': deliveryLat,
        'p_delivery_lng': deliveryLng,
        if (vehicleCategoryId != null)
          'p_vehicle_category_id': vehicleCategoryId,
        if (city != null) 'p_city': city,
      });
      if (res is! Map) return DeliveryQuote.unavailable;
      final row = Map<String, dynamic>.from(res);
      return DeliveryQuote(
        ok: row['ok'] == true,
        reason: row['reason'] as String?,
        fee: (row['fee'] as num?)?.toDouble(),
        distanceKm: (row['distance_km'] as num?)?.toDouble(),
        message: row['message'] as String?,
      );
    } catch (_) {
      return DeliveryQuote.unavailable;
    }
  }

  /// A booking fee for a category, city and distance, from
  /// `calculate_booking_fee_at` — the composed server reader, so the
  /// GREATEST(minimum, base + per_km * km) rule has one home and this class
  /// never restates it.
  Future<FeeQuote> bookingFare({
    required String categoryId,
    required double distanceKm,
    String? city,
  }) async {
    try {
      final res = await _client.rpc('calculate_booking_fee_at', params: {
        'p_category_id': categoryId,
        'p_city': city ?? _city,
        'p_distance_km': distanceKm,
      });
      return FeeQuote(
        value: (res as num?)?.toDouble(),
        source: 'calculate_booking_fee_at',
      );
    } catch (_) {
      return const FeeQuote(value: null, source: 'calculate_booking_fee_at');
    }
  }

  /// The commission PERCENT for a category and city, from
  /// `fee_commission_percent` — the reader `platform_transaction_fee_for`
  /// (and therefore `deduct_transaction_fee`) resolves through. Shown to a
  /// provider as "you are charged X%"; never multiplied here.
  Future<FeeQuote> commissionPercent({
    String? categoryId,
    String? city,
    bool isProduct = false,
  }) async {
    try {
      final res = await _client.rpc('fee_commission_percent', params: {
        'p_category_id': categoryId,
        'p_city': city ?? _city,
        'p_is_product': isProduct,
      });
      return FeeQuote(
        value: (res as num?)?.toDouble(),
        source: 'fee_commission_percent',
      );
    } catch (_) {
      return const FeeQuote(value: null, source: 'fee_commission_percent');
    }
  }

  /// The commission AMOUNT for a sale, from `platform_transaction_fee_for` —
  /// the exact reader `deduct_transaction_fee` charges with. Use this rather
  /// than [commissionPercent] whenever a birr figure is shown, so the number
  /// includes the same per-category minimum the charge applies.
  Future<FeeQuote> commissionAmount({
    required double amount,
    String? categoryId,
    String? city,
    bool isProduct = false,
  }) async {
    try {
      final res = await _client.rpc('platform_transaction_fee_for', params: {
        'p_amount': amount,
        'p_category_id': categoryId,
        'p_city': city ?? _city,
        'p_is_product': isProduct,
      });
      return FeeQuote(
        value: (res as num?)?.toDouble(),
        source: 'platform_transaction_fee_for',
      );
    } catch (_) {
      return const FeeQuote(value: null, source: 'platform_transaction_fee_for');
    }
  }

  /// The monthly subscription, from `fee_subscription` — the reader
  /// `deduct_subscription_fee` charges with.
  Future<FeeQuote> subscriptionFee({
    String? categoryId,
    String? city,
  }) async {
    try {
      final res = await _client.rpc('fee_subscription', params: {
        'p_category_id': categoryId,
        'p_city': city ?? _city,
      });
      return FeeQuote(
        value: (res as num?)?.toDouble(),
        source: 'fee_subscription',
      );
    } catch (_) {
      return const FeeQuote(value: null, source: 'fee_subscription');
    }
  }

  /// The one-time activation (registration) fee, from `fee_activation` — the
  /// reader `approve_wallet_recharge` withholds with (restated in
  /// 20261007000005 to call exactly this).
  Future<FeeQuote> activationFee({
    String? categoryId,
    String? city,
  }) async {
    try {
      final res = await _client.rpc('fee_activation', params: {
        'p_category_id': categoryId,
        'p_city': city ?? _city,
      });
      return FeeQuote(
        value: (res as num?)?.toDouble(),
        source: 'fee_activation',
      );
    } catch (_) {
      return const FeeQuote(value: null, source: 'fee_activation');
    }
  }

  /// The one-time product listing fee, from `fee_product_listing_fee` (added
  /// in 20261007000005) — the number the posting gate shows and the product
  /// catalogue the admin edits resolves.
  Future<FeeQuote> listingFee({
    String? categoryId,
    String? city,
  }) async {
    try {
      final res = await _client.rpc('fee_product_listing_fee', params: {
        'p_category_id': categoryId,
        'p_city': city ?? _city,
      });
      return FeeQuote(
        value: (res as num?)?.toDouble(),
        source: 'fee_product_listing_fee',
      );
    } catch (_) {
      return const FeeQuote(value: null, source: 'fee_product_listing_fee');
    }
  }
}
