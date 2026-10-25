import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/points_service.dart';
import '../../core/utils/friendly_error.dart';

/// Tuning for the provider list. Kept as constants so the pagination footer and
/// the test that pins the filter behaviour agree on one number.
const int kProviderPageSize = 12;

/// The status filter values the chips offer. `DELETED` is not a status in the
/// database — it is `deleted_at IS NOT NULL`, which is what the soft delete
/// (20261025000002) stamps. Adding it as a filter value keeps the chip row
/// honest without inventing a status the enum does not have.
const List<String> kProviderStatusFilters = [
  'PENDING_APPROVAL',
  'APPROVED',
  'REJECTED',
  'SUSPENDED',
  'DELETED',
];

/// Does this provider row match a free-text search?
///
/// Searched fields are the ones an administrator actually has in front of them
/// when a complaint arrives: the business name, the owner's name, and the phone
/// number. Case-insensitive substring; an empty query matches everything.
bool providerMatchesQuery(Map<String, dynamic> p, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final profile = p['profiles'] as Map<String, dynamic>?;
  final haystack = [
    p['business_name'],
    profile?['full_name'],
    profile?['phone'],
    p['provider_type'],
  ].whereType<Object>().map((v) => v.toString().toLowerCase()).join(' ');
  return haystack.contains(q);
}

/// One provider row against every filter the header offers.
bool providerMatchesFilters(
  Map<String, dynamic> p, {
  required String status,
  required String type,
  required String query,
}) {
  final deleted = p['deleted_at'] != null;
  if (status == 'DELETED') {
    if (!deleted) return false;
  } else {
    // A deleted business must not reappear under "Approved" just because the
    // status column still says SUSPENDED: it is gone as far as the operator is
    // concerned, and showing it twice under two chips is how a "deleted"
    // provider gets approved again by mistake.
    if (deleted) return false;
    if ((p['status'] as String?) != status) return false;
  }
  if (type != 'ALL' && (p['provider_type'] as String?) != type) return false;
  return providerMatchesQuery(p, query);
}

/// Sort order for the list. Newest first is the default because an
/// administrator is usually chasing a recent registration.
List<Map<String, dynamic>> sortProviders(
  List<Map<String, dynamic>> rows,
  String sort,
) {
  final out = List<Map<String, dynamic>>.from(rows);
  int byName(Map<String, dynamic> a, Map<String, dynamic> b) =>
      (a['business_name'] ?? '').toString().toLowerCase().compareTo(
          (b['business_name'] ?? '').toString().toLowerCase());
  switch (sort) {
    case 'NAME':
      out.sort(byName);
      break;
    case 'OLDEST':
      out.sort((a, b) =>
          (a['created_at'] ?? '').toString().compareTo((b['created_at'] ?? '').toString()));
      break;
    default: // NEWEST
      out.sort((a, b) =>
          (b['created_at'] ?? '').toString().compareTo((a['created_at'] ?? '').toString()));
  }
  return out;
}

class AdminProviderManagementScreen extends StatefulWidget {
  const AdminProviderManagementScreen({super.key});
  @override
  State<AdminProviderManagementScreen> createState() => _State();
}

class _State extends State<AdminProviderManagementScreen> {
  /// EVERY provider, not just one status: the search and the type filter have
  /// to work across the set, and the deleted/not-deleted split needs both.
  /// Loaded once per refresh and filtered in Dart, which is what makes the
  /// counts in the footer match the rows on screen.
  List<Map<String, dynamic>> _providers = [];
  Map<String, int> _productCounts = {};
  bool _loading = true;
  String _filter = 'PENDING_APPROVAL';
  String _type = 'ALL';
  String _sort = 'NEWEST';
  String _query = '';
  int _page = 0;
  String? _error;
  final _searchCtrl = TextEditingController();

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
    try {
      // Providers + their profile embed. user_documents CANNOT be embedded
      // here: user_documents.user_id references auth.users(id) (0001) and
      // profiles(id) (0031), never provider_profiles — PostgREST resolves
      // embeds only through declared FKs, so the old embed failed with
      // PGRST200 and killed the whole query. Documents are fetched
      // separately below and grouped per provider in Dart.
      final data = await Supabase.instance.client
          .from('provider_profiles')
          .select('*, profiles(full_name, phone)')
          .order('created_at', ascending: false)
          .limit(500);
      final providers = List<Map<String, dynamic>>.from(data as List);

      // Second query: documents for all listed providers' auth user ids.
      final userIds = providers
          .map((p) => p['user_id'])
          .whereType<String>()
          .toSet()
          .toList();
      final Map<String, List<Map<String, dynamic>>> docsByUser = {};
      if (userIds.isNotEmpty) {
        final docs = await Supabase.instance.client
            .from('user_documents')
            .select('id, user_id, document_type, other_document_label, '
                'storage_path, uploaded_at')
            .inFilter('user_id', userIds);
        for (final d in (docs as List).whereType<Map<String, dynamic>>()) {
          docsByUser.putIfAbsent(d['user_id'] as String, () => []).add(d);
        }
      }
      for (final p in providers) {
        p['user_documents'] = docsByUser[p['user_id']] ?? const [];
      }

      // Listing counts for the whole page set, in one read. PostgREST cannot
      // GROUP BY, and N per-row counts would be N round trips for a number the
      // delete confirmation needs anyway.
      final counts = <String, int>{};
      try {
        final rows = await Supabase.instance.client
            .from('products')
            .select('provider_id')
            .limit(5000);
        for (final r in (rows as List).whereType<Map<String, dynamic>>()) {
          final pid = r['provider_id'] as String?;
          if (pid != null) counts[pid] = (counts[pid] ?? 0) + 1;
        }
      } catch (_) {
        // Counts are decoration on the row; the list must still render.
      }

      if (mounted) {
        setState(() {
          _providers = providers;
          _productCounts = counts;
          _loading = false;
          _page = 0;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load registrations');
        });
      }
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final rows = _providers
        .where((p) => providerMatchesFilters(p,
            status: _filter, type: _type, query: _query))
        .toList();
    return sortProviders(rows, _sort);
  }

  int get _pageCount {
    final n = _filtered.length;
    return n == 0 ? 1 : ((n - 1) ~/ kProviderPageSize) + 1;
  }

  Future<void> _approve(String providerId) async {
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {'provider_id': providerId, 'action': 'APPROVE'});
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not update this provider'))));
      }
    }
  }

  Future<void> _reject(String providerId) async {
    final reason = await _showReasonDialog('Reject Reason');
    if (reason == null || reason.isEmpty) return;
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {
            'provider_id': providerId,
            'action': 'REJECT',
            'reason': reason,
          });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not update this provider'))));
      }
    }
  }

  Future<void> _requestCorrection(String providerId) async {
    final reason = await _showReasonDialog('Correction Required');
    if (reason == null || reason.isEmpty) return;
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {
            'provider_id': providerId,
            'action': 'REQUEST_CORRECTION',
            'reason': reason,
          });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not update this provider'))));
      }
    }
  }

  /// Suspend a live business.
  ///
  /// The `provider-approval` Edge Function supports SUSPEND (it routes to
  /// `suspend_provider`, which marks the business's vehicles unavailable and
  /// notifies the owner). Suspension is the reversible option and is offered
  /// before deletion for exactly that reason.
  Future<void> _suspend(String providerId) async {
    final reason = await _showReasonDialog('Reason for suspension');
    final trimmed = reason?.trim() ?? '';
    if (trimmed.isEmpty) return;
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {
            'provider_id': providerId,
            'action': 'SUSPEND',
            'reason': trimmed,
          });
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(friendlyError(e,
                context: 'Could not suspend this provider'))));
      }
    }
  }

  /// Put a suspended business back.
  ///
  /// No reason is collected: the suspension already carries its reason in the
  /// permanent record, and reinstating restores the status the business had
  /// before it was taken down.
  Future<void> _unsuspend(String providerId) async {
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {
            'provider_id': providerId,
            'action': 'UNSUSPEND',
          });
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(friendlyError(e,
                context: 'Could not reinstate this provider'))));
      }
    }
  }

  /// Delete a provider business.
  ///
  /// Reads the open-work counts FIRST so the confirmation can state what will
  /// happen instead of discovering it afterwards, and refuses in the dialog
  /// when live orders or rides exist. The RPC re-checks both — the dialog is
  /// the explanation, not the guard.
  ///
  /// The delete itself is a soft delete (20261025000002): listings are hidden,
  /// sessions and device tokens are revoked, `deleted_at` is stamped and the
  /// reason is written to the audit trail. Nothing anybody paid for is
  /// rewritten, which is why it is safe to offer from a list.
  Future<void> _delete(Map<String, dynamic> p) async {
    final id = p['id'] as String;
    final client = Supabase.instance.client;
    setState(() => _loading = true);
    var openOrders = 0;
    var openRides = 0;
    try {
      final orders = await client
          .from('orders')
          .select('id')
          .eq('provider_id', id)
          .inFilter('status', [
            'CREATED',
            'PENDING_PROVIDER',
            'ACCEPTED',
            'PAYMENT_PENDING',
            'PAYMENT_VERIFICATION',
            'APPROVED',
            'STARTED',
            'DISPUTED',
          ])
          .count(CountOption.exact);
      openOrders = orders.count ?? 0;
      final rides = await client
          .from('ride_requests')
          .select('id')
          .eq('claimed_by_provider_id', id)
          .inFilter('status', [
            'REQUESTED',
            'CLAIMED',
            'DRIVER_ARRIVING',
            'DRIVER_EN_ROUTE',
            'ARRIVED',
            'STARTED',
          ])
          .count(CountOption.exact);
      openRides = rides.count ?? 0;
    } catch (_) {
      // Counts unavailable: fall through to the RPC, which refuses on the
      // server if there really is live work.
    }
    if (!mounted) return;
    setState(() => _loading = false);

    final reasonCtrl = TextEditingController();
    final products = _productCounts[id] ?? 0;
    final blocked = openOrders > 0 || openRides > 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
          title: const Text('Delete this provider?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${p['business_name'] ?? 'This business'} will be removed '
                    'from Aliob.'),
                const SizedBox(height: 10),
                Text('• Their dashboard and login stop working.',
                    style: const TextStyle(fontSize: 13)),
                Text('• $products listing${products == 1 ? '' : 's'} disappear '
                    'from search and the app.',
                    style: const TextStyle(fontSize: 13)),
                Text('• Past orders and receipts are kept for your records.',
                    style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 10),
                if (blocked) ...[
                  Text(
                    'This provider still has $openOrders open order(s) and '
                    '$openRides open ride(s). Finish or cancel that work '
                    'first — deleting now would leave a customer waiting on a '
                    'business that no longer answers.',
                    style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.error,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: reasonCtrl,
                  maxLines: 2,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'Reason (optional, kept in the audit log)',
                    hintText: 'e.g. duplicate business, requested removal',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: blocked
                  ? null
                  : () => Navigator.pop(dialogCtx, true),
              style: TextButton.styleFrom(
                  foregroundColor: AppTheme.error,
                  disabledForegroundColor: AppTheme.textMuted),
              child: const Text('DELETE'),
            ),
          ],
        ),
    );

    if (confirmed != true) {
      reasonCtrl.dispose();
      return;
    }

    try {
      final res = await client.rpc('admin_delete_provider', params: {
        'p_provider_id': id,
        'p_reason': reasonCtrl.text.trim().isEmpty
            ? null
            : reasonCtrl.text.trim(),
      });
      reasonCtrl.dispose();
      if (!mounted) return;
      final map = res is Map
          ? Map<String, dynamic>.from(res)
          : <String, dynamic>{};
      final hidden = (map['products_hidden'] as num?)?.toInt() ?? products;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${p['business_name'] ?? 'Provider'} deleted — '
            '$hidden listing${hidden == 1 ? '' : 's'} hidden.'),
      ));
      await _load();
    } catch (e) {
      reasonCtrl.dispose();
      if (!mounted) return;
      final message = friendlyError(e, context: 'Could not delete this provider');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.error,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  Future<String?> _showReasonDialog(String title) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Enter reason...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('Submit')),
        ],
      ),
    );
  }

  /// Everything an operator needs before deciding, in one place: the profile,
  /// the documents, what they sell, and the decisions already made.
  Future<void> _openDetail(Map<String, dynamic> p) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => _ProviderDetailSheet(
        provider: p,
        productCount: _productCounts[p['id']] ?? 0,
        onDelete: () {
          Navigator.pop(context);
          _delete(p);
        },
        onSuspend: () {
          Navigator.pop(context);
          _suspend(p['id'] as String);
        },
        onUnsuspend: () {
          Navigator.pop(context);
          _unsuspend(p['id'] as String);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final start = _page * kProviderPageSize;
    final pageRows = rows.skip(start).take(kProviderPageSize).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Providers')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() {
                _query = v;
                _page = 0;
              }),
              decoration: InputDecoration(
                hintText: 'Search business, owner or phone',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() {
                            _query = '';
                            _page = 0;
                          });
                        },
                      ),
              ),
            ),
          ),
          // Status chips
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final s in kProviderStatusFilters)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _chip(s, _statusLabel(s)),
                  ),
              ],
            ),
          ),
          // Type + sort. Only the two provider types the schema actually has
          // (provider_profiles.provider_type CHECK): shops and bookings are
          // carried by these two, they are not separate types.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    children: [
                      _typeChip('ALL', 'All types'),
                      _typeChip('SERVICE_PROVIDER', 'Service'),
                      _typeChip('VEHICLE_PROVIDER', 'Vehicle'),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Sort',
                  initialValue: _sort,
                  onSelected: (v) => setState(() => _sort = v),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'NEWEST', child: Text('Newest first')),
                    PopupMenuItem(value: 'OLDEST', child: Text('Oldest first')),
                    PopupMenuItem(value: 'NAME', child: Text('Name A–Z')),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.sort, size: 20),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.primaryGreen))
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline,
                                color: AppTheme.error, size: 40),
                            const SizedBox(height: 12),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24),
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 13, color: AppTheme.error),
                              ),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : rows.isEmpty
                        ? Center(
                            child: Text(
                                _query.trim().isEmpty
                                    ? 'No ${_statusLabel(_filter).toLowerCase()} providers'
                                    : 'No provider matches “${_query.trim()}”',
                                style: const TextStyle(
                                    color: AppTheme.textMuted)))
                        : Column(
                            children: [
                              Expanded(
                                child: RefreshIndicator(
                                  onRefresh: _load,
                                  child: ListView.builder(
                                    padding: const EdgeInsets.all(16),
                                    itemCount: pageRows.length,
                                    itemBuilder: (_, i) =>
                                        _card(pageRows[i]),
                                  ),
                                ),
                              ),
                              _pagination(rows.length, start, pageRows.length),
                            ],
                          ),
          ),
        ],
      ),
    );
  }

  static String _statusLabel(String s) {
    switch (s) {
      case 'PENDING_APPROVAL':
        return 'Pending';
      case 'APPROVED':
        return 'Approved';
      case 'REJECTED':
        return 'Rejected';
      case 'SUSPENDED':
        return 'Suspended';
      case 'DELETED':
        return 'Deleted';
      default:
        return s;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'APPROVED':
        return AppTheme.success;
      case 'PENDING_APPROVAL':
        return AppTheme.warning;
      case 'REJECTED':
        return AppTheme.error;
      case 'SUSPENDED':
        return AppTheme.error;
      default:
        return AppTheme.textMuted;
    }
  }

  Widget _card(Map<String, dynamic> p) {
    final profile = p['profiles'] as Map<String, dynamic>?;
    final deleted = p['deleted_at'] != null;
    final status = (p['status'] as String?) ?? 'UNKNOWN';
    final products = _productCounts[p['id']] ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(p['business_name'] ?? '',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (deleted ? AppTheme.textMuted : _statusColor(status))
                        .withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                      deleted ? 'DELETED' : status.replaceAll('_', ' '),
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: deleted
                              ? AppTheme.textMuted
                              : _statusColor(status))),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
                p['provider_type']
                    .toString()
                    .replaceAll('_', ' ')
                    .toLowerCase(),
                style: const TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.primaryGreen,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(profile?['full_name'] ?? '',
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary)),
            Text(profile?['phone'] ?? '',
                style:
                    const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            const SizedBox(height: 6),
            Text(
                '$products listing${products == 1 ? '' : 's'} · joined '
                '${_joined(p['created_at'])}',
                style:
                    const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            const SizedBox(height: 6),
            _ProviderPointsLine(providerId: p['id'] as String),
            const SizedBox(height: 8),
            _ProviderDocumentsRow(
              documents: (p['user_documents'] as List?) ?? const [],
              businessName: p['business_name']?.toString() ?? '',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _openDetail(p),
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  label: const Text('Details',
                      style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                ),
                const Spacer(),
                if (status == 'APPROVED' && !deleted)
                  OutlinedButton.icon(
                    onPressed: () =>
                        context.push('/admin/providers/${p['id']}/wallet'),
                    icon: const Icon(
                        Icons.account_balance_wallet_outlined,
                        size: 16),
                    label: const Text('Wallet',
                        style: TextStyle(fontSize: 13)),
                  ),
              ],
            ),
            if (_filter == 'PENDING_APPROVAL' && !deleted) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _approve(p['id']),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Text('Approve',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _requestCorrection(p['id']),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Text('Correction',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _reject(p['id']),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.error),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Text('Reject',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.error)),
                    ),
                  ),
                ],
              ),
            ],
            if (status == 'APPROVED' && !deleted) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _suspend(p['id'] as String),
                  icon: const Icon(Icons.block_outlined, size: 16),
                  label: const Text('Suspend business',
                      style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error,
                    side: const BorderSide(color: AppTheme.error),
                  ),
                ),
              ),
            ],
            if (status == 'SUSPENDED' && !deleted) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _unsuspend(p['id'] as String),
                  icon: const Icon(Icons.restart_alt_outlined, size: 16),
                  label: const Text('Reinstate business',
                      style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primaryGreen,
                    side: const BorderSide(color: AppTheme.primaryGreen),
                  ),
                ),
              ),
            ],
            // Deletion is last and quiet. Suspension is the reversible option
            // and is presented first; this one is for a business that should
            // not exist at all (fake, duplicate, removed on request).
            if (!deleted) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _delete(p),
                  icon: const Icon(Icons.delete_outline,
                      size: 16, color: AppTheme.textMuted),
                  label: const Text('Delete provider',
                      style: TextStyle(
                          fontSize: 12.5, color: AppTheme.textMuted)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _joined(dynamic raw) {
    final d = DateTime.tryParse('${raw ?? ''}');
    if (d == null) return '—';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Widget _pagination(int total, int start, int shown) {
    if (total <= kProviderPageSize) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text('$total provider${total == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _page == 0 ? null : () => setState(() => _page--),
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
          ),
          Expanded(
            child: Text(
              '${start + 1}–${start + shown} of $total · page ${_page + 1} of $_pageCount',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
          ),
          IconButton(
            onPressed: _page + 1 >= _pageCount
                ? null
                : () => setState(() => _page++),
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next page',
          ),
        ],
      ),
    );
  }

  Widget _chip(String value, String label) {
    final selected = _filter == value;
    final count = _providers
        .where((p) => providerMatchesFilters(p,
            status: value, type: _type, query: _query))
        .length;
    return FilterChip(
      label: Text('$label ($count)'),
      selected: selected,
      onSelected: (_) => setState(() {
        // Everything is already loaded; switching chip is a filter change, not
        // a round trip. Reloading here also reset the page under the operator.
        _filter = value;
        _page = 0;
      }),
      selectedColor: AppTheme.primaryGreen,
      labelStyle: TextStyle(
          color: selected ? Colors.white : AppTheme.textPrimary,
          fontSize: 13),
    );
  }

  Widget _typeChip(String value, String label) {
    final selected = _type == value;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      selectedColor: AppTheme.primaryGreen.withOpacity(0.15),
      onSelected: (_) => setState(() {
        _type = value;
        _page = 0;
      }),
    );
  }
}

/// The full record for one provider, opened from "Details".
///
/// The list row is a summary; a deletion decision needs the documents, the
/// volume they trade and the decisions already recorded against them, so this
/// sheet reads those rather than asking the administrator to open three other
/// screens first.
class _ProviderDetailSheet extends StatefulWidget {
  final Map<String, dynamic> provider;
  final int productCount;
  final VoidCallback onDelete;
  final VoidCallback onSuspend;
  final VoidCallback onUnsuspend;

  const _ProviderDetailSheet({
    required this.provider,
    required this.productCount,
    required this.onDelete,
    required this.onSuspend,
    required this.onUnsuspend,
  });

  @override
  State<_ProviderDetailSheet> createState() => _ProviderDetailSheetState();
}

class _ProviderDetailSheetState extends State<_ProviderDetailSheet> {
  int? _orders;
  int? _openOrders;
  List<Map<String, dynamic>> _history = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.provider['id'] as String;
    final client = Supabase.instance.client;
    var orders = 0;
    var open = 0;
    List<Map<String, dynamic>> history = const [];
    try {
      final all = await client
          .from('orders')
          .select('id')
          .eq('provider_id', id)
          .count(CountOption.exact);
      orders = all.count ?? 0;
      final live = await client
          .from('orders')
          .select('id')
          .eq('provider_id', id)
          .inFilter('status', [
            'CREATED',
            'PENDING_PROVIDER',
            'ACCEPTED',
            'PAYMENT_PENDING',
            'PAYMENT_VERIFICATION',
            'APPROVED',
            'STARTED',
            'DISPUTED',
          ])
          .count(CountOption.exact);
      open = live.count ?? 0;
    } catch (_) {
      // A count that cannot be read is shown as unknown, never as zero.
    }
    try {
      final rows = await client
          .from('approval_history')
          .select('action, reason, created_at')
          .eq('subject_type', 'PROVIDER')
          .eq('subject_id', id)
          .order('created_at', ascending: false)
          .limit(8);
      history = List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {
      history = const [];
    }
    if (mounted) {
      setState(() {
        _orders = orders;
        _openOrders = open;
        _history = history;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final profile = p['profiles'] as Map<String, dynamic>?;
    final deleted = p['deleted_at'] != null;
    final status = (p['status'] as String?) ?? 'UNKNOWN';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.cardBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(p['business_name'] ?? '',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                  '${(p['provider_type'] ?? '').toString().replaceAll('_', ' ').toLowerCase()}'
                  ' · ${deleted ? 'DELETED' : status.replaceAll('_', ' ')}',
                  style: const TextStyle(
                      fontSize: 12.5, color: AppTheme.textSecondary)),
              const SizedBox(height: 14),
              _kv('Owner', profile?['full_name'] ?? '—'),
              _kv('Phone', profile?['phone'] ?? '—'),
              _kv('Joined', (p['created_at'] ?? '—').toString().split('T').first),
              _kv('Listings', '${widget.productCount}'),
              _kv('Orders', _loading ? '…' : '${_orders ?? '—'}'),
              _kv('Open orders', _loading ? '…' : '${_openOrders ?? '—'}'),
              if (p['deleted_at'] != null)
                _kv('Deleted', '${p['deleted_at']}'.split('T').first),
              const SizedBox(height: 12),
              const Text('Documents',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              _ProviderDocumentsRow(
                documents: (p['user_documents'] as List?) ?? const [],
                businessName: p['business_name']?.toString() ?? '',
              ),
              const SizedBox(height: 12),
              const Text('Status history',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else if (_history.isEmpty)
                const Text('No decisions recorded yet',
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textMuted))
              else
                for (final h in _history)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${(h['action'] ?? '').toString().replaceAll('_', ' ')} · '
                      '${(h['created_at'] ?? '').toString().split('T').first}'
                      '${(h['reason'] as String?)?.trim().isNotEmpty == true ? ' — ${h['reason']}' : ''}',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                    ),
                  ),
              const SizedBox(height: 18),
              if (!deleted)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: status == 'APPROVED'
                            ? widget.onSuspend
                            : (status == 'SUSPENDED'
                                ? widget.onUnsuspend
                                : null),
                        icon: const Icon(Icons.block_outlined, size: 16),
                        label: Text(status == 'SUSPENDED'
                            ? 'Reinstate'
                            : 'Suspend'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: widget.onDelete,
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('Delete'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.error,
                          side: const BorderSide(color: AppTheme.error),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 96,
                child: Text(k,
                    style: const TextStyle(
                        fontSize: 12.5, color: AppTheme.textMuted))),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 12.5, color: AppTheme.textPrimary))),
          ],
        ),
      );
}

/// Live points total for one provider row (Feature 3 admin view).
class _ProviderPointsLine extends StatefulWidget {
  final String providerId;
  const _ProviderPointsLine({required this.providerId});
  @override
  State<_ProviderPointsLine> createState() => _ProviderPointsLineState();
}

class _ProviderPointsLineState extends State<_ProviderPointsLine> {
  int? _points;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final map =
          await PointsService.instance.getProviderPointsBulk([widget.providerId]);
      if (mounted) setState(() => _points = map[widget.providerId] ?? 0);
    } catch (_) {
      if (mounted) setState(() => _points = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.stars_rounded,
            size: 15, color: AppTheme.primaryGreen),
        const SizedBox(width: 5),
        Text('Points: ${_points ?? "…"}',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary)),
      ],
    );
  }
}

/// Documents summary row for one provider: shows what was uploaded and
/// opens a viewer with signed-URL previews (admin can always read the
/// user-documents bucket).
class _ProviderDocumentsRow extends StatelessWidget {
  final List<dynamic> documents;
  final String businessName;
  const _ProviderDocumentsRow({
    required this.documents,
    required this.businessName,
  });

  @override
  Widget build(BuildContext context) {
    final docs = documents
        .whereType<Map<String, dynamic>>()
        .where((d) => (d['storage_path'] as String?)?.isNotEmpty == true)
        .toList();
    return Row(
      children: [
        const Icon(Icons.badge_outlined,
            size: 15, color: AppTheme.textSecondary),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            docs.isEmpty
                ? 'No documents uploaded'
                : docs.map((d) => _typeOf(d)).join(', '),
            style: const TextStyle(
                fontSize: 12, color: AppTheme.textSecondary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (docs.isNotEmpty)
          TextButton.icon(
            onPressed: () => showDialog(
              context: context,
              builder: (_) => _ProviderDocumentsDialog(
                docs: docs,
                businessName: businessName,
              ),
            ),
            icon: const Icon(Icons.visibility_outlined, size: 15),
            label: const Text('View', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6)),
          ),
      ],
    );
  }

  /// The display name of one document ROW. An OTHER row shows the label the
  /// uploader typed ("Other — business licence"), not a bare "Other" — the
  /// reviewer is being asked to look at a specific document, and a type that
  /// says nothing about which one makes the review a guess. The fallback
  /// covers rows written before the label column existed.
  static String _typeOf(dynamic row) {
    final d = row is Map<String, dynamic> ? row : <String, dynamic>{};
    final type = d['document_type']?.toString();
    if (type == 'OTHER') {
      final label = (d['other_document_label'] as String?)?.trim();
      return (label == null || label.isEmpty) ? 'Other' : 'Other — $label';
    }
    return _shortType(type);
  }

  static String _shortType(dynamic t) {
    switch (t?.toString()) {
      case 'NATIONAL_ID':
        return 'National ID';
      case 'DRIVING_LICENSE':
        return 'Driving license';
      case 'TRADE_LICENSE':
        return 'Trade license';
      default:
        return (t ?? 'Document').toString();
    }
  }
}

class _ProviderDocumentsDialog extends StatelessWidget {
  final List<Map<String, dynamic>> docs;
  final String businessName;
  const _ProviderDocumentsDialog({required this.docs, required this.businessName});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Documents — $businessName',
          style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final d in docs)
              ListTile(
                dense: true,
                leading: const Icon(Icons.image_outlined),
                title: Text(_ProviderDocumentsRow._typeOf(d),
                    style: const TextStyle(fontSize: 14)),
                onTap: () => showDialog(
                  context: context,
                  builder: (_) => _ProviderDocPreview(
                    storagePath: d['storage_path'] as String,
                    docType: _ProviderDocumentsRow._typeOf(d),
                    businessName: businessName,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}

/// Full-screen-ish preview of one document via a 5-minute signed URL.
class _ProviderDocPreview extends StatefulWidget {
  final String storagePath;
  final String docType;
  final String businessName;
  const _ProviderDocPreview({
    required this.storagePath,
    required this.docType,
    required this.businessName,
  });

  @override
  State<_ProviderDocPreview> createState() => _ProviderDocPreviewState();
}

class _ProviderDocPreviewState extends State<_ProviderDocPreview> {
  String? _signedUrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final url = await Supabase.instance.client.storage
          .from('user-documents')
          .createSignedUrl(widget.storagePath, 300);
      if (mounted) {
        setState(() {
          _signedUrl = url;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _signedUrl = null;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppBar(
              title: Text('${widget.businessName} — ${widget.docType}',
                  style: const TextStyle(fontSize: 16)),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: AppTheme.primaryGreen))
                  : _signedUrl != null
                      ? InteractiveViewer(
                          minScale: 0.5,
                          maxScale: 3.0,
                          child: Image.network(
                            _signedUrl!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Text('Failed to load image'),
                            ),
                          ),
                        )
                      : const Center(
                          child: Text(
                              'Document file is missing from storage.\nAsk the provider to re-upload.',
                              textAlign: TextAlign.center)),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              child: const Text(
                'Signed URL expires in 5 minutes',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
