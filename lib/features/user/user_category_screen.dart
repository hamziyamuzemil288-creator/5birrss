import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/city_service.dart';
import '../../core/services/product_like_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/product_card.dart';
import '../../core/widgets/subcategory_chip.dart';

/// One category, as a buyer meets it: its sub-categories, the providers who
/// work in it, and its listings.
///
/// ## Where this screen sits in the buyer's path
///
/// Home's three big cards open the group screen
/// (`/user/category-group/:group`), and every row there opens this screen.
/// Both steps are `push`, so the path a buyer walked stays behind them and
/// Back returns to the screen they came from. This screen's sub-category chips
/// used to call `go`, which rebuilds the stack from the top-level route — the
/// parent category and its group were discarded, and Back left the category
/// tree altogether. Same-level navigation now behaves the same way everywhere:
/// one level down is a push, and nothing silently replaces the history.
///
/// ## What every section is drawn with
///
/// The section headings use the home screen's type scale, the sub-category
/// chips are the shared [SubcategoryChip], and the listings are the shared
/// [ProductCard] — the same card the home feed, search results and a
/// provider's page render, including the BUY/BOOK action decided by the
/// listing's own type. The provider rows carry the provider's photo, their
/// published price range and their completed work, which are the facts the
/// home rail's tiles already show for the same people.
class UserCategoryScreen extends StatefulWidget {
  final String categoryId;
  const UserCategoryScreen({super.key, required this.categoryId});

  @override
  State<UserCategoryScreen> createState() => _UserCategoryScreenState();
}

class _UserCategoryScreenState extends State<UserCategoryScreen> {
  Map<String, dynamic>? _category;
  List<Map<String, dynamic>> _subcategories = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _providers = [];
  bool _loading = true;
  String? _error;

  /// The browse city this screen's product list was fetched for. The list is
  /// held in [_products], so a category page opened before the user changed
  /// city would keep rendering the previous city's products until it was
  /// reopened. Subscribing to [CityService] re-queries instead, which is what
  /// "city-selected listing" is supposed to mean.
  final CityService _cityService = CityService.instance;

  @override
  void initState() {
    super.initState();
    _cityService.addListener(_onBrowseCityChanged);
    _load();
  }

  void _onBrowseCityChanged() {
    if (!mounted) return;
    _load();
  }

  @override
  void dispose() {
    _cityService.removeListener(_onBrowseCityChanged);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final cat =
          await client.from('categories').select().eq('id', widget.categoryId).single();
      final subs = await client
          .from('categories')
          .select()
          .eq('parent_id', widget.categoryId)
          .eq('is_active', true)
          .order('sort_order');
      final city = CityService.instance.activeCity;
      // User-visible image column. A provider sets it on the business profile
      // edit sheet; when it is missing the listing still loads, but the tile
      // renders a green placeholder so the panel never shows a broken image.
      //
      // An empty browse city is "All cities" and is sent as NULL; the function
      // treats an empty/NULL city as "do not filter" (20261010000002).
      final prods = await client.rpc('visible_products_for_city', params: {
        'p_city': city.isEmpty ? null : city,
        'p_category_id': widget.categoryId,
      });
      final prodsRaw = List<Map<String, dynamic>>.from(prods as List);
      final providers = await client.rpc('ranked_providers', params: {
        'p_category_id': widget.categoryId,
        'p_limit': 10,
      });
      final ranked = List<Map<String, dynamic>>.from(providers as List);

      // Hydrate images. The RPC returns the listing row; the image is attached
      // from `product_images` so the tile can show the photo, and a
      // location-less listing still carries its image even though it will be
      // ranked below located rows.
      final imgs = prodsRaw.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await client
              .from('product_images')
              .select()
              .inFilter(
                'product_id',
                prodsRaw.map((p) => p['id'] as String).toList(),
              ));
      final imagesByProduct = <String, List<Map<String, dynamic>>>{};
      for (final im in imgs) {
        (imagesByProduct[im['product_id'] as String] ??= []).add(im);
      }
      // The hearts on this grid: the caller's own reaction has to be known
      // BEFORE the cards render, or every heart shows empty and the first tap
      // clears a like the user already had. One batched call for the page —
      // the same one the home rail makes for its own grid.
      final likeCounts = <String, int>{
        for (final p in prodsRaw)
          p['id'] as String: (p['like_count'] as num?)?.toInt() ?? 0,
      };
      ProductLikeService.instance.ensureLoaded(
        prodsRaw.map((p) => p['id'] as String),
        likeCountOf: (id) => likeCounts[id] ?? 0,
      );

      if (mounted) {
        setState(() {
          _category = cat;
          _subcategories = List<Map<String, dynamic>>.from(subs as List);
          _products = prodsRaw
              .map<Map<String, dynamic>>((p) => {
                    ...p,
                    'image': imagesByProduct[p['id'] as String] ??
                        const <Map<String, dynamic>>[],
                  })
              .toList();
          _providers = ranked;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load this category');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_category?['name'] ?? 'Category'),
        actions: const [CartIconButton()],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppTheme.primaryGreen,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      // Sub-categories. Each chip PUSHES the category it names
                      // rather than replacing this screen: the buyer keeps the
                      // path they walked, and Back returns to the parent.
                      if (_subcategories.isNotEmpty) ...[
                        _sectionTitle('Subcategories'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _subcategories
                              .map((s) => SubcategoryChip(
                                    label: (s['name'] ?? '').toString(),
                                    onTap: () => context
                                        .push('/user/category/${s['id']}'),
                                  ))
                              .toList(),
                        ),
                        const SizedBox(height: 20),
                      ],
                      // The people, ranked by completed work.
                      if (_providers.isNotEmpty) ...[
                        _sectionTitle('Top providers'),
                        const SizedBox(height: 8),
                        ..._providers.map(_providerRow),
                        const SizedBox(height: 8),
                      ],
                      // Products — the SAME card the home feed uses.
                      //
                      // This screen used to hand-roll its own listing tile: a
                      // photo, a name and a price with no way to act on any of
                      // it, so a listing a buyer could buy in two taps from the
                      // home rail was a dead end on its own category page. The
                      // shared card carries the photo, the price AND the
                      // BUY button together, which is what makes that class of
                      // inconsistency impossible to reintroduce one screen at a
                      // time.
                      _sectionTitle('Products (${_products.length})'),
                      const SizedBox(height: 8),
                      if (_products.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(30),
                          child: Center(
                            child: Text(
                              'No products in this category yet',
                              style: TextStyle(color: AppTheme.textMuted),
                            ),
                          ),
                        )
                      else
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            // The home feed's own ratio, so one listing is the
                            // same size wherever a buyer meets it.
                            childAspectRatio: 0.66,
                          ),
                          itemCount: _products.length,
                          itemBuilder: (_, i) {
                            final p = _products[i];
                            // User-visible image column. A provider sets it on
                            // the product form and this screen hydrates it from
                            // `product_images`, so the card always leads with
                            // the photo the provider picked; `listingCoverUrl`
                            // reads the same row the feed's card does.
                            final unitPrice =
                                (p['price_per_unit'] as num?)?.toDouble() ?? 0;
                            return ProductCard.listing(
                              productId: (p['id'] ?? '') as String,
                              providerId: (p['provider_id'] ?? '') as String,
                              title: (p['name'] ?? '') as String,
                              priceLabel: listingPriceLabel(p),
                              // BUY for a good, BOOK for a service or a room:
                              // the row's own listing_type, so this page cannot
                              // call a bookable thing a purchase. Nothing to
                              // pass for the photo — `visible_products_for_city`
                              // excludes photo-less listings server-side
                              // (20261011000001).
                              listingType: p['listing_type'] as String?,
                              imageUrl: listingCoverUrl(
                                  (p['image'] as List?) ?? const []),
                              // The per-unit price leads when there is one (the
                              // number a buyer weighs against a fixed price),
                              // otherwise the listing's own words.
                              caption: unitPrice > 0
                                  ? '${p['price_per_unit']} ${p['unit'] ?? 'kg'} each'
                                  : ((p['description'] ?? '') as String),
                              rating: (p['rating'] as num?)?.toDouble() ?? 0,
                              likeCount:
                                  (p['like_count'] as num?)?.toInt() ?? 0,
                              isAvailable: p['is_available'] != false,
                              onTap: () =>
                                  context.push('/user/product/${p['id']}'),
                            );
                          },
                        ),
                    ],
                  ),
                ),
    );
  }

  /// A section heading on this screen.
  ///
  /// The same type scale and colour the buyer home's sections use, so a
  /// category page reads as part of the same app instead of a list with
  /// headings of its own.
  Widget _sectionTitle(String text) => Text(
        text,
        style: const TextStyle(
          fontSize: 16.5,
          fontWeight: FontWeight.w700,
          color: AppTheme.textPrimary,
        ),
      );

  /// One ranked provider, as a row.
  ///
  /// The row always opened the provider's page; what it did not carry was the
  /// provider's own photo, their published price range, or their place in the
  /// ranking, so the same business was described differently here (rank badge,
  /// no photo) and on the home rail and in the "All providers" sheet (photo,
  /// price range, completed work). The facts are read off the same
  /// `ranked_providers` row all three lists are built from, so they cannot
  /// disagree about who is biggest.
  Widget _providerRow(Map<String, dynamic> p) {
    final id = (p['id'] ?? '').toString();
    final name = ((p['business_name'] as String?) ?? '').trim();
    final city = ((p['city'] as String?) ?? '').trim();
    final range = ((p['price_range'] as String?) ?? '').trim();
    final jobs = (p['completed_transactions'] as num?)?.toInt() ?? 0;
    final rank = (p['rank_position'] as num?)?.toInt();
    final path = ((p['photo_storage_path'] as String?) ?? '').trim();
    // The provider's business photo, from the same bucket and the same column
    // the home rail resolves its tiles from. A provider with no photo gets the
    // placeholder rather than a broken image box.
    final photoUrl = path.isEmpty
        ? null
        : Supabase.instance.client.storage
            .from('provider-photos')
            .getPublicUrl(path);
    final facts = <String>[
      if (jobs > 0) '$jobs completed job${jobs == 1 ? '' : 's'}',
      if (range.isNotEmpty) range,
      if (jobs == 0 && city.isNotEmpty) city,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: id.isEmpty ? null : () => context.push('/user/provider/$id'),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.cardBorder, width: 0.5),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: photoUrl == null
                      ? const _ProviderPhotoPlaceholder()
                      : Image.network(
                          photoUrl,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          // Never stretch a cached frame while it re-decodes.
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) =>
                              const _ProviderPhotoPlaceholder(),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name.isEmpty ? 'Unnamed provider' : name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                          if (rank != null && rank > 0)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.primaryGreen.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                '#$rank',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.primaryGreenDark,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        facts.isEmpty
                            ? 'No completed jobs yet'
                            : facts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppTheme.textMuted, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The row's photo slot when a provider has published none.
class _ProviderPhotoPlaceholder extends StatelessWidget {
  const _ProviderPhotoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      color: AppTheme.creamDark,
      child: const Icon(Icons.storefront_outlined,
          size: 20, color: AppTheme.textMuted),
    );
  }
}
