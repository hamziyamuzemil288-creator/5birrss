import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;

import '../../core/widgets/cart_icon_button.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/location_service.dart';
import '../../core/services/city_service.dart';
import '../../core/services/product_like_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/product_card.dart';

/// Push listings with no known location to the end, preserving the server's
/// order within each group.
///
/// search_products sorts by ST_Distance, which is NULL for a listing that has
/// no location, and NULLs land wherever the sort puts them — typically
/// interleaved with genuine nearby hits. A listing that cannot be located is
/// not a "nearby" result and must not outrank one that is, so it is demoted
/// here. Once every product carries a location this is a no-op; it exists so
/// the ranking stays correct while any location-less rows remain (and it
/// cannot be done in SQL without changing the RPC's result contract).
///
/// Public and top-level so the ordering can be unit-tested directly.
List<Map<String, dynamic>> rankLocationLessLast(
    List<Map<String, dynamic>> rows) {
  final located = <Map<String, dynamic>>[];
  final unlocated = <Map<String, dynamic>>[];
  for (final r in rows) {
    final d = r['distance_km'];
    if (d is num) {
      located.add(r);
    } else {
      unlocated.add(r);
    }
  }
  return [...located, ...unlocated];
}

class UserSearchScreen extends StatefulWidget {
  const UserSearchScreen({super.key});
  @override
  State<UserSearchScreen> createState() => _UserSearchScreenState();
}

class _UserSearchScreenState extends State<UserSearchScreen> {
  /// Proximity radius for search when the device has a position. search_products
  /// filters on ST_DWithin, so omitting the radius makes the distance test
  /// evaluate to NULL and silently drops every located listing — leaving only
  /// location-less rows, which is what surfaced foreign results. Kept in sync
  /// with the server-side default in 20260925140000_search_geo_scope.sql.
  static const double _searchRadiusKm = 50;

  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _loading = false;
  bool _searched = false;
  String? _error;
  Timer? _debounce;

  // Live GPS: distance-from-user comes from the real device position.
  geo.Position? _myPos;

  @override
  void initState() {
    super.initState();
    _primeLocation();
  }

  /// One-time live GPS prime (permission prompt fires on first use).
  Future<void> _primeLocation() async {
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    if (r.success) {
      setState(() => _myPos = r.position);
      // Re-run the last query so distance_km fills in from real GPS.
      if (_ctrl.text.trim().isNotEmpty) _search(_ctrl.text.trim());
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      // Server-side full-text + geo search. Passing the live GPS position
      // makes the server compute real distance_km per result and lets the
      // user sort by distance; without permission it still works (no distance).
      final pos = _myPos;
      // Phase 1: scope search to the active city (travel city in travel
      // mode). City-less listings stay visible everywhere.
      //
      // An empty browse city is the "All cities" mode and is sent as NULL:
      // search_products treats a NULL city as "do not filter", where an empty
      // string would have matched only city-less rows.
      final browseCity = CityService.instance.activeCity;
      final data =
          await Supabase.instance.client.rpc('search_products', params: {
        'p_query': q.trim(),
        'p_limit': 30,
        'p_offset': 0,
        'p_city': browseCity.isEmpty ? null : browseCity,
        // "Global" (city-less) listings are an explicit FALLBACK, not the
        // default. With a position in hand the user asked for what is near
        // them; admitting every city-less listing unconditionally ranks a
        // listing from another area as a peer of a nearby one, which is what
        // produced the "unfamiliar place name" results. Only widen to global
        // when we have no position to narrow with.
        'p_include_global': pos == null,
        if (pos != null) ...{
          'p_lat': pos.latitude,
          'p_lng': pos.longitude,
          'p_radius_km': _searchRadiusKm,
          'p_sort_by': 'distance',
        },
      });
      var rows = List<Map<String, dynamic>>.from(data as List);
      // `search_products` did not project `listing_type` at all until migration
      // 20261011000001, and the DEPLOYED function still does not — so against a
      // live database every row here is missing the one column that decides BUY
      // vs BOOK, and a search result for a service read BUY while the same
      // service on its own page read BOOK. The migration fixes the projection;
      // this fixes the screen on the database the app is actually talking to.
      // One batched read of the rows that came back without the column, never
      // one per card, and a row that still cannot answer falls back to the
      // column default exactly as it did before.
      if (rows.any((r) => (r['listing_type'] as String?) == null)) {
        try {
          final ids = rows
              .where((r) => (r['listing_type'] as String?) == null)
              .map((r) => r['id'] as String)
              .toList();
          final types = await Supabase.instance.client
              .from('products')
              .select('id, listing_type')
              .inFilter('id', ids);
          final byId = <String, String>{};
          for (final raw in types as List) {
            final t = Map<String, dynamic>.from(raw as Map);
            byId['${t['id']}'] = (t['listing_type'] as String?) ?? '';
          }
          rows = rows
              .map((r) => <String, dynamic>{
                    ...r,
                    'listing_type': (r['listing_type'] as String?) ??
                        byId[r['id'] as String],
                  })
              .toList();
        } catch (_) {
          // Best-effort: a failed lookup leaves the rows as the RPC returned
          // them, which is the behaviour this screen had before.
        }
      }

      // The hearts on the grid: the caller's own reaction has to be known
      // BEFORE the cards render, or every heart shows empty and the first tap
      // clears a like the user already had. One batched call for the page.
      final counts = <String, int>{
        for (final r in rows)
          r['id'] as String: (r['like_count'] as num?)?.toInt() ?? 0,
      };
      ProductLikeService.instance.ensureLoaded(
        rows.map((r) => r['id'] as String),
        likeCountOf: (id) => counts[id] ?? 0,
      );

      if (mounted) {
        setState(() {
          _results = rankLocationLessLast(rows);
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Search is unavailable right now');
        });
      }
    }
  }

  /// Live-GPS distance as a plain label ("2.4 km away"), for the shared
  /// card's one-line caption. Empty until GPS is granted and the listing has
  /// a known location.
  String _distanceLabel(Map<String, dynamic> p) {
    if (_myPos == null) return '';
    final d = p['distance_km'];
    if (d == null) return '';
    final km = (d as num).toDouble();
    return km < 1
        ? '${(km * 1000).round()} m away'
        : '${km.toStringAsFixed(1)} km away';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          color: AppTheme.primaryGreen,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  onSubmitted: _onQueryChanged,
                  onChanged: _onQueryChanged,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search products, services...',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                    prefixIcon: const Icon(Icons.search,
                        color: Colors.white70, size: 20),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.15),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none),
                  ),
                ),
              ),
              const CartIconButton(iconColor: Colors.white),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.primaryGreen))                  : !_searched
                      ? const Center(
                          child: Text('Search for products and services',
                              style: TextStyle(color: AppTheme.textMuted)))
                      : _error != null
                          // _search takes the query, so retry re-runs it
                          // against whatever is currently in the box.
                          ? LoadErrorView(
                              message: _error!,
                              onRetry: () => _search(_ctrl.text.trim()))
                          : _results.isEmpty
                      ? const Center(
                          child: Text('No results found',
                              style: TextStyle(color: AppTheme.textMuted)))
                      : GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            // The same ratio as the home feed and the category
                            // pages, so a result is the same card they met on
                            // the way here.
                            childAspectRatio: 0.66,
                          ),
                          itemCount: _results.length,
                          itemBuilder: (_, i) {
                            final p = _results[i];
                            // A result used to be a text row with a grey
                            // placeholder where the photo goes and no action on
                            // it at all. It is the shared card now: the
                            // listing's own photo (search_products returns its
                            // cover path), the price, and the same BUY button
                            // every other surface carries.
                            final path =
                                (p['image_path'] as String?)?.trim() ?? '';
                            final caption = _distanceLabel(p);
                            return ProductCard.listing(
                              productId: (p['id'] ?? '') as String,
                              providerId: (p['provider_id'] ?? '') as String,
                              title: (p['name'] ?? '') as String,
                              priceLabel: listingPriceLabel(p),
                              // BUY for a good, BOOK for a service or a room.
                              // `search_products` carries the listing's own type
                              // since 20261011000001 for exactly this, so the
                              // card asks the same question every other surface
                              // asks and gets the same verb.
                              listingType: (p['listing_type'] as String?) ?? '',
                              imageUrl: path.isEmpty
                                  ? null
                                  : Supabase.instance.client.storage
                                      .from('product-images')
                                      .getPublicUrl(path),
                              // The distance when GPS has one, otherwise who is
                              // selling it — the card's provider tag carries
                              // the name, so the row never reads the same word
                              // twice.
                              caption: caption.isNotEmpty
                                  ? caption
                                  : (p['provider_name'] ?? '') as String,
                              rating: (p['rating'] as num?)?.toDouble() ?? 0,
                              isAvailable: p['is_available'] != false,
                              onTap: () =>
                                  context.push('/user/product/${p['id']}'),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
