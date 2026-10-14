import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../models/product.dart';
import 'rank_badge.dart';
import 'product_engagement.dart';
import 'product_buy_button.dart';

/// The display price of a raw `products` row: `50 ETB`, or `50 ETB/kg` for a
/// listing sold per unit.
///
/// Public and shared on purpose. Three screens read listing rows straight from
/// an RPC (`visible_products_for_city`, `search_products`) rather than through
/// [Product], and before this existed each one formatted the number its own
/// way — the search list dropped the `/kg` an item was actually priced by, and
/// the category grid printed a bare number with no currency at all. One
/// formatter means the same listing cannot quote two prices.
///
/// The number it prints is the PUBLIC price — the generated
/// `products.display_price` column (migration 20261014000002: provider price
/// + 5 + 1.9%), which every public read now carries. `price` (the provider's
/// own raw number) is only read as a fallback for a database that has not run
/// that migration yet, so a stale backend shows what it always showed rather
/// than an empty card. The markup is NEVER computed here: one column, one
/// arithmetic, one source.
String listingPriceLabel(Map<String, dynamic> row) {
  final price = ((row['display_price'] ?? row['price']) as num?)?.toDouble();
  if (price == null) return '';
  final currency = (row['currency'] as String?) ?? 'ETB';
  final unit = row['unit'] as String?;
  final number =
      price == price.roundToDouble() ? price.toStringAsFixed(0) : price.toStringAsFixed(2);
  if (unit == 'KG') return '$number $currency/kg';
  if (unit == 'LTR') return '$number $currency/liter';
  return '$number $currency';
}

/// The cover photo path of a raw `product_images` result: the row with the
/// lowest `sort_order`, which is what the upload path writes first
/// (`product_images` has no `is_primary` column, so sort order is the only
/// truth there is). Null when the listing has no usable photo — [Product]'s
/// `coverStoragePath` is the same rule for a parsed model, so "does this
/// listing have a photo?" has exactly one answer per shape.
String? listingCoverPathFromRows(List<dynamic> images) {
  final rows = images.whereType<Map>().toList()
    ..sort((a, b) => ((a['sort_order'] as num?)?.toInt() ?? 0)
        .compareTo((b['sort_order'] as num?)?.toInt() ?? 0));
  for (final row in rows) {
    final path = (row['storage_path'] as String?)?.trim();
    if (path != null && path.isNotEmpty) return path;
  }
  return null;
}

/// The public URL of a listing row's cover photo, or null when it has none.
String? listingCoverUrl(List<dynamic> images) {
  final path = listingCoverPathFromRows(images);
  if (path == null) return null;
  return Supabase.instance.client.storage
      .from('product-images')
      .getPublicUrl(path);
}

/// What the ONE action button says for a listing of [listingType].
///
/// A SERVICE or a ROOM is BOOKED (a beauty appointment, a hotel room, a tow
/// truck); a PRODUCT, FOOD or OTHER is BOUGHT. This is the only definition of
/// that rule in the app — [ProductCard] and the product detail screen's primary
/// button both read it (through `Product.actionLabel`) — which is what stops the
/// same service from reading BUY on one surface and BOOK on the next.
String listingActionLabel(String? listingType) {
  final type = (listingType ?? '').trim().toUpperCase();
  return (type == 'SERVICE' || type == 'ROOM') ? 'Book' : 'Buy';
}

/// One product, service or provider photo, always as the same card: **image,
/// price and a BUY / BOOK button, together, on every screen that shows one.**
///
/// THE REPORT this exists for: the buy/book action and the price were on some
/// listing surfaces and not on others, so the same item was buyable from the
/// home rail, un-actionable on its category page, and picture-only where
/// provider photos were mixed into the feed. Every one of those was a separate
/// hand-rolled card, and a fix to one of them did nothing for the other three.
///
/// So there is one card and three ways to build it:
///
///   * [ProductCard] — the caller has a [Product] (the home rail);
///   * `ProductCard.listing` — the caller has a raw listing row from an RPC
///     (a category page, a search result), or a photo of a listing;
///   * `ProductCard.provider` — the photo belongs to a provider rather than to
///     one listing (a gallery photo mixed into the feed): the price line is
///     their published price range and the action is BOOK, which opens their
///     page — the only honest action a provider photo can offer.
///
/// The BUY / BOOK button is [ProductBuyButton], which is the single entry point
/// into the availability gate (`/user/availability`) and therefore into the
/// checkout behind it. No card here carries a button of its own, so no card
/// can drift into a dead one.
class ProductCard extends StatelessWidget {
  final _CardData _data;

  /// What the tile does when tapped. The button inside it is separate: a tap
  /// anywhere opens the listing, the button starts the purchase.
  final VoidCallback? onTap;

  ProductCard({
    super.key,
    required Product product,
    this.onTap,
    String? imageUrl,
  }) : _data = _CardData(
          id: product.id,
          providerId: product.providerId,
          title: product.name,
          priceLabel: product.formattedDisplayPrice,
          imageUrl: imageUrl ?? _productCoverUrl(product),
          rating: product.rating,
          likeCount: product.likeCount,
          available: product.isAvailable,
          // Bought or booked, from the listing's own `listing_type` — a service
          // on the home rail says BOOK, exactly as it does everywhere else.
          actionLabel: product.actionLabel,
        );

  /// A listing the caller has as a raw row: an RPC result, or a photo of one.
  ///
  /// [listingType] is the row's own `listing_type` and decides the button:
  /// BOOK for a SERVICE or a ROOM, BUY otherwise (see
  /// [listingActionLabel]). It is optional only so an older caller still
  /// compiles — a caller that has the column must pass it, or a bookable
  /// service renders the wrong verb.
  ProductCard.listing({
    super.key,
    required String productId,
    required String providerId,
    required String title,
    required String priceLabel,
    String? listingType,
    String? imageUrl,
    String? caption,
    double rating = 0,
    int likeCount = 0,
    bool isAvailable = true,
    this.onTap,
  }) : _data = _CardData(
          id: productId,
          providerId: providerId,
          title: title,
          priceLabel: priceLabel,
          imageUrl: imageUrl,
          caption: caption,
          rating: rating,
          likeCount: likeCount,
          available: isAvailable,
          actionLabel: listingActionLabel(listingType),
        );

  /// A provider's own photo — their gallery, or the feed's mixed-in gallery
  /// tiles. There is no listing id behind it, so the card leads with their name
  /// and price range and the action reads BOOK.
  ProductCard.provider({
    super.key,
    required String providerId,
    required String title,
    required String priceLabel,
    String? imageUrl,
    String? caption,
    this.onTap,
  }) : _data = _CardData(
          id: '',
          providerId: providerId,
          title: title,
          priceLabel: priceLabel,
          imageUrl: imageUrl,
          caption: caption,
          actionLabel: 'Book',
        );

  /// The photo a card leads with: the listing's primary image — the row
  /// with the lowest `sort_order`, which is what the upload path writes
  /// first — never whatever the storage layer happened to return first.
  ///
  /// This is what made Fresh Finds look broken: `images.first` was raw row
  /// order, so a card could show a secondary screenshot, or a thin band of
  /// one, instead of the photo the provider actually picked.
  static String? _productCoverUrl(Product product) {
    final path = product.coverStoragePath;
    if (path == null) return null;
    return Supabase.instance.client.storage
        .from('product-images')
        .getPublicUrl(path);
  }

  @override
  Widget build(BuildContext context) {
    final String? img = _data.data.imageUrl;
    // A card with no photo is the TEXT-ONLY card: name, price and the same
    // action, with no image area at all. That is what a photo-less listing
    // renders as on its own provider's page — the one surface allowed to show
    // it. Every public discovery read keeps those rows out (see
    // `Product.hasPhoto` and migration 20261011000001), so an empty frame here
    // would only ever be a broken image read as a broken listing.
    final hasImage = img != null && img.isNotEmpty;
    // Engagement widgets address a listing row by id. A provider photo has no
    // listing behind it, so the reactions, the popularity mark and the provider
    // tag are all omitted for it rather than pointed at an id that does not
    // exist — which is how a tile ends up rendering a reaction it can never
    // record.
    final isListing = _data.id.isNotEmpty;
    final hasProvider = _data.providerId.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image — Expanded (not a fixed 1:1 AspectRatio) so the card
            // always fills its grid slot: the text block keeps its intrinsic
            // height and the image absorbs whatever remains. A fixed square
            // image + fixed text scaled as width + ~80dp while the slot scaled
            // as width / childAspectRatio, which overflowed by a few pixels on
            // some device widths (BOTTOM OVERFLOWED BY 4.1 PIXELS).
            if (hasImage)
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: AppTheme.creamDark,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(12)),
                    // CONTAIN, not cover — the Part 7 fix.
                    //
                    // The report was "public product images are cropped / cut
                    // off", and the cause was the fit, not the frame: the
                    // image area is an Expanded slot whose height depends on
                    // the card width, the grid's childAspectRatio and the
                    // device, so its aspect ratio matches no particular
                    // photo. `cover` fills that frame by cutting whatever
                    // falls outside it — a tall shop-front loses its top and
                    // bottom, a wide one loses its sides — on every screen
                    // that renders this card.
                    //
                    // `contain` shows the WHOLE photo, centred, letterboxed
                    // against the card's own tint — nothing is cut, on any
                    // aspect ratio. The frame, the grid geometry and the
                    // rounded clip are unchanged, so the card layout every
                    // grid depends on is identical; only what is drawn inside
                    // the image area changed. This is the ONE shared card, so
                    // home, search, category, trending-mixed feed and the
                    // provider gallery all change together — there is no
                    // second card to keep in sync.
                    child: SizedBox(
                      width: double.infinity,
                      height: double.infinity,
                      child: CachedNetworkImage(
                        imageUrl: img,
                        fit: BoxFit.contain,
                        alignment: Alignment.center,
                        filterQuality: FilterQuality.medium,
                        placeholder: (_, __) => const Center(
                            child: CircularProgressIndicator(
                                strokeWidth: 2)),
                        errorWidget: (_, __, ___) => const Center(
                          child: Icon(Icons.image_outlined,
                              color: AppTheme.textMuted, size: 40),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // Info
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(_data.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                      // Popular is a CEO-tunable social signal, not a claim we
                      // verify here: the threshold lives in system_settings
                      // and the count is maintained by a database trigger.
                      if (isListing)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: PopularMark(
                              productId: _data.id,
                              fallbackCount: _data.likeCount),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // Who is selling it. One tap to their existing detail
                  // screen; it adds no new surface of its own. A provider tile
                  // leads with their own name, so the tag would only repeat it.
                  if (isListing && hasProvider)
                    ProviderNameTag(providerId: _data.providerId),
                  if (_data.caption != null && _data.caption!.isNotEmpty) ...[
                    // One line of context the caller already had and used to
                    // print somewhere else (a caption, a distance, a city).
                    Text(
                      _data.caption!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary),
                    ),
                  ],
                  const SizedBox(height: 2),
                  // Price and the BUY action share one row: the number the
                  // buyer is deciding on and the button that acts on it read
                  // together, and it costs no extra height on a grid tile.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                            _data.priceLabel.isEmpty
                                ? 'See prices'
                                : _data.priceLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.primaryGreen)),
                      ),
                      const SizedBox(width: 6),
                      // The single purchase entry point, and the reason this
                      // card exists: an empty listing id means "this tile is a
                      // provider", and the button then opens their page, so it
                      // is never a dead control either way.
                      ProductBuyButton(
                        productId: _data.id,
                        providerId: _data.providerId,
                        label: _data.actionLabel,
                        compact: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (_data.rating > 0) ...[
                        const Icon(Icons.star, color: AppTheme.gold, size: 14),
                        const SizedBox(width: 2),
                        Text('${_data.rating.toStringAsFixed(1)}',
                            style: const TextStyle(
                                fontSize: 11, color: AppTheme.textSecondary)),
                        const SizedBox(width: 4),
                      ],
                      if (!_data.available)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.error.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('Unavailable',
                              style: TextStyle(
                                  fontSize: 10, color: AppTheme.error)),
                        ),
                      // The seller's rank, where a buyer is choosing. A trust
                      // signal and nothing more: it gates no product and no
                      // order. Renders nothing until the batched lookup lands,
                      // so a grid of cards costs one round trip, not twelve.
                      const Spacer(),
                      if (hasProvider) RankBadge(providerId: _data.providerId),
                      if (isListing) ...[
                        const SizedBox(width: 4),
                        // Reaction, not rating: the thumb-down says "not for
                        // me" and shows no count, because dislike counts are
                        // deliberately not public (migration 20260927000076).
                        DislikeButton(
                            productId: _data.id,
                            fallbackCount: _data.likeCount),
                        LikeButton(
                            productId: _data.id,
                            fallbackCount: _data.likeCount),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The fields one card renders, whichever constructor produced it.
class _CardData {
  final String id;
  final String providerId;
  final String title;
  final String priceLabel;
  final String? imageUrl;
  final String? caption;
  final double rating;
  final int likeCount;
  final bool available;
  final String actionLabel;

  const _CardData({
    required this.id,
    required this.providerId,
    required this.title,
    required this.priceLabel,
    this.imageUrl,
    this.caption,
    this.rating = 0,
    this.likeCount = 0,
    this.available = true,
    this.actionLabel = 'Buy',
  });
}
