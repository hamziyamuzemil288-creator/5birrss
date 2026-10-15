import 'package:flutter/material.dart';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:storage_client/storage_client.dart' show FileOptions;
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/review_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/order_chat_service.dart';
import '../../core/utils/order_number_format.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/admin_payment_details_card.dart';
import '../../core/widgets/platform_contact_card.dart';
import '../../core/widgets/rank_badge.dart';

/// Statuses from which CANCELLED is a legal transition for the BUYER
/// (see transition_order_status whitelist in 0003_functions.sql).
///
/// PAYMENT_PENDING is deliberately absent. The whitelist allows CANCELLED
/// from there only to an admin, so offering the buyer the button produced an
/// error on every tap. The buyer's real exit from PAYMENT_PENDING is to
/// submit payment (see _submitPayment).
const _cancellableStatuses = {
  'CREATED',
  'PENDING_PROVIDER',
  'ACCEPTED',
  'APPROVED',
  'STARTED',
};

/// Shared status → color mapping for order UIs.
Color orderStatusColor(String status) {
  switch (status) {
    case 'COMPLETED':
    case 'REFUNDED':
      return AppTheme.success;
    case 'CANCELLED':
    case 'REJECTED':
      return AppTheme.error;
    case 'DISPUTED':
      return AppTheme.gold;
    case 'CREATED':
    case 'PENDING_PROVIDER':
    case 'PAYMENT_PENDING':
    case 'PAYMENT_VERIFICATION':
      return AppTheme.gold;
    default: // ACCEPTED, APPROVED, STARTED
      return AppTheme.teal;
  }
}

/// Shared order detail view. `viewerRole` is 'user' (default) or 'provider' —
/// it controls which action buttons are offered. All status changes go
/// through the existing order-transition Edge Function.
class UserOrderDetailScreen extends ConsumerStatefulWidget {
  final String orderId;
  final String viewerRole;
  const UserOrderDetailScreen({
    super.key,
    required this.orderId,
    this.viewerRole = 'user',
  });
  @override
  ConsumerState<UserOrderDetailScreen> createState() =>
      _UserOrderDetailScreenState();
}

class _UserOrderDetailScreenState
    extends ConsumerState<UserOrderDetailScreen> {
  Map<String, dynamic>? _order;
  List<Map<String, dynamic>> _timeline = [];
  Map<String, String> _actorNames = {};
  String? _proofUrl;
  bool _reviewed = false;
  bool _loading = true;
  bool _acting = false;
  String? _error;

  // Escrow-gated live location (buyer share / provider directions).
  geo.Position? _myPos;
  bool _locSharing = false;
  bool _directionsLaunching = false;

  // In-order chat (buyer ↔ provider).
  final _chatCtrl = TextEditingController();
  bool _sendingChat = false;

  // Buyer payment-proof submission (PAYMENT_PENDING -> PAYMENT_VERIFICATION).
  bool _paying = false;

  // Escrow-gated provider contact (release_order_contact, APPROVED onwards).
  Map<String, String>? _providerContact;

  // Where to pay, read once the provider has confirmed availability.
  List<Map<String, dynamic>>? _paymentMethods;

  @override
  void dispose() {
    _chatCtrl.dispose();
    super.dispose();
  }

  bool get _isProvider => widget.viewerRole == 'provider';

  @override
  void initState() {
    super.initState();
    _load();
    if (_isProvider) _primeProviderGps();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final order = await client
          .from('orders')
          .select(
              '*, provider_profiles(business_name), order_items(product_id, quantity, unit_price, subtotal, products(name, price, currency))')
          .eq('id', widget.orderId)
          .single();
      final timeline = await client
          .from('order_status_history')
          .select('*')
          .eq('order_id', widget.orderId)
          .order('created_at', ascending: true);

      // Resolve actor names (best-effort; timeline still shows without them).
      final names = <String, String>{};
      try {
        final actorIds = (timeline as List)
            .map((t) => t['changed_by'] as String?)
            .whereType<String>()
            .toSet()
            .toList();
        if (actorIds.isNotEmpty) {
          final profiles = await client
              .from('profiles')
              .select('id, full_name')
              .inFilter('id', actorIds);
          for (final p in profiles as List) {
            names[p['id'] as String] = p['full_name'] as String? ?? '';
          }
        }
      } catch (_) {}

      String? proofUrl;
      final proof = await client
          .from('payment_proofs')
          .select('storage_path')
          .eq('order_id', widget.orderId)
          .maybeSingle();
      if (proof != null && proof['storage_path'] != null) {
        proofUrl = await client.storage
            .from('payment-proofs')
            .createSignedUrl(proof['storage_path'] as String, 3600);
      }

      // Whether the current user already reviewed this order (best-effort).
      var reviewed = false;
      try {
        reviewed = await ReviewService.instance
            .hasUserReviewedOrder(widget.orderId);
      } catch (_) {}

      // Escrow-gated provider contact, and the payment details the buyer may
      // now be shown. Both are read after `_order` is known, because both are
      // decided by the order's status.
      final contact = await _loadProviderContact(order);
      final methods = await _loadPaymentMethods(order);

      if (mounted) {
        setState(() {
          _order = order;
          _timeline = List<Map<String, dynamic>>.from(timeline as List);
          _actorNames = names;
          _proofUrl = proofUrl;
          _reviewed = reviewed;
          _providerContact = contact;
          _paymentMethods = methods;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load order';
        });
      }
    }
  }

  bool get _canCancel {
    final status = _order?['status'] as String?;
    return status != null && _cancellableStatuses.contains(status);
  }

  /// The provider's contact details, once the escrow releases them.
  ///
  /// This does not read `profiles.phone`. It calls
  /// `release_order_contact(order_id)`, which since migration
  /// 20260922000001 raises CONTACT_AVAILABLE_AFTER_APPROVAL for anything
  /// before APPROVED and records the release in admin_history. Until the order
  /// detail screen called it, the release the Terms screen promises never
  /// happened — this is what makes it happen, and it puts the rule in the
  /// database rather than in a `WHERE` clause here.
  ///
  /// Returns null (and says nothing) on any failure: the caller's own id not
  /// being the order owner is the normal case for the provider-side view of
  /// somebody else's order, not an error worth surfacing.
  Future<Map<String, String>?> _loadProviderContact(Map<String, dynamic> order) async {
    final status = order['status'] as String?;
    if (status != 'APPROVED' && status != 'STARTED' && status != 'COMPLETED') {
      return null;
    }
    try {
      final rows = await Supabase.instance.client
          .rpc('release_order_contact', params: {'p_order_id': widget.orderId});
      final list = (rows as List?) ?? const [];
      if (list.isEmpty) return null;
      final row = Map<String, dynamic>.from(list.first as Map);
      final phone = row['provider_phone'] as String?;
      final name = row['provider_name'] as String?;
      if (phone == null || phone.trim().isEmpty) return null;
      return {'phone': phone, 'name': (name != null && name.isNotEmpty) ? name : 'Provider'};
    } catch (_) {
      return null;
    }
  }

  /// The accounts a buyer may pay into.
  ///
  /// Read only once the provider has confirmed the order is available
  /// (ACCEPTED or later). Below that the buyer has nothing to pay for yet,
  /// and this list is the payment information the gate is withholding.
  ///
  /// Returns null for "not unlocked yet" and null for "the read failed" —
  /// deliberately not distinguished, because the caller's response is the
  /// same either way: the payment card is still rendered (gated on
  /// [ _awaitingMyPayment] as well) so a failed read can never take away the
  /// buyer's only way to pay.
  Future<List<Map<String, dynamic>>?> _loadPaymentMethods(
      Map<String, dynamic> order) async {
    if (_isProvider) return null;
    final status = order['status'] as String?;
    if (status == null || !_afterProviderAccepted.contains(status)) return null;
    try {
      final rows = await Supabase.instance.client
          .from('payment_methods')
          .select('name, account_name, account_number, instructions')
          .eq('is_active', true)
          .order('sort_order');
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {
      return null;
    }
  }

  /// In-order chat: text coordination any time, location sharing gated by
  /// the same escrow reveal window as the GPS card above (enforced both
  /// client-side for messaging and server-side in migration 0036).
  Widget _chatCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.forum_outlined,
                    size: 18, color: AppTheme.teal),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Order Chat',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                ),
                if (!_deliveryRevealed)
                  const Text('Location sharing after payment verified',
                      style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
              ],
            ),
          ),
          SizedBox(
            height: 300,
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: OrderChatService.instance.streamMessages(widget.orderId),
              builder: (context, snap) {
                // A realtime subscribe failure is not a data error. Show it
                // inline and keep whatever was already loaded rather than
                // pretending the conversation is empty.
                if (snap.hasError && !snap.hasData) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Chat is reconnecting… messages will reappear shortly.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                      ),
                    ),
                  );
                }
                final msgs = (snap.data ?? const [])
                    .map(OrderChatMessage.fromRow)
                    .toList();
                if (msgs.isEmpty) {
                  return const Center(
                    child: Text(
                        'No messages yet — say hello or ask about this order.',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textMuted)),
                  );
                }
                final myId =
                    Supabase.instance.client.auth.currentUser?.id;
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _chatBubble(msgs[i], mine: msgs[i].senderId == myId),
                );
              },
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Share live location',
                    onPressed: _sendingChat ? null : _shareChatLocation,
                    icon: const Icon(Icons.share_location_outlined,
                        color: AppTheme.teal),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _chatCtrl,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendChatText(),
                      decoration: const InputDecoration(
                        hintText: 'Message…',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: _sendingChat ? null : _sendChatText,
                    icon: _sendingChat
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chatBubble(OrderChatMessage m, {required bool mine}) {
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    final who = mine ? 'You' : (_isProvider ? 'Buyer' : 'Provider');
    final time =
        '${m.createdAt.hour}:${m.createdAt.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: align,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7),
          decoration: BoxDecoration(
            color: m.isLocation
                ? AppTheme.teal.withOpacity(0.08)
                : (mine
                    ? AppTheme.primaryGreen.withOpacity(0.08)
                    : AppTheme.creamDark),
            borderRadius: BorderRadius.circular(12),
            border: m.isLocation
                ? Border.all(color: AppTheme.teal.withOpacity(0.4))
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$who · $time',
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.textMuted)),
              const SizedBox(height: 4),
              if (m.isLocation)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.location_on_outlined,
                            size: 16, color: AppTheme.teal),
                        SizedBox(width: 4),
                        Text('Live location shared',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary)),
                      ],
                    ),
                    if (m.locationLabel != null &&
                        m.locationLabel!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(m.locationLabel!,
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary)),
                      ),
                    TextButton.icon(
                      onPressed: (m.lat == null || m.lng == null)
                          ? null
                          : () => LocationService.instance.openDirectionsTo(
                                destLat: m.lat!,
                                destLng: m.lng!,
                                label: m.locationLabel ?? 'Shared location',
                              ),
                      icon: const Icon(Icons.navigation_outlined, size: 16),
                      label: const Text('Get directions',
                          style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                          foregroundColor: AppTheme.teal,
                          padding: const EdgeInsets.symmetric(horizontal: 4)),
                    ),
                  ],
                )
              else
                SelectableText(m.body ?? '',
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendChatText() async {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty || _sendingChat) return;
    setState(() => _sendingChat = true);
    try {
      await OrderChatService.instance
          .sendText(orderId: widget.orderId, body: text);
      _chatCtrl.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not send your message'))));
      }
    } finally {
      if (mounted) setState(() => _sendingChat = false);
    }
  }

  /// One-shot live GPS share into the chat. Server-side gate (0036)
  /// enforces the escrow reveal window; mirror the error here.
  Future<void> _shareChatLocation() async {
    setState(() => _sendingChat = true);
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!r.success) {
      if (mounted) {
        setState(() => _sendingChat = false);
        final openSettings = r.status == LocationStatus.deniedForever ||
            r.status == LocationStatus.serviceDisabled;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(openSettings
              ? 'Enable location services to share your location'
              : 'Location permission is needed to share your location'),
          action: openSettings
              ? SnackBarAction(
                  label: 'Open settings',
                  onPressed: () =>
                      LocationService.instance.openLocationSettings())
              : null,
        ));
      }
      return;
    }
    try {
      await OrderChatService.instance.sendLocation(
        orderId: widget.orderId,
        lat: r.position!.latitude,
        lng: r.position!.longitude,
      );
    } on LocationNotRevealedException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Location sharing unlocks once the payment is verified.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not share your location'))));
      }
    } finally {
      if (mounted) setState(() => _sendingChat = false);
    }
  }

  /// Escrow reveal window: payment verified (APPROVED) or delivery in
  /// progress (STARTED) — the same statuses the DB gate (0032) enforces.
  bool get _deliveryRevealed {
    final status = _order?['status'] as String?;
    return status == 'APPROVED' || status == 'STARTED';
  }

  // ----------------------------------------------------------------
  // Availability confirmation
  //
  // The order carries a snapshot of products.requires_availability_confirmation
  // taken by create_order_secure when the order was created. It is read off
  // the order row, never re-joined from order_items, so a provider changing
  // the flag on a listing next week cannot close the payment screen on an
  // order a buyer has already paid for.
  // ----------------------------------------------------------------

  bool get _needsAvailabilityConfirmation =>
      (_order?['requires_availability_confirmation'] as bool?) ?? false;

  /// Statuses at or past the provider accepting, which is the moment the
  /// listing is confirmed available for this order. ACCEPTED is the
  /// confirmation itself; everything after it inherits it.
  static const _afterProviderAccepted = {
    'ACCEPTED',
    'PAYMENT_PENDING',
    'PAYMENT_VERIFICATION',
    'APPROVED',
    'STARTED',
    'COMPLETED',
    'DISPUTED',
    'REFUNDED',
  };

  /// The buyer is waiting on the provider. Only reachable for a gated order:
  /// for everything else the order is simply awaiting a response, which the
  /// timeline already says.
  bool get _awaitingAvailabilityConfirmation =>
      !_isProvider &&
      _needsAvailabilityConfirmation &&
      (_order?['status'] as String?) == 'PENDING_PROVIDER';

  /// Buyer side: grab a fresh live GPS fix and share it for this order.
  Future<void> _shareMyLocation() async {
    setState(() => _locSharing = true);
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!r.success) {
      if (mounted) {
        setState(() => _locSharing = false);
        final openSettings = r.status == LocationStatus.deniedForever ||
            r.status == LocationStatus.serviceDisabled;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(openSettings
              ? 'Enable location services to share your delivery point'
              : 'Location permission is needed to share your delivery point'),
          action: openSettings
              ? SnackBarAction(
                  label: 'Open settings',
                  onPressed: () =>
                      LocationService.instance.openLocationSettings())
              : null,
        ));
      }
      return;
    }
    try {
      await Supabase.instance.client.rpc('set_order_delivery_location', params: {
        'p_order_id': widget.orderId,
        'p_lat': r.position!.latitude,
        'p_lng': r.position!.longitude,
      });
      if (mounted) {
        setState(() {
          _myPos = r.position;
          _locSharing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Live location shared with the provider')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _locSharing = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not share your location'))));
      }
    }
  }

  /// Provider side: fetch the buyer-shared GPS point (only exists after the
  /// buyer shared it post-approval) and launch directions to it.
  Future<void> _openBuyerDirections() async {
    setState(() => _directionsLaunching = true);
    try {
      final data = await Supabase.instance.client
          .rpc('get_order_delivery_location', params: {'p_order_id': widget.orderId});
      final rows = (data as List?) ?? const [];
      if (!mounted) return;
      if (rows.isEmpty || rows.first['lat'] == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Buyer has not shared their live location yet — ask them to tap "Share live location" on the order')));
        return;
      }
      final lat = (rows.first['lat'] as num).toDouble();
      final lng = (rows.first['lng'] as num).toDouble();
      final pos = _myPos;
      await LocationService.instance.openDirectionsTo(
        destLat: lat,
        destLng: lng,
        label: 'Delivery location',
        originLat: pos?.latitude,
        originLng: pos?.longitude,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not get your location'))));
      }
    } finally {
      if (mounted) setState(() => _directionsLaunching = false);
    }
  }

  /// Provider side: directions to their own business location pickup.
  Future<void> _openBusinessDirections() async {
    final providerId = _order?['provider_id'] as String?;
    if (providerId == null) return;
    setState(() => _directionsLaunching = true);
    try {
      final data = await Supabase.instance.client.rpc(
          'get_provider_public_location',
          params: {'p_provider_id': providerId});
      final rows = (data as List?) ?? const [];
      if (!mounted) return;
      if (rows.isEmpty || rows.first['lat'] == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'No business location set — add it in the business profile')));
        return;
      }
      final lat = (rows.first['lat'] as num).toDouble();
      final lng = (rows.first['lng'] as num).toDouble();
      final label = (rows.first['address_text'] as String?) ?? 'Business location';
      final pos = _myPos;
      await LocationService.instance.openDirectionsTo(
        destLat: lat,
        destLng: lng,
        label: label,
        originLat: pos?.latitude,
        originLng: pos?.longitude,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not get your location'))));
      }
    } finally {
      if (mounted) setState(() => _directionsLaunching = false);
    }
  }

  /// Provider side: prime own live GPS so routes start from the real position.
  Future<void> _primeProviderGps() async {
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (mounted && r.success) setState(() => _myPos = r.position);
  }

  /// Provider status actions allowed by the transition whitelist.
  List<({String status, String label, IconData icon})>
      get _providerActions {
    final status = _order?['status'] as String?;
    switch (status) {
      case 'PENDING_PROVIDER':
        // Same two transitions as always — PENDING_PROVIDER -> ACCEPTED and
        // PENDING_PROVIDER -> REJECTED, which is the existing state machine's
        // answer. Only the wording changes on a gated order, so that what the
        // provider is actually deciding ("do you have it for this date?")
        // matches what the buyer was told they were waiting for. Un-gated
        // orders keep the original labels.
        return [
          (
            status: 'ACCEPTED',
            label: _needsAvailabilityConfirmation
                ? 'Confirm Availability'
                : 'Accept Order',
            icon: Icons.check_circle_outline,
          ),
          (
            status: 'REJECTED',
            label: _needsAvailabilityConfirmation ? 'Not Available' : 'Reject',
            icon: Icons.cancel_outlined,
          ),
        ];
      case 'ACCEPTED':
        // On a gated order the buyer can now open the payment step themselves
        // the moment availability is confirmed (migration 85), so this button
        // is a shortcut rather than the only route. It is kept because a
        // provider who wants to push a buyer to pay now still can, and because
        // removing it would change the un-gated flow this branch also serves.
        return [
          (
            status: 'PAYMENT_PENDING',
            label: _needsAvailabilityConfirmation
                ? 'Request Payment (optional)'
                : 'Request Payment',
            icon: Icons.payment,
          ),
        ];
      case 'APPROVED':
        return [
          (
            status: 'STARTED',
            label: 'Mark In Progress',
            icon: Icons.play_circle_outline,
          ),
        ];
      case 'STARTED':
        return [
          (
            status: 'COMPLETED',
            label: 'Mark Completed',
            icon: Icons.flag_outlined,
          ),
        ];
      default:
        return [];
    }
  }

  Future<void> _cancelOrder() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Cancel order?'),
        content: const Text(
            'This will cancel the order. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => dctx.pop(false),
              child: const Text('KEEP ORDER')),
          TextButton(
              onPressed: () => dctx.pop(true),
              child: const Text('CANCEL ORDER')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _transition('CANCELLED', note: 'Cancelled by customer');
  }

  Future<void> _transition(String newStatus, {String? note}) async {    setState(() => _acting = true);
    try {
      await Supabase.instance.client.functions.invoke('order-transition',
          body: {
            'order_id': widget.orderId,
            'new_status': newStatus,
            if (note != null) 'note': note,
          });
      if (!mounted) return;
      setState(() => _acting = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Order ${_label(newStatus)}')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _acting = false);
      // This used to show the exception verbatim after stripping only the
      // FunctionException prefix, so a PostgREST error surfaced here in full.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              friendlyError(e, context: 'Could not complete that action'))));
    }
  }

  String _label(String status) => status.replaceAll('_', ' ');

  /// True when the buyer is the one who owes money for this order.
  ///
  /// PAYMENT_PENDING is the state a payment screenshot is submitted from,
  /// and the only legal exit from it is PAYMENT_VERIFICATION — which the
  /// transition whitelist allows for the buyer alone.
  ///
  /// On a GATED order the buyer may also open that step themselves the
  /// moment the provider confirms availability. Migration 74 built the gate
  /// and this screen already read it correctly — the buyer saw "waiting for
  /// the provider", the provider got a "Confirm Availability" button, and
  /// the payment details appeared at ACCEPTED — but the LAST link was
  /// missing: ACCEPTED -> PAYMENT_PENDING was provider-or-admin only, so the
  /// order sat at ACCEPTED with payment details on screen and no button
  /// anywhere until the provider happened to open their own orders list and
  /// press "Request Payment". That is the reported "the screenshot page does
  /// not appear after the availability confirmation".
  ///
  /// Migration 85 widened that one transition for the buyer on a gated
  /// order and nothing else, so the chain now closes without a second
  /// provider round trip. An un-gated order is unaffected: the provider
  /// still requests payment exactly as before.
  bool get _awaitingMyPayment {
    if (_isProvider) return false;
    final status = _order?['status'] as String?;
    if (status == 'PAYMENT_PENDING') return true;
    return status == 'ACCEPTED' && _needsAvailabilityConfirmation;
  }

  /// The order is ACCEPTED but the payment step has not been opened yet, so
  /// [ _submitPayment] has to open it before a proof can be attached.
  ///
  /// False once the order is PAYMENT_PENDING, which is what makes a retry
  /// after a failed upload safe: the second attempt skips the hop instead of
  /// asking the server for a transition it has already made.
  bool get _needsPaymentStepOpened =>
      (_order?['status'] as String?) == 'ACCEPTED' &&
      _needsAvailabilityConfirmation;

  /// Buyer attaches a payment screenshot and hands the order to an admin
  /// for verification.
  ///
  /// Two things happen, in this order, and both are load-bearing.
  ///
  /// 1. On a gated order the provider has confirmed availability but the
  ///    payment step is not open yet, so it is opened here. The server
  ///    permits this for the buyer who placed a gated order and for nobody
  ///    else (migration 85), and it is skipped entirely when the order is
  ///    already PAYMENT_PENDING — so a retry after a failed upload does not
  ///    ask for a transition that has already happened.
  ///
  /// 2. The proof row is written and the order is transitioned to
  ///    PAYMENT_VERIFICATION. Proof FIRST, transition SECOND, because the
  ///    reverse leaves a proof attached to an order that is still
  ///    PAYMENT_PENDING if the transition is refused.
  ///
  /// The insert is additionally guarded by a read for an existing
  /// unverified proof. That was not needed when submit was a single
  /// transition, but it is two now, so a failure between them leaves a
  /// pending proof — and without the guard the buyer's next tap would
  /// insert a SECOND proof for the same order, which the admin verification
  /// screen would then show as two competing claims to review.
  Future<void> _submitPayment() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      _toast('You need to be signed in to pay for this order.');
      return;
    }

    if (_needsPaymentStepOpened) {
      setState(() => _paying = true);
      try {
        await client.functions.invoke('order-transition', body: {
          'order_id': widget.orderId,
          'new_status': 'PAYMENT_PENDING',
          'note': 'Buyer opened payment after availability was confirmed',
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _paying = false);
        _toast(friendlyError(
            e, context: 'Could not open payment for this order'));
        return;
      }
      if (!mounted) return;
      // The order just moved and _order is now stale. Reload before anything
      // else so a cancelled picker cannot leave the screen describing a state
      // the database has already left behind.
      await _load();
      if (!mounted) return;
    }

    // Downscaled, like every other bucket upload in this app (the provider
    // recharge screen had the same latent refusal and was fixed first).
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Submit payment proof?'),
        content: const Text(
            'Attach a screenshot of your transfer. An admin will verify it '
            'before the order starts.'),
        actions: [
          TextButton(
              onPressed: () => dctx.pop(false),
              child: const Text('CANCEL')),
          TextButton(
              onPressed: () => dctx.pop(true),
              child: const Text('SUBMIT')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _paying = true);
    try {
      // Reuse the pending proof from a previous attempt rather than adding a
      // second one. `maybeSingle` on an order that has none returns null and
      // on an order that has exactly one returns that row; anything else (two
      // rows, which would mean a pre-existing duplicate) throws and lands in
      // the catch, which is the safe direction — we would rather refuse than
      // add a third.
      Map<String, dynamic>? existing;
      try {
        existing = await client
            .from('payment_proofs')
            .select('id, storage_path')
            .eq('order_id', widget.orderId)
            .maybeSingle();
      } catch (_) {
        existing = null;
      }

      if (existing == null) {
        final path =
            '${user.id}/${widget.orderId}/${DateTime.now().millisecondsSinceEpoch}.jpg';
        await client.storage.from('payment-proofs').upload(path, File(picked.path),
            fileOptions: const FileOptions(upsert: true));
        await client.from('payment_proofs').insert({
          'order_id': widget.orderId,
          'storage_path': path,
        });
      }

      if (!mounted) return;
      await _transition('PAYMENT_VERIFICATION', note: 'Payment proof submitted');
    } catch (e) {
      if (!mounted) return;
      _toast(friendlyError(e, context: 'Could not submit your payment proof'));
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// First product id in the order, used to target a product review.
  String? get _firstProductId {
    final items = (_order?['order_items'] as List?) ?? const [];
    if (items.isEmpty) return null;
    return (items.first as Map<String, dynamic>)['product_id'] as String?;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order Details')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: AppTheme.textMuted),
                      const SizedBox(height: 12),
                      Text(_error!,
                          style:
                              const TextStyle(color: AppTheme.textMuted)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _headerCard(),
                        const SizedBox(height: 16),
                        if (_awaitingAvailabilityConfirmation) ...[
                          _waitingCard(),
                          const SizedBox(height: 16),
                        ],
                        // The payment step is ONE card: the accounts to pay
                        // into, and the button that attaches the receipt. They
                        // used to be separated — details near the top of a
                        // long scroll, the upload button below the items, the
                        // chat and the timeline — so the buyer was told where
                        // to pay and then had to hunt for the thing that pays
                        // it. It is also what makes the gate legible: if this
                        // card is on screen, the provider has confirmed.
                        //
                        // `_awaitingMyPayment` is in the condition as well as
                        // `_paymentMethods`, because `_loadPaymentMethods`
                        // returns null when the read fails, and a failed read
                        // must not remove the buyer's only way to pay.
                        if (_awaitingMyPayment || _paymentMethods != null) ...[
                          _paymentStepCard(),
                          const SizedBox(height: 16),
                        ],
                        if (_providerContact != null) ...[
                          _contactCard(),
                          const SizedBox(height: 16),
                        ],
                        if (_deliveryRevealed) ...[
                          _locationCard(),
                          const SizedBox(height: 16),
                        ],
                        // Part 3: the buyer's only "call a human" door
                        // points at the PLATFORM (Admin → Contact Settings),
                        // never at the provider — and never at a number
                        // hard-coded into this screen.
                        if (!_isProvider) ...[
                          const PlatformContactCard(),
                          const SizedBox(height: 12),
                          // The other half of "something happened": a case, not
                          // a phone number. It files into `appeal_cases`, which
                          // is what the admin dashboard's Appeals badge counts
                          // and /admin/appeals lists, and it arrives pre-tagged
                          // as a dispute about this order so a reviewer has the
                          // context without asking for it. The same door stands
                          // on the payment screen, where the money problem
                          // actually happens.
                          _appealCard(),
                          const SizedBox(height: 16),
                        ],
                        _itemsCard(),
                        const SizedBox(height: 16),
                        if (_proofUrl != null) _proofCard(),
                        if (_proofUrl != null) const SizedBox(height: 16),
                        _chatCard(),
                        const SizedBox(height: 16),
                        _timelineCard(),
                        const SizedBox(height: 20),
                        if (_isProvider && _providerActions.isNotEmpty)
                          ..._providerActions.map((a) => Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 8),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: a.status == 'REJECTED'
                                      ? OutlinedButton.icon(
                                          onPressed: _acting
                                              ? null
                                              : () => _transition(a.status),
                                          icon: Icon(a.icon,
                                              size: 18,
                                              color: AppTheme.error),
                                          label: Text(a.label),
                                          style: OutlinedButton.styleFrom(
                                              foregroundColor:
                                                  AppTheme.error),
                                        )
                                      : PrimaryButton(
                                          label: a.label,
                                          icon: a.icon,
                                          isLoading: _acting,
                                          onPressed: () => _transition(
                                            a.status,
                                            // The buyer sees this timeline,
                                            // and "Confirm Availability" is
                                            // the answer they are waiting
                                            // for — so it is written down
                                            // rather than left as a bare
                                            // status change.
                                            note: a.status == 'ACCEPTED' &&
                                                    _needsAvailabilityConfirmation
                                                ? 'Availability confirmed'
                                                : null,
                                          ),
                                        ),
                                ),
                              )),
                        if (!_isProvider &&
                            _canCancel &&
                            !_awaitingMyPayment)
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _acting ? null : _cancelOrder,
                              icon: const Icon(Icons.cancel_outlined,
                                  size: 18, color: AppTheme.error),
                              label: const Text('CANCEL ORDER'),
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: AppTheme.error),
                            ),
                          ),
                        if (!_isProvider &&
                            (_order?['status'] as String?) == 'COMPLETED')
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: SizedBox(
                              width: double.infinity,
                              child: PrimaryButton(
                                label: _reviewed
                                    ? 'EDIT YOUR REVIEW'
                                    : 'LEAVE A REVIEW',
                                icon: Icons.rate_review_outlined,
                                isOutlined: true,
                                onPressed: () async {
                                  await context.push('/review/new', extra: {
                                    'orderId': widget.orderId,
                                    'productId': _firstProductId,
                                    'providerId': _order?['provider_id'],
                                  });
                                  if (mounted) _load();
                                },
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
    );
  }

  /// Escrow-gated live location card. Visible only once payment is verified
  /// (APPROVED) or delivery started — matching the DB-side gate exactly.
  /// "Waiting for provider to confirm availability".
  ///
  /// The counterpart of the checkout notice: the buyer placed a request and
  /// the payment section is deliberately not here yet. It sits directly under
  /// the header so the state is the first thing read, rather than a
  /// conspicuous gap where the payment button used to be.
  Widget _waitingCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.gold.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.gold.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.hourglass_top_rounded, size: 18, color: AppTheme.gold),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Waiting for provider to confirm availability',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'We have sent your request. Nothing is due yet — payment details '
            'and your upload option appear here once the provider confirms '
            'this booking is available.',
            style: TextStyle(fontSize: 12.5, height: 1.45),
          ),
        ],
      ),
    );
  }

  /// The payment step: where to pay, and the button that attaches the receipt.
  ///
  /// Part 4 of the rework: the details are [AdminPaymentDetailsCard] — the
  /// PLATFORM's account, read from the administrator's configuration
  /// (`admin_payment_details`, with the admin-managed Payment Methods rows
  /// as the fallback), never a provider's saved account. The provider's own
  /// money channel for receiving earnings (their wallet) is untouched; what
  /// changed is whose account the BUYER sends money to.
  ///
  /// Rendered only once the provider has confirmed availability — on a gated
  /// order that is exactly the moment [ _awaitingMyPayment] becomes true, so
  /// "confirmation happened" and "this card appeared" cannot drift apart.
  ///
  /// The provider's business name stays on the card: the buyer is still
  /// paying for THAT business's service, and naming it is the difference
  /// between "pay this order" and "pay some unnamed account".
  Widget _paymentStepCard() {
    final providerName = ((_order?['provider_profiles']
        as Map<String, dynamic>?)?['business_name'] as String?)?.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
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
              const Icon(Icons.account_balance_wallet_outlined,
                  size: 18, color: AppTheme.primaryGreen),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Where to pay',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              if (_proofUrl == null)
                const Text('AWAITING RECEIPT',
                    style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textMuted)),
            ],
          ),
          if (providerName != null && providerName.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('Paying $providerName',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary)),
          ],
          const SizedBox(height: 8),
          // Part 4: whose account receives the money — the platform's,
          // configured in Admin → Payment Settings. One card, one source,
          // identical to what checkout shows.
          const AdminPaymentDetailsCard(),
          if (_awaitingMyPayment) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'PAY & UPLOAD PROOF',
                icon: Icons.upload_file_outlined,
                isLoading: _paying,
                onPressed: _paying ? null : _submitPayment,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Tap the button, choose the screenshot of your transfer from '
              'your gallery, and submit it. Nothing is charged by the app — '
              'you pay into the account above yourself.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, height: 1.4, color: AppTheme.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  /// The provider's number, released by release_order_contact() only after
  /// the payment proof has been verified.
  Widget _contactCard() {
    final contact = _providerContact ?? const <String, String>{};
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_open_rounded,
                  size: 18, color: AppTheme.primaryGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  contact['name'] ?? 'Provider',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              const Text(
                'PAID',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            contact['phone'] ?? '',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppTheme.primaryGreen,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Your payment has been verified, so you can now contact the '
            'provider directly. Keep arrangements in the app where you can.',
            style: TextStyle(fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _locationCard() {
    final status = (_order?['status'] as String?) ?? '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.teal.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.teal.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.share_location_outlined,
                  size: 18, color: AppTheme.teal),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Live Location',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
              ),
              Text(status == 'STARTED' ? 'Delivery in progress' : 'Payment verified',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _isProvider
                ? 'Navigate to the buyer\'s shared live GPS position, or to your business pickup point.'
                : 'Share your live GPS position so the provider can navigate to you. Your location is never visible before payment is confirmed.',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          if (_isProvider) ...[
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'DIRECTIONS TO BUYER LOCATION',
                icon: Icons.navigation_outlined,
                isLoading: _directionsLaunching,
                onPressed: _openBuyerDirections,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'DIRECTIONS TO MY BUSINESS',
                icon: Icons.store_outlined,
                isOutlined: true,
                onPressed: _openBusinessDirections,
              ),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'SHARE LIVE LOCATION',
                icon: Icons.my_location,
                isLoading: _locSharing,
                onPressed: _shareMyLocation,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'DIRECTIONS TO PROVIDER',
                icon: Icons.store_outlined,
                isOutlined: true,
                onPressed: _openBusinessDirections,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Files an appeal: the fast path from "this transaction went wrong" to the
  /// admin queue that acts on it, without an email address or a form to find.
  /// The case lands in `appeal_cases` pre-tagged as a dispute, which is what
  /// the admin dashboard's Appeals badge counts and /admin/appeals lists.
  ///
  /// The order goes with it. The reviewer reads the case's description, so the
  /// reference the buyer already knows (`Order Vh00001`) is what makes the case
  /// actionable on sight instead of a follow-up question.
  Widget _appealCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.error.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.error.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.gavel_outlined, size: 20, color: AppTheme.error),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Something wrong with this order?',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () {
              final label = orderLabel(_order ?? const {});
              final encoded = Uri.encodeComponent(label);
              context.push('/appeal?about=dispute&order=$encoded');
            },
            child: const Text('REPORT IT',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _headerCard() {
    final o = _order!;
    final status = (o['status'] as String?) ?? 'UNKNOWN';
    final provider =
        (o['provider_profiles'] as Map<String, dynamic>?) ?? const {};
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
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
              Expanded(
                child: Text('Order ${orderLabel(o)}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: orderStatusColor(status).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_label(status),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: orderStatusColor(status))),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Created ${_fmtDate(DateTime.parse(o['created_at'] as String))}',
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
          if (provider['business_name'] != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Flexible(
                  child: Text(provider['business_name'] as String,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.teal)),
                ),
                const SizedBox(width: 6),
                // The counterparty's rank, at the point of a real transaction.
                RankBadge(providerId: o['provider_id'] as String?),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _itemsCard() {
    final o = _order!;
    final items = (o['order_items'] as List?) ?? const [];
    final total = (o['total_amount'] as num).toDouble();
    final currency = o['currency'] as String? ?? 'ETB';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Items',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_itemName(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w500)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                      '${item['quantity']} × '
                      '${(item['unit_price'] as num).toDouble().toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary)),
                  const SizedBox(width: 12),
                  Text(
                      _lineTotal(item),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
              Text('${total.toStringAsFixed(2)} $currency',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryGreen)),
            ],
          ),
        ],
      ),
    );
  }

  String _itemName(Map<String, dynamic> item) {
    final product = item['products'] as Map<String, dynamic>?;
    if (product == null) return 'Product unavailable';
    return product['name'] as String? ?? 'Product unavailable';
  }

  String _lineTotal(Map<String, dynamic> item) {
    final lineTotal = (item['subtotal'] as num?)?.toDouble() ??
        (item['quantity'] as num).toDouble() *
            (item['unit_price'] as num).toDouble();
    return lineTotal.toStringAsFixed(2);
  }

  Widget _proofCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Payment Proof',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: _proofUrl!,
              height: 140,
              width: double.infinity,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(
                height: 140,
                color: AppTheme.creamDark,
                child: const Center(
                    child: Icon(Icons.image_outlined,
                        size: 40, color: AppTheme.textMuted)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timelineCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Timeline',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_timeline.isEmpty)
            const Text('No status history yet',
                style: TextStyle(fontSize: 13, color: AppTheme.textMuted))
          else
            ..._timeline.map((t) => _timelineEntry(t)),
        ],
      ),
    );
  }

  Widget _timelineEntry(Map<String, dynamic> t) {
    final from = t['from_status'] as String?;
    final to = t['to_status'] as String? ?? 'UNKNOWN';
    final actor = t['changed_by'] as String?;
    final actorName = actor != null
        ? (_actorNames[actor] ?? '#${actor.substring(0, 8)}')
        : null;
    final note = t['note'] as String?;
    final when = t['created_at'] != null
        ? _fmtDate(DateTime.parse(t['created_at'] as String))
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: orderStatusColor(to),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  from == null
                      ? 'Order created'
                      : '${_label(from)} → ${_label(to)}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(when,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
                if (actorName != null)
                  Text('by $actorName',
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
                if (note != null && note.isNotEmpty)
                  Text(note,
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                          fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        ],
      ),
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