import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:storage_client/storage_client.dart' show FileOptions;
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/admin_payment_details_card.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/cart_service.dart';
import '../../core/services/fee_resolver.dart';
import '../../core/services/document_upload_service.dart';
import '../../core/services/location_prompt.dart';
import '../../core/services/location_service.dart';
import '../../core/widgets/where_to_picker.dart';
import '../../core/utils/order_number_format.dart' as onf;
import '../../core/utils/friendly_error.dart';
import '../../core/utils/friendly_failure.dart';

class UserCheckoutScreen extends ConsumerStatefulWidget {
  final String providerId;
  const UserCheckoutScreen({super.key, required this.providerId});
  @override
  ConsumerState<UserCheckoutScreen> createState() => _UserCheckoutScreenState();
}

class _UserCheckoutScreenState extends ConsumerState<UserCheckoutScreen> {
  List<CartItem> _items = [];
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  DateTime? _lastOrderTime;
  final _addressCtrl = TextEditingController();
  final _refCtrl = TextEditingController();

  // Phase 4: shared selection flow — Delivery or Self-pickup. Self-pickup
  // pays the product price only (no delivery), delivery shows the address
  // step. Both paths share the same payment step below.
  //
  // A BOOKING starts on the other option (see [_isBookingCart]): a service or
  // a room is not delivered, and the delivery path demands a delivery address
  // — server-side, `order-create` answers "Delivery requires an address" — so
  // booking a haircut used to stop at a form asking where to ship it.
  String _fulfillmentMode = 'DELIVERY';

  /// True once the buyer has picked a fulfillment option themselves. The
  /// booking default is applied only while this is false, so a buyer who chose
  /// delivery for a booking keeps it when the cart re-reads.
  bool _fulfillmentTouched = false;

  /// True when every line in this cart is booked rather than bought — the same
  /// two listing types the shared BUY/BOOK rule names (`listingActionLabel` in
  /// core/widgets/product_card.dart; `CartItem.isBooking` is that rule on the
  /// cart's own line). An empty cart is not a booking.
  bool get _isBookingCart =>
      _items.isNotEmpty && _items.every((i) => i.isBooking);

  // ── Part 10: the delivery option ──
  //
  // Choosing Delivery now asks three things in order — which vehicle, where it
  // goes, and (implicitly) whether location is on — and prices the trip with
  // the SAME fare function the transport section charges a ride with. Nothing
  // here computes a fee: [_deliveryQuote] is what the server answered, and the
  // order is priced by the server from the same reader.
  //
  // The vehicle types are the categories the ride form offers
  // (`sector = 'VEHICLE'`), so "Car", "Bajaj", … mean the same thing in both
  // flows and an admin editing one rate changes both.
  List<Map<String, dynamic>> _vehicleCategories = const [];
  String? _deliveryVehicleId;
  String? _deliveryVehicleName;
  double? _deliveryLat;
  double? _deliveryLng;
  String? _deliveryPlaceLabel;
  DeliveryQuote? _deliveryQuote;
  bool _deliveryQuoting = false;
  bool _deliveryFlowRunning = false;

  /// The delivery fee actually added to the total: zero unless the server
  /// priced this delivery. A failed or unpriceable quote contributes NOTHING
  /// rather than an invented number.
  double get _deliveryFee =>
      _fulfillmentMode == 'DELIVERY' && (_deliveryQuote?.hasValue ?? false)
          ? _deliveryQuote!.fee!
          : 0.0;

  /// What the buyer pays: the product display prices plus the delivery fee
  /// when there is one. Switching to Self-pickup drops the fee out of the
  /// total immediately, because [_deliveryFee] reads [_fulfillmentMode].
  double get _payableTotal => _total + _deliveryFee;
  File? _screenshot;
  File? _nationalId;
  final _picker = ImagePicker();

  /// Whether this buyer still needs to provide a National ID. Users sign up
  /// with only email/phone/password, so the ID is verified at booking time —
  /// attached alongside the payment proof on their first order. Once a
  /// NATIONAL_ID document exists in user_documents, no upload is needed.
  bool _needsNationalId = true;

  /// True when at least one item in this cart is a listing whose provider
  /// must confirm it is available before the buyer is shown payment details
  /// or the screenshot upload.
  ///
  /// Snapshotted onto the order by `create_order_secure` at the moment the
  /// order is created, so the gate cannot move under a buyer after they have
  /// paid. Read here from the products themselves, best-effort: a database
  /// that has not run migration 20260927000074 has no such column, the read
  /// raises, and the flag stays false — the order is then placed exactly as
  /// it was before this feature existed.
  bool _needsAvailabilityConfirmation = false;

  /// Provider readiness (Fix: orders are blocked when the provider's wallet is
  /// 0 — they cannot cover the transaction fee — or when the provider has not
  /// yet paid the one-time registration fee).
  bool _providerActivated = true;
  bool _providerHasBalance = true;
  String _providerName = 'The provider';

  // Item H: the platform commission this order will incur, resolved by the
  // SAME reader deduct_transaction_fee charges with
  // (platform_transaction_fee_for). Display-only and rendered OUTSIDE the
  // totals card, deliberately: the buyer pays the product price and nothing
  // else, and the row says so. It exists so the number on screen is the
  // number the provider is charged, from one resolver — not a second copy of
  // the commission arithmetic.
  FeeQuote? _commissionPreview;

  // Part 4: whose account the buyer pays. The provider's saved accounts are
  // no longer read here AT ALL — the card below is AdminPaymentDetailsCard,
  // which shows the PLATFORM's configured account (Admin → Payment Settings)
  // with the platform's Payment Methods rows as fallback. Nothing about the
  // provider's payout side changes: providers still receive their earnings
  // through their own wallet, untouched by this rework.

  // The provider's category and city used to be read here as well, for a
  // buyer-visible platform-fee quote. That row is gone (the fee is charged
  // to the provider, never the buyer), and the commission is resolved
  // per-category and per-city SERVER-side by deduct_transaction_fee — so the
  // buyer's checkout needs none of it, only who they are paying.

  /// Re-fetches the provider's activation/wallet state. Called on load and
  /// again after returning from the waiting screen, so a provider who has just
  /// recharged does not bounce the buyer straight back to waiting.
  Future<void> _refreshProviderReadiness() async {
    try {
      final prov = await Supabase.instance.client
          .from('public_provider_profiles')
          .select('business_name, registration_fee_paid, status')
          .eq('id', widget.providerId)
          .maybeSingle();
      if (prov != null) {
        _providerName = (prov['business_name'] as String?)?.isNotEmpty == true
            ? prov['business_name'] as String
            : _providerName;
        _providerActivated = (prov['registration_fee_paid'] as bool?) == true &&
            prov['status'] == 'APPROVED';
        final wallet = await Supabase.instance.client
            .from('wallets')
            .select('balance')
            .eq('provider_id', widget.providerId)
            .maybeSingle();
        _providerHasBalance =
            ((wallet?['balance'] as num?)?.toDouble() ?? 0) > 0;
      }
    } catch (_) {
      // Non-fatal: if it fails, the server-side gate in create_order_secure
      // still blocks and the error is surfaced after submission.
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addressCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final all = await CartService.instance.getCart();
      final items =
          all.where((i) => i.providerId == widget.providerId).toList();
      // Read the provider BEFORE quoting: the quote resolves the provider's
      // category and city through provider_fee_context(), and quoting first
      // would resolve them as null, fall back to the global rate, and silently
      // reintroduce exactly the drift this quote exists to remove. Ordering,
      // not correctness, is the whole fix here.
      await _refreshProviderReadiness();
      // Item H: the platform commission this order will incur, through the SAME
      // reader deduct_transaction_fee charges with — platform_transaction_fee_for
      // resolved against the provider's own category and city, with
      // is_product = true (an order, not a ride). Best-effort: a failure hides
      // the row; it never blocks checkout.
      try {
        final orderTotal = items.fold<double>(0, (s, i) => s + i.lineTotal);
        if (orderTotal > 0) {
          final ctx =
              await FeeResolver.instance.providerContext(widget.providerId);
          final quote = await FeeResolver.instance.commissionAmount(
            amount: orderTotal,
            categoryId: ctx.categoryId,
            city: ctx.city,
            isProduct: true,
          );
          if (mounted) setState(() => _commissionPreview = quote);
        }
      } catch (_) {}
      // The provider's payment accounts, shown on the card above the payment
      // reference. Best-effort like every read on this screen: a failure
      // leaves the card in its loading state instead of inventing an answer.
      //
      // The platform commission is deliberately NOT quoted here any more.
      // It is charged to the provider (deduct_transaction_fee, per category
      // and city), never to the buyer, so showing it on the buyer's checkout
      // was a number the buyer never pays — the fee still lives in the
      // provider wallet screen and the admin income views, where it is real.
      // Skip the ID upload for buyers who already verified one at signup
      // (older accounts / re-installed app). Best-effort: on failure the
      // checkout keeps asking for the ID, which is always safe.
      try {
        final uid = Supabase.instance.client.auth.currentUser?.id;
        if (uid != null) {
          final existing = await Supabase.instance.client
              .from('user_documents')
              .select('id')
              .eq('user_id', uid)
              .eq('document_type', 'NATIONAL_ID')
              .limit(1)
              .maybeSingle();
          if (existing != null) _needsNationalId = false;
        }
      } catch (_) {}

      // Does anything in this cart need the provider to confirm it is
      // available? One gated item gates the order: the buyer pays for the
      // whole basket in one transfer, so there is no way to split the
      // payment screen either. Same best-effort rule as the fee quote
      // above — a failure here means "not gated", which is the behaviour
      // that was already working.
      var needsConfirmation = false;
      try {
        final ids = items.map((i) => i.productId).toList();
        if (ids.isNotEmpty) {
          final rows = await Supabase.instance.client
              .from('products')
              .select('id, requires_availability_confirmation')
              .inFilter('id', ids);
          needsConfirmation = (rows as List)
              .any((r) => r['requires_availability_confirmation'] == true);
        }
      } catch (_) {
        needsConfirmation = false;
      }

      // THE AVAILABILITY-GATE BACKSTOP. Deep links, a restored navigation
      // stack, or any future caller that forgets the gate can still land
      // here — so this screen checks the basket itself: unless every
      // product carries an ACCEPTED, unexpired, UNUSED availability request,
      // it replaces itself with /user/availability (replace, not push, so
      // Back cannot bounce straight back into payment).
      //
      // Best-effort by design: the RULE lives in create_order_secure
      // (migration 20261006000006), which raises
      // AVAILABILITY_CONFIRMATION_REQUIRED per product at submission. A
      // failed read here must not block an order the server would accept —
      // the server-side refusal is the guarantee; this is UX.
      if (items.isNotEmpty) {
        try {
          final uid = Supabase.instance.client.auth.currentUser?.id;
          final ids = items.map((i) => i.productId).toSet().toList();
          final cleared = <String>{};
          if (uid != null) {
            final rows = await Supabase.instance.client
                .from('availability_requests')
                .select('product_id, status, expires_at, used_at')
                .eq('buyer_id', uid)
                .inFilter('product_id', ids);
            final now = DateTime.now().toUtc();
            for (final r in rows as List) {
              if (r['status'] != 'ACCEPTED' || r['used_at'] != null) continue;
              final exp = DateTime.tryParse('${r['expires_at']}');
              if (exp == null || !exp.isAfter(now)) continue;
              cleared.add(r['product_id'] as String);
            }
          }
          if (mounted && !cleared.containsAll(ids)) {
            context.pushReplacement('/user/availability',
                extra: {'providerId': widget.providerId});
            return;
          }
        } catch (_) {
          // Table absent (migration not deployed) or read failed: the gate
          // degrades to the server-side check at submission.
        }
      }

      if (mounted) {
        setState(() {
          _items = items;
          _needsAvailabilityConfirmation = needsConfirmation;
          // A basket of bookings does not need a delivery address, and asking
          // for one is where a booking stopped looking like a booking. The
          // buyer can still switch to delivery — that is the option a service
          // performed at their address needs — and switching sets
          // [_fulfillmentTouched] so this never overrides them.
          if (!_fulfillmentTouched &&
              items.isNotEmpty &&
              items.every((i) => i.isBooking)) {
            _fulfillmentMode = 'SELF_PICKUP';
          }
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load your cart';
        });
      }
    }
  }

  double get _total => _items.fold(0.0, (sum, i) => sum + i.lineTotal);

  /// The vehicle types the transport section offers, from the same source:
  /// active `VEHICLE` categories, in the admin's order.
  Future<void> _loadVehicleCategories() async {
    if (_vehicleCategories.isNotEmpty) return;
    try {
      final cats = await Supabase.instance.client
          .from('categories')
          .select('id,name,slug')
          .eq('sector', 'VEHICLE')
          .eq('is_active', true)
          .order('sort_order');
      if (mounted) {
        setState(() =>
            _vehicleCategories = List<Map<String, dynamic>>.from(cats as List));
      }
    } catch (_) {
      // No categories: the buyer can still order for delivery; the fee is just
      // not quotable yet, and the server refuses to invent one either.
    }
  }

  /// Step 1 of the delivery option: which vehicle. Re-picking re-quotes
  /// immediately, without leaving checkout.
  Future<void> _chooseVehicleType() async {
    await _loadVehicleCategories();
    if (!mounted) return;
    if (_vehicleCategories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No delivery vehicle types are configured yet'),
        ),
      );
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text('How should it be delivered?',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            for (final c in _vehicleCategories)
              ListTile(
                leading: const Icon(Icons.local_shipping_outlined,
                    color: AppTheme.primaryGreen),
                title: Text('${c['name']}'),
                trailing: (_deliveryVehicleId == c['id'])
                    ? const Icon(Icons.check, color: AppTheme.primaryGreen)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(c),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _deliveryVehicleId = picked['id'] as String?;
      _deliveryVehicleName = picked['name'] as String?;
      _deliveryQuote = null;
    });
    // A different vehicle is a different rate: re-quote with the same point.
    await _requoteDelivery();
  }

  /// Step 2: location on, then step 3: the map. Both already exist in the app
  /// — LocationPrompt owns the one wording for every location state, and
  /// WhereToPicker IS the map page (search, nearby kebeles, tap to drop a pin),
  /// so no second map or second permission flow is introduced here.
  Future<void> _chooseDeliveryPoint() async {
    await LocationPrompt.offerOnce(
      context,
      title: 'Turn on location?',
      reason: 'We use your location to measure the delivery distance and price '
          'it. You can also drop the pin by hand on the map.',
    );
    if (!mounted) return;

    GeoPoint? center;
    final fix = await LocationService.instance.getCurrentPositionDetailed();
    if (fix.success && fix.position != null) {
      center = GeoPoint(fix.position!.latitude, fix.position!.longitude);
    }
    if (!mounted) return;

    final chosen = await WhereToPicker.open(
      context,
      title: 'Where should we deliver?',
      initialCenter: center,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _deliveryLat = chosen.lat;
      _deliveryLng = chosen.lng;
      _deliveryPlaceLabel = chosen.label;
      _deliveryQuote = null;
    });
    await _requoteDelivery();
  }

  /// Asks the SERVER for the fee. One reader, the same one the order is priced
  /// with, so the breakdown below and the amount charged agree by construction.
  Future<void> _requoteDelivery() async {
    final lat = _deliveryLat;
    final lng = _deliveryLng;
    if (lat == null || lng == null) return;
    setState(() => _deliveryQuoting = true);
    final quote = await FeeResolver.instance.deliveryFee(
      providerId: widget.providerId,
      deliveryLat: lat,
      deliveryLng: lng,
      vehicleCategoryId: _deliveryVehicleId,
    );
    if (!mounted) return;
    setState(() {
      _deliveryQuote = quote;
      _deliveryQuoting = false;
    });
  }

  /// "With Delivery" chosen: prompt the vehicle, then the point. Both are
  /// re-runnable from the receipt block below, so changing your mind never
  /// costs the buyer their place.
  Future<void> _startDeliveryFlow() async {
    if (_deliveryFlowRunning) return;
    _deliveryFlowRunning = true;
    try {
      if (_deliveryVehicleId == null) await _chooseVehicleType();
      if (!mounted) return;
      if (_deliveryLat == null || _deliveryLng == null) {
        await _chooseDeliveryPoint();
      }
    } finally {
      _deliveryFlowRunning = false;
    }
  }

  /// The delivery option's receipt: what was chosen, what the server priced,
  /// and the two controls that change it — all in place, so a buyer who
  /// changes their mind never restarts checkout.
  Widget _deliveryReceipt() {
    final quote = _deliveryQuote;
    final hasPoint = _deliveryLat != null && _deliveryLng != null;
    final currency =
        _items.isNotEmpty ? _items.first.currency : 'ETB';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _deliveryVehicleName == null
                      ? 'Choose a delivery vehicle'
                      : '$_deliveryVehicleName delivery',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: _chooseVehicleType,
                child: Text(_deliveryVehicleName == null ? 'Choose' : 'Change'),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  !hasPoint
                      ? 'Set the delivery point on the map'
                      : (_deliveryPlaceLabel ??
                          '${_deliveryLat!.toStringAsFixed(4)}, '
                              '${_deliveryLng!.toStringAsFixed(4)}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _chooseDeliveryPoint,
                child: Text(hasPoint ? 'Change' : 'Set on map'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (_deliveryQuoting)
            const Row(
              children: [
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('Pricing the delivery…',
                    style: TextStyle(fontSize: 12.5)),
              ],
            )
          else if (quote != null && quote.hasValue)
            Text(
              'Distance ${quote.distanceKm?.toStringAsFixed(2) ?? '—'} km · '
              'delivery fee ${quote.fee!.toStringAsFixed(2)} $currency '
              '(ride rate for '
              '${_deliveryVehicleName ?? 'this vehicle'} + platform markup)',
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            )
          else if (quote != null && !quote.ok)
            // The server refused to price it and said why. Shown as the
            // server's own sentence rather than a made-up number — a
            // provider with no published point is a real state, not an
            // error to hide.
            Text(
              quote.message ??
                  'A delivery fee could not be calculated for this order.',
              style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  color: AppTheme.textMuted),
            )
          else if (!hasPoint)
            const Text(
              'Choose a point on the map and the delivery fee is calculated '
              'from the provider\'s location to yours.',
              style: TextStyle(
                  fontSize: 12.5, height: 1.35, color: AppTheme.textMuted),
            ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => setState(() {
              _fulfillmentTouched = true;
              _fulfillmentMode = 'SELF_PICKUP';
            }),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('Remove delivery — I will pick it up',
                style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickScreenshot() async {
    // Downscaled like every other bucket upload in the app. payment-proofs
    // allows 10MB, which hides the problem on most phones but not on a
    // 48MP camera image — the same defect the provider recharge screen had,
    // fixed there first.
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked != null) {
      setState(() => _screenshot = File(picked.path));
    }
  }

  Future<void> _pickNationalId() async {
    // user-documents allows 10MB and takes jpeg/png/webp/pdf, so this one
    // has the same latent refusal as the screenshot above.
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked != null) {
      setState(() => _nationalId = File(picked.path));
    }
  }

  Future<void> _placeOrder() async {
    // Duplicate-tap guard: prevent double-submission within 3 seconds.
    final now = DateTime.now();
    if (_lastOrderTime != null &&
        now.difference(_lastOrderTime!) < const Duration(seconds: 3)) {
      return; // silently ignore rapid re-tap
    }
    _lastOrderTime = now;

    if (_items.isEmpty) {
      setState(() => _error = 'Your cart is empty for this provider');
      return;
    }
    if (_needsNationalId && _nationalId == null) {
      setState(() => _error =
          'Please upload a photo of your National ID to place an order');
      return;
    }

    // Provider readiness: a not-yet-activated provider (one-time registration
    // fee unpaid) or a 0-balance wallet cannot accept the order — the
    // server-side gate in create_order_secure would reject it. Re-check at
    // submission time (a provider may have just recharged), then show the
    // waiting screen instead of submitting an order that would fail; it
    // re-checks the provider and sends the buyer back to browse on timeout.
    await _refreshProviderReadiness();
    if (mounted) setState(() {});
    if (!_providerActivated || !_providerHasBalance) {
      await context.push('/user/order-waiting', extra: {
        'providerId': widget.providerId,
        'providerName': _providerName,
        'providerNotActivated': !_providerActivated,
      });
      if (!mounted) return;
      // Back from waiting: re-check — if the provider is ready now, fall
      // through and place the order; otherwise the user can retry or cancel.
      await _refreshProviderReadiness();
      if (!mounted) return;
      if (!_providerActivated || !_providerHasBalance) return;
    }

    // Part 4: the submit no longer re-checks the PROVIDER's accounts — the
    // buyer pays the platform's account (AdminPaymentDetailsCard), which is
    // configuration rather than something a provider can leave empty, so
    // there is no "nowhere to send money" state left to guard. The server
    // gate (order-create + the availability request claim) is unchanged.

    setState(() {
      _submitting = true;
      _error = null;
    });
    // Once order-create returns, the order EXISTS. Everything after that
    // point is bookkeeping, and none of it is allowed to report failure —
    // the outer catch used to set "Could not place your order" for a thrown
    // clearCart()/invalidate/showDialog, which would tell the user their
    // order failed when it had in fact been created, inviting them to submit
    // again and place a duplicate.
    String? createdOrderId;
    var orderCreated = false;
    try {
      final client = Supabase.instance.client;

      // Send ONLY product_id + quantity — the server computes prices/total.
      // Quantity stays a double: unit-priced lines (kg/liter) are fractional
      // (order_items.quantity is numeric(10,3)); fixed-price lines are whole.
      final noteParts = <String>[
        if (_fulfillmentMode == 'SELF_PICKUP') 'Fulfillment: self-pickup',
        if (_fulfillmentMode == 'DELIVERY' &&
            _addressCtrl.text.trim().isNotEmpty)
          'Delivery: ${_addressCtrl.text.trim()}',
        // Part 10: what the delivery cost and why, on the order itself. The
        // server re-prices it, so this is a record of the answer rather than
        // the number charged.
        if (_fulfillmentMode == 'DELIVERY' && _deliveryFee > 0)
          'Delivery fee: ${_deliveryFee.toStringAsFixed(2)}'
              '${_deliveryVehicleName != null ? ' ($_deliveryVehicleName)' : ''}'
              '${_deliveryQuote?.distanceKm != null ? ', ${_deliveryQuote!.distanceKm} km' : ''}',
        if (_refCtrl.text.trim().isNotEmpty)
          'Payment ref: ${_refCtrl.text.trim()}',
      ];
      final result = await client.functions.invoke('order-create', body: {
        'provider_id': widget.providerId,
        'items': _items
            .map((i) => {'product_id': i.productId, 'quantity': i.quantity})
            .toList(),
        if (noteParts.isNotEmpty) 'note': noteParts.join(' | '),
        'fulfillment_mode': _fulfillmentMode,
        if (_fulfillmentMode == 'DELIVERY')
          'delivery_address': _addressCtrl.text.trim(),
        // The delivery pricing inputs. Coordinates and a vehicle category, NOT
        // a fee: the Edge Function resolves the provider's own point and
        // prices the trip through the same delivery quote this screen showed.
        // Sending a fee from here would be a second pricing rule the client
        // could lie about.
        if (_fulfillmentMode == 'DELIVERY' && _deliveryLat != null)
          'delivery_lat': _deliveryLat,
        if (_fulfillmentMode == 'DELIVERY' && _deliveryLng != null)
          'delivery_lng': _deliveryLng,
        if (_fulfillmentMode == 'DELIVERY' && _deliveryVehicleId != null)
          'vehicle_category_id': _deliveryVehicleId,
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      final order = data['order'] as Map<String, dynamic>?;
      final orderId = order?['id'] as String?;
      createdOrderId = orderId;
      orderCreated = true;
      final orderNumber =
          onf.formatOrderNumber(order?['order_number'] as String?);

      // ID on file → upload it with the same retry as signup (user_documents).
      // Follows the screenshot pattern: the order is already placed, so a
      // failed upload surfaces a message instead of blocking or duplicating
      // the order. The user can retry from their profile / support.
      String? idIssue;
      if (_needsNationalId && _nationalId != null) {
        try {
          await DocumentUploadService.instance.uploadAndRecord(
            file: _nationalId!,
            userId: client.auth.currentUser!.id,
            documentType: 'NATIONAL_ID',
          );
        } catch (_) {
          idIssue =
              'Your order was placed, but the National ID photo could not be '
              'uploaded. Open Profile → Verify Document (or Help & Support) '
              'to retry so your identity can be verified.';
        }
      }

      // Optional payment screenshot → existing 'payment-proofs' bucket,
      // linked to the order in payment_proofs (user-insert RLS allows this).
      String? screenshotIssue;
      if (_screenshot != null && orderId != null) {
        try {
          final userId = client.auth.currentUser!.id;
          final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
          final path = '$userId/$orderId/$fileName';
          await client.storage.from('payment-proofs').upload(path, _screenshot!,
              fileOptions: const FileOptions(upsert: true));
          await client.from('payment_proofs').insert({
            'order_id': orderId,
            'storage_path': path,
          });
        } catch (_) {
          screenshotIssue =
              'Your order was placed, but the payment screenshot could not be attached.';
        }
      }

      // Cart clearing is best-effort for the same reason the uploads above
      // are: it runs after the order exists, so a failure must be reported as
      // a leftover cart, not as a failed order. The user can empty the cart
      // from the cart screen.
      var cartIssue = false;
      try {
        await CartService.instance.clearCart();
        ref.invalidate(cartCountProvider);
      } catch (_) {
        cartIssue = true;
      }

      if (!mounted) return;
      setState(() => _submitting = false);
      final dialogMessage = idIssue ??
          screenshotIssue ??
          (cartIssue
              ? 'Your order has been placed successfully, but your cart could '
                  'not be cleared automatically. Please empty it from the cart.'
              : (orderNumber != null
                  ? 'Order $orderNumber has been placed successfully. '
                      'You can track it in My Orders.'
                  : 'Your order has been placed successfully. You can track it in My Orders.'));
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) => AlertDialog(
          icon: Icon(
              (idIssue != null || screenshotIssue != null)
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle,
              color: (idIssue != null || screenshotIssue != null)
                  ? AppTheme.warning
                  : AppTheme.success,
              size: 44),
          title: const Text('Order placed'),
          content: Text(dialogMessage),
          actions: [
            TextButton(
              onPressed: () {
                dialogCtx.pop();
                if (orderId != null) {
                  context.go('/user/orders/$orderId');
                } else {
                  context.go('/user?tab=1');
                }
              },
              child: const Text('VIEW ORDER'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      if (orderCreated) {
        // The order is real. Say so plainly and send them to it rather than
        // implying it failed — otherwise the obvious next move is to submit
        // again, and that creates a duplicate order.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyError(e,
                context: 'Your order was placed, but we could not finish the last step')),
            backgroundColor: AppTheme.warning,
          ),
        );
        context.go(createdOrderId != null
            ? '/user/orders/$createdOrderId'
            : '/user?tab=1');
        return;
      }
      setState(() {
        // With a reference code, so a buyer whose order failed has something
        // exact to send support instead of a screenshot of a sentence.
        _error = friendlyErrorWithRef(e,
            context: 'Could not place your order', source: 'checkout');
      });
    }
  }

  static String _fmtQty(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _items.isEmpty
              ? const Center(
                  child: Text('Your cart is empty for this provider',
                      style: TextStyle(color: AppTheme.textMuted)))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_error != null)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.error.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(_error!,
                              style: const TextStyle(
                                  fontSize: 13, color: AppTheme.error)),
                        ),
                      const Text('Order Summary',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: Column(
                          children: [
                            for (final item in _items)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(item.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500)),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                        '${_fmtQty(item.quantity)} ${item.unit != null ? item.unitLabel : '×'} '
                                        '${item.price.toStringAsFixed(2)}',
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: AppTheme.textSecondary)),
                                    const SizedBox(width: 12),
                                    Text(item.lineTotal.toStringAsFixed(2),
                                        style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),                            const Divider(height: 20),
                            // No platform-fee row here on purpose: the fee is
                            // charged to the provider, never the buyer, so
                            // the buyer sees product price and (when there is
                            // one) delivery — the total is what they pay.
                            // Part 10: when delivery has been priced, the
                            // breakdown is shown as its two parts — product
                            // price and delivery fee — and the total is their
                            // sum. With self-pickup (or before a delivery has
                            // been priced) there is one line, exactly as
                            // before, so nothing about the ordinary checkout
                            // changed shape.
                            if (_deliveryFee > 0) ...[
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Product price',
                                      style: TextStyle(fontSize: 13)),
                                  Text(
                                    '${_total.toStringAsFixed(2)} '
                                    '${_items.first.currency}',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _deliveryVehicleName == null
                                        ? 'Delivery fee'
                                        : 'Delivery fee (${_deliveryVehicleName})',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  Text(
                                    '${_deliveryFee.toStringAsFixed(2)} '
                                    '${_items.first.currency}',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                              const Divider(height: 20),
                            ],
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Total',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700)),
                                Text(
                                  '${_payableTotal.toStringAsFixed(2)} '
                                  '${_items.first.currency}',
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.primaryGreen),
                                ),
                              ],
                            ),
                            // Item H: the platform commission, rendered OUTSIDE
                            // the totals card because the buyer pays no fee for
                            // it. It is resolved by the same reader
                            // deduct_transaction_fee charges with, so the
                            // number on screen is the number the provider is
                            // charged — one resolver, not two copies.
                            if (_commissionPreview?.hasValue ?? false) ...[
                              const SizedBox(height: 6),
                              Text(
                                'Platform commission on this order: '
                                'ETB ${_commissionPreview!.value!.toStringAsFixed(2)} '
                                '(deducted from the provider — no extra cost to you)',
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    height: 1.35,
                                    color: AppTheme.textMuted),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Phase 4: fulfillment selection (shared flow). The two
                      // options are the same two the server knows (DELIVERY /
                      // SELF_PICKUP); only the words change for a booking, so a
                      // service says where it happens rather than where it is
                      // shipped.
                      Text(
                          _isBookingCart
                              ? 'How will this booking work?'
                              : 'How do you want to get it?',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _FulfillmentCard(
                              icon: Icons.local_shipping_outlined,
                              title: _isBookingCart
                                  ? 'They come to me'
                                  : 'Delivery',
                              subtitle: _isBookingCart
                                  ? 'At the address you give'
                                  : 'Brought to your address',
                              selected: _fulfillmentMode == 'DELIVERY',
                              onTap: () {
                                setState(() {
                                  _fulfillmentTouched = true;
                                  _fulfillmentMode = 'DELIVERY';
                                });
                                // Choosing delivery is what starts the three
                                // steps — vehicle, location, map — so the
                                // buyer is never left with a delivery order
                                // and no fee. Switching BACK to pickup is the
                                // other card, which simply drops the fee out
                                // of the total.
                                _startDeliveryFlow();
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _FulfillmentCard(
                              icon: Icons.store_outlined,
                              title: _isBookingCart
                                  ? 'I go to them'
                                  : 'Self-pickup',
                              subtitle: _isBookingCart
                                  ? 'Pay the listing price only'
                                  : 'Pay product price only',
                              selected: _fulfillmentMode == 'SELF_PICKUP',
                              onTap: () => setState(() {
                                _fulfillmentTouched = true;
                                _fulfillmentMode = 'SELF_PICKUP';
                              }),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_fulfillmentMode == 'DELIVERY') ...[
                        const Text('Delivery Details',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        BirrTextField(
                          label: 'Delivery Address',
                          controller: _addressCtrl,
                          maxLines: 2,
                          hint: 'Street, area, city',
                        ),
                        const SizedBox(height: 12),
                        _deliveryReceipt(),
                        const SizedBox(height: 16),
                      ],
                      if (_fulfillmentMode == 'SELF_PICKUP') ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryGreen.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color:
                                    AppTheme.primaryGreen.withOpacity(0.25)),
                          ),
                          child: Text(
                            _isBookingCart
                                ? 'You pay the listing price only and go to the '
                                    'provider at the time you agree. Their '
                                    'contact details become available after '
                                    'payment approval.'
                                : 'Self-pickup: pay the product price only and '
                                    'collect it from the provider. Their '
                                    'contact details become available after '
                                    'payment approval.',
                            style: const TextStyle(fontSize: 12.5, height: 1.4),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      // ── Payment ──
                      //
                      // Gated behind the provider's availability
                      // confirmation. A listing flagged
                      // requires_availability_confirmation is one where
                      // "in stock" is a claim rather than a fact — a
                      // hotel room, a vehicle for a date, a service slot
                      // — so the buyer is not shown where to pay, or a
                      // way to pay, until the provider has confirmed it
                      // exists for this order. The order is still placed
                      // now; it opens in PENDING_PROVIDER, the provider
                      // confirms from their order screen, and the buyer's
                      // order detail then shows the payment card with the
                      // accounts AND the upload button together.
                      //
                      // That last part used to be false. The card appeared at
                      // ACCEPTED but the upload button did not, because the
                      // button lived on PAYMENT_PENDING and only the
                      // provider could move an order there — so this notice
                      // promised an upload option that the order screen did
                      // not actually have. Migration 85 lets the buyer open
                      // that step themselves on a gated order, which is what
                      // makes the sentence below true.
                      //
                      // Nothing here is a second checkout: the same
                      // order-create call, the same order, the same
                      // payment-proof upload and the same admin
                      // verification — only the moment the payment
                      // section appears is conditional. Listings with
                      // the flag off (every listing today) see exactly
                      // the screen they saw before.
                      if (_needsAvailabilityConfirmation) ...[
                        _AvailabilityNotice(),
                        const SizedBox(height: 20),
                      ]                      else ...[
                        // Part 4: the PLATFORM's account, never the
                        // provider's. The card reads the administrator's
                        // configured details (Admin → Payment Settings →
                        // system_settings.admin_payment_details, through the
                        // whitelisted public_app_settings RPC) with the
                        // platform's Payment Methods rows as fallback, and
                        // says the team will contact the buyer when neither
                        // is configured. It sits directly above the
                        // reference field and the screenshot upload — the
                        // three belong together — and only ever inside the
                        // availability gate, exactly where the provider
                        // card used to render.
                        const AdminPaymentDetailsCard(),
                        const SizedBox(height: 16),
                        BirrTextField(
                          label: 'Payment Reference (optional)',
                          controller: _refCtrl,
                          hint: 'Transaction ID or reference number',
                        ),
                        const SizedBox(height: 16),
                        const Text('Payment Screenshot (optional)',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: _pickScreenshot,
                          child: Container(
                            width: double.infinity,
                            height: _screenshot != null ? 160 : 110,
                            decoration: BoxDecoration(
                              color: AppTheme.creamDark,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppTheme.cardBorder),
                            ),
                            child: _screenshot != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.file(_screenshot!,
                                        fit: BoxFit.cover),
                                  )
                                : const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_a_photo_outlined,
                                          size: 32, color: AppTheme.textMuted),
                                      SizedBox(height: 8),
                                      Text('Tap to upload proof of payment',
                                          style: TextStyle(
                                              fontSize: 13,
                                              color: AppTheme.textMuted)),
                                    ],
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_needsNationalId) ...[
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Expanded(
                              child: Text('National ID (required)',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppTheme.gold.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text('VERIFICATION',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.gold)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                            'First-time verification: we need a photo of your '
                            'National ID to confirm your identity. It is stored '
                            'securely and only visible to our admin team.',
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textMuted)),
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: _pickNationalId,
                          child: Container(
                            width: double.infinity,
                            height: _nationalId != null ? 160 : 110,
                            decoration: BoxDecoration(
                              color: AppTheme.creamDark,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: _nationalId != null
                                      ? AppTheme.primaryGreen
                                      : AppTheme.cardBorder),
                            ),
                            child: _nationalId != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.file(_nationalId!,
                                        fit: BoxFit.cover),
                                  )
                                : const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.badge_outlined,
                                          size: 32, color: AppTheme.textMuted),
                                      SizedBox(height: 8),
                                      Text('Tap to upload your National ID',
                                          style: TextStyle(
                                              fontSize: 13,
                                              color: AppTheme.textMuted)),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        // On a gated listing the press does not pay and does
                        // not claim the booking: it ASKS the provider. So the
                        // button says what it does — "check availability" —
                        // rather than "request order", which reads as a
                        // purchase the buyer has not made yet.
                        child: PrimaryButton(
                          label: _needsAvailabilityConfirmation
                              ? 'CHECK AVAILABILITY'
                              : 'PLACE ORDER',
                          isLoading: _submitting,
                          onPressed: _placeOrder,
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

/// Stands in for the payment section when the cart needs a provider
/// confirmation first.
///
/// Says what is happening and what happens next, because the alternative --
/// silently omitting the payment fields -- reads as a broken screen. The
/// wording deliberately promises nothing about timing: the provider sets it.
class _AvailabilityNotice extends StatelessWidget {
  const _AvailabilityNotice();

  @override
  Widget build(BuildContext context) {
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
          Row(
            children: [
              const Icon(Icons.hourglass_top_rounded,
                  size: 18, color: AppTheme.gold),
              const SizedBox(width: 8),
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
            'This booking is made for a specific date, room or slot, so the '
            'provider has to confirm it is available before you pay. Send the '
            'request now — as soon as they confirm, the payment details and '
            'your upload option appear on the order, and you will be notified.',
            style: TextStyle(fontSize: 12.5, height: 1.45),
          ),
        ],
      ),
    );
  }
}

/// Phase 4: delivery vs self-pickup selection card (shared across the
/// product/service flow).
class _FulfillmentCard extends StatelessWidget {
  const _FulfillmentCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppTheme.primaryGreen.withOpacity(0.08)
          : AppTheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppTheme.primaryGreen : AppTheme.cardBorder,
              width: selected ? 1.4 : 0.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon,
                  size: 20,
                  color:
                      selected ? AppTheme.primaryGreen : AppTheme.textMuted),
              const SizedBox(height: 6),
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? AppTheme.primaryGreen
                          : AppTheme.textPrimary)),
              Text(subtitle,
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
