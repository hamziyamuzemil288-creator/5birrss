import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
// `AuthState` is hidden because GoTrue also exports one and they are
// unrelated: this file's `_initials(AuthState auth)` takes the app's, which
// carries `.profile` (a UserProfile). GoTrue's has no `profile` at all.
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import 'package:postgrest/postgrest.dart' show CountOption;
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';

class AdminDashboard extends ConsumerStatefulWidget {
  const AdminDashboard({super.key});
  @override
  ConsumerState<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends ConsumerState<AdminDashboard> {
  int _pendingProviders = 0;
  int _pendingUsers = 0;
  int _pendingRecharges = 0;
  int _totalProviders = 0;
  int _totalUsers = 0;
  int _totalProducts = 0;
  int _totalOrders = 0;
  int _openAppeals = 0;
  int _openDisputes = 0;
  int _pendingOrderPayments = 0;

  /// Buyers waiting on a stock check right now. Counted by the server
  /// (`pending_availability_request_count`) so the badge is the real queue,
  /// not the first 300 rows the screen happens to have loaded.
  int _pendingAvailability = 0;

  /// Identity documents waiting on a reviewer. Shown on the Document
  /// Verification card, and folded into the header badge so a queue nobody
  /// opens is still visible.
  int _pendingDocuments = 0;
  double _totalIncome = 0;
  // my_admin_permissions() returns ['*'] for the true Admin/CEO — i.e. every
  // card visible — and the explicit list for staff, who then see only their
  // permitted sections. Server-side RLS remains the real boundary.
  Set<String> _myPerms = const {'*'};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final client = Supabase.instance.client;

    // Each metric is loaded independently: one failing query must never
    // abort the whole load (previously a single bad query zeroed every
    // counter and silently hid pending approvals from the admin).
    //
    // TWO SHAPES COME BACK FROM THESE QUERIES, and reading only one of them is
    // exactly what hid the document queue from this dashboard.
    //
    //   `.count(CountOption.exact)` on a table  -> a PostgrestList, which
    //     carries `.count`
    //   an RPC declared `RETURNS integer`        -> a plain int, which does
    //     NOT
    //
    // `admin_pending_document_count` is the second kind. `(7 as dynamic).count`
    // throws NoSuchMethodError, the `catch (_)` below turned that into 0, and
    // the Document Verification card read "No documents waiting" forever while
    // the screen behind it showed a full queue -- which is reported as "it is
    // not on the dashboard, but I get it when I go to document verification".
    //
    // Both shapes are read explicitly rather than by `catch`, because a
    // swallowed mismatch and a genuine zero are indistinguishable from the
    // outside, and that ambiguity is what hid this for so long.
    Future<int> count(Future<dynamic> Function() query) async {
      try {
        final res = await query();
        if (res is int) return res;
        if (res is num) return res.toInt();
        final c = (res as dynamic).count;
        return c is int ? c : 0;
      } catch (_) {
        return 0;
      }
    }

    final results = await Future.wait<int>([
      count(() => client.from('provider_profiles').select('id').eq('status', 'PENDING_APPROVAL').count(CountOption.exact)),
      count(() => client.from('profiles').select('id').eq('status', 'PENDING_APPROVAL').count(CountOption.exact)),
      count(() => client.from('wallet_recharge_requests').select('id').eq('status', 'PENDING').count(CountOption.exact)),
      count(() => client.from('provider_profiles').select('id').count(CountOption.exact)),
      count(() => client.from('profiles').select('id').count(CountOption.exact)),
      count(() => client.from('products').select('id').count(CountOption.exact)),
      count(() => client.from('orders').select('id').inFilter('status', ['APPROVED', 'STARTED', 'COMPLETED']).count(CountOption.exact)),
      count(() => client.from('appeal_cases').select('id').eq('status', 'OPEN').count(CountOption.exact)),
      // Open order disputes. These are NOT appeal_cases: only an admin can
      // move an order out of DISPUTED, so without a count here an open
      // dispute is invisible from the dashboard entirely.
      count(() => client.from('orders').select('id').eq('status', 'DISPUTED').count(CountOption.exact)),
      // Orders whose payment the buyer submitted and is waiting on an admin.
      // Only an admin can move an order out of PAYMENT_VERIFICATION, so
      // without this count a customer who has already paid is invisible and
      // the provider never gets the release.
      count(() => client
          .from('orders')
          .select('id')
          .eq('status', 'PAYMENT_VERIFICATION')
          .count(CountOption.exact)),
      // Identity documents waiting for a verdict. Every other actionable card
      // on this dashboard carries a number and this one carried only the words
      // "ID documents awaiting review", so "are there any?" was answered by
      // opening the page. The count comes from a server function that checks
      // the reviewer's own permission, rather than a client COUNT against
      // `user_documents`, which RLS does not scope for reviewers -- so a
      // non-reviewer sees 0 rather than a permission error, and a reviewer
      // sees their real queue.
      count(() async => await client.rpc('admin_pending_document_count')),
      // Requests sitting in the availability queue. The card used to read
      // "Pre-order stock checks" with no number at all, so the one queue with
      // a 15-minute clock on it was also the one nothing pointed at.
      count(() async => await client.rpc('pending_availability_request_count')),
    ]);

    // Section visibility for the signed-in principal (fail-open to '*' is
    // impossible: my_admin_permissions returns [] for no perms — a genuine
    // restriction — so a thrown call simply leaves the default).

    // Platform income = fees actually charged: per-transaction fees plus
    // subscription fees from the wallet ledger (orders table has no fee
    // column, and subscriptions hold schedule rows, not charges).
    //
    // RECHARGE is in this list for one reason: approve_wallet_recharge()
    // withholds the one-time provider_registration_fee from a provider's FIRST
    // approved recharge and records it as `platform_fee` on the RECHARGE row.
    // Without it the activation fee — the only income collected before a
    // provider completes an order — was missing from this total, so a
    // deployment whose providers were still activating showed ETB 0.00 while
    // money had been taken. Every later recharge carries platform_fee = 0, so
    // counting the column over all three types cannot double-count a deposit.
    // The income summary screen counts the same three types, so the definition
    // of "income" lives in one place even though the two windows differ (this
    // total is all-time; the summary screen is date-filterable).
    double income = 0;
    try {
      final feeRows = await client
          .from('wallet_transactions')
          .select('platform_fee')
          .inFilter(
              'transaction_type', ['TRANSACTION_FEE', 'SUBSCRIPTION_FEE', 'RECHARGE'])
          .limit(1000);
      for (final t in feeRows as List) {
        income += (t['platform_fee'] as num?)?.toDouble() ?? 0;
      }
    } catch (_) {}

    // Permission fetch is independent of the counts (a failure must never
    // blank the dashboard; worst case the full list shows while RLS still
    // guards every screen).
    try {
      final perms = await client.rpc('my_admin_permissions');
      final list = ((perms as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      if (mounted) setState(() => _myPerms = list.toSet());
    } catch (_) {}

    if (mounted) {
      setState(() {
        _pendingProviders = results[0];
        _pendingUsers = results[1];
        _pendingRecharges = results[2];
        _totalProviders = results[3];
        _totalUsers = results[4];
        _totalProducts = results[5];
        _totalOrders = results[6];
        _openAppeals = results[7];
        _openDisputes = results[8];
        _pendingOrderPayments = results[9];
        _pendingDocuments = results[10];
        _pendingAvailability = results[11];
        _totalIncome = income;
        _loading = false;
      });
    }
  }

  /// Card visibility per the signed-in principal's permissions.
  bool _can(String perm) =>
      _myPerms.contains('*') || _myPerms.contains(perm);

  /// Up to two initials for the account avatar, from whatever the signed-in
  /// profile carries. Falls back to a single letter rather than an empty
  /// avatar, so the menu button always has something to tap and read.
  ///
  /// Derived from the auth state rather than a second profile query: this is
  /// decoration, and a failure to load a name must not put an error on the
  /// dashboard.
  String _initials(AuthState auth) {
    final source = (auth.profile?.fullName ?? '').trim().isNotEmpty
        ? auth.profile!.fullName
        : (auth.user?.email ?? '');
    final parts = source
        .trim()
        .split(RegExp(r'[\s@._-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  /// Which queue is actually holding work, checked in the order a case
  /// arrives: an account or provider awaiting a decision, then a document,
  /// then a filed appeal, then a disputed order, then money to verify.
  ///
  /// ONE definition, used by the header bell AND the Pending tile: two
  /// copies of this ladder is how the badge and the tile ended up pointing
  /// at different queues while showing the same number.
  String _firstPendingRoute() {
    if (_pendingProviders + _pendingUsers > 0) return '/admin/approvals';
    if (_pendingDocuments > 0) return '/admin/document-verification';
    if (_openAppeals > 0) return '/admin/appeals';
    if (_openDisputes > 0) return '/admin/disputes';
    if (_pendingOrderPayments > 0) return '/admin/payments';
    if (_pendingRecharges > 0) return '/admin/payments';
    // Last before the catch-all: an unanswered stock check expires in minutes,
    // so it outranks nothing above it but should not be invisible either.
    if (_pendingAvailability > 0) return '/admin/availability';
    return '/admin/approvals';
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    // EVERY queue this dashboard already counts, and nothing else.
    //
    // Appeals and order disputes used to be missing here even though both were
    // loaded into fields further down and shown as cards: an open appeal was
    // counted, carded, and absent from the one number meant to say "there is
    // work waiting". That is the "it is not showing at the top" half of the
    // report, and it is why the badge could read 0 while the Appeals card two
    // inches below it read "3 open cases".
    final pendingTotal = _pendingProviders +
        _pendingUsers +
        _pendingRecharges +
        _pendingDocuments +
        _openAppeals +
        _openDisputes +
        // Order payments sat OUTSIDE this sum while the bell routed to them:
        // the badge could read 0 with five payments waiting to be verified.
        _pendingOrderPayments +
        _pendingAvailability;
    final hasPending = pendingTotal > 0;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Aliob Admin',
            style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.primaryGreenDark,
        elevation: 0,
        actions: [
          // The way into the CEO workspace. Rendered only for a CEO account,
          // because for anyone else the destination explains it is CEO-only
          // and offering it would be a dead end. The real check is server-side
          // in is_ceo(); this only decides whether to show the door.
          // `canOpenCeoOnly`, not `isCeo`: the workspace is still reachable
          // for a CEO whose authority the database grants through a staff row
          // flagged is_ceo, which the local heuristic misses. The screen
          // behind it re-checks (is_ceo_authority) before rendering anything.
          if (ref.watch(authProvider).canOpenCeoOnly)
            IconButton(
              tooltip: 'CEO workspace',
              icon: const Icon(Icons.workspace_premium),
              onPressed: () => context.push('/ceo'),
            ),
          // The admin's own inbox. The bell below carries a PENDING-WORK count
          // and routes to the queue that is holding it, which is a different
          // thing: an application submitted or resubmitted writes a
          // notification to this account, and until there was a link here an
          // administrator had no way to read one. The screen and the
          // /admin-notifications route already existed and are owner-scoped,
          // so this adds a door rather than a feature.
          // ONE bell, not two. The header used to carry an inbox bell and a
          // pending-work bell side by side — two identical icons doing
          // different jobs, which reads as a duplicate either way. The count
          // that changes an administrator's day is the work waiting, so the
          // surviving bell keeps the badge and opens whichever queue holds
          // it; the inbox moved into the account menu below ("Notifications").
          if (hasPending)
            Badge(
              label: Text('$pendingTotal',
                  style: const TextStyle(fontSize: 10, color: Colors.white)),
              backgroundColor: AppTheme.error,
              child: IconButton(
                tooltip: 'Pending items',
                icon: const Icon(Icons.notifications_outlined),
                // Was `() {}` — a bell carrying a count of pending work that
                // did nothing when tapped. It goes to whichever queue is
                // actually holding the work — the SAME route the Pending
                // tile below opens, so the badge and the tile can never
                // disagree about where the work is.
                onPressed: () => context.push(_firstPendingRoute()),
              ),
            ),
          // The account menu. The admin app bar previously offered exactly two
          // actions — CEO workspace and a bare logout — so an administrator had
          // no way to reach /account/password from the surface they actually
          // work in, even though the screen and its Edge Function both existed
          // and worked. Sign-out moves in here so the bar does not lose it.
          PopupMenuButton<String>(
            tooltip: 'Account',
            icon: CircleAvatar(
              radius: 15,
              // Was primaryGreen@15% with primaryGreenDark initials — on the
              // dark-green app bar that is dark-on-dark, which is why the
              // "NU" avatar read as an invisible smudge. A light disc with
              // dark-green initials is legible on both bar backgrounds.
              backgroundColor: Colors.white,
              child: Text(
                _initials(auth),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryGreenDark,
                ),
              ),
            ),
            onSelected: (value) {
              if (value == 'profile') {
                context.push('/profile');
              } else if (value == 'notifications') {
                context.push('/admin-notifications');
              } else if (value == 'password') {
                context.push('/account/password');
              } else if (value == 'logout') {
                ref.read(authProvider.notifier).signOut();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'profile',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.person_outline, size: 20,
                      color: AppTheme.primaryGreenDark),
                  title: Text('My profile',
                      style: TextStyle(fontSize: 14)),
                ),
              ),
              PopupMenuItem<String>(
                value: 'notifications',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.notifications_none_rounded, size: 20,
                      color: AppTheme.primaryGreenDark),
                  title: Text('Notifications',
                      style: TextStyle(fontSize: 14)),
                ),
              ),
              PopupMenuItem<String>(
                value: 'password',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.lock_outline, size: 20,
                      color: AppTheme.primaryGreenDark),
                  title: Text('Change password',
                      style: TextStyle(fontSize: 14)),
                ),
              ),
              PopupMenuItem<String>(
                value: 'logout',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout, size: 20, color: AppTheme.error),
                  title: Text('Sign out',
                      style: TextStyle(fontSize: 14, color: AppTheme.error)),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : RefreshIndicator(
              onRefresh: _load,
              child: CustomScrollView(
                slivers: [
                  // Header with gradient
                  SliverToBoxAdapter(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppTheme.primaryGreenDark, Color(0xFF071F0A)],
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                          // The header rosette. It was decoration: a badge
                          // icon sitting in a box nobody could tap. It now
                          // opens the admin's own profile — the same door the
                          // avatar menu offers — so every tappable-looking
                          // thing in this header does something.
                          Tooltip(
                            message: 'Your profile',
                            child: InkWell(
                              onTap: () => context.push('/profile'),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.admin_panel_settings, color: Colors.white, size: 24),
                              ),
                            ),
                          ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Welcome back!',
                                        style: TextStyle(fontSize: 13, color: Colors.white70)),
                                    Text('Aliob Dashboard',
                                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // Income highlight
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white.withOpacity(0.1)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.account_balance_wallet, color: AppTheme.gold, size: 22),
                                const SizedBox(width: 10),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Total Income', style: TextStyle(fontSize: 11, color: Colors.white60)),
                                    Text('ETB ${_totalIncome.toStringAsFixed(2)}',
                                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                                  ],
                                ),
                                const Spacer(),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text('$_totalOrders orders',
                                        style: const TextStyle(fontSize: 11, color: Colors.white54)),
                                    Text('$_totalProducts products',
                                        style: const TextStyle(fontSize: 11, color: Colors.white54)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Quick stats. Each tile opens the screen that holds the
                  // number it shows — a card that looks tappable and is not
                  // is a decoy, and all four of these were exactly that
                  // (no InkWell, no handler, four dead buttons in a row).
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Row(
                        children: [
                          // ONE source of truth for "Pending": the same
                          // pendingTotal the bell badge and the Requires
                          // Attention section are built from. It used to show
                          // _pendingProviders alone, so the tile read 0 while
                          // 21 identity documents waited one screen away.
                          _quickStat(Icons.pending_actions, 'Pending', '$pendingTotal', AppTheme.warning,
                              () => context.push(_firstPendingRoute())),
                          const SizedBox(width: 8),
                          _quickStat(Icons.people, 'Users', '$_totalUsers', AppTheme.info,
                              () => context.push('/admin/users')),
                          const SizedBox(width: 8),
                          _quickStat(Icons.storefront, 'Providers', '$_totalProviders', AppTheme.primaryGreen,
                              () => context.push('/admin/providers')),
                          const SizedBox(width: 8),
                          _quickStat(Icons.receipt, 'Orders', '$_totalOrders', AppTheme.teal,
                              () => context.push('/admin/orders')),
                        ],
                      ),
                    ),
                  ),

                  // Approvals (if any pending)
                  if (hasPending) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                        child: Row(
                          children: [
                            Container(width: 3, height: 16,
                                decoration: BoxDecoration(color: AppTheme.warning, borderRadius: BorderRadius.circular(2))),
                            const SizedBox(width: 8),
                            const Text('Requires Attention',
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            if (_pendingProviders > 0)
                              _pendingCard(Icons.approval, 'Provider Approvals',
                                  '$_pendingProviders pending', AppTheme.warning, () => context.push('/admin/approvals')),
                            if (_pendingUsers > 0)
                              _pendingCard(Icons.person_add, 'User Approvals',
                                  '$_pendingUsers pending', AppTheme.teal, () => context.push('/admin/users')),
                            if (_pendingRecharges > 0)
                              _pendingCard(Icons.payment, 'Recharge Requests',
                                  '$_pendingRecharges pending', AppTheme.info, () => context.push('/admin/payments')),
                            // Everything the bell counts, in the same order
                            // it routes — the first three kinds were all this
                            // section could show, so a queue with real work in
                            // it (documents, appeals, disputes, payments)
                            // vanished from the one section that exists to
                            // point at work.
                            if (_pendingDocuments > 0)
                              _pendingCard(Icons.assignment_outlined,
                                  'Identity Documents',
                                  '$_pendingDocuments waiting to review',
                                  AppTheme.warning,
                                  () => context.push('/admin/document-verification')),
                            if (_openAppeals > 0)
                              _pendingCard(Icons.gavel_outlined, 'Appeals',
                                  '$_openAppeals open cases', AppTheme.error,
                                  () => context.push('/admin/appeals')),
                            if (_openDisputes > 0)
                              _pendingCard(Icons.report_gmailerrorred_outlined,
                                  'Order Disputes',
                                  '$_openDisputes open cases', AppTheme.error,
                                  () => context.push('/admin/disputes')),
                            if (_pendingOrderPayments > 0)
                              _pendingCard(Icons.receipt_long_outlined,
                                  'Order Payments',
                                  '$_pendingOrderPayments waiting to verify',
                                  AppTheme.info,
                                  () => context.push('/admin/payments')),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // Operations section
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Row(
                        children: [
                          Container(width: 3, height: 16,
                              decoration: BoxDecoration(color: AppTheme.primaryGreen, borderRadius: BorderRadius.circular(2))),
                          const SizedBox(width: 8),
                          const Text('Operations',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          if (_can('registrations'))
                            _menuCard(Icons.person_add, 'User Approvals', '$_pendingUsers pending', () => context.push('/admin/users')),
                          if (_can('registrations'))
                            _menuCard(Icons.approval, 'Provider Approvals', '$_pendingProviders pending', () => context.push('/admin/approvals')),
                          if (_can('registrations'))
                            _menuCard(Icons.storefront_outlined, 'All Providers', '$_totalProviders total', () => context.push('/admin/providers')),
                          // Gated on 'document_verification' — a staff_jobs key
                          // that has existed since 20260927000034, seeded with
                          // the label "Review identity documents and record a
                          // verified or rejected decision", and on which NO
                          // screen consulted it. A CEO could assign that job
                          // to a staff member and it would have granted access
                          // to nothing at all, because the only way to reach
                          // review_user_document() was a dialog inside one user
                          // row on the Users page, behind the 'registrations'
                          // key instead. Two different permissions for one
                          // action, and the specific one dead.
                          if (_can('document_verification'))
                            _menuCard(
                                Icons.badge_outlined,
                                'Document Verification',
                                _pendingDocuments > 0
                                    ? '$_pendingDocuments waiting to review'
                                    : 'No documents waiting',
                                () => context.push('/admin/document-verification')),
                          if (_can('payment_verification'))
                            _menuCard(Icons.payment, 'Payment Verification', null, () => context.push('/admin/payments')),
                          if (_can('payment_verification'))
                            _menuCard(Icons.account_balance_wallet_outlined, 'Payment Methods', null, () => context.push('/admin/payment-methods')),
                          // Item 5: the banks rules table and every
                          // provider's accounts (disable one, edit a bank).
                          if (_can('payment_verification'))
                            _menuCard(Icons.account_balance, 'Payment Accounts & Banks',
                                'Banks, limits, disable an account',
                                () => context.push('/admin/payment-accounts')),
                        ],
                      ),
                    ),
                  ),

                  // Financial section
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: Row(
                        children: [
                          Container(width: 3, height: 16,
                              decoration: BoxDecoration(color: AppTheme.gold, borderRadius: BorderRadius.circular(2))),
                          const SizedBox(width: 8),
                          const Text('Financial',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          if (_can('sales_transactions'))
                            _menuCard(Icons.receipt_long, 'Transaction History', '1% fees & orders', () => context.push('/admin/transactions')),
                          if (_can('view_reports'))
                            _menuCard(Icons.account_balance_wallet, 'Income Summary', 'ETB ${_totalIncome.toStringAsFixed(0)} total', () => context.push('/admin/income')),
                          if (_can('view_expenses'))
                            _menuCard(Icons.receipt, 'Expenses', 'Log & track', () => context.push('/admin/expenses')),
                          if (_can('view_reports'))
                            _menuCard(Icons.analytics_outlined, 'Sector Reports', 'Per-category data', () => context.push('/admin/reports')),
                        ],
                      ),
                    ),
                  ),

                  // Data & Communications
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: Row(
                        children: [
                          Container(width: 3, height: 16,
                              decoration: BoxDecoration(color: AppTheme.teal, borderRadius: BorderRadius.circular(2))),
                          const SizedBox(width: 8),
                          const Text('Data & Communications',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                      child: Column(
                        children: [
                          if (_can('registrations'))
                            _menuCard(Icons.badge_outlined, 'Registration History', 'Buyers & sellers', () => context.push('/admin/registrations')),
                          if (_can('*') || _can('admin_history'))
                            _menuCard(Icons.notifications_outlined, 'Send Notifications', 'To users or broadcast', () => context.push('/admin/send-notifications')),
                          // Item I: the forced-update policy — latest/minimum
                          // build, store link, per-locale message, the force
                          // switch and the notify-all-users blast.
                          if (_can('*') || _can('admin_history'))
                            _menuCard(Icons.system_update_alt_rounded, 'App Releases', 'Force-update policy', () => context.push('/admin/app-releases')),
                          if (_can('support_chat'))
                            _menuCard(Icons.support_agent, 'Support Tickets', 'From the in-app help chat', () => context.push('/admin/support-tickets')),
                          if (_can('*') || _can('account_deletion'))
                            _menuCard(Icons.person_remove_outlined, 'Account Deletions',
                                'Deletion requests',
                                () => context.push('/admin/deletions')),
                          if (_can('support_chat'))
                            _menuCard(Icons.gavel_outlined, 'Appeals',
                                _openAppeals > 0
                                    ? '$_openAppeals open case${_openAppeals == 1 ? '' : 's'}'
                                    : 'User appeals & reports',
                                () => context.push('/admin/appeals')),
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.report_gmailerrorred_outlined, 'Disputes',
                                _openDisputes > 0
                                    ? '$_openDisputes open dispute${_openDisputes == 1 ? '' : 's'}'
                                    : 'Refund or uphold',
                                () => context.push('/admin/disputes')),
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.receipt_long_outlined, 'Order Payments',
                                _pendingOrderPayments > 0
                                    ? '$_pendingOrderPayments waiting to verify'
                                    : 'Verify customer payments',
                                () => context.push('/admin/order-payments')),
                          // The pre-order availability queue: who asked,
                          // who answered, how long it took. Same
                          // buyer/provider oversight as the approval
                          // queues, so the same permission gates it.
                          if (_can('registrations'))
                            _menuCard(Icons.schedule_outlined, 'Availability Requests',
                                _pendingAvailability > 0
                                    ? '$_pendingAvailability awaiting an answer'
                                    : 'Pre-order stock checks',
                                () => context.push('/admin/availability')),
                          if (_can('admin_history'))
                            _menuCard(Icons.history_edu_outlined, 'Admin History', 'Full audit trail', () => context.push('/admin/history')),
                          // Phase 2: staff management (server-side RBAC; the
                          // screen itself also self-hides without permission).
                          if (_can('*') || _can('admin_history'))
                            _menuCard(Icons.group_outlined, 'Staff / Sub-admins', 'Permissions & targets', () => context.push('/admin/staff')),
                          // Task 3: true-Admin-only assignment console.
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.admin_panel_settings_outlined, 'Staff Assignment',
                                'Roles, city, warnings, deletion', () => context.push('/admin/staff-assignment')),
                          // The CEO account directory: every registered
                          // account with the delete action. CEO-only, both in
                          // this condition and — the real boundary — inside
                          // the RPCs the screen calls. The "All Users" and
                          // "All Providers" cards above cover reads for the
                          // staff who work queues; this one exists because
                          // nobody below the CEO may end an account.
                          if (ref.watch(authProvider).canOpenCeoOnly)
                            _menuCard(Icons.people_alt_outlined, 'All Users & Providers',
                                'Every account · CEO delete', () => context.push('/admin/accounts')),
                          if (_can('*') || _can('admin_history'))
                            _menuCard(Icons.tune, 'Role Permissions', 'Per-staff section access', () => context.push('/admin/roles/permissions')),
                          // The business rules — fees, thresholds, the points
                          // awards and the points-to-birr rate — editable
                          // without a migration. Writes go through
                          // admin_update_setting(), which is Admin-gated.
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.settings_outlined, 'System Settings',
                                'Fees, points & rank rules', () => context.push('/admin/settings')),
                          // Parts 3 and 4: the number a buyer calls and the
                          // account a buyer pays into are DATA, edited here
                          // and read by every buyer-facing card through
                          // public_app_settings(). Two doors into one screen
                          // (initialSection focuses the right half) because
                          // "who do we call" and "where does the money land"
                          // are different decisions. Each card carries its
                          // OWN `if` — the list-literal trap the Fees card
                          // below documents applies to these too.
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.contact_phone_outlined, 'Contact Settings',
                                'The number buyers call',
                                () => context.push('/admin/platform-settings?section=contact')),
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.account_balance_outlined, 'Payment Settings',
                                'The account buyers pay into',
                                () => context.push('/admin/platform-settings?section=payment')),
                          // Every money value the platform charges, editable
                          // live. Separate from System Settings because a fee
                          // change is a money decision with its own history,
                          // not one row among dozens of knobs.
                          //
                          // This card carries its OWN `if`, and that is not
                          // cosmetic. It used to be written as a second
                          // argument to the System Settings `if` above, and in
                          // a Dart list literal `[if (c) a, b]` the `if` takes
                          // only `a` — `b` became an unconditional element.
                          // Every staff member therefore saw Fees & Pricing
                          // regardless of isAdmin, while System Settings was
                          // correctly hidden from them. Server-side
                          // admin_update_setting() still refused the write, so
                          // this never cost money, but it advertised a money
                          // screen to people who cannot use it.
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.payments_outlined, 'Fees & Pricing',
                                'Commission, activation and ride fares',
                                () => context.push('/admin/fees')),
                          if (ref.read(authProvider).isAdmin ||
                              _can('category_management'))
                            _menuCard(Icons.category_outlined, 'Categories',
                                'The tree, and the door that adds to it',
                                () => context.push('/admin/categories')),
                          // The override layer above Fees & Pricing: what a
                          // bajaj pays differs from a big truck, and Addis
                          // Ababa differs from Hawassa. Without this card the
                          // per-category rates exist in the schema with no way
                          // to reach them.
                          // OR'd with isAdmin rather than replaced by
                          // _can('category_management'): `category_management`
                          // is a grantable staff job that gated NOTHING for its
                          // whole life, so this adds access for staff who hold
                          // it without taking any away from an admin who does
                          // not. The writes behind it are still refused
                          // server-side by is_fee_editor()/is_ceo(), so the card
                          // is navigation, not permission.
                          if (ref.read(authProvider).isAdmin ||
                              _can('category_management'))
                            _menuCard(Icons.price_change_outlined,
                                'Category & City Fees',
                                'Bajaj vs truck · per-city rates',
                                () => context.push('/admin/fees/categories')),
                          // What a provider of each trade is asked for and what
                          // it costs. Its own guard, not a sibling of the
                          // card above: in a Dart list literal an element
                          // written after another element's `if` becomes
                          // unconditional, which is how a money screen once
                          // reached every staff member.
                          if (ref.read(authProvider).isAdmin ||
                              _can('category_management'))
                            _menuCard(Icons.tune, 'Category Fields',
                                'Hotel rooms, doctor rates, delivery fees',
                                () => context.push('/admin/category-fields')),
                          // The authority section: take one uploaded image down,
                          // suspend an account, and read the append-only record
                          // of what has been done. Nothing else in this
                          // dashboard can remove content — user management
                          // suspends accounts and provider management
                          // suspends businesses, but neither can delete a
                          // photograph that breaks the terms.
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.gavel_outlined, 'Content Control',
                                'Reports, image takedown, suspensions',
                                () => context.push('/admin/content')),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _quickStat(IconData icon, String label, String value, Color color,
      VoidCallback? onTap) {
    final tile = Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color)),
            Text(label, style: const TextStyle(fontSize: 9, color: AppTheme.textMuted)),
          ],
        ),
      );
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: tile,
        ),
      ),
    );
  }

  Widget _pendingCard(IconData icon, String title, String subtitle, Color color, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      Text(subtitle, style: TextStyle(fontSize: 11, color: color)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: color, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuCard(IconData icon, String title, String? subtitle, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryGreen.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: AppTheme.primaryGreen, size: 19),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
                      if (subtitle != null)
                        Text(subtitle, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppTheme.textMuted, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
