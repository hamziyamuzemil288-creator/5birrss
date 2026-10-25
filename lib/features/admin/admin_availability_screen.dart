import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/product_card.dart' show listingCoverUrl;

/// Rows per page in the queue. Small on purpose: a request has a 15-minute
/// window, so page 1 is the only page that matters in practice.
const int kAvailabilityPageSize = 20;

/// One request against the search box, the provider filter and the date window.
///
/// Kept as a pure function so the behaviour that decides what an administrator
/// is looking at can be tested without a database or a widget tree.
bool availabilityMatchesFilters(
  Map<String, dynamic> r, {
  required String query,
  required String provider,
  required int days,
}) {
  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) {
    final product = r['products'] as Map<String, dynamic>?;
    final prov = r['provider_profiles'] as Map<String, dynamic>?;
    final hay = [
      product?['name'],
      prov?['business_name'],
      r['reason'],
      r['id'],
    ].whereType<Object>().map((v) => v.toString().toLowerCase()).join(' ');
    if (!hay.contains(q)) return false;
  }
  if (provider != 'ALL') {
    final prov = r['provider_profiles'] as Map<String, dynamic>?;
    if ((prov?['business_name'] as String?) != provider) return false;
  }
  if (days > 0) {
    final created = DateTime.tryParse('${r['created_at'] ?? ''}');
    if (created == null) return false;
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days));
    if (created.toUtc().isBefore(cutoff)) return false;
  }
  return true;
}

/// The availability queue, as an administrator sees it.
///
/// The pre-order gate (migration 20261006000006) puts every "is this
/// available?" exchange in one table with timestamps on both ends. This
/// screen is where a dispute about one is settled: who asked, which
/// provider, what answer, the reason they gave, and how long the answer
/// took — the number that shows a provider who lets requests time out.
///
/// Part 5 of the rework: the administrator ANSWERS too. A provider who goes
/// quiet used to cost the buyer their 15-minute window and the platform the
/// sale, even though the platform knew the answer — so PENDING rows carry
/// Approve/Decline here, next to the same read the queue always had. Which
/// privileged human answered first decides (respond_availability_request
/// re-checks PENDING after a row lock, migration 20261014000004), so the
/// provider's own dashboard buttons and these race safely to one answer.
/// Each request also shows the listing's cover photo, so a row is
/// recognisable at a glance rather than by product name alone.
class AdminAvailabilityScreen extends StatefulWidget {
  const AdminAvailabilityScreen({super.key});

  @override
  State<AdminAvailabilityScreen> createState() =>
      _AdminAvailabilityScreenState();
}

class _AdminAvailabilityScreenState extends State<AdminAvailabilityScreen> {
  static const _filters = [
    'All',
    'Pending',
    'Accepted',
    'Rejected',
    'Expired',
    'Cancelled',
  ];

  List<Map<String, dynamic>> _requests = [];
  Map<String, String> _buyerNames = {};
  String _filter = 'All';
  String _provider = 'ALL';
  int _days = 0;
  String _query = '';
  int _page = 0;
  bool _loading = true;
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

  /// The provider names present in the loaded window, for the filter dropdown.
  /// Derived from the rows rather than a second query: a filter that offers a
  /// name with no rows behind it is a dead end.
  List<String> get _providerNames {
    final names = <String>{};
    for (final r in _requests) {
      final p = r['provider_profiles'] as Map<String, dynamic>?;
      final n = p?['business_name'] as String?;
      if (n != null && n.trim().isNotEmpty) names.add(n);
    }
    final list = names.toList()..sort();
    return list;
  }

  Future<void> _load() async {
    try {
      final data = await Supabase.instance.client
          .from('availability_requests')
          .select(
              '*, products(name, product_images(storage_path, sort_order)), '
              'provider_profiles(business_name)')
          .order('created_at', ascending: false)
          .limit(500);
      final rows = List<Map<String, dynamic>>.from(data as List);

      // The buyer id points at auth.users, not profiles, so PostgREST
      // cannot embed the name in the same read — a second, batched query
      // by id. Best effort: an unnamed buyer still shows its id prefix.
      final buyerIds = rows
          .map((r) => r['buyer_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final names = <String, String>{};
      if (buyerIds.isNotEmpty) {
        try {
          final profiles = await Supabase.instance.client
              .from('profiles')
              .select('id, full_name')
              .inFilter('id', buyerIds);
          for (final p in profiles as List) {
            final name = p['full_name'];
            if (p['id'] is String && name is String && name.isNotEmpty) {
              names[p['id'] as String] = name;
            }
          }
        } catch (_) {
          // Names are decoration; the queue itself must still render.
        }
      }

      if (mounted) {
        setState(() {
          _requests = rows;
          _buyerNames = names;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          // A database that has not run 20261006000006 has no table; the
          // refusal reaches the screen as a sentence, not a red page.
          _error =
              friendlyError(e, context: 'Could not load availability requests');
        });
      }
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final wanted = _filter.toUpperCase();
    return _requests
        .where((r) => _filter == 'All' || r['status'] == wanted)
        .where((r) => availabilityMatchesFilters(r,
            query: _query, provider: _provider, days: _days))
        .toList();
  }

  static Color _statusColor(String status) {
    switch (status) {
      case 'ACCEPTED':
        return AppTheme.success;
      case 'PENDING':
        return AppTheme.warning;
      case 'REJECTED':
        return AppTheme.error;
      case 'EXPIRED':
        return AppTheme.textMuted;
      default:
        return AppTheme.info; // CANCELLED
    }
  }

  /// How long the provider took to answer: created_at → responded_at.
  /// Unanswered rows show the age of the request instead, because "still
  /// waiting" and "answered in 4 minutes" are different facts.
  static String _timing(Map<String, dynamic> r) {
    final created = DateTime.tryParse('${r['created_at']}');
    if (created == null) return '';
    final responded = DateTime.tryParse('${r['responded_at'] ?? ''}');
    final end = responded ?? DateTime.now().toUtc();
    final secs = end.difference(created.toUtc()).inSeconds;
    if (secs < 0) return '';
    final label = '${secs ~/ 60}m ${secs % 60}s';
    return responded == null ? 'waiting $label' : 'answered in $label';
  }

  @override
  Widget build(BuildContext context) {
    // A filter value whose rows have gone (a provider answered everything and
    // was refreshed away) must fall back to "All providers" — DropdownButton
    // asserts when its value is not one of its items.
    final providerValue =
        _provider == 'ALL' || _providerNames.contains(_provider)
            ? _provider
            : 'ALL';

    return Scaffold(
      appBar: AppBar(title: const Text('Availability Requests')),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.primaryGreen))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (v) => setState(() {
                          _query = v;
                          _page = 0;
                        }),
                        decoration: InputDecoration(
                          hintText: 'Search item, provider or reason',
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
                    SizedBox(
                      height: 46,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        children: [
                          for (final f in _filters)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(
                                label: Text(f),
                                selected: _filter == f,
                                selectedColor:
                                    AppTheme.primaryGreen.withOpacity(0.15),
                                onSelected: (_) => setState(() {
                                  _filter = f;
                                  _page = 0;
                                }),
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Provider + date window. Both are narrowed on the rows
                    // already in hand, so a filter change is instant and never
                    // hides a request behind an unapplied database predicate.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: providerValue,
                                isExpanded: true,
                                isDense: true,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    color: AppTheme.textPrimary),
                                items: [
                                  const DropdownMenuItem(
                                      value: 'ALL',
                                      child: Text('All providers')),
                                  for (final n in _providerNames)
                                    DropdownMenuItem(
                                        value: n,
                                        child: Text(n,
                                            overflow: TextOverflow.ellipsis)),
                                ],
                                onChanged: (v) => setState(() {
                                  _provider = v ?? 'ALL';
                                  _page = 0;
                                }),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: _days,
                              isDense: true,
                              style: const TextStyle(
                                  fontSize: 12.5,
                                  color: AppTheme.textPrimary),
                              items: const [
                                DropdownMenuItem(
                                    value: 0, child: Text('All dates')),
                                DropdownMenuItem(
                                    value: 1, child: Text('Today')),
                                DropdownMenuItem(
                                    value: 7, child: Text('7 days')),
                                DropdownMenuItem(
                                    value: 30, child: Text('30 days')),
                              ],
                              onChanged: (v) => setState(() {
                                _days = v ?? 0;
                                _page = 0;
                              }),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _filtered.isEmpty
                          ? Center(
                              child: Text(
                                _query.trim().isEmpty
                                    ? 'No $_filter requests'
                                    : 'No request matches “${_query.trim()}”',
                                style: const TextStyle(
                                    color: AppTheme.textMuted,
                                    fontSize: 14),
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView.builder(
                                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                                itemCount: _pageRows.length,
                                itemBuilder: (_, i) => _tile(_pageRows[i]),
                              ),
                            ),
                    ),
                    _pagination(),
                  ],
                ),
    );
  }

  List<Map<String, dynamic>> get _pageRows => _filtered
      .skip(_page * kAvailabilityPageSize)
      .take(kAvailabilityPageSize)
      .toList();

  Widget _pagination() {
    final total = _filtered.length;
    if (total <= kAvailabilityPageSize) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text('$total request${total == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
      );
    }
    final pages = ((total - 1) ~/ kAvailabilityPageSize) + 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Row(
        children: [
          IconButton(
            onPressed: _page == 0 ? null : () => setState(() => _page--),
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
          ),
          Expanded(
            child: Text(
              '${_page * kAvailabilityPageSize + 1}–'
              '${_page * kAvailabilityPageSize + _pageRows.length} of $total · '
              'page ${_page + 1} of $pages',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
          ),
          IconButton(
            onPressed: _page + 1 >= pages ? null : () => setState(() => _page++),
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next page',
          ),
        ],
      ),
    );
  }

  Widget _tile(Map<String, dynamic> r) {
    final status = (r['status'] as String?) ?? 'UNKNOWN';
    final product = r['products'] as Map<String, dynamic>?;
    final provider = r['provider_profiles'] as Map<String, dynamic>?;
    final buyerId = r['buyer_id'] as String?;
    final buyer = buyerId == null
        ? null
        : (_buyerNames[buyerId] ??
            '${buyerId.substring(0, buyerId.length.clamp(0, 8))}…');
    final qty = ((r['quantity'] as num?)?.toDouble() ?? 1);
    final qtyText =
        qty == qty.roundToDouble() ? qty.toInt().toString() : qty.toString();
    final reason = (r['reason'] as String?)?.trim();
    // Part 5: the listing's own cover photo, same lowest-sort_order rule as
    // every shared card (listingCoverUrl in core/widgets/product_card.dart).
    final coverUrl =
        listingCoverUrl((product?['product_images'] as List?) ?? const []);
    final cover = coverUrl == null
        ? null
        : ResizeImage(NetworkImage(coverUrl), width: 46, height: 46);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: cover == null
                    ? Container(
                        width: 46,
                        height: 46,
                        color: AppTheme.creamDark,
                        child: const Icon(Icons.image_outlined,
                            size: 20, color: AppTheme.textMuted),
                      )
                    : Image(
                        image: cover,
                        fit: BoxFit.cover,
                        width: 46,
                        height: 46),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  (product?['name'] as String?) ?? 'An item',
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor(status).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _statusColor(status)),
                ),
              ),
              IconButton(
                onPressed: () => _openDetail(r),
                icon: const Icon(Icons.info_outline, size: 18),
                tooltip: 'Details',
                visualDensity: VisualDensity.compact,
                color: AppTheme.textMuted,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (buyer != null) 'Buyer: $buyer',
              if (provider?['business_name'] is String)
                'Provider: ${provider!['business_name']}',
              'Quantity: $qtyText',
              _timing(r),
            ].join(' · '),
            style:
                const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          if (reason != null && reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Reason: $reason',
              style: const TextStyle(
                  fontSize: 12.5,
                  fontStyle: FontStyle.italic,
                  color: AppTheme.textPrimary),
            ),
          ],
          // Part 5: only PENDING rows can be answered, and only here does
          // the admin get the buttons — an answered row shows the answer.
          if (status == 'PENDING') ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _respond(r, true),
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text('APPROVE'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primaryGreen,
                      side: const BorderSide(color: AppTheme.primaryGreen),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _decline(r),
                    icon: const Icon(Icons.cancel_outlined, size: 16),
                    label: const Text('DECLINE'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.error,
                      side: const BorderSide(color: AppTheme.error),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Everything about one request, including the timestamps the row cannot fit.
  /// Approve/decline live here too, for the same reason the row has them: the
  /// window is 15 minutes and an administrator should not have to hunt for the
  /// control after opening the detail.
  Future<void> _openDetail(Map<String, dynamic> r) async {
    final status = (r['status'] as String?) ?? 'UNKNOWN';
    final product = r['products'] as Map<String, dynamic>?;
    final provider = r['provider_profiles'] as Map<String, dynamic>?;
    final buyerId = r['buyer_id'] as String?;
    final buyer = buyerId == null
        ? '—'
        : (_buyerNames[buyerId] ?? '$buyerId');
    final qty = (r['quantity'] as num?)?.toDouble() ?? 1;
    String stamp(dynamic v) {
      final d = DateTime.tryParse('${v ?? ''}');
      if (d == null) return '—';
      final local = d.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${local.year}-${two(local.month)}-${two(local.day)} '
          '${two(local.hour)}:${two(local.minute)}';
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text((product?['name'] as String?) ?? 'An item',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(status,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _statusColor(status))),
              const SizedBox(height: 14),
              _kv('Buyer', buyer),
              _kv('Provider',
                  (provider?['business_name'] as String?) ?? '—'),
              _kv('Quantity',
                  qty == qty.roundToDouble() ? '${qty.toInt()}' : '$qty'),
              _kv('Requested', stamp(r['created_at'])),
              _kv('Expires', stamp(r['expires_at'])),
              _kv('Answered', stamp(r['responded_at'])),
              _kv('Time to answer', _timing(r)),
              if ((r['reason'] as String?)?.trim().isNotEmpty == true)
                _kv('Reason', (r['reason'] as String).trim()),
              const SizedBox(height: 16),
              if (status == 'PENDING')
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetCtx);
                          _respond(r, true);
                        },
                        icon: const Icon(Icons.check_circle_outline,
                            size: 16),
                        label: const Text('APPROVE'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryGreen,
                          side:
                              const BorderSide(color: AppTheme.primaryGreen),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetCtx);
                          _decline(r);
                        },
                        icon: const Icon(Icons.cancel_outlined, size: 16),
                        label: const Text('DECLINE'),
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

  static Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 110,
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

  /// Part 5: the administrator's own answer, through the same RPC the
  /// provider's dashboard buttons use — so both paths land in one row, one
  /// notification, one outcome.
  Future<void> _respond(Map<String, dynamic> r, bool accept,
      {String? reason}) async {
    try {
      await Supabase.instance.client.rpc('respond_availability_request',
          params: {
            'p_request_id': r['id'],
            'p_accept': accept,
            if (reason != null && reason.isNotEmpty) 'p_reason': reason,
          });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(accept
              ? 'Approved — the buyer can continue to checkout.'
              : 'Declined — the buyer has been told.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // The usual loser's error is REQUEST_ALREADY_ANSWERED (the provider
      // beat the admin to the row) or REQUEST_EXPIRED — both mean "the
      // database has moved on", so the reload below matters as much as the
      // sentence.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                friendlyError(e, context: 'Could not save your answer'))),
      );
    } finally {
      if (mounted) await _load();
    }
  }

  /// Decline asks for the same optional reason the provider is asked for,
  /// because the buyer reads one sentence either way.
  Future<void> _decline(Map<String, dynamic> r) async {
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Decline this request?'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
            hintText: 'e.g. Sold out until Friday',
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
    await _respond(r, false, reason: reason);
  }
}
