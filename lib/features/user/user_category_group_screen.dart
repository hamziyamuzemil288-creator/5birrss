import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/category.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/category_icons.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/widgets/load_error_view.dart';

/// The 3 big category cards on Home, and how their members are decided.
///
/// This is the grouping Home's big cards use, kept here so the screen that
/// opens from a card and the card itself can never disagree about who
/// belongs where. A category can sit in exactly one group: the vehicle
/// sector first (it is the most specific signal), then the marketplace
/// sector, then the booking flag.
enum CategoryGroup {
  transport('transport', 'Transport & Rides'),
  shops('shops', 'Shops & Products'),
  services('services', 'Services & Booking');

  const CategoryGroup(this.slug, this.title);

  final String slug;
  final String title;

  static CategoryGroup? parse(String? slug) {
    for (final g in CategoryGroup.values) {
      if (g.slug == slug) return g;
    }
    return null;
  }

  /// Every top-level category in this group, in the order Home shows them.
  ///
  /// The three groups are EXCLUSIVE and ordered by specificity — transport,
  /// then shops, then services takes what is left — because a big card is a
  /// promise about what is behind it:
  ///
  /// * Every VEHICLE row (and any row tagged `TRANSPORT`) is a ride, even
  ///   though migration 20260923000004 tagged every VEHICLE row
  ///   `BOOKING_BASED`. Under a naive `service_group` check a taxi landed in
  ///   BOTH Transport and Services, which double-counted the card and
  ///   rendered the same category twice from two different screens.
  /// * FOOD / RETAIL / OTHER is a shop, whatever its booking flag says.
  /// * Everything else is Services & Booking — including a category an
  ///   admin seeded with no marketplace sector at all. Dropping it would
  ///   make it the one category in the app that exists nowhere, and
  ///   invisible is worse than imperfectly filed.
  List<AppCategory> membersOf(List<AppCategory> all) {
    final list = all.where(_owns).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  bool _owns(AppCategory c) {
    if (_isTransport(c)) return this == CategoryGroup.transport;
    if (_isShop(c)) return this == CategoryGroup.shops;
    return this == CategoryGroup.services;
  }

  static bool _isTransport(AppCategory c) =>
      c.sector == 'VEHICLE' || c.marketplaceSector == 'TRANSPORT';

  static bool _isShop(AppCategory c) =>
      c.marketplaceSector == 'FOOD' ||
      c.marketplaceSector == 'RETAIL' ||
      c.marketplaceSector == 'OTHER';
}

/// One of the three big categories, opened from Home: its sub-categories
/// only, searchable, and nothing from any other group.
///
/// This screen replaces the 3-up card grid that used to live on Home. The
/// grid had two rendering bugs — labels shrunk to nothing by a FittedBox,
/// and tiles whose label was empty rendering as a bare number — and both are
/// gone with it: every row here prints the category name at a readable size
/// first, and the count is a subtitle rather than the whole card.
class UserCategoryGroupScreen extends StatefulWidget {
  const UserCategoryGroupScreen({super.key, required this.group});

  /// The group slug from the route (`transport`, `shops`, `services`).
  final String group;

  @override
  State<UserCategoryGroupScreen> createState() =>
      _UserCategoryGroupScreenState();
}

class _UserCategoryGroupScreenState extends State<UserCategoryGroupScreen> {
  final _searchCtrl = TextEditingController();
  List<AppCategory> _members = const [];

  /// How many sub-categories each member owns, counted once for the screen.
  Map<String, int> _childCounts = const {};
  bool _loading = true;
  String? _error;

  CategoryGroup? get _group => CategoryGroup.parse(widget.group);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final group = _group;
    if (group == null) {
      setState(() {
        _loading = false;
        _error = 'That category group does not exist.';
      });
      return;
    }
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('categories')
          .select()
          .eq('is_active', true)
          .isFilter('parent_id', null)
          .order('sort_order')
          .limit(200);
      final all = (rows as List)
          .map((j) => AppCategory.fromJson(j))
          .toList(growable: false);
      final members = group.membersOf(all);

      // How many sub-categories each of these owns, in ONE query rather than
      // one per row. The count is context for the row, never the row itself:
      // a category with no children still opens, and still shows its name.
      final counts = <String, int>{};
      if (members.isNotEmpty) {
        final childRows = await client
            .from('categories')
            .select('parent_id')
            .inFilter('parent_id', members.map((c) => c.id).toList())
            .eq('is_active', true)
            .limit(500);
        for (final raw in childRows as List) {
          final pid = (raw as Map)['parent_id']?.toString();
          if (pid == null) continue;
          counts[pid] = (counts[pid] ?? 0) + 1;
        }
      }

      if (!mounted) return;
      setState(() {
        _members = members;
        _childCounts = counts;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load this category');
      });
    }
  }

  List<AppCategory> get _visible {
    final needle = _searchCtrl.text.trim().toLowerCase();
    if (needle.isEmpty) return _members;
    return _members
        .where((c) => c.name.toLowerCase().contains(needle))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    return Scaffold(
      appBar: AppBar(
        title: Text(group?.title ?? 'Category'),
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
                      // Search: the reason this screen exists rather than a
                      // longer grid on Home. 23 categories are browsable
                      // only if you can type the one you mean.
                      TextField(
                        controller: _searchCtrl,
                        onChanged: (_) => setState(() {}),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search in ${group?.title ?? 'categories'}',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _searchCtrl.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close_rounded),
                                  tooltip: 'Clear',
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    setState(() {});
                                  },
                                ),
                          filled: true,
                          fillColor: AppTheme.surface,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 0),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(
                                color: AppTheme.cardBorder, width: 0.5),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(
                                color: AppTheme.cardBorder, width: 0.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _searchCtrl.text.isEmpty
                            ? '${_members.length} categories'
                            : '${_visible.length} of ${_members.length} categories',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_visible.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 36),
                          child: Center(
                            child: Text(
                              _members.isEmpty
                                  ? 'No categories here yet'
                                  : 'No category matches "${_searchCtrl.text.trim()}"',
                              style:
                                  const TextStyle(color: AppTheme.textMuted),
                            ),
                          ),
                        )
                      else
                        ..._visible.map(_row),
                    ],
                  ),
                ),
    );
  }

  /// One category: readable name first, sub-category count as the subtitle,
  /// never a bare number.
  Widget _row(AppCategory c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.push('/user/category/${c.id}'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.cardBorder, width: 0.5),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryGreen.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  // The category's own sector glyph — the same rule the home
                  // rail's chips use (core/utils/category_icons.dart), so a
                  // food category wears the same icon here as it does on the
                  // rail that led to this screen. Was one generic glyph for
                  // every row, which told the buyer nothing about what is
                  // behind the row.
                  child: Icon(categoryIconForSector(c.marketplaceSector),
                      color: AppTheme.primaryGreenDark, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        // The name is the row. Never a FittedBox, never
                        // ellipsised to a fragment: one line at 15, two if
                        // it is long, and always readable.
                        c.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        (_childCounts[c.id] ?? 0) > 0
                            ? '${_childCounts[c.id]} sub-categories'
                            : 'Browse listings in this category',
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
