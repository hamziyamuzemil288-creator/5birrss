/// Product/Listing model mapped to the `products` Supabase table.
/// Supports all listing types: PRODUCT, FOOD, SERVICE, ROOM, OTHER.
class Product {
  final String id;
  final String providerId;
  final String? categoryId;
  final String name;
  final String? description;

  /// The provider's own raw price (`products.price`) — what the product form
  /// writes and what the PROVIDER's own screens show. Never shown publicly:
  /// since migration 20261014000002 every buyer-facing surface reads
  /// [publicPrice] instead.
  final double price;

  /// The PUBLIC price — the generated `products.display_price` column
  /// (provider price + 5 + 1.9%, computed once in the database). Null only
  /// when the row predates migration 20261014000002; callers fall back to
  /// [price] so a database that has not run the migration yet behaves as it
  /// did before. This is a READ, never a Dart computation: the arithmetic
  /// exists exactly once, in the table.
  final double? publicPrice;
  final String currency;
  final String listingType; // PRODUCT, FOOD, SERVICE, ROOM, OTHER
  final int? quantity;
  final double pricePerUnit; // >0 for unit-priced listings (per kg/liter)
  final String? unit; // 'KG' | 'LTR' | null (fixed-price listing)
  final int? stockQuantity;
  final int? lowStockThreshold;
  final String listingStatus; // ACTIVE, DRAFT, SOLD_OUT, ARCHIVED
  final bool isAvailable;
  final bool isActive;
  final double rating;
  final int reviewCount;
  final int salesCount;

  /// Denormalised like count, maintained by a database trigger on
  /// `product_likes`. Never computed in Dart: a list query must not count
  /// rows, which is the whole reason the column exists.
  final int likeCount;

  /// When true, a buyer must wait for the provider to confirm this
  /// listing is available before they see payment details or can upload a
  /// payment screenshot. Defaults to false so every existing listing keeps
  /// the behaviour it has today.
  final bool requiresAvailabilityConfirmation;

  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ListingImage> images;

  const Product({
    required this.id,
    required this.providerId,
    this.categoryId,
    required this.name,
    this.description,
    required this.price,
    this.publicPrice,
    this.currency = 'ETB',
    this.listingType = 'PRODUCT',
    this.quantity,
    this.pricePerUnit = 0,
    this.unit,
    this.stockQuantity,
    this.lowStockThreshold,
    this.listingStatus = 'ACTIVE',
    this.isAvailable = true,
    this.isActive = true,
    this.rating = 0,
    this.reviewCount = 0,
    this.salesCount = 0,
    this.likeCount = 0,
    this.requiresAvailabilityConfirmation = false,
    this.metadata,
    required this.createdAt,
    required this.updatedAt,
    this.images = const [],
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['id'] as String,
      providerId: json['provider_id'] as String,
      categoryId: json['category_id'] as String?,
      name: json['name'] as String,
      description: json['description'] as String?,
      price: (json['price'] as num).toDouble(),
      // Absent means the database has not run 20261014000002 yet; the
      // getters below then fall back to `price` rather than showing nothing.
      publicPrice: (json['display_price'] as num?)?.toDouble(),
      currency: json['currency'] as String? ?? 'ETB',
      listingType: json['listing_type'] as String? ?? 'PRODUCT',
      quantity: json['quantity'] as int?,
      pricePerUnit: (json['price_per_unit'] as num?)?.toDouble() ?? 0,
      unit: json['unit'] as String?,
      stockQuantity: json['stock_quantity'] as int?,
      lowStockThreshold: json['low_stock_threshold'] as int?,
      listingStatus: json['listing_status'] as String? ?? 'ACTIVE',
      isAvailable: json['is_available'] as bool? ?? true,
      isActive: json['is_active'] as bool? ?? true,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      reviewCount: json['review_count'] as int? ?? 0,
      salesCount: json['sales_count'] as int? ?? 0,
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      // Absent means the column does not exist yet (a database that has not
      // run migration 20260927000074). `?? false` is the safe direction: an
      // old database must behave exactly as it did before this field existed.
      requiresAvailabilityConfirmation:
          (json['requires_availability_confirmation'] as bool?) ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  String get formattedPrice => '$price $currency';

  /// True when this listing is BOOKED rather than bought.
  ///
  /// The schema has carried the answer since the first migration:
  /// `products.listing_type` is the enum `listing_type`
  /// ('PRODUCT','FOOD','SERVICE','ROOM','OTHER', 0022a, line 17). A physical
  /// good (PRODUCT, FOOD, OTHER) is BOUGHT; a bookable thing (SERVICE, ROOM) is
  /// BOOKED. Nothing in the app re-derives that list: [actionLabel] and the
  /// shared card's `listingActionLabel()` both read it, so one screen cannot
  /// call a service BUY while the next calls it BOOK.
  bool get isBookable => listingType == 'SERVICE' || listingType == 'ROOM';

  /// What the action button on this listing says. `'Book'` or `'Buy'` — never
  /// both, never neither.
  String get actionLabel => isBookable ? 'Book' : 'Buy';

  /// The storage path of this listing's cover photo, or null when it has none.
  ///
  /// The cover is the row with the lowest `sort_order`, which is what the
  /// upload path writes first — `product_images` has no `is_primary` column,
  /// so sort order is the only truth there is. The shared helpers in
  /// `core/widgets/product_card.dart` apply the same rule to a raw
  /// `product_images` result, and `hasPhoto` is what a public discovery read
  /// uses to keep a photo-less listing out of the feed (it belongs on its own
  /// provider's page, where it renders as a text-only card).
  String? get coverStoragePath {
    final sorted = [...images]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    for (final image in sorted) {
      final path = image.storagePath.trim();
      if (path.isNotEmpty) return path;
    }
    return null;
  }

  /// True when this listing has a photo a card can show.
  bool get hasPhoto => coverStoragePath != null;

  /// True when the listing is sold by unit (kg / liter).
  bool get isUnitPriced => unit == 'KG' || unit == 'LTR';

  /// Display price: "50 ETB/kg" for unit-priced items, "50 ETB" otherwise.
  ///
  /// The number shown is ALWAYS the public price (the generated
  /// `display_price` — provider price + 5 + 1.9%), never the provider's raw
  /// [price]. One column, read here; no screen recomputes the markup.
  String get formattedDisplayPrice {
    final shown = publicPrice ?? price;
    if (!isUnitPriced) return '${_fmt(shown)} $currency';
    final unitWord = unit == 'KG' ? 'kg' : 'liter';
    return '${_fmt(shown)} $currency/$unitWord';
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  bool get inStock => stockQuantity == null || (stockQuantity ?? 0) > 0;

  bool get isLowStock =>
      stockQuantity != null &&
      lowStockThreshold != null &&
      stockQuantity! <= lowStockThreshold!;

  bool get isActiveListing =>
      isActive && listingStatus == 'ACTIVE' && isAvailable;
}

/// Listing image model mapped to the `listing_images` Supabase table.
/// Unified image management for all listing types.
class ListingImage {
  final String id;
  final String listingId;
  final String storagePath;
  final String? altText;
  final bool isPrimary;
  final int sortOrder;

  const ListingImage({
    required this.id,
    required this.listingId,
    required this.storagePath,
    this.altText,
    this.isPrimary = false,
    this.sortOrder = 0,
  });

  factory ListingImage.fromJson(Map<String, dynamic> json) {
    return ListingImage(
      id: json['id'] as String,
      listingId:
          json['listing_id'] as String? ?? json['product_id'] as String? ?? '',
      storagePath: json['storage_path'] as String,
      altText: json['alt_text'] as String?,
      isPrimary: json['is_primary'] as bool? ?? false,
      sortOrder: json['sort_order'] as int? ?? 0,
    );
  }
}

/// Legacy product image model mapped to the `product_images` Supabase table.
/// Kept for backward compatibility with existing code.
@Deprecated('Use ListingImage instead for new code')
class ProductImage {
  final String id;
  final String productId;
  final String storagePath;
  final int sortOrder;

  const ProductImage({
    required this.id,
    required this.productId,
    required this.storagePath,
    this.sortOrder = 0,
  });

  factory ProductImage.fromJson(Map<String, dynamic> json) {
    return ProductImage(
      id: json['id'] as String,
      productId: json['product_id'] as String,
      storagePath: json['storage_path'] as String,
      sortOrder: json['sort_order'] as int? ?? 0,
    );
  }
}
