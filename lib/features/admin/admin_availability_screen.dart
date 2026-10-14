import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/product_card.dart' show listingCoverUrl;

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
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await Supabase.instance.client
          .from('availability_requests')
          .select(
              '*, products(name, product_images(storage_path, sort_order)), '
              'provider_profiles(business_name)')
          .order('created_at', ascending: false)
          .limit(300);
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
    if (_filter == 'All') return _requests;
    final wanted = _filter.toUpperCase();
    return _requests.where((r) => r['status'] == wanted).toList();
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
    return Scaffold(
      appBar: AppBar(title: const Text('Availability Requests')),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.primaryGreen))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: Column(
                    children: [
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
                                  onSelected: (_) =>
                                      setState(() => _filter = f),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: _filtered.isEmpty
                            ? Center(
                                child: Text(
                                  'No $_filter requests',
                                  style: const TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 14),
                                ),
                              )
                            : ListView.builder(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 4, 12, 24),
                                itemCount: _filtered.length,
                                itemBuilder: (_, i) => _tile(_filtered[i]),
                              ),
                      ),
                    ],
                  ),
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
