import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/points_service.dart';
import '../../core/services/posting_gate.dart';
import '../../core/services/provider_readiness.dart';
import '../../core/services/rank_service.dart';
import '../../core/services/resilient_subscription.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/product_card.dart' show listingCoverUrl;
import '../../core/widgets/publish_readiness_banner.dart';
import '../../core/widgets/rank_badge.dart';
import '../../core/widgets/dashboard_top_tabs.dart';
import '../../core/widgets/quick_action_pill.dart';
import 'provider_payment_methods_screen.dart';

class ServiceProviderDashboard extends ConsumerStatefulWidget {
  const ServiceProviderDashboard({super.key});
  @override
  ConsumerState<ServiceProviderDashboard> createState() =>
      _ServiceProviderDashboardState();
}

class _ServiceProviderDashboardState
    extends ConsumerState<ServiceProviderDashboard> {
  Map<String, dynamic>? _providerProfile;
  int _productCount = 0;
  int _orderCount = 0;

  /// Orders sitting at PENDING_PROVIDER — the provider is the only actor who
  /// can move them, so this is work that is blocked on THEM and nobody else.
  ///
  /// `_orderCount` above is every order ever, which is a vanity number: it
  /// cannot change when new work arrives, so a provider watching it has no way
  /// to tell a quiet week from a queue of three bookings they have not
  /// answered. This is the number that moves.
  int _awaitingMe = 0;

  /// Of those, the ones whose listing asked for an availability confirmation.
  ///
  /// Counted separately because they are the ones with a deadline attached: a
  /// buyer is sitting on "Waiting for the provider to confirm availability" and
  /// cannot pay until this is answered.
  int _awaitingAvailability = 0; // kept so the build slate can announce "N new requests" — wire when a future turn adds that notification

  /// Pre-order availability requests (the gate every Buy/Book now crosses,
  /// migration 20261006000006) still PENDING on this provider's listings —
  /// buyers sitting on a 15-minute countdown who cannot pay until this
  /// provider answers.
  List<Map<String, dynamic>> _pendingAvailability = [];

  /// Ids already surfaced to this provider, so the realtime subscription
  /// announces each new request exactly once (the first frame of a
  /// subscription is the whole current queue, not news).
  final Set<String> _knownPendingAvailability = {};
  ResilientSubscription<List<Map<String, dynamic>>>? _availabilityLive;
  int _points = 0;
  RankProgress? _rankProgress;
  double? _walletBalance;
  bool _loading = true;
  String? _error;

  /// What the SERVER says is outstanding before this provider may publish.
  ///
  /// Loaded alongside the rest of the dashboard, and re-read whenever the
  /// provider returns from fixing something. It is deliberately not derived
  /// from `ProviderDocGate`: the client's rule and the server's rule differ
  /// (see `ProviderReadiness`), and it was the client's more permissive answer
  /// that let a provider fill in a form the server would refuse.
  ProviderReadiness _readiness = ProviderReadiness.unknown;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final prov = await client
          .from('provider_profiles')
          .select()
          .eq('user_id', userId)
          .eq('provider_type', 'SERVICE_PROVIDER')
          .maybeSingle();
      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final prods = await client
          .from('products')
          .select('id')
          .eq('provider_id', prov['id'])
          .eq('is_active', true)
          .count(CountOption.exact);
      final orders = await client
          .from('orders')
          .select('id')
          .eq('provider_id', prov['id'])
          .count(CountOption.exact);
      // The queue. `.eq('status', 'PENDING_PROVIDER')` rather than a client
      // filter over the 200 rows the orders screen loads: this has to be right
      // the moment the dashboard opens, not only after a list has paged in.
      final waiting = await client
          .from('orders')
          .select('id, requires_availability_confirmation')
          .eq('provider_id', prov['id'])
          .eq('status', 'PENDING_PROVIDER');
      final waitingRows = List<Map<String, dynamic>>.from(waiting as List);
      final points = await PointsService.instance.getProviderPoints(prov['id'] as String);
      // Ladder from the server; best-effort so a rank hiccup never blocks the
      // dashboard itself.
      RankProgress? progress;
      try {
        progress = await RankService.instance.progressForPoints(points);
      } catch (_) {
        progress = null;
      }
      final wallet = await client
          .from('wallets')
          .select('balance')
          .eq('provider_id', prov['id'])
          .maybeSingle();
      // Asked of the server, alongside the rest, and never allowed to fail the
      // dashboard: a provider who cannot publish still needs to see their
      // orders. An unreadable answer leaves the banner hidden rather than
      // showing a wrong "you are ready".
      final readiness =
          await ProviderReadiness.load(prov['id'] as String);
      // The availability queue, alongside everything else: the section has
      // to be right the moment the dashboard opens, then stay live.
      await _loadAvailability(prov['id'] as String);
      if (mounted) {
        setState(() {
          _providerProfile = prov;
          _productCount = prods.count ?? 0;
          _orderCount = orders.count ?? 0;
          _awaitingMe = waitingRows.length;
          _awaitingAvailability = waitingRows
              .where((o) => o['requires_availability_confirmation'] == true)
              .length;
          _points = points;
          _rankProgress = progress;
          _walletBalance = (wallet?['balance'] as num?)?.toDouble();
          _readiness = readiness;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your dashboard');
        });
      }
    }
  }

  /// Re-asks the server whether the provider may publish now.
  ///
  /// Called when the provider returns from a remedy in the banner. It does not
  /// assume the fix worked: the provider may have opened the wrong screen, or
  /// the activation fee may still be processing, and a banner that clears
  /// itself optimistically is the same lie the server's refusal used to tell.
  Future<void> _reloadReadiness() async {
    final id = _providerProfile?['id'];
    if (id is! String || !mounted) return;
    final readiness = await ProviderReadiness.load(id);
    if (!mounted) return;
    setState(() => _readiness = readiness);
  }

  @override
  void dispose() {
    _availabilityLive?.cancel();
    super.dispose();
  }

  /// Reads (and re-reads) the PENDING pre-order availability requests for
  /// this provider's listings, then keeps the realtime subscription alive.
  ///
  /// Best-effort: a database that has not run migration 20261006000006 has
  /// no such table, and the section simply stays hidden — nothing else on
  /// this dashboard depends on the gate existing.
  Future<void> _loadAvailability(String providerId) async {
    try {
      final rows = await Supabase.instance.client
          .from('availability_requests')
          .select(
              'id, product_id, quantity, created_at, expires_at, '
              'products(name, listing_type, '
              'product_images(storage_path, sort_order))')
          .eq('provider_id', providerId)
          .eq('status', 'PENDING')
          .order('created_at', ascending: false)
          .limit(20);
      final list = List<Map<String, dynamic>>.from(rows as List);
      if (!mounted) return;
      setState(() {
        _pendingAvailability = list;
        _knownPendingAvailability
          ..clear()
          ..addAll(list.map((r) => r['id'] as String));
      });
      _subscribeAvailability(providerId);
    } catch (_) {
      // No table yet (migration pending) — the section stays hidden.
    }
  }

  /// One subscription per dashboard life. Every frame that carries a
  /// request this provider has not seen announces it once and re-reads the
  /// queue; frames that carry nothing new only refresh silently.
  void _subscribeAvailability(String providerId) {
    if (_availabilityLive != null) return;
    _availabilityLive = ResilientSubscription<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('availability_requests')
          .stream(primaryKey: ['id'])
          .eq('provider_id', providerId)
          .order('created_at'),
      onData: (rows) {
        final fresh = rows
            .where((r) =>
                r['status'] == 'PENDING' &&
                _knownPendingAvailability.add(r['id'] as String))
            .toList();
        if (!mounted) return;
        if (fresh.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              // Neutral wording on purpose: a booking and a purchase ask the
              // same question through the same row, and the tile below says
              // which one it is — this line only says somebody is waiting.
              content: Text(fresh.length == 1
                  ? 'A buyer is waiting for your answer. They have 15 '
                      'minutes before the request expires.'
                  : '${fresh.length} buyers are waiting for an availability '
                      'answer.'),
            ),
          );
        }
        _loadAvailability(providerId);
      },
      // Connection quality only changes how much the poll matters; the
      // reload above runs either way.
      onState: (_) {},
    );
  }

  /// Accept: the buyer is released into checkout immediately (their screen
  /// is watching the same row over realtime).
  Future<void> _respondToAvailability(Map<String, dynamic> request,
      bool accept, {String? reason}) async {
    try {
      await Supabase.instance.client.rpc('respond_availability_request',
          params: {
            'p_request_id': request['id'],
            'p_accept': accept,
            if (reason != null && reason.isNotEmpty) 'p_reason': reason,
          });
      if (!mounted) return;
      final product = request['products'] as Map<String, dynamic>?;
      final type = ((product?['listing_type'] as String?) ?? '').toUpperCase();
      final isBooking = type == 'SERVICE' || type == 'ROOM';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(accept
              ? (isBooking
                  ? 'Told the buyer you can take this booking — they can pay '
                      'now.'
                  : 'Told the buyer it is available — they can check out now.')
              : (isBooking
                  ? 'Told the buyer you cannot take this booking.'
                  : 'Told the buyer it is not available.')),
        ),
      );
      final id = _providerProfile?['id'] as String?;
      if (id != null) await _loadAvailability(id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(friendlyError(e, context: 'Could not send your answer'))),
      );
    }
  }

  /// Decline asks for the reason the buyer will read, because "Not
  /// available" with no words behind it sends the buyer to guess.
  Future<void> _declineAvailability(Map<String, dynamic> request) async {
    final ctrl = TextEditingController();
    final product = request['products'] as Map<String, dynamic>?;
    final type = ((product?['listing_type'] as String?) ?? '').toUpperCase();
    final isBooking = type == 'SERVICE' || type == 'ROOM';
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(isBooking ? 'Decline this booking?' : 'Not available?'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 120,
          decoration: InputDecoration(
            labelText: 'Reason (optional)',
            hintText: isBooking
                ? 'e.g. Fully booked until Friday'
                : 'e.g. Sold out until Friday',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, ctrl.text.trim()),
            child: const Text('SEND'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (reason == null || !mounted) return; // dismissed: nothing is sent
    await _respondToAvailability(request, false, reason: reason);
  }

  /// The queue itself: one row per request, each directly answerable.
  Widget _availabilitySection() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warning.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule, size: 20, color: AppTheme.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Pending availability requests',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_pendingAvailability.length}',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Buyers waiting before they can pay — 15 minutes to answer.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const Divider(height: 20),
          ..._pendingAvailability.map(_availabilityTile),
        ],
      ),
    );
  }

  Widget _availabilityTile(Map<String, dynamic> request) {
    final product = request['products'] as Map<String, dynamic>?;
    final name = product?['name'] as String? ?? 'An item';
    // Part 5: the request shows the listing's own cover photo — the same
    // lowest-sort_order rule every shared card uses (listingCoverUrl in
    // core/widgets/product_card.dart), so "which item is this" is answered
    // by the picture the buyer was looking at when they asked.
    final coverUrl = listingCoverUrl(
        (product?['product_images'] as List?) ?? const []);
    final cover = coverUrl == null
        ? null
        : ResizeImage(NetworkImage(coverUrl), width: 44, height: 44);
    // A SERVICE or a ROOM is BOOKED, everything else is bought — the same two
    // types the buyer's own button reads (`listingActionLabel` in
    // core/widgets/product_card.dart). The request is identical either way; what
    // differs is that a provider accepting an appointment is not confirming
    // stock, and the button they read should say so.
    final type = ((product?['listing_type'] as String?) ?? '').toUpperCase();
    final isBooking = type == 'SERVICE' || type == 'ROOM';
    final qty = ((request['quantity'] as num?)?.toDouble() ?? 1);
    final qtyText = qty == qty.roundToDouble()
        ? qty.toInt().toString()
        : qty.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: cover == null
                    ? Container(
                        width: 44,
                        height: 44,
                        color: AppTheme.creamDark,
                        child: const Icon(Icons.image_outlined,
                            size: 20, color: AppTheme.textMuted),
                      )
                    : Image(image: cover, fit: BoxFit.cover, width: 44, height: 44),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isBooking ? '$name · booking' : '$name × $qtyText',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _respondToAvailability(request, true),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primaryGreen,
                    side: const BorderSide(color: AppTheme.primaryGreen),
                  ),
                  child: Text(isBooking ? 'ACCEPT BOOKING' : 'AVAILABLE'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _declineAvailability(request),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error,
                    side: const BorderSide(color: AppTheme.error),
                  ),
                  child: Text(isBooking ? 'DECLINE' : 'NOT AVAILABLE'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aliob Business'),
        actions: [
          // Task 7 item 2: real notification inbox (admin broadcasts land
          // here), not a placeholder snackbar.
          IconButton(
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => context.push('/admin-notifications')),
          IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () =>
                  ref.read(authProvider.notifier).signOut()),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [
                              AppTheme.primaryGreen,
                              Color(0xFF2E7D32)
                            ]),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              _providerProfile?['business_name'] ??
                                  auth.profile?.fullName ??
                                  'Business',
                              style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                    (_providerProfile?['status'] ?? 'UNKNOWN')
                                        .replaceAll('_', ' '),
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.white)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Before anything else: can this provider publish at all?
                    //
                    // "Add Product" and "Add Vehicle" are both refused by the
                    // server until this list is empty, and until this banner
                    // existed the ONLY place that surfaced was a failed save at
                    // the end of a fully filled form. A provider who could not
                    // publish had no way to find out why short of trying.
                    PublishReadinessBanner(
                      readiness: _readiness,
                      onChanged: _reloadReadiness,
                    ),
                    // The availability queue. A buyer is on a 15-minute
                    // countdown before they can pay, and the notification
                    // that announces it is easy to miss — the same rows stay
                    // answerable here, so a missed popup is never missed
                    // work.
                    if (_pendingAvailability.isNotEmpty) _availabilitySection(),
                    // The one shortcut this role opens most: a provider's
                    // photos are what a customer reads before they book, and
                    // the Business tab buried them one tab and one list row
                    // deep. This is the same pill the user home screen uses
                    // for "Book a ride" — QuickActionPill, not a second
                    // button style.
                    //
                    // Additive, not a move: the Business tab entry stays,
                    // because a provider who already knows where it is should
                    // find it there too.
                    //
                    // Gated on the same condition as that entry, for the same
                    // reason: the route is /provider/gallery/:id, so without a
                    // provider id this would push a path matching no route.
                    if (_providerProfile?['id'] != null)
                      QuickActionPill(
                        icon: Icons.photo_library_outlined,
                        label: 'My Gallery',
                        onTap: () => context.push(
                            '/provider/gallery/${_providerProfile!['id']}'),
                      ),
                    const SizedBox(height: 20),
                    // Rank: the business's standing on the loyalty ladder, with
                    // the distance to the next rung. Status only — no feature
                    // is gated on it.
                    RankProgressCard(
                      points: _points,
                      progress: _rankProgress,
                      subjectLabel: 'Business',
                      onTap: () => context.push('/points'),
                    ),
                    const SizedBox(height: 20),
                    // Wallet balance strip
                    _walletCard(),
                    const SizedBox(height: 20),
                    // Stats
                    Row(
                      children: [
                        _statCard(Icons.inventory_2_outlined, 'Products',
                            '$_productCount'),
                        const SizedBox(width: 12),
                        _statCard(
                            Icons.receipt_long, 'Orders', '$_orderCount'),
                        const SizedBox(width: 12),
                        _statCard(
                            Icons.stars_rounded, 'Points', '$_points'),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Grouped per the founder's top-tab sketch. The same
                    // entries, in the same order, in the same screens —
                    // only the navigation shape changed.
                    DashboardTopTabs(
                      tabs: [
                        DashboardTab(
                          label: 'Business',
                          icon: Icons.storefront_outlined,
                          builder: (_) => _actionList([
                            // Buyer mode: providers can shop from other
                            // providers using the regular user experience
                            // (browse, cart, checkout, escrow) while keeping
                            // this business view.
                            _action(Icons.shopping_bag_outlined,
                                'Browse & Shop', () => context.push('/user')),
                            _action(Icons.storefront_outlined,
                                'Business Profile',
                                () => context.push('/provider/business')),
                            // The trade-specific form: the fields and prices
                            // this provider's own category defines, set by an
                            // administrator. Sits beside Business Profile
                            // rather than replacing it -- that one is who they
                            // are, this one is what they sell.
                            _action(Icons.tune, 'Settings & Pricing',
                                () => context.push('/provider/category-settings')),
                            // Parts 1 and 8: document verification is
                            // voluntary and lives here — this door did not
                            // exist while the server refused to activate a
                            // provider without documents nobody could upload
                            // from Settings. Nothing behind it gates trading:
                            // posting and selling work without it.
                            _action(Icons.badge_outlined, 'Verify Documents',
                                () => context.push('/provider/documents')),
                            // Only rendered once a profile row exists. The
                            // route is /provider/gallery/:id, so a null id
                            // here would push a path matching no route at all.
                            if (_providerProfile?['id'] != null)
                              _action(Icons.photo_library_outlined, 'My Gallery',
                                  () => context.push(
                                      '/provider/gallery/${_providerProfile!['id']}')),
                            _action(Icons.card_membership, 'Subscription',
                                () => context.push('/provider/subscription')),
                            _action(
                                Icons.payment_outlined,
                                'Payment account number',
                                () => context.push('/provider/payment-methods')),
                          ]),
                        ),
                        DashboardTab(
                          label: 'Catalogue',
                          icon: Icons.inventory_2_outlined,
                          builder: (_) => _actionList([
                            _action(Icons.inventory_2_outlined,
                                'My Products',
                                () => context.push('/provider/products')),
                            _action(Icons.add_circle_outline, 'Add Product',
                                _startAddProduct),
                          ]),
                        ),
                        DashboardTab(
                          label: 'Orders',
                          icon: Icons.receipt_long_outlined,
                          builder: (_) => _actionList([
                            _action(Icons.receipt_long_outlined, 'Orders',
                                () => context.push('/provider/orders')),
                            // The money a buyer paid into this account. The
                            // provider can confirm it here as well as an admin
                            // can; the platform wallet top-up stays
                            // admin-only and is not on this screen.
                            _action(Icons.verified_outlined,
                                'Verify Buyer Payments',
                                () => context.push('/provider/payment-verification')),
                          ]),
                        ),
                        DashboardTab(
                          label: 'Account',
                          icon: Icons.person_outline,
                          builder: (_) => _actionList([
                            _action(
                                Icons.account_balance_wallet_outlined, 'Wallet',
                                () => context.push('/wallet')),
                            _action(Icons.person_outline, 'Profile',
                                () => context.push('/profile')),
                          ]),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  /// The entries of one dashboard tab, as a single widget.
  ///
  /// Returns a Column rather than a List<Widget> because a DashboardTab's
  /// builder is a WidgetBuilder: handing it a list is a type error, and
  /// returning the raw list is what made this compile-fail.
  Widget _actionList(List<Widget> actions) =>
      Column(children: actions);

  /// Add Product, gated like every other add-product entry (the header's
  /// "Post product" button, the product list's FAB and empty state): the
  /// server's fulfilment blockers decide, and the two-step checklist prompt
  /// appears for anyone short of document verification or the wallet
  /// minimum, re-checking itself as they finish each step.
  Future<void> _startAddProduct() async {
    final providerId = _providerProfile?['id'] as String?;
    if (providerId == null || !mounted) return;
    final allowed =
        await PostingGate.instance.ensure(context, providerId: providerId);
    if (!allowed || !mounted) return;
    await context.push('/provider/products/new');
  }

  /// Compact wallet balance strip: balance at a glance + one-tap recharge.
  Widget _walletCard() {
    final balance = _walletBalance ?? 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.primaryGreen.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.account_balance_wallet_outlined,
                color: AppTheme.primaryGreen, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Wallet Balance',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                const SizedBox(height: 2),
                Text('${balance.toStringAsFixed(2)} ETB',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => context.push('/wallet/recharge'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Recharge',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            style: TextButton.styleFrom(foregroundColor: AppTheme.teal),
          ),
        ],
      ),
    );
  }

  Widget _statCard(IconData icon, String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppTheme.primaryGreen, size: 22),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback? onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: AppTheme.primaryGreen),
        title: Text(label,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w500)),
        trailing: const Icon(Icons.chevron_right,
            color: AppTheme.textMuted, size: 20),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
        tileColor: AppTheme.surface,
      ),
    );
  }
}
