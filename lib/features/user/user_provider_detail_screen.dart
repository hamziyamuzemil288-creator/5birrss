import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/models/provider_gallery.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/favorites_service.dart';
import '../../core/services/guest_session.dart';
import '../../core/services/product_like_service.dart';
import '../../core/services/review_service.dart';
import '../../core/utils/category_field_value.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/photo_grid.dart';
import '../../core/widgets/product_buy_button.dart';
import '../../core/widgets/product_card.dart';
import '../../core/widgets/product_engagement.dart';
import '../../core/widgets/provider_trust_section.dart';
import '../../core/widgets/rank_badge.dart';

class UserProviderDetailScreen extends StatefulWidget {
  final String providerId;
  const UserProviderDetailScreen({super.key, required this.providerId});
  @override
  State<UserProviderDetailScreen> createState() => _State();
}

class _State extends State<UserProviderDetailScreen> {
  Map<String, dynamic>? _provider;
  List<Map<String, dynamic>> _products = [];

  /// The provider's OWN gallery, i.e. `provider_gallery`.
  ///
  /// This page had a "Photos" section and no gallery in it. Every tile came
  /// from `product_images` -- the marketplace listings -- so a provider who
  /// spent real money on the gallery upload screen saw none of it here. The
  /// report was "the posting page is missing on gallery after uploading the
  /// image 2", and it was missing because nothing ever queried the table this
  /// screen is about.
  ///
  /// Read through the same RLS policy the rest of the page uses
  /// (`provider_gallery_public_read`: is_active AND an APPROVED provider), so a
  /// hidden photo is absent here for the same reason it is absent everywhere,
  /// rather than being un-hidden by a second query that disagrees.
  List<Map<String, dynamic>> _gallery = [];
  /// The provider's trade-specific declared fields (a hotel's room types, a
  /// doctor's hourly rate) as returned by `provider_public_profile_fields`.
  List<Map<String, dynamic>> _declared = [];
  List<Map<String, dynamic>> _reviews = [];
  ProviderTrustStats? _trust;
  bool _loading = true;
  bool _fav = false;
  bool _reporting = false;
  // A dropped connection used to land on the same "Provider not found" screen
  // as a deleted provider, so a network blip read as "this shop is gone".
  String? _error;
  bool _notFound = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final prov = await client
          .from('public_provider_profiles')
          .select()
          .eq('id', widget.providerId)
          .single();
      final prods = await client
          .from('products')
          .select('*, product_images(*)')
          .eq('provider_id', widget.providerId)
          .eq('is_active', true)
          .order('created_at', ascending: false)
          .limit(50);
      final fav = await FavoritesService.instance
          .isFavorited('PROVIDER', widget.providerId);
      // Non-fatal by design. A gallery that fails to load must not take the
      // whole provider page down with it -- the name, the products and the
      // reviews are all still worth showing, and an empty gallery reads as
      // "this provider has no photos" rather than "we could not ask".
      List<Map<String, dynamic>> gallery = const [];
      try {
        gallery = List<Map<String, dynamic>>.from(await client
                .from('provider_gallery')
                // `price` is listed explicitly because this query names its
                // columns rather than selecting `*` -- which is exactly how
                // migration 0137 caught a gallery query reading columns that
                // do not exist. A per-photo price nobody selects is a price
                // nobody can see, so it is added here in the same change that
                // creates the column.
                .select('id, storage_path, caption, display_order, price')
                .eq('provider_id', widget.providerId)
                .eq('is_active', true)
                .order('display_order') as List);
      } catch (_) {}
      // What this provider's trade lets them declare -- a hotel's room types
      // and nightly rate, a doctor's hourly price and services. Read through a
      // definer RPC that returns nothing at all for a provider that is not
      // approved, so a pending business cannot publish a price here.
      //
      // Non-fatal for the same reason as the gallery: the page is still worth
      // showing without it, and an empty list reads as "this provider has
      // declared nothing" rather than "we could not ask".
      List<Map<String, dynamic>> declared = const [];
      try {
        declared = List<Map<String, dynamic>>.from(await client
            .rpc('provider_public_profile_fields',
                params: {'p_provider_id': widget.providerId}) as List);
      } catch (_) {}
      List<Map<String, dynamic>> reviews = [];
      try {
        reviews = await ReviewService.instance
            .getReviewsForProvider(widget.providerId);
      } catch (_) {}
      // Trust stats come from the provider_trust_stats view (real,
      // aggregated data; view read is non-fatal if unavailable).
      final trust = await ProviderTrustStats.fetch(widget.providerId);
      // The hearts on this provider's listings: the caller's own reaction has
      // to be known BEFORE the cards render, or every heart shows empty and the
      // first tap clears a like the user already had. One batched call for the
      // page, the same one the home rail makes for its own grid.
      final listingRows = List<Map<String, dynamic>>.from(prods as List);
      final likeCounts = <String, int>{
        for (final p in listingRows)
          p['id'] as String: (p['like_count'] as num?)?.toInt() ?? 0,
      };
      ProductLikeService.instance.ensureLoaded(
        listingRows.map((p) => p['id'] as String),
        likeCountOf: (id) => likeCounts[id] ?? 0,
      );
      if (mounted) {
        setState(() {
          _provider = prov;
          _products = listingRows;
          _gallery = gallery;
          _declared = declared;
          _reviews = reviews;
          _trust = trust;
          _fav = fav;
          _loading = false;
          _error = null;
          _notFound = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _notFound = isNotFound(e);
          if (!_notFound) {
            _error = friendlyError(e, context: 'Could not load this provider');
          }
        });
      }
    }
  }

  /// Files a content report about this provider, or about one specific image
  /// on it.
  ///
  /// `file_content_report` landed in 0122 and was reachable from no Dart file,
  /// so `content_reports` has been an empty table: administrators had a queue
  /// to work through and no way for a customer to fill it. The same call is
  /// what `AdminContentControlScreen` reads and acts on, so this closes the
  /// loop end to end.
  ///
  /// The report names `reported_provider_id`, never `reported_user_id`:
  /// `public_provider_profiles` deliberately withholds the owner's account id
  /// (migration 20260924000006 hardened it), and asking the server for it here
  /// would undo that.
  Future<void> _openReport() async {
    final photos = _reportablePhotos();
    var category = 'MISLEADING_LISTING';
    String? chosenPath;
    final bucket = photos.isEmpty ? null : photos.first.bucket;
    final controller = TextEditingController();

    final submit = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Report this provider'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'What is wrong'),
                  items: const [
                    DropdownMenuItem(
                        value: 'MISLEADING_LISTING',
                        child: Text('Misleading listing')),
                    DropdownMenuItem(
                        value: 'SPAM_OR_SCAMS', child: Text('Spam or scam')),
                    DropdownMenuItem(
                        value: 'HARASSMENT', child: Text('Harassment')),
                    DropdownMenuItem(
                        value: 'HATE_OR_ABUSE', child: Text('Hate or abuse')),
                    DropdownMenuItem(
                        value: 'VIOLENT_OR_THREATENING',
                        child: Text('Violence or a threat')),
                    DropdownMenuItem(
                        value: 'NUDITY_OR_SEXUAL',
                        child: Text('Sexual content')),
                    DropdownMenuItem(
                        value: 'FAKE_ACCOUNT', child: Text('Fake account')),
                    DropdownMenuItem(value: 'OTHER', child: Text('Something else')),
                  ],
                  onChanged: (v) => setInner(() => category = v ?? 'OTHER'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 3,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                    labelText: 'What happened',
                    helperText:
                        'At least 10 characters. An administrator cannot ask '
                        'you a follow-up question, so say what you saw.',
                  ),
                ),
                if (photos.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Or point at one photo',
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 74,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: photos.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        if (i == 0) {
                          return _photoChoice(
                            ctx,
                            selected: chosenPath == null,
                            onTap: () => setInner(() => chosenPath = null),
                            child: const Icon(Icons.block,
                                size: 18, color: AppTheme.textMuted),
                          );
                        }
                        final photo = photos[i - 1];
                        return _photoChoice(
                          ctx,
                          selected: chosenPath == photo.path,
                          onTap: () => setInner(() => chosenPath = photo.path),
                          child: Image.network(photo.url,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(
                                  Icons.broken_image_outlined,
                                  size: 18,
                                  color: AppTheme.textMuted)),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send report'),
            ),
          ],
        ),
      ),
    );

    final description = controller.text.trim();
    controller.dispose();
    if (submit != true || !mounted) return;

    // The server refuses under ten characters with REPORT_NEEDS_A_DESCRIPTION.
    // Checked here so the customer is told what is wrong before the round
    // trip, not after it.
    if (description.length < 10) {
      _snack('Please describe what happened in at least 10 characters.',
          bad: true);
      return;
    }

    setState(() => _reporting = true);
    try {
      await Supabase.instance.client.rpc('file_content_report', params: {
        'p_reported_provider_id': widget.providerId,
        // Sent as an explicit NULL rather than omitted, so this call site
        // states the whole argument list the function declares. It is NULL on
        // purpose: `public_provider_profiles` withholds the owner's account id
        // by design, so naming the provider is the most this screen can do.
        'p_reported_user_id': null,
        'p_object_bucket': chosenPath == null ? null : bucket,
        'p_object_path': chosenPath,
        'p_category': category,
        'p_description': description,
      });
      if (!mounted) return;
      _snack('Report sent. An administrator will review it.');
    } catch (e) {
      if (mounted) {
        _snack(friendlyError(e, context: 'Could not send this report'),
            bad: true);
      }
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  Widget _photoChoice(
    BuildContext ctx, {
    required bool selected,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 74,
        height: 74,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? AppTheme.primaryGreen
                : AppTheme.cardBorder,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: child,
      ),
    );
  }

  /// The images on this page an administrator could actually take down: the
  /// header photo and every product image. Both buckets are on
  /// `admin_moderate_image`'s allowlist, so naming one here is a report the
  /// admin can act on rather than a note they cannot resolve.
  List<({String bucket, String path, String url})> _reportablePhotos() {
    final out = <({String bucket, String path, String url})>[];
    final p = _provider;
    if (p == null) return out;
    final client = Supabase.instance.client;

    final header = p['photo_storage_path'] as String?;
    if (header != null && header.isNotEmpty) {
      out.add((
        bucket: 'provider-photos',
        path: header,
        url: client.storage.from('provider-photos').getPublicUrl(header),
      ));
    }
    for (final prod in _products) {
      final path = listingCoverPathFromRows(
          (prod['product_images'] as List?) ?? const []);
      if (path == null) continue;
      out.add((
        bucket: 'product-images',
        path: path,
        url: client.storage.from('product-images').getPublicUrl(path),
      ));
    }
    return out;
  }

  void _snack(String message, {bool bad = false}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: bad ? AppTheme.error : null,
      ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
          body: const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen)));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Provider')),
        body: LoadErrorView(message: _error!, onRetry: _load),
      );
    }
    if (_provider == null || _notFound) {
      return Scaffold(
          appBar: AppBar(title: const Text('Provider')),
          body: const Center(child: Text('Provider not found')));
    }
    final p = _provider!;
    // Added by 20260927000106 as a storage PATH, not a URL, and exposed on the
    // public_provider_profiles view rather than on provider_profiles so this
    // screen never needs a read policy on the base table. Null for every
    // provider that has not set one, which renders exactly as the page did
    // before.
    final photoPath = p['photo_storage_path'] as String?;
    final photoUrl = photoPath == null || photoPath.isEmpty
        ? null
        : Supabase.instance.client.storage
            .from('provider-photos')
            .getPublicUrl(photoPath);
    // product_images comes back with the products query above and was being
    // discarded; these are the tiles for the gallery grid. Resolved once here
    // rather than per-widget: `listingCoverPathFromRows` sorts, and the grid,
    // the header and every list row all need the same answer. It is the shared
    // rule from the card module, not a private copy — a second copy of "which
    // photo is the cover" is how the same listing came out looking different on
    // two screens.
    // Each entry keeps the whole listing row, not just its id: the shared card
    // renders the price and the BUY button from that row, so a photo tile and
    // the list row below it cannot quote two different numbers.
    final photoProducts = <({Map<String, dynamic> row, String url})>[];
    for (final prod in _products) {
      final path = listingCoverPathFromRows(
          (prod['product_images'] as List?) ?? const []);
      if (path == null) continue;
      photoProducts.add((
        row: prod,
        url: Supabase.instance.client.storage
            .from('product-images')
            .getPublicUrl(path),
      ));
    }
    // The provider's own gallery, first. `provider-gallery` is a public bucket,
    // so `getPublicUrl` is right and `PhotoGridItem.url` avoids the per-tile
    // createSignedUrl round trip that `stored` would otherwise cost.
    final galleryPhotos =
        <({String? id, String url, String? caption, double? price})>[];
    for (final g in _gallery) {
      final path = g['storage_path'] as String?;
      if (path == null || path.isEmpty) continue;
      galleryPhotos.add((
        id: g['id'] as String?,
        url: Supabase.instance.client.storage
            .from('provider-gallery')
            .getPublicUrl(path),
        caption: g['caption'] as String?,
        price: (g['price'] as num?)?.toDouble(),
      ));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(p['business_name'] ?? ''),
        actions: [
          IconButton(
            tooltip: 'Report this provider',
            icon: _reporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child:
                        CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.flag_outlined),
            onPressed: _reporting ? null : _openReport,
          ),
          // Wrapped in a Consumer (this screen is a plain StatefulWidget)
          // so the heart can apply the guest rule the same way the product
          // page does: a guest has no favourites to write to, so the tap
          // opens the registration dialog instead of failing silently.
          Consumer(
            builder: (context, ref, _) => IconButton(
              icon: Icon(_fav ? Icons.favorite : Icons.favorite_border,
                  color: _fav ? AppTheme.error : null),
              onPressed: () async {
                if (ref.read(guestModeProvider)) {
                  await requestAccountToContinue(context,
                      action: 'save favourites to your account');
                  return;
                }
                final now = await FavoritesService.instance
                    .toggle('PROVIDER', widget.providerId);
                if (mounted) setState(() => _fav = now);
              },
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    colors: [AppTheme.teal, Color(0xFF00695C)]),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.35)),
                        ),
                        child: photoUrl == null
                            ? const Icon(Icons.storefront_outlined,
                                color: Colors.white, size: 28)
                            : Image.network(
                                photoUrl,
                                fit: BoxFit.cover,
                                // A photo that 404s must not take the header
                                // with it, and must not look like a crash.
                                errorBuilder: (_, __, ___) => const Icon(
                                    Icons.storefront_outlined,
                                    color: Colors.white,
                                    size: 28),
                              ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(p['business_name'] ?? '',
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(p['address_text'] ?? 'Location not set',
                      style: TextStyle(
                          fontSize: 13, color: Colors.white.withOpacity(0.8))),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.star, color: AppTheme.gold, size: 16),
                      const SizedBox(width: 4),
                      Text(
                          _trust != null
                              ? _trust!.avgRating.toStringAsFixed(1)
                              : '0.0',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                      const SizedBox(width: 12),
                      Text('${_products.length} products',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.8),
                              fontSize: 13)),
                    ],
                  ),
                  // The price, which the public view has always exposed as
                  // `price_range` and which no screen in the app ever
                  // rendered. A provider who set a price range and a customer
                  // who is choosing between two providers both had no way to
                  // see it. Shown only when it is actually set: an empty pill
                  // reads as "this provider charges nothing", which is the
                  // opposite of what "not set" means.
                  if (_priceRange.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: Colors.white.withOpacity(0.35)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.payments_outlined,
                              size: 14, color: Colors.white),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _priceRange,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Trust & quality summary — real aggregated stats
            ProviderTrustSection(stats: _trust),
            // What this provider's TRADE declares, with their own answers:
            // room types and a nightly rate for a hotel, an hourly price and
            // the services offered for a doctor. Defined per category by an
            // administrator, so this section is never a generic key/value
            // dump -- every row is a field someone decided this trade needs.
            if (_declared.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text('Details & pricing',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.cardBorder),
                  ),
                  child: Column(
                    children: [
                      for (final d in _declared)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text('${d['label']}',
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.textSecondary)),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  _declaredValue(d),
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: d['is_price'] == true
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: d['is_price'] == true
                                        ? AppTheme.primaryGreen
                                        : AppTheme.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            // The provider's OWN gallery. Shown before the product photos
            // because it is the one they paid to upload and the one that was
            // invisible from here; `product_images` below is the marketplace
            // listing imagery, which is a different thing.
            if (galleryPhotos.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text('Photos (${galleryPhotos.length})',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: PhotoGrid(
                  items: [
                    for (final g in galleryPhotos)
                      PhotoGridItem.url(
                        g.url,
                        onTap: () =>
                            _openPhoto(context, g.url, g.caption, g.price),
                        // What the photo costs, on the tile rather than only in
                        // the viewer. The number is the reason a customer
                        // picks this photo over the next one, and hiding it
                        // behind a tap is the same as not having it.
                        //
                        // Nothing at all when the provider has not priced this
                        // photo -- null means "no price", not "free", so a
                        // chip reading "0 ETB" would be a claim they never
                        // made. See ProviderGalleryImage.priceLabel.
                        overlay: g.price == null
                            ? null
                            : Align(
                                alignment: Alignment.bottomLeft,
                                child: Container(
                                  margin: const EdgeInsets.all(4),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${ProviderGalleryImage.formatPrice(g.price!)} ETB',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                      ),
                  ],
                ),
              ),
            ],
            // The provider's listings, as photos. One shared [ProductCard] per
            // listing: the photo, its price and its BUY button together.
            //
            // This grid used to be a bare photo wall — a price was nowhere on
            // the tile and the only action was "open the product", so the one
            // screen a buyer opens to choose a seller was the one screen whose
            // pictures could not be bought. It uses product_images, which the
            // products query already fetched, so the cards cost no extra round
            // trip.
            if (photoProducts.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text('Listing photos (${photoProducts.length})',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    // The feed's ratio, so a listing is the same card here as
                    // it is on the home rail and the category pages.
                    childAspectRatio: 0.66,
                  ),
                  itemCount: photoProducts.length,
                  itemBuilder: (_, i) {
                    final prod = photoProducts[i].row;
                    return ProductCard.listing(
                      productId: (prod['id'] ?? '') as String,
                      providerId: ((prod['provider_id'] as String?) ??
                              widget.providerId)
                          .toString(),
                      title: (prod['name'] ?? '') as String,
                      priceLabel: listingPriceLabel(prod),
                      // BUY for goods, BOOK for a service or a room — the
                      // row's own listing_type, through the shared rule.
                      listingType: prod['listing_type'] as String?,
                      imageUrl: photoProducts[i].url,
                      rating: (prod['rating'] as num?)?.toDouble() ?? 0,
                      likeCount: (prod['like_count'] as num?)?.toInt() ?? 0,
                      isAvailable: prod['is_available'] != false,
                      onTap: () =>
                          context.push('/user/product/${prod['id']}'),
                    );
                  },
                ),
              ),
            ],
            // Products
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('Products (${_products.length})',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            if (_products.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(
                    child: Text('No products yet',
                        style: TextStyle(color: AppTheme.textMuted))),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: _products.length,
                itemBuilder: (_, i) {
                  final prod = _products[i];
                  // A listing with no photo is the TEXT-ONLY card, and this
                  // page is the only surface it appears on: name, price and the
                  // same BUY/BOOK action, with no image box — an empty frame
                  // reads as a broken photo rather than as a listing that never
                  // had one. Discovery keeps these rows out entirely
                  // (`Product.hasPhoto`, and the two RPCs 20261011000001
                  // filters), which is why the card here is the only way this
                  // provider's text-only listing can be bought at all.
                  if (listingCoverPathFromRows(
                          (prod['product_images'] as List?) ?? const []) ==
                      null) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ProductCard.listing(
                        productId: (prod['id'] ?? '') as String,
                        providerId: ((prod['provider_id'] as String?) ??
                                widget.providerId)
                            .toString(),
                        title: (prod['name'] ?? '') as String,
                        priceLabel: listingPriceLabel(prod),
                        listingType: prod['listing_type'] as String?,
                        caption: (prod['description'] ?? '') as String,
                        isAvailable: prod['is_available'] != false,
                        onTap: () =>
                            context.push('/user/product/${prod['id']}'),
                      ),
                    );
                  }
                  return ListTile(
                    onTap: () =>
                        context.push('/user/product/${prod['id']}'),
                    leading: Container(
                      width: 48,
                      height: 48,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                          color: AppTheme.creamDark,
                          borderRadius: BorderRadius.circular(8)),
                      child: _thumbnailFor(prod),
                    ),
                    title: Text(prod['name'] ?? '',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${prod['price']} ${prod['currency'] ?? 'ETB'}',
                        style: const TextStyle(
                            color: AppTheme.primaryGreen,
                            fontWeight: FontWeight.w600)),
                    // Same reaction pair and BUY action as the grid cards, so
                    // a product behaves identically wherever it is listed.
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DislikeButton(
                          productId: prod['id'] as String,
                          fallbackCount:
                              (prod['like_count'] as num?)?.toInt() ?? 0,
                        ),
                        const SizedBox(width: 6),
                        LikeButton(
                          productId: prod['id'] as String,
                          fallbackCount:
                              (prod['like_count'] as num?)?.toInt() ?? 0,
                        ),
                        const SizedBox(width: 8),
                        ProductBuyButton(
                          productId: prod['id'] as String,
                          providerId: widget.providerId,
                          // BUY for a good, BOOK for a service — the row's own
                          // listing_type, through the same shared rule the card
                          // uses.
                          label: listingActionLabel(
                              prod['listing_type'] as String?),
                          compact: true,
                        ),
                      ],
                    ),
                  );
                },
              ),
            const SizedBox(height: 20),
            _reviewsSection(),
          ],
        ),
      ),
    );
  }

  /// Leading thumbnail for the product list. Falls back to the same box-drawing
  /// icon the row showed before this screen had photos, so a product with no
  /// image — or one whose image 404s — looks the same as it always did.
  Widget _thumbnailFor(Map<String, dynamic> product) {
    const fallback = Icon(Icons.inventory_2_outlined,
        color: AppTheme.textMuted);
    final path = listingCoverPathFromRows(
        (product['product_images'] as List?) ?? const []);
    if (path == null) return fallback;
    return Image.network(
      Supabase.instance.client.storage
          .from('product-images')
          .getPublicUrl(path),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => fallback,
    );
  }

  /// First photo path on a product, or null when it has none. Sorted by
  /// `sort_order` the way product_card.dart expects, so a product whose
  /// cover was deliberately ordered first still shows that one.
  /// The price this provider asks for, or '' when they have not set one.
  String get _priceRange {
    final raw = _provider?['price_range'] as String?;
    return (raw ?? '').trim();
  }

  /// One declared field's value.
  ///
  /// The formatting lives in `categoryFieldValue` (core/utils) so it is
  /// unit-tested directly rather than through this widget.
  static String _declaredValue(Map<String, dynamic> d) => categoryFieldValue(
        valueText: d['value_text'] as String?,
        valueNumber: d['value_number'] as num?,
        valueBoolean: d['value_boolean'] as bool?,
        unitLabel: d['unit_label'] as String?,
      );

  /// Full-screen a gallery photo, with its caption.
  ///
  /// A grid tile the size of a thumb is not enough to judge whether a photograph
  /// is of this provider's actual work, which is the entire reason the gallery
  /// exists.
  void _openPhoto(
      BuildContext context, String url, String? caption, double? price) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(
                maxScale: 4,
                child: Image.network(url, fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.broken_image_outlined,
                        size: 48,
                        color: Colors.white)),
              ),
            ),
            if ((caption ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text((caption ?? '').trim(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ],
            // The full-size view is where a customer is looking hardest, so
            // the price is here as well as on the tile.
            if (price != null) ...[
              const SizedBox(height: 8),
              Text('${ProviderGalleryImage.formatPrice(price)} ETB',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ],
            const SizedBox(height: 6),
            IconButton(
              onPressed: () => Navigator.pop(ctx),
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'Close',
            ),
          ],
        ),
      ),
    );
  }

  Widget _reviewsSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Reviews',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          if (_reviews.isEmpty)
            const Text('No reviews yet',
                style: TextStyle(color: AppTheme.textMuted))
          else
            ..._reviews.map((r) => _reviewTile(r)),
        ],
      ),
    );
  }

  Widget _reviewTile(Map<String, dynamic> r) {
    final rating = (r['rating'] as num).toInt();
    final when = r['created_at'] != null
        ? _fmtDate(DateTime.parse(r['created_at'] as String))
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(r['reviewer_name'] ?? 'Anonymous',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 6),
              // A reviewer's rank, so the reviews read as people with a track
              // record rather than as anonymous text.
              RankBadge(userId: r['user_id'] as String?),
              const Spacer(),
              _stars(rating),
            ],
          ),
          if (when.isNotEmpty)
            Text(when,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textMuted)),
          if (r['comment'] != null && (r['comment'] as String).isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(r['comment'] as String,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    height: 1.4)),
          ],
        ],
      ),
    );
  }

  Widget _stars(int rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Icon(
            i < rating ? Icons.star : Icons.star_border,
            size: 14,
            color: AppTheme.gold,
          )),
    );
  }

  String _fmtDate(DateTime dt) {
    final l = dt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${months[l.month - 1]} ${l.day}, ${l.year} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}
