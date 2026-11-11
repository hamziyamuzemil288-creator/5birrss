import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/category.dart';
import '../../core/models/product.dart';
import '../../core/providers/auth_provider.dart' show cityProvider;
import '../../core/resilience/app_failure.dart';
import '../../core/resilience/safe_call.dart';
import '../../core/services/city_service.dart';
import '../../core/services/guest_session.dart';
import '../../core/services/posting_gate.dart';
import '../../core/services/ride_service.dart';
import '../../core/services/product_like_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/category_icons.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/widgets/dashboard_product_card.dart';
import '../../core/widgets/product_buy_button.dart';
import '../../core/widgets/shimmer_effect.dart';
import '../../core/widgets/system_banner.dart';
import 'city_switcher_sheet.dart';
import 'user_category_group_screen.dart';
// The bell's badge reads this screen's own provider, so the count and the
// inbox can never disagree about what "unread" means.
import 'user_notifications_screen.dart' show unreadNotificationsCountProvider;

/// The dashboard grid's page size. A multiple of three is deliberate: every
/// page fills whole rows in a three-column grid, so the last row is never a
/// surprising single tile in the middle of a scroll.
const int kDashboardFeedPageSize = 24;

/// One request for one page. The server receives `pageSize + 1`, which is how
/// the client knows whether another page exists without a second COUNT query.
Map<String, dynamic> dashboardFeedParams({
  required String? categoryId,
  required int offset,
  String city = '',
  int pageSize = kDashboardFeedPageSize,
}) {
  final trimmedCity = city.trim();
  return {
    'p_category_id': categoryId,
    'p_limit': pageSize + 1,
    'p_offset': offset,
    'p_city': trimmedCity.isEmpty ? null : trimmedCity,
  };
}

/// True when a page of `pageSize + 1` rows means there is another page.
bool dashboardFeedHasMore(int returnedRows, int pageSize) =>
    returnedRows > pageSize;

/// The chip order: the server's parent/sort order, with Other last.
///
/// The SQL function already returns this order; applying the same rule in Dart
/// keeps a cached/older response from ever painting Other in the middle.
List<Map<String, dynamic>> orderDashboardCategoryChips(Iterable<dynamic> rows) {
  final list = rows
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .where((row) => (row['category_id']?.toString() ?? '').isNotEmpty)
      .toList();

  int number(dynamic value) => value is num ? value.toInt() : 0;
  bool isOther(Map<String, dynamic> row) {
    final name = (row['name']?.toString() ?? '').trim().toLowerCase();
    return name == 'other' || name == 'other services';
  }

  list.sort((a, b) {
    final other = (isOther(a) ? 1 : 0).compareTo(isOther(b) ? 1 : 0);
    if (other != 0) return other;
    final parentSort = number(a['parent_sort_order'])
        .compareTo(number(b['parent_sort_order']));
    if (parentSort != 0) return parentSort;
    final parentNull = (a['parent_id'] == null ? 0 : 1)
        .compareTo(b['parent_id'] == null ? 0 : 1);
    if (parentNull != 0) return parentNull;
    final sort = number(a['sort_order']).compareTo(number(b['sort_order']));
    if (sort != 0) return sort;
    return (a['name']?.toString() ?? '')
        .toLowerCase()
        .compareTo((b['name']?.toString() ?? '').toLowerCase());
  });
  return list;
}

/// The user home:
///
/// ```text
///   [city] [+ Post product]           [bell] [search] [cart]
///   All-in-One Business Center
///   [ Book a ride ] [ All providers ]
///   [ Transport & Rides ]
///   [ Shops & Products  ]
///   [ Services & Booking]
///   Trending providers  (4 photos across, name + badge below each)
///   [ ride in progress ]  (only while the buyer has an active ride)
///   Top categories this week  (small categories, as a chip rail)
///   Fresh Finds         (product grid)
/// ```
///
/// ## Why there is no tab row and no category grid here any more
///
/// The screen used to carry four tabs, a sub-tab rail and a 3-up grid of
/// category cards, and every one of those was a second copy of navigation
/// that already existed: the same categories, spread across a rail, a chip
/// row and a grid, none of which agreed about which one was current. The
/// cards also had two rendering bugs of their own — labels shrunk to nothing
/// by a FittedBox, and empty-named tiles that rendered as a bare number.
///
/// Now the three big cards are the only category navigation on Home, and
/// each opens its OWN screen (`/user/category-group/:group`) where that
/// group's sub-categories are listed with a search bar. Nothing was
/// deleted from the product: every category is still one tap away, and
/// `/user/category/:id` still resolves a category and its listings.
///
/// ## What did not change
///
/// The feed queries, the routes and the screens behind the tiles are all the
/// existing ones. Header actions (notifications, search, cart) keep their
/// routes; the ride request screen is reached from the "Book a ride" card
/// and from Profile.
class UserHomeScreen extends ConsumerStatefulWidget {
  const UserHomeScreen({super.key});

  @override
  ConsumerState<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends ConsumerState<UserHomeScreen> {
  List<AppCategory> _categories = const [];
  List<Product> _products = const [];
  Map<String, dynamic>? _activeRide;

  /// One image per trending provider, resolved on the server round trip so a
  /// tile never has to run its own query. Priority is the provider's trending
  /// (best-selling) product photo, then their first gallery photo, then the
  /// profile photo, then the placeholder — see [_resolveProviderImage].
  Map<String, String> _providerImages = const {};

  /// Who carries the verified badge beside their name on the rail.
  Set<String> _verifiedProviders = const {};

  /// The top SMALL categories of the last 7 days, from `ranked_categories`.
  /// Rendered as the chip rail directly above Fresh Finds: the ordering is
  /// completed work this week (20261015000011), so it is the same "what is
  /// happening now" answer the Trending provider rail gives, one level down.
  ///
  /// These are the leaves — Restaurants, Electronics, Construction — not the
  /// three big cards above. A chip naming "Shops & Products" repeated the big
  /// card the buyer had already scrolled past; a chip naming the small
  /// category they can actually shop is one tap to listings they can buy.
  ///
  /// Empty means no rail at all rather than an empty strip: a failed ranking
  /// is not a fact about the marketplace.
  List<Map<String, dynamic>> _rankedCategories = const [];

  /// Approved providers, for the gallery section. Read from
  /// `public_provider_profiles`, which already filters to `APPROVED` and is
  /// granted to anon + authenticated, so this needs no RLS change and no
  /// migration.
  ///
  /// Best-effort: an empty list renders no section at all rather than an
  /// error, because the feed is still fully usable without it.
  List<Map<String, dynamic>> _galleryProviders = const [];

  /// The dashboard grid's category chips, from `home_product_categories`.
  /// The first chip is always All products (selected when this is null).
  List<Map<String, dynamic>> _feedCategories = const [];
  String? _feedCategoryId;

  /// The current category's loaded page(s). Kept separate from the home's
  /// other reads so a chip switch can empty and refill only the grid.
  bool _feedInitialLoading = false;
  bool _feedLoadingMore = false;
  bool _feedHasMore = false;
  String? _feedError;
  int _feedOffset = 0;

  /// Bumped on every chip switch. A response whose sequence is stale is
  /// dropped, which is what stops a fast All → Electronics → Construction
  /// sequence painting Electronics' rows under the Construction chip.
  int _feedRequestSeq = 0;

  final ScrollController _feedScroll = ScrollController();

  bool _loading = true;
  String? _error;

  /// Categories change rarely, so a short cache keeps tab switching instant
  /// without letting a genuine admin change sit invisible for the session.
  static List<AppCategory>? _cachedCategories;
  static DateTime? _categoriesFetchedAt;
  static const _categoryCacheTtl = Duration(minutes: 5);

  /// The browse city is app-global state that this screen reads once and then
  /// holds in [_products]. The city chip's own flow reloads the feed when it
  /// changes, but two other paths change the active city without passing
  /// through here — the profile screen's "My City" picker (updateSavedCity)
  /// and "Back to my city" (setTravelMode) — and the feed used to keep
  /// displaying the city the user had just left. Subscribing to the service
  /// closes that gap for every entry point at once.
  late final CityService _cityService = ref.read(cityProvider);

  @override
  void initState() {
    super.initState();
    _cityService.addListener(_onBrowseCityChanged);
    _feedScroll.addListener(_onFeedScroll);
    _load();
    _announceUnreadOnce();
  }

  /// Infinite scroll over the SAME scroll view the dashboard already uses.
  /// A nested GridView would either swallow the gesture or need its own
  /// scrollbar; asking the one controller how much is left avoids both.
  void _onFeedScroll() {
    if (!_feedScroll.hasClients) return;
    if (_feedScroll.position.extentAfter > 420) return;
    unawaited(_loadMoreFeed());
  }

  /// True once this process has greeted the reader. A static rather than a
  /// field because the home screen is rebuilt on every tab switch, and a
  /// banner per rebuild is a banner nobody reads.
  static bool _greeted = false;

  /// "Something happened, and the app said so at the very top" — the in-app
  /// half of "notifications must appear when the app opens".
  ///
  /// It used to return silently whenever there was nothing UNREAD, which is
  /// how a working inbox read as a dead feature: open the app having already
  /// read yesterday's updates and the top of the screen said nothing at all.
  /// Now every app open announces something, in this order:
  ///
  ///   1. unread rows exist       -> the count (the thing worth acting on),
  ///   2. a recent notification   -> its own title and body, read or not,
  ///                                  so the banner carries real content,
  ///   3. nothing at all          -> the welcome.
  ///
  /// Still at most once per app run (see [_greeted]) and still non-blocking:
  /// the bell's badge and the inbox remain the durable record.
  Future<void> _announceUnreadOnce() async {
    if (_greeted) return;
    _greeted = true;
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;

      final unread = await ref.read(unreadNotificationsCountProvider.future);

      // Only worth reading when the count has nothing to say.
      Map<String, dynamic>? latest;
      if (unread <= 0) {
        final rows = await Supabase.instance.client
            .from('notifications')
            .select('title, body, created_at')
            .eq('user_id', uid)
            .order('created_at', ascending: false)
            .limit(1);
        if (rows.isNotEmpty) {
          final row = Map<String, dynamic>.from(rows.first as Map);
          final at = DateTime.tryParse('${row['created_at']}');
          // A month-old row is history, not news — the inbox is where that
          // belongs, so it does not get announced as though it just landed.
          if (at != null &&
              DateTime.now().difference(at) < const Duration(days: 7)) {
            latest = row;
          }
        }
      }

      if (!mounted) return;
      if (unread > 0) {
        SystemBannerController.instance.show(
          title: unread == 1
              ? 'You have 1 new update'
              : 'You have $unread new updates',
          message: 'Tap the bell at the top to read them.',
        );
      } else if (latest != null) {
        final body = '${latest['body'] ?? ''}'.trim();
        SystemBannerController.instance.show(
          title: '${latest['title'] ?? 'Aliob'}',
          message: body.isEmpty ? 'Tap the bell to open your updates.' : body,
        );
      } else {
        SystemBannerController.instance.show(
          title: 'Welcome to Aliob',
          message: 'Browse, order and pay — everything lands under the bell.',
        );
      }
    } catch (_) {
      // A greeting is never worth an error.
    }
  }

  /// Re-query for whichever city is active now. [CityService] only notifies
  /// when the active city actually differs, so this does not fire for a
  /// redundant set.
  void _onBrowseCityChanged() {
    if (!mounted) return;
    _load();
  }

  @override
  void dispose() {
    _cityService.removeListener(_onBrowseCityChanged);
    _feedScroll.removeListener(_onFeedScroll);
    _feedScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // A pull-to-refresh while the previous page is still arriving must not let
    // that page append itself to the fresh grid. The reload gets a new
    // sequence, exactly as a chip switch does.
    _feedRequestSeq++;
    setState(() {
      _loading = true;
      _error = null;
      _feedInitialLoading = true;
      _feedLoadingMore = false;
      _feedHasMore = false;
      _feedOffset = 0;
      _feedError = null;
    });
    try {
      // withRetry, not a bare await: this is the app's first screen and the
      // one most likely to be opened on a weak connection. A transient blip
      // should cost a moment, not an error page.
      final data = await withRetry<Map<String, dynamic>>(
        _fetchAll,
        context: 'loading the home feed',
      );
      if (!mounted) return;
      setState(() {
        _categories = data['categories'] as List<AppCategory>;
        _products = data['products'] as List<Product>;
        _activeRide = data['activeRide'] as Map<String, dynamic>?;
        _galleryProviders = data['providers'] as List<Map<String, dynamic>>;
        _providerImages =
            Map<String, String>.from(data['providerImages'] as Map);
        _verifiedProviders =
            Set<String>.from(data['verified'] as Set);
        _rankedCategories =
            List<Map<String, dynamic>>.from(data['ranked'] as List);
        _feedCategories =
            List<Map<String, dynamic>>.from(data['feedCategories'] as List);
        _feedHasMore = data['feedHasMore'] == true;
        _feedOffset = _products.length;
        _feedError = data['feedError'] as String?;
        _feedInitialLoading = false;
        _loading = false;
        _error = null;
        // Who liked what. A grid of cards must cost one query, not one per
        // card, and the like state is a separate question from the product
        // row -- reading it is what stops a tap on an already-liked product
        // from toggling the server's row off.
        _hydrateReactions(_products);
      });
    } on AppFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _feedInitialLoading = false;
        _error = e.message;
        _feedError = e.message;
      });
    }
  }

  /// One round trip for the whole feed, so the tabs never render against
  /// half-loaded data.
  Future<Map<String, dynamic>> _fetchAll() async {
    final client = Supabase.instance.client;
    final cityService = ref.read(cityProvider);
    if (!cityService.isLoaded) await cityService.loadSavedCity();
    final city = cityService.activeCity;

    // 1. Top-level categories, cached.
    List<AppCategory> categories;
    final cacheFresh = _cachedCategories != null &&
        _categoriesFetchedAt != null &&
        DateTime.now().difference(_categoriesFetchedAt!) < _categoryCacheTtl;
    if (cacheFresh) {
      categories = _cachedCategories!;
    } else {
      final catData = await client
          .from('categories')
          .select()
          .eq('is_active', true)
          .isFilter('parent_id', null)
          .order('sort_order')
          .limit(40);
      categories = (catData as List).map((j) => AppCategory.fromJson(j)).toList();
      _cachedCategories = categories;
      _categoriesFetchedAt = DateTime.now();
    }

    // 1b. The weekly ranking, read on EVERY load rather than only on a cache
    //     miss, because it now drives a rail of its own below. Caching the
    //     category list and forgetting to re-read the rank is exactly how a
    //     "this week" rail goes permanently empty for the rest of the session.
    //    
    //     The ordering is completed work in the LAST 7 DAYS (migration
    //     20261015000011), so a category that came alive this week is visible
    //     here and one whose week is over drops off — the same window the
    //     Trending provider rail ranks by. Non-fatal: a failed ranking leaves
    //     the categories in the sort_order the query gave them, and hides the
    //     rail rather than rendering it empty.
    List<Map<String, dynamic>> ranked = const [];
    try {
      final rows = await client.rpc('ranked_categories', params: {
        'p_limit': 100,
        'p_offset': 0,
      });
      ranked = List<Map<String, dynamic>>.from(rows as List);
      final order = <String, int>{};
      var i = 0;
      for (final row in ranked) {
        final id = row['category_id'];
        if (id is String) order[id] = i++;
      }
      if (order.isNotEmpty) {
        categories.sort((a, b) =>
            (order[a.id] ?? 1 << 30).compareTo(order[b.id] ?? 1 << 30));
      }
      // The cache holds the RANKED order now, so a later cache hit keeps it.
      _cachedCategories = categories;
    } catch (_) {
      // Keep the sort_order the categories query already gave us.
    }

    // 2. The product grid. The SERVER owns the public rule and the paging:
    //    approved, non-deleted providers; active/available listings; an image;
    //    the selected category and its descendants; 24 rows at a time. The
    //    dashboard used to read `products` directly, which had none of those
    //    guarantees and stopped at 20 rows.
    var feedProducts = <Product>[];
    var feedHasMore = false;
    String? feedError;
    var feedCategories = <Map<String, dynamic>>[];
    try {
      final page = await _fetchFeedPage(
        categoryId: _feedCategoryId,
        offset: 0,
      );
      feedProducts = page.products;
      feedHasMore = page.hasMore;
    } catch (e) {
      // The rest of Home is still useful when the grid is not. The grid gets
      // its own error and retry underneath, rather than the whole screen
      // turning into an error page.
      feedError = e is AppFailure
          ? e.message
          : 'The product feed could not be loaded.';
    }

    try {
      final rows = await client.rpc('home_product_categories', params: {
        'p_city': city.isEmpty ? null : city,
      });
      feedCategories = orderDashboardCategoryChips(rows as List);
    } catch (_) {
      // All products still works without chips; the section is not hidden.
      feedCategories = const [];
    }

    // 3. Active ride, best-effort. A failed lookup here must not take the
    //    whole feed down — the feed is still useful without the banner.
    Map<String, dynamic>? activeRide;
    try {
      activeRide = await RideService.instance.getMyActiveRide();
    } catch (_) {
      activeRide = null;
    }

    // 4. Approved providers for the trending rail, best-effort for the same
    //    reason as the ride banner. Bounded (12) because this is a rail, not
    //    a directory — the full list is behind the "All providers" card.
    List<Map<String, dynamic>> providers = const [];
    try {
      // Ranked by completed transactions, not by who signed up last. Read
      // through the server so the rail, the "All providers" sheet and the
      // category screen cannot disagree about the order.
      final provData = await client.rpc('ranked_providers', params: {
        'p_limit': 12,
        'p_offset': 0,
      });
      providers = List<Map<String, dynamic>>.from(provData as List);
    } catch (_) {
      // No gallery section. The feed below it is unaffected.
    }

    // 5. What each trending provider looks like, and whether they carry the
    //    verified badge. Three bounded reads, each best-effort: a rail with no
    //    photos still beats a rail that fails to render.
    final imageMaps = await _resolveProviderImages(providers);
    final verified = await _resolveVerifiedProviders(providers);

    // 6. The chips above Fresh Finds. The SMALL categories, not the ranking
    //    verbatim -- see [_subcategoryRail] for why the leaves need the
    //    parents' order to be ranked at all.
    final rail = await _subcategoryRail(client, ranked);

    return {
      'categories': categories,
      'products': feedProducts,
      'feedHasMore': feedHasMore,
      'feedError': feedError,
      'feedCategories': feedCategories,
      'activeRide': activeRide,
      'providers': providers,
      'providerImages': imageMaps,
      'verified': verified,
      // The weekly ranking, narrowed to small categories and capped to the
      // rail. The full list already sorted the mother categories above.
      'ranked': rail,
    };
  }

  /// One page of the public feed. The RPC returns `pageSize + 1` rows on
  /// purpose: the extra row is the "there is another page" signal, so the grid
  /// never has to run a second COUNT query or show a spinner at the exact end.
  Future<({List<Product> products, bool hasMore})> _fetchFeedPage({
    required String? categoryId,
    required int offset,
  }) async {
    final client = Supabase.instance.client;
    final city = ref.read(cityProvider).activeCity;
    final rows = await client.rpc('home_product_feed', params: {
      ...dashboardFeedParams(
        categoryId: categoryId,
        offset: offset,
        city: city,
      ),
    });
    final raw = List<Map<String, dynamic>>.from(rows as List);
    final hasMore = dashboardFeedHasMore(raw.length, kDashboardFeedPageSize);
    final pageRows =
        hasMore ? raw.take(kDashboardFeedPageSize).toList() : raw;

    // One batched image read for the whole page. The RPC returns `products`,
    // not a table join, so the cover photo is attached here before the model
    // is parsed — never one query per card.
    // A failed image read becomes the grid's retry state, not an empty grid:
    // the server guarantees a photo, so "no photos" here means the image query
    // failed, and an empty-state message would be a lie.
    final images = await _fetchProductImages(pageRows);
    for (final row in pageRows) {
      row['product_images'] =
          images[(row['id'] ?? '').toString()] ?? const <Map<String, dynamic>>[];
    }

    return (products: _toProducts(pageRows), hasMore: hasMore);
  }

  Future<Map<String, List<Map<String, dynamic>>>> _fetchProductImages(
    List<Map<String, dynamic>> rows,
  ) async {
    final ids = rows
        .map((row) => (row['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return const {};
    final data = await Supabase.instance.client
        .from('product_images')
        .select('id, product_id, storage_path, sort_order')
        .inFilter('product_id', ids)
        .order('sort_order');
    final out = <String, List<Map<String, dynamic>>>{};
    for (final raw in data as List) {
      final image = Map<String, dynamic>.from(raw as Map);
      final productId = (image['product_id'] ?? '').toString();
      if (productId.isEmpty) continue;
      (out[productId] ??= []).add(image);
    }
    return out;
  }

  /// Reload the grid for the current chip. The sequence bump is the shield
  /// against a slow response for the old category painting under the new chip.
  Future<void> _reloadFeed() async {
    final seq = ++_feedRequestSeq;
    setState(() {
      _feedInitialLoading = true;
      _feedLoadingMore = false;
      _feedError = null;
      _feedHasMore = false;
      _feedOffset = 0;
      _products = const [];
    });
    try {
      final page = await _fetchFeedPage(
        categoryId: _feedCategoryId,
        offset: 0,
      );
      if (!mounted || seq != _feedRequestSeq) return;
      setState(() {
        _products = page.products;
        _feedHasMore = page.hasMore;
        _feedOffset = page.products.length;
        _feedInitialLoading = false;
      });
      _hydrateReactions(page.products);
    } catch (e) {
      if (!mounted || seq != _feedRequestSeq) return;
      setState(() {
        _feedInitialLoading = false;
        _feedError = e is AppFailure
            ? e.message
            : 'This category could not be loaded.';
      });
    }
  }

  Future<void> _selectFeedCategory(String? categoryId) async {
    if (_feedCategoryId == categoryId) return;
    setState(() => _feedCategoryId = categoryId);
    await _reloadFeed();
  }

  Future<void> _loadMoreFeed() async {
    if (!_feedHasMore || _feedLoadingMore || _feedInitialLoading) return;
    final seq = _feedRequestSeq;
    final offset = _feedOffset;
    setState(() => _feedLoadingMore = true);
    try {
      final page = await _fetchFeedPage(
        categoryId: _feedCategoryId,
        offset: offset,
      );
      if (!mounted || seq != _feedRequestSeq) return;
      setState(() {
        _products = [..._products, ...page.products];
        _feedOffset = offset + page.products.length;
        _feedHasMore = page.hasMore;
        _feedLoadingMore = false;
      });
      _hydrateReactions(page.products);
    } catch (_) {
      if (!mounted || seq != _feedRequestSeq) return;
      setState(() => _feedLoadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('More products could not be loaded. Scroll to retry.'),
        ),
      );
    }
  }

  String get _feedCategoryLabel {
    final id = _feedCategoryId;
    if (id == null) return 'All products';
    for (final row in _feedCategories) {
      if (row['category_id']?.toString() == id) {
        return (row['name']?.toString() ?? 'This category').trim();
      }
    }
    return 'This category';
  }

  /// The chips above Fresh Finds: the SMALL categories, ordered by this week.
  ///
  /// `ranked_categories` ranks every active category — the three mother
  /// categories and their leaves — by completed work in the last 7 days. A
  /// rail that printed that ranking verbatim repeated the three big cards the
  /// buyer had just scrolled past, and answered "what are the biggest
  /// categories" when the question is "what is being bought this week".
  /// Restaurants, Electronics, Construction are the answer; a chip has to
  /// open something the buyer can shop.
  ///
  /// The ranking itself cannot order the leaves: a listing is filed against
  /// the category its provider picked, which is usually the mother, so every
  /// leaf's own week count is zero and the tiebreak (name) would turn the
  /// rail into an alphabetical list. The leaves are therefore taken parent by
  /// parent in the parents' ranked order, one leaf per parent per round: the
  /// first chip is the busiest trade's first specialty, the second chip is the
  /// next trade's, and the rail stays as mixed as the marketplace is.
  ///
  /// Best-effort throughout. A failed read of the tree returns no chips, and
  /// the section hides itself — an empty strip is not a fact about trading.
  Future<List<Map<String, dynamic>>> _subcategoryRail(
    SupabaseClient client,
    List<Map<String, dynamic>> ranked,
  ) async {
    if (ranked.isEmpty) return const [];
    // id -> mother id for every active small category. Without this the rail
    // would name the mothers again, so a failure hides the rail rather than
    // falling back to the wrong set.
    final motherOf = <String, String>{};
    try {
      final rows = await client
          .from('categories')
          .select('id, parent_id')
          .eq('is_active', true)
          .not('parent_id', 'is', null)
          .limit(1000);
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = row['id'];
        final parent = row['parent_id'];
        if (id is String && parent is String) motherOf[id] = parent;
      }
    } catch (_) {
      return const [];
    }
    if (motherOf.isEmpty) return const [];
    return subcategoryRailOrder(ranked, motherOf);
  }

  /// One image per provider, in the priority the spec asks for:
  ///
  /// 1. the trending product's photo (the listing that made them trend),
  /// 2. their first uploaded gallery photo,
  /// 3. their profile photo,
  /// 4. nothing, so the tile falls back to the placeholder.
  ///
  /// Three batched reads rather than one per tile: a rail of 12 providers
  /// would otherwise be 24 round trips on the app's first screen. Every read
  /// is best-effort and the empty map is a legal answer — the tile already
  /// knows how to render a placeholder.
  Future<Map<String, String>> _resolveProviderImages(
      List<Map<String, dynamic>> providers) async {
    final out = <String, String>{};
    final ids = providers
        .map((p) => (p['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return out;
    final client = Supabase.instance.client;

    // 1. The best-selling listing of each provider, with its photo.
    try {
      final rows = await client
          .from('products')
          .select('provider_id, sales_count, product_images(storage_path, sort_order)')
          .inFilter('provider_id', ids)
          .eq('is_active', true)
          .order('sales_count', ascending: false, nullsFirst: false)
          .order('created_at', ascending: false)
          .limit(60);
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final pid = row['provider_id']?.toString();
        if (pid == null || out.containsKey(pid)) continue;
        final path = _firstImagePath(row['product_images']);
        if (path != null) {
          out[pid] = client.storage.from('product-images').getPublicUrl(path);
        }
      }
    } catch (_) {
      // Fall through to the gallery.
    }

    // 2. The first gallery photo of whoever still has none above.
    try {
      final missing = ids.where((id) => !out.containsKey(id)).toList();
      if (missing.isNotEmpty) {
        final rows = await client
            .from('provider_gallery')
            .select('provider_id, storage_path, display_order')
            .inFilter('provider_id', missing)
            .eq('is_active', true)
            .order('display_order');
        for (final raw in rows as List) {
          final row = Map<String, dynamic>.from(raw as Map);
          final pid = row['provider_id']?.toString();
          final path = (row['storage_path'] as String?)?.trim() ?? '';
          if (pid == null || path.isEmpty || out.containsKey(pid)) continue;
          out[pid] =
              client.storage.from('provider-gallery').getPublicUrl(path);
        }
      }
    } catch (_) {
      // Fall through to the profile photo.
    }

    // 3. The profile photo everyone else is left with.
    try {
      final missing = ids.where((id) => !out.containsKey(id)).toList();
      if (missing.isNotEmpty) {
        final rows = await client
            .from('provider_profiles')
            .select('id, photo_storage_path')
            .inFilter('id', missing);
        for (final raw in rows as List) {
          final row = Map<String, dynamic>.from(raw as Map);
          final pid = row['id']?.toString();
          final path = (row['photo_storage_path'] as String?)?.trim() ?? '';
          if (pid == null || path.isEmpty || out.containsKey(pid)) continue;
          out[pid] =
              client.storage.from('provider-photos').getPublicUrl(path);
        }
      }
    } catch (_) {
      // No photos at all: every remaining tile renders the placeholder.
    }

    return out;
  }

  /// The primary photo of an embedded `product_images(*)` list: the lowest
  /// sort order, which is what the upload path writes first.
  static String? _firstImagePath(dynamic images) {
    if (images is! List || images.isEmpty) return null;
    final rows = images
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList()
      ..sort((a, b) => ((a['sort_order'] as num?) ?? 0)
          .compareTo((b['sort_order'] as num?) ?? 0));
    for (final row in rows) {
      final path = (row['storage_path'] as String?)?.trim() ?? '';
      if (path.isNotEmpty) return path;
    }
    return null;
  }

  /// The verified badge beside a provider's name, read from the same view the
  /// provider profile's "Trust & Quality" pill reads, so the two screens can
  /// never disagree about who is verified.
  ///
  /// A failed read falls back to the whole rail, not to an empty set: every
  /// row [ranked_providers] returns already carries
  /// `provider_profiles.status = APPROVED`, and APPROVED is what "Verified"
  /// means on the provider's own page. Hiding the badge because a secondary
  /// view was unreadable would be the same class of lie as showing it for a
  /// provider nobody approved — just in the other direction.
  Future<Set<String>> _resolveVerifiedProviders(
      List<Map<String, dynamic>> providers) async {
    final ids = providers
        .map((p) => (p['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return <String>{};
    try {
      final rows = await Supabase.instance.client
          .from('provider_trust_stats')
          .select('provider_id, is_verified')
          .inFilter('provider_id', ids);
      return {
        for (final raw in rows as List)
          if ((raw as Map)['is_verified'] == true)
            (raw['provider_id'] as String),
      };
    } catch (_) {
      return ids.toSet();
    }
  }

  /// How many photos the feed already holds for each provider, counted from
  /// `_products` rather than queried. The products query above embeds
  /// `product_images(*)`, so this number is free, and it is the number the
  /// customer actually cares about: "how much of this provider can I see".
  Map<String, int> get _photoCountsByProvider {
    final counts = <String, int>{};
    for (final p in _products) {
      final n = p.images.length;
      if (n == 0) continue;
      counts[p.providerId] = (counts[p.providerId] ?? 0) + n;
    }
    return counts;
  }

  /// Tell the like service what this feed holds, in one batched read.
  ///
  /// Fire-and-forget and deliberately not awaited: the feed is already on
  /// screen, and the buttons render their unknown state until this lands.
  /// A failure here leaves them unknown, which is honest, rather than
  /// asserting a reaction the server has not confirmed.
  void _hydrateReactions(List<Product> products) {
    if (products.isEmpty) return;
    final counts = {for (final p in products) p.id: p.likeCount};
    ProductLikeService.instance.ensureLoaded(
      products.map((p) => p.id),
      likeCountOf: (id) => counts[id] ?? 0,
    );
  }

  /// The feed's listings as models: parsed, typed, and with the photo-less ones
  /// dropped.
  ///
  /// `listing_type` is what decides whether a card says BUY or BOOK, and this
  /// mapping used to omit it entirely — so every card in the feed was a
  /// PRODUCT, and a service in the rail read BUY like a tin of paint. It is
  /// read here now, once for the whole rail.
  ///
  /// A listing with no photo never reaches the grid: it is dropped here, in the
  /// read that feeds the feed, because a text-only listing belongs on its own
  /// provider's page (where the shared card renders it with no image box) and
  /// never in general discovery. This is the one discovery read the client
  /// owns, so the rule sits here for it; the category screen's
  /// `visible_products_for_city` and the search screen's `search_products`
  /// carry the same exclusion server-side (migration 20261011000001).
  /// `products_public_read` deliberately does not: that same policy also
  /// answers the provider page, which must keep showing the listing.
  static List<Product> _toProducts(List rows) {
    return rows.map((j) {
      final imgs = (j['product_images'] as List?)
              ?.map((i) => ListingImage.fromJson(i))
              .toList() ??
          [];
      return Product(
        id: j['id'],
        providerId: j['provider_id'],
        categoryId: j['category_id'],
        name: j['name'],
        description: j['description'],
        price: (j['price'] as num).toDouble(),
        currency: j['currency'] ?? 'ETB',
        listingType: (j['listing_type'] as String?) ?? 'PRODUCT',
        quantity: j['quantity'],
        isAvailable: j['is_available'] ?? true,
        isActive: j['is_active'] ?? true,
        rating: (j['rating'] as num?)?.toDouble() ?? 0,
        reviewCount: j['review_count'] ?? 0,
        salesCount: j['sales_count'] ?? 0,
        // The count next to the heart comes from the feed, not from a second
        // query per card. It was missing here, so every card on this screen
        // showed "0" no matter how many likes the product had.
        likeCount: (j['like_count'] as num?)?.toInt() ?? 0,
        requiresAvailabilityConfirmation:
            j['requires_availability_confirmation'] ?? false,
        city: (j['city'] as String?)?.trim(),
        createdAt: DateTime.parse(j['created_at']),
        updatedAt: DateTime.parse(j['updated_at']),
        images: imgs,
      );
      // Discovery stays photo-first: a listing with no image is not shown on
      // Home (the existing marketplace rule), while a photo whose URL fails to
      // load still gets DashboardProductCard's placeholder.
    }).where((p) => p.hasPhoto).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _categories.isEmpty) return _buildSkeleton();

    // A first load that failed has nothing to show. A refresh that failed
    // keeps the feed and the banner says so — the same rule as AsyncView,
    // applied to a screen that was not built with it.
    if (_error != null && _categories.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primaryGreen,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
            _ErrorBlock(message: _error!, onRetry: _load),
          ],
        ),
      );
    }

    // The whole home, in the order the founder sketched it:
    //
    //   header (city, + Post product, notifications, search, cart)
    //   Book a ride | All providers  — side by side, one height
    //   the 3 big categories — compact rows, half their old height
    //   trending providers — four photos across, no horizontal scrolling
    //   [ ride in progress ]
    //   Top categories this week — the SMALL categories, above Fresh Finds so
    //                              the buyer reaches them right where they are
    //                              about to browse listings
    //   Fresh Finds
    //
    // The tab row and the 3-up category grid that used to live between the
    // quick actions and the feed are gone: every small category card now sits
    // inside its own parent category screen, which is one tap away from the
    // big card it belongs to.
    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primaryGreen,
      child: CustomScrollView(
        controller: _feedScroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _header()),
          if (_error != null)
            SliverToBoxAdapter(
              child: _StaleBanner(
                  message: _error!, onRetry: _load),
            ),
          SliverToBoxAdapter(child: _categorySection()),
          SliverToBoxAdapter(child: _gallerySection()),
          if (_activeRide != null)
            SliverToBoxAdapter(child: _rideBanner(_activeRide!)),
          SliverToBoxAdapter(child: _rankedCategoryRail()),
          ..._feedSlivers(),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- header

  Widget _header() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // City selector, top-left, per the sketch.
              Flexible(child: _CityChip(onOpen: _openCitySwitcher)),
              const SizedBox(width: 8),
              // The post entry point, beside the city it will be listed in.
              // One button for every role: it decides for itself whether the
              // tapper is logged out, not-yet-a-provider, or a provider with
              // something outstanding.
              const Flexible(child: _PostProductButton()),
              const Spacer(),
              // Notifications move to a bell here (they were a bottom-nav
              // tab, and the nav is now Home|Order|Favourite|Account). The
              // existing /admin-notifications route hosts the inbox for every
              // role, so the bell reuses it rather than adding a fifth tab
              // back.
              // The count is what makes the bell a notification centre rather
              // than a decoration: unread rows are written by the server for
              // orders, payments, availability answers and account events, and
              // until the badge existed nothing on the home screen said so.
              _HeaderIcon(
                icon: Icons.notifications_none_rounded,
                tooltip: 'Notifications',
                badgeCount:
                    ref.watch(unreadNotificationsCountProvider).valueOrNull ?? 0,
                onTap: () async {
                  await context.push('/admin-notifications');
                  // Coming back, the badge must reflect what was just read.
                  ref.invalidate(unreadNotificationsCountProvider);
                },
              ),
              _HeaderIcon(
                icon: Icons.search_rounded,
                tooltip: 'Search',
                onTap: () => context.push('/user/search'),
              ),
              const CartIconButton(iconColor: Colors.white),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            'All-in-One Business Center',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _greeting(),
            style: TextStyle(
              fontSize: 12.5,
              color: Colors.white.withOpacity(0.72),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openCitySwitcher() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const CitySwitcherSheet(),
    );
    if (changed == true && mounted) _load();
  }

  // ------------------------------------------------------- trending rail

  /// Every approved provider's gallery, on the same screen a customer books
  /// a ride from.
  ///
  /// It used to live only in the SERVICE provider's own dashboard, as a
  /// "My Gallery" pill at the top — a provider editing their own photos. A
  /// customer browsing this screen had no equivalent: the only way to see a
  /// provider's photos was to open one product card, then the provider page,
  /// then scroll. So the people who choose a provider could not browse
  /// providers, while the people being chosen could.
  ///
  /// The styling is deliberately the same pill, not a second look: the entry
  /// point is [QuickActionPill] — the one definition of this pattern, already
  /// used by every dashboard — and the tiles reuse its brand green and its
  /// white w700 label. The tiles round to 16 rather than 20 on purpose: a pill
  /// is an action and a photo card is content, and giving the card the pill's
  /// exact geometry is how a screen stops being able to tell the reader which
  /// one is a button. A gallery section that looked like a different product
  /// would be the third button style this repo keeps paying for.
  Widget _gallerySection() {
    if (_galleryProviders.isEmpty) return const SizedBox.shrink();
    final counts = _photoCountsByProvider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(
            'Trending providers',
            style: TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ),
        // Four photos across, exactly. The width is the space left after the
        // page's 16px gutters and the three gaps between the tiles, divided by
        // four — so four are readable on the narrowest phone and the row
        // still reads on a tablet instead of growing into a different layout.
        //
        // It used to be a horizontal rail of 110-wide tiles: two and a half
        // visible, the rest off-screen with no cue that they existed, and a
        // fixed 200px band for it. Four across answers "who is nearby"
        // without a gesture nobody performs.
        LayoutBuilder(
          builder: (context, constraints) {
            const gutter = 16.0;
            const gap = 8.0;
            final width = (constraints.maxWidth - gutter * 2 - gap * 3) / 4;
            if (width <= 0) return const SizedBox.shrink();
            final shown = _galleryProviders.take(4).toList();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: gutter),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < shown.length; i++) ...[
                    if (i > 0) const SizedBox(width: gap),
                    SizedBox(
                      width: width,
                      child: _galleryTile(
                        width: width,
                        id: (shown[i]['id'] ?? '') as String,
                        name:
                            ((shown[i]['business_name'] as String?) ?? '').trim(),
                        city: ((shown[i]['city'] as String?) ?? '').trim(),
                        imageUrl: _providerImages[(shown[i]['id'] ?? '') as String],
                        verified: _verifiedProviders
                            .contains((shown[i]['id'] ?? '') as String),
                        photoPath: shown[i]['photo_storage_path'] as String?,
                        photoCount:
                            counts[(shown[i]['id'] ?? '') as String] ?? 0,
                        transactions:
                            (shown[i]['completed_transactions'] as num?)
                                    ?.toInt() ??
                                0,
                        priceRange:
                            ((shown[i]['price_range'] as String?) ?? '').trim(),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _galleryTile({
    required double width,
    required String id,
    required String name,
    required String city,
    required String? imageUrl,
    required bool verified,
    required String? photoPath,
    required int photoCount,
    required int transactions,
    required String priceRange,
  }) {
    // An id is the only thing the route needs; a row without one would push a
    // path matching no route at all, so it is dropped rather than rendered
    // as a tile that does nothing when tapped.
    if (id.isEmpty) return const SizedBox.shrink();
    // Trending photo → gallery photo → profile photo → placeholder. The
    // first three are resolved in [_resolveProviderImages]; the raw profile
    // path is kept here as a last resort for the case where that read failed
    // but the RPC row still carried one.
    final url = imageUrl ??
        ((photoPath == null || photoPath.isEmpty)
            ? null
            : Supabase.instance.client.storage
                .from('provider-photos')
                .getPublicUrl(photoPath));
    // Completed work outranks a photo count as the thing a customer reads on
    // a card that is now ordered by that work -- leading with "3 photos" on
    // the busiest provider in the city says the wrong thing about why it is
    // first. A provider with no completed job keeps the old subtitle.
    final base = transactions > 0
        ? '$transactions completed job${transactions == 1 ? '' : 's'}${
            photoCount > 0 ? ' · $photoCount photo${photoCount == 1 ? '' : 's'}' : ''}'
        : (photoCount > 0
            ? '$photoCount photo${photoCount == 1 ? '' : 's'}'
            : (city.isEmpty ? 'No photos yet' : city));
    // A provider's published price range, when they set one. It leads the
    // subtitle because it is the number a buyer is actually weighing; the
    // job/photo count is context for it.
    final subtitle = priceRange.isEmpty ? base : '$priceRange · $base';

    // The image is the card (cover fit, rounded, square), with the name under
    // it and a verified badge next to it. The caller decides the width: four
    // of these have to fit the screen.
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Card: image on top, cover fit, with the name under the card.
          InkWell(
            onTap: () => context.push('/user/provider/$id'),
            borderRadius: BorderRadius.circular(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: width,
                height: width,
                child: url == null
                    ? _providerFallback(name)
                    : Image.network(
                        url,
                        // Cover, not contain: a photo of a shop front fills
                        // the card instead of floating in a letterbox.
                        fit: BoxFit.cover,
                        // Never stretch a cached frame while it re-decodes.
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => _providerFallback(name),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Name UNDER the card with the verified badge beside it.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  name.isEmpty ? 'Unnamed' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              if (verified) ...[
                const SizedBox(width: 3),
                const Icon(
                  Icons.verified_rounded,
                  size: 13,
                  color: AppTheme.primaryGreen,
                  semanticLabel: 'Verified provider',
                ),
              ],
            ],
          ),
          // The trade facts under the name: price range first (the number a
          // buyer weighs), then the completed work. One line, ellipsised —
          // the card is deliberately small and the name must stay readable.
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          // The same purchase entry point every other card carries: a provider
          // photo's buyer action is to see and book their work, so this goes
          // through the shared button rather than a second hand-rolled tap
          // target. It has no listing to add, so the button opens the provider
          // — the same place the photo goes. Scaled down rather than fixed:
          // four across leaves ~76px per tile, and a long label at a large text
          // scale must shrink, not overflow its card.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: ProductBuyButton(
              providerId: id,
              label: 'Book',
              compact: true,
            ),
          ),
        ],
      ),
    );
  }

  /// Soft brand-green fallback for a provider with no photo. Not the hard
  /// dark-green flat fill the old tiles used — a muted green-grey reads as
  /// "no photo yet" rather than "this provider is dark green".
  Widget _providerFallback(String name) {
    return Container(
      color: AppTheme.primaryGreenLight.withOpacity(0.18),
      child: Center(
        child: Icon(
          Icons.business,
          size: 28,
          color: AppTheme.primaryGreenDark.withOpacity(0.5),
        ),
      ),
    );
  }

  /// The full directory behind the pill. A modal sheet rather than a new
  /// route: the list is read-only navigation to a screen that already exists
  /// (`/user/provider/:id`), and adding a route for it would put another
  /// entry point to break.
  ///
  /// Opened FIRST and loaded inside it. Awaiting the query before showing the
  /// sheet left the button dead for the length of the request with no
  /// feedback at all, and made the sheet's own loading branch unreachable.
  ///
  /// `isScrollControlled: true` is required, not cosmetic: without it the
  /// bottom sheet is clamped to a fraction of the screen and a
  /// DraggableScrollableSheet inside it has almost no height to work with.
  Future<void> _openAllProviders() async {
    if (!mounted) return;
    final client = Supabase.instance.client;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        // The future is created once, when the sheet is built. Retry pops the
        // sheet and opens a new one, so it gets a fresh query -- which is why
        // there is no StatefulBuilder here to rebuild: a retry that reuses the
        // same Future would immediately re-show the same error.
        // Ordered the same way the rail is, and by the same server: most
        // transacted first, best to least. Ordering this one by
        // `business_name` was the only reason two lists of the same
        // providers could disagree about who is biggest.
        final future = client
            .rpc('ranked_providers', params: {'p_limit': 200, 'p_offset': 0})
            .then((rows) => List<Map<String, dynamic>>.from(rows as List));
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (_, controller) {
            return FutureBuilder<List<Map<String, dynamic>>>(
                  future: future,
                  builder: (ctx, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(
                          child: CircularProgressIndicator());
                    }
                    final providers = snap.data ?? const [];
                    return ListView.separated(
                      controller: controller,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: providers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final p = providers[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppTheme.primaryGreen,
                            child: Text(
                              '#$i',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                            ),
                          ),
                          title: Text(
                            (p['business_name'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${p['city'] ?? ''}${p['completed_transactions'] != null && (p['completed_transactions'] as num).toInt() > 0 ? ' · ${p['completed_transactions']}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: p['photo_storage_path'] != null
                              ? ClipRRect(
                                  borderRadius:
                                      const BorderRadius.horizontal(
                                          left: Radius.circular(8)),
                                  child: Image.network(
                                    Supabase.instance.client
                                        .storage
                                        .from('provider-photos')
                                        .getPublicUrl(
                                            p['photo_storage_path']
                                                as String),
                                    fit: BoxFit.cover,
                                    width: 48,
                                    height: 48,
                                    errorBuilder: (_, __, ___) =>
                                        Container(
                                          width: 48,
                                          height: 48,
                                          color: AppTheme.creamDark,
                                          child: const Icon(
                                              Icons.photo_library_outlined,
                                              color: AppTheme.textMuted),
                                        ),
                                  ),
                                )
                              : null,
                          onTap: () =>
                              context.push('/user/provider/${p['id']}'),
                        );
                      },
                    );
                  },
                );
          },
        );
      },
    );
  }

  // ------------------------------------------------------- category section

  /// The 3 big main categories plus the quick-action row.
  ///
  /// The two quick actions sit above the big cards, equal width, equal
  /// height, right under the header. The three big cards are the only
  /// category navigation left on Home: tapping one opens that group's own
  /// screen, where every sub-category it owns is listed and searchable.
  Widget _categorySection() {
    // Quick actions: Book a ride + All providers, equal width, same height.
    // The two `Expanded`s in the row below do the sizing; a screen-width
    // calculation used to be passed into each card and read by nothing.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Quick actions row
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: _QuickActionCard(
                  icon: Icons.local_taxi_outlined,
                  title: 'Book a ride',
                  subtitle: 'Request a driver',
                  tint: AppTheme.primaryGreen,
                  onTap: () async {
                    // Book-a-ride needs an identity for the ride request, so
                    // a guest opens the anonymous session here. No form, no
                    // interruption of the flow.
                    if (ref.read(guestModeProvider) &&
                        !await ensureGuestCheckoutSession(context)) {
                      return;
                    }
                    context.push('/user/ride-request');
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _QuickActionCard(
                  icon: Icons.photo_library_outlined,
                  title: 'All providers',
                  subtitle: 'Browse every business',
                  tint: AppTheme.teal,
                  onTap: _openAllProviders,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 3 big main category cards
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _MainCategoryCard(
                  title: 'Transport & Rides',
                  subtitle: _groupedSubtitle(_transportCategories),
                  icon: Icons.directions_car_outlined,
                  tint: AppTheme.primaryGreen,
                  onTap: _transportCategories.isNotEmpty
                      ? () => _openCategoryGroup('transport')
                      : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _MainCategoryCard(
                  title: 'Shops & Products',
                  subtitle: _groupedSubtitle(_shopCategories),
                  icon: Icons.storefront_outlined,
                  tint: AppTheme.gold,
                  onTap: _shopCategories.isNotEmpty
                      ? () => _openCategoryGroup('shops')
                      : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _MainCategoryCard(
                  title: 'Services & Booking',
                  subtitle: _groupedSubtitle(_serviceCategories),
                  icon: Icons.book_online_outlined,
                  tint: AppTheme.teal,
                  onTap: _serviceCategories.isNotEmpty
                      ? () => _openCategoryGroup('services')
                      : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ------------------------------------------------- top categories, this week

  /// The chip rail just above Fresh Finds: the SMALL categories the last 7
  /// days actually traded in, most first.
  ///
  /// This is where the ranking's window becomes visible. `ranked_categories`
  /// used to order by career totals, which is an ordering that never changes —
  /// so "the top categories" was really "the categories that existed longest".
  /// Since 20261015000011 the first key is completed work in the last 7 days,
  /// the same window the Trending provider rail ranks by, and this rail is the
  /// surface that shows it: a category with a busy week moves up, and one with
  /// nothing this week drops off even though its lifetime total is larger.
  ///
  /// Every chip is NAVIGATION, not decoration: it opens the small category's
  /// own screen (/user/category/:id), which lists its providers and listings.
  /// An empty ranking renders no rail at all — a failed read is not a fact
  /// about the marketplace, and a strip of nothing says it is.
  Widget _rankedCategoryRail() {
    final rows = _rankedCategories;
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 22, 20, 2),
          child: Text(
            'Top categories this week',
            style: TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(
            'Ranked by completed work in the last 7 days',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _rankedCategoryChip(rows[i]),
          ),
        ),
      ],
    );
  }

  Widget _rankedCategoryChip(Map<String, dynamic> row) {
    final id = ((row['category_id'] as String?) ?? '').trim();
    final name = ((row['name'] as String?) ?? '').trim();
    if (id.isEmpty || name.isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      onTap: id.isEmpty ? null : () => context.push('/user/category/$id'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppTheme.primaryGreen.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              categoryIconForSector(row['marketplace_sector'] as String?),
              size: 15,
              color: AppTheme.primaryGreen,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Groups of categories mapped into the 3 big sections.
  ///
  /// Delegated to [CategoryGroup] rather than re-filtered here: the card's
  /// count and the screen it opens MUST be the same list, and the grouping
  /// rule being written twice is exactly how they drift — the old copy of
  /// this rule filed every vehicle in two groups at once.
  List<AppCategory> get _transportCategories =>
      CategoryGroup.transport.membersOf(_categories);

  List<AppCategory> get _shopCategories =>
      CategoryGroup.shops.membersOf(_categories);

  List<AppCategory> get _serviceCategories =>
      CategoryGroup.services.membersOf(_categories);

  /// What a big card says under its title: how many sub-categories are behind
  /// it, in words.
  ///
  /// It used to print the raw number as the subtitle AND the same number again
  /// in a chip beside it, so a card read "7" over "7 categories" — the
  /// number-only tile that the screen it opens was built to replace. The
  /// subtitle now carries the whole fact, so there is exactly one place the
  /// count is stated.
  String _groupedSubtitle(List<AppCategory> list) => list.isEmpty
      ? 'Nothing listed yet'
      : '${list.length} sub-categor${list.length == 1 ? 'y' : 'ies'}';

  /// A big category card opens its own screen: every sub-category of that
  /// group, searchable, and nothing from any other group. The screen loads
  /// the same grouping itself (one query) rather than being handed a list,
  /// so a card can never push a stale copy of a list the admin has since
  /// edited.
  void _openCategoryGroup(String group) {
    context.push('/user/category-group/$group');
  }

  // ------------------------------------------------------------- products

  /// The dashboard product section: title, channel-style category chips, and
  /// a three-up sliver grid in the SAME CustomScrollView as the rest of Home.
  /// Nothing here owns a vertical scroll view, so pull-to-refresh, the chip
  /// rail and the grid scroll as one page.
  List<Widget> _feedSlivers() {
    final header = SliverToBoxAdapter(child: _feedHeader());

    if (_feedInitialLoading) {
      return [
        header,
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverGrid(
            gridDelegate: _feedGridDelegate,
            delegate: SliverChildBuilderDelegate(
              (_, __) => const SkeletonBox(
                width: double.infinity,
                height: 150,
                borderRadius: 12,
              ),
              childCount: 6,
            ),
          ),
        ),
      ];
    }

    if (_feedError != null && _products.isEmpty) {
      return [
        header,
        SliverToBoxAdapter(
          child: _feedErrorView(_feedError!),
        ),
      ];
    }

    if (_products.isEmpty) {
      return [
        header,
        SliverToBoxAdapter(child: _feedEmptyView()),
      ];
    }

    return [
      header,
      // A refresh can fail while the previous page is still on screen. Keep
      // the products, but show the retry instead of pretending the stale grid
      // is current.
      if (_feedError != null)
        SliverToBoxAdapter(child: _feedErrorView(_feedError!)),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        sliver: SliverGrid(
          gridDelegate: _feedGridDelegate,
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final product = _products[i];
              return DashboardProductCard(
                product: product,
                onTap: () => context.push('/user/product/${product.id}'),
              );
            },
            childCount: _products.length,
          ),
        ),
      ),
      SliverToBoxAdapter(child: _feedFooter()),
    ];
  }

  static const SliverGridDelegateWithFixedCrossAxisCount _feedGridDelegate =
      SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 3,
    mainAxisSpacing: 10,
    crossAxisSpacing: 8,
    // The card's text block has a fixed intrinsic height and its image absorbs
    // the rest. 0.58 gives a ~100dp tile a square-ish photo and enough room for
    // name, provider, city and price without a BOTTOM OVERFLOWED stripe.
    childAspectRatio: 0.58,
  );

  Widget _feedHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 22, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Fresh Finds',
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => context.push('/user/search'),
                  child: const Text(
                    'See all',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.teal,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _feedCategories.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                if (i == 0) {
                  return _feedChip(
                    label: 'All products',
                    selected: _feedCategoryId == null,
                    onTap: () => _selectFeedCategory(null),
                  );
                }
                final row = _feedCategories[i - 1];
                final id = row['category_id']?.toString() ?? '';
                final name = (row['name']?.toString() ?? '').trim();
                if (id.isEmpty || name.isEmpty) return const SizedBox.shrink();
                return _feedChip(
                  label: name,
                  selected: _feedCategoryId == id,
                  onTap: () => _selectFeedCategory(id),
                );
              },
            ),
          ),
        ],
      );
    );
  }

  Widget _feedChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryGreen
              : AppTheme.primaryGreen.withOpacity(0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppTheme.primaryGreen
                : AppTheme.primaryGreen.withOpacity(0.22),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppTheme.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _feedErrorView(String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_outlined,
                color: AppTheme.warning, size: 26),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, height: 1.4, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _reloadFeed,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
              style: TextButton.styleFrom(
                  foregroundColor: AppTheme.primaryGreen),
            ),
          ],
        ),
      ),
    );
  }

  Widget _feedEmptyView() {
    final scoped = _feedCategoryId != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 26),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          children: [
            Icon(
              scoped
                  ? Icons.inventory_2_outlined
                  : Icons.storefront_outlined,
              color: AppTheme.primaryGreen.withOpacity(0.65),
              size: 34,
            ),
            const SizedBox(height: 10),
            Text(
              scoped
                  ? 'No products in $_feedCategoryLabel yet'
                  : 'No products available yet',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 4),
            const Text(
              'Approved providers who publish a listing with a photo appear '
              'here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, height: 1.4, color: AppTheme.textMuted),
            ),
            if (scoped) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _selectFeedCategory(null),
                style: TextButton.styleFrom(
                    foregroundColor: AppTheme.teal),
                child: const Text('SHOW ALL PRODUCTS'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _feedFooter() {
    if (_feedLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppTheme.primaryGreen),
          ),
        ),
      );
    }
    if (!_feedHasMore && _feedError == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 6),
        child: Center(
          child: Text(
            "You've seen everything",
            style: TextStyle(
                fontSize: 11.5,
                fontStyle: FontStyle.italic,
                color: AppTheme.textMuted),
          ),
        ),
      );
    }
    return const SizedBox(height: 12);
  }

  // ------------------------------------------------------------ ride card

  Widget _rideBanner(Map<String, dynamic> ride) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: GestureDetector(
        onTap: () => context.push('/user/ride-active'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.primaryGreen, Color(0xFF2E7D32)],
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.near_me, color: Colors.white, size: 19),
              const SizedBox(width: 11),
              const Expanded(
                child: Text(
                  'Ride in progress — track your driver',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.8)),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ empty/err

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning \u2728';
    if (hour < 17) return 'Good afternoon \u2600\uFE0F';
    return 'Good evening \uD83C\uDF19';
  }

  Widget _buildSkeleton() {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 132,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
              ),
            ),
          ),
          const SizedBox(height: 14),
          // The quick-action row: two equal cards, same height.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: const [
                Expanded(
                  child: ShimmerEffect(
                    child: SkeletonBox(
                        width: double.infinity,
                        height: 96,
                        borderRadius: 16),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: ShimmerEffect(
                    child: SkeletonBox(
                        width: double.infinity,
                        height: 96,
                        borderRadius: 16),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // The 3 big category cards.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: List.generate(
                3,
                (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ShimmerEffect(
                    child: SkeletonBox(
                      width: double.infinity,
                      // 60, the compact card's own height: a placeholder of
                      // a different size makes the whole page jump when the
                      // data lands.
                      height: 60,
                      borderRadius: 16,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================ header pieces

/// Circular icon button for the header row.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.badgeCount = 0,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  /// Unread notifications, drawn as a superscript count. Zero hides it, so a
  /// caught-up inbox looks like an ordinary icon rather than a "0".
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.white.withOpacity(0.16),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 38,
              height: 38,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(icon, color: Colors.white, size: 20),
                  if (badgeCount > 0)
                    Positioned(
                      top: 6,
                      right: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        constraints: const BoxConstraints(minWidth: 14),
                        decoration: BoxDecoration(
                          color: AppTheme.error,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white, width: 1.2),
                        ),
                        child: Text(
                          badgeCount > 9 ? '9+' : '$badgeCount',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 8.5,
                            height: 1.25,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Equal-width, equal-height quick action card for the home row.
///
/// Used for "Book a ride" and "All providers": two cards side by side that
/// look like one unified row.
class _QuickActionCard extends StatelessWidget {
    const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tint,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.cardBorder, width: 0.5),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: tint.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: tint, size: 22),
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A big main category card: large, clean, with icon, title, the count in
/// words, and a subtle background tint. Tapping opens the group's
/// sub-categories.
class _MainCategoryCard extends StatelessWidget {
    const _MainCategoryCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tint,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          // Half the old 120. The three cards are navigation, not content:
          // they sat a full 120 + 120 + 120 + gaps between the quick actions
          // and the photos, which is most of the first screen spent on three
          // rows whose whole job is to be tapped and left.
          //
          // A MINIMUM, not a height: at a large accessibility text scale the
          // two lines need more than the compact row allows, and a fixed 60
          // would paint a BOTTOM OVERFLOWED stripe on the app's first screen.
          // The row grows instead of breaking.
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.cardBorder, width: 0.5),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                tint.withOpacity(0.04),
                Colors.white,
              ],
            ),
          ),
          child: Row(
            children: [
              // Left: icon block, sized to the new row height rather than to
              // the old card.
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tint.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: tint, size: 19),
              ),
              const SizedBox(width: 10),
              // Right: text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.keyboard_arrow_right,
                color: tint.withOpacity(0.6),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The small categories for the rail above Fresh Finds, in the order they are
/// shown.
///
/// Split out of the screen so the ordering can be tested without a database:
/// it is the one rule here that a reader cannot check by looking at the UI,
/// and getting it wrong quietly turns "top this week" into "alphabetical".
///
/// [ranked] is `ranked_categories` in rank order (mothers and leaves mixed),
/// and [motherOf] maps each leaf id to its mother's id. Since a listing is
/// filed against the category its provider picked — usually the mother — a
/// leaf's own week count is almost always zero, so the leaves are taken one
/// per mother per round in the MOTHERS' ranked order: the busiest trade's
/// first specialty, then the next trade's, and so on. A leaf with no known
/// mother is dropped rather than promoted to the top of the rail.
List<Map<String, dynamic>> subcategoryRailOrder(
  List<Map<String, dynamic>> ranked,
  Map<String, String> motherOf, {
  int maxChips = 12,
}) {
  if (ranked.isEmpty || motherOf.isEmpty || maxChips <= 0) return const [];

  // A row's index IS its rank, because the query already ordered them.
  final rankOf = <String, int>{};
  final leavesOf = <String, List<Map<String, dynamic>>>{};
  for (var i = 0; i < ranked.length; i++) {
    final id = ranked[i]['category_id'];
    if (id is! String) continue;
    rankOf[id] = i;
    final mother = motherOf[id];
    if (mother == null) continue;
    leavesOf.putIfAbsent(mother, () => []).add(ranked[i]);
  }
  final mothers = leavesOf.keys.toList()
    ..sort((a, b) => (rankOf[a] ?? 1 << 30).compareTo(rankOf[b] ?? 1 << 30));

  final rail = <Map<String, dynamic>>[];
  for (var round = 0; rail.length < maxChips; round++) {
    var addedThisRound = 0;
    for (final mother in mothers) {
      final leaves = leavesOf[mother]!;
      if (round >= leaves.length) continue;
      rail.add(leaves[round]);
      addedThisRound++;
      if (rail.length == maxChips) break;
    }
    if (addedThisRound == 0) break;
  }
  return rail;
}

// ============================================================== small views

/// "+ Post product", beside the city selector in the header.
///
/// One button for every role, and it decides what happens next:
///
/// * signed out → the login screen;
/// * signed in with no provider profile → an offer to become one;
/// * a provider → the posting gate (verification + wallet minimum), and
///   only then the add-product form.
class _PostProductButton extends StatelessWidget {
  const _PostProductButton();

  Future<void> _start(BuildContext context) async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      await context.push('/login');
      return;
    }

    Map<String, dynamic>? profile;
    try {
      profile = await client
          .from('provider_profiles')
          .select('id, status')
          .eq('user_id', user.id)
          .maybeSingle();
    } catch (_) {
      profile = null;
    }
    if (!context.mounted) return;

    if (profile == null) {
      await _offerBecomeProvider(context);
      return;
    }

    final providerId = profile['id'] as String;
    // The verification + wallet posting gate. A verified, funded provider
    // proceeds straight through; anyone else gets the two-step checklist
    // (document verification, wallet minimum) which re-checks itself on
    // app resume and via realtime, so finishing a step elsewhere lets them
    // through with no manual action. The server has the final word either
    // way: `create_provider_product` and the products trigger refuse a
    // provider the fulfilment gate rejects, and the form turns that
    // refusal into a sentence (see `showPublishBlockedDialog`).
    final allowed = await _postingGateHook(context, providerId);
    if (!allowed || !context.mounted) return;
    await context.push('/provider/products/new');
  }

  /// The one place the posting gate attaches to this button.
  ///
  /// Returns true when the provider may open the add-product form. The same
  /// gate also wraps every other add-product entry (the product list's FAB
  /// and empty-state button, the dashboard's Add Product action), so the
  /// rule cannot be walked around by entering through a different door.
  Future<bool> _postingGateHook(BuildContext context, String providerId) {
    return PostingGate.instance.ensure(context, providerId: providerId);
  }

  /// A signed-in user who is not (yet) a provider is offered the choice
  /// rather than dropped on a form that cannot save anything for them.
  Future<void> _offerBecomeProvider(BuildContext context) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.storefront_outlined,
            color: AppTheme.primaryGreen, size: 30),
        title: const Text('Become a provider'),
        content: const Text(
          'Selling on Aliob starts with a provider account: a business name, '
          'a category, and a one-time ID check. It takes a few minutes.',
          style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'go'),
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen),
            child: const Text('Become a provider'),
          ),
        ],
      ),
    );
    if (choice == 'go' && context.mounted) {
      await context.push('/role-select');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _start(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_circle_outline,
                  size: 15, color: AppTheme.primaryGreenDark),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  'Post product',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryGreenDark,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// City chip, top-left of the header.
class _CityChip extends ConsumerWidget {
  const _CityChip({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final city = ref.watch(cityProvider);
    final label = city.isAllCities
        ? 'All cities'
        : (city.isTravelMode
            ? '\u2708 ${city.activeCity}'
            : city.activeCity);
    return Material(
      color: Colors.white.withOpacity(0.16),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on_outlined, size: 16, color: Colors.white),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Couldn't refresh" strip. Same rule as AsyncView: content stays, the
/// failure is stated quietly and the whole strip is a retry target.
class _StaleBanner extends StatelessWidget {
    const _StaleBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.gold.withOpacity(0.14),
      child: InkWell(
        onTap: onRetry,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 15, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Couldn\'t refresh — $message',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Retry',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryGreen,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
    const _ErrorBlock({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: AppTheme.error.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.wifi_off_rounded,
                  size: 34, color: AppTheme.error),
            ),
            const SizedBox(height: 18),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
